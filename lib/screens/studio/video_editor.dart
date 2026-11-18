import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../studio/edit/exporter.dart';
import '../../studio/edit/photo_edit.dart';
import '../../studio/edit/video_edit.dart';
import 'photo_editor.dart' show LightPanel, ColorPanel, CurvePanel;
import 'studio_widgets.dart';
import '../../studio/image_disposal.dart';

/// Plays a list of frames (for previews and the video editor).
class FramePlayback extends ChangeNotifier {
  FramePlayback({required this.length, required int fps}) {
    _fps = fps;
  }

  int length;
  late int _fps;
  int position = 0;
  Timer? _timer;
  bool get playing => _timer != null;

  set fps(int v) {
    _fps = v;
    if (playing) {
      pause();
      play();
    }
  }

  void play() {
    if (length < 2) return;
    _timer?.cancel();
    _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ _fps), (_) {
      position = (position + 1) % length;
      notifyListeners();
    });
    notifyListeners();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  void seek(int i) {
    position = i.clamp(0, length - 1);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class VideoEditorController extends ChangeNotifier {
  VideoEditorController({
    required this.frames,
    required this.videoPath,
    required this.width,
    required this.height,
    required int fps,
  })  : _edit = VideoEdit(trimStart: 0, trimEnd: frames.length - 1, fps: fps),
        originalFps = fps {
    playback = FramePlayback(length: frames.length, fps: fps)..addListener(_onTick);
  }

  final List<String> frames;
  final String videoPath;
  final int width;
  final int height;
  final int originalFps;
  late final FramePlayback playback;

  VideoEdit _edit;
  VideoEdit get edit => _edit;
  List<int> _order = const [];
  List<int> get order => _order.isEmpty ? (_order = _edit.frameOrder()) : _order;

  List<double>? means;
  List<double>? _gains;
  double analyzing = -1; // 0..1 while measuring brightness
  bool dirty = false;
  bool _disposed = false;

  /// Exact render of the paused frame (null while playing).
  ui.Image? still;
  int _stillGen = 0;

  int get currentFrame => order[playback.position.clamp(0, order.length - 1)];
  double get currentGain => _gains == null ? 1 : _gains![currentFrame];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onTick() {
    if (playback.playing) {
      _clearStill();
    } else {
      _renderStill();
    }
    _notify();
  }

  void _clearStill() {
    _stillGen++;
    disposeImageLater(still);
    still = null;
  }

  Future<void> _renderStill() async {
    final gen = ++_stillGen;
    final tone = _edit.tone.toneOnly;
    final gain = currentGain;
    if (tone.isIdentity && gain == 1) {
      disposeImageLater(still);
      still = null;
      return;
    }
    final src = await decodeImageFile(frames[currentFrame], maxSide: 1080);
    final out = await renderInBackground(src, tone);
    if (gain != 1) applyTone(out, const PhotoEdit(), gain: gain);
    final image = await toUiImage(out);
    if (_disposed || gen != _stillGen) {
      image.dispose();
      return;
    }
    disposeImageLater(still);
    still = image;
    _notify();
  }

  void update(VideoEdit e, {bool interactive = false}) {
    final orderChanged = e.trimStart != _edit.trimStart || e.trimEnd != _edit.trimEnd || e.loop != _edit.loop;
    final fpsChanged = e.fps != _edit.fps;
    _edit = e;
    dirty = true;
    if (orderChanged) {
      _order = e.frameOrder();
      playback.length = _order.length;
      playback.seek(playback.position.clamp(0, _order.length - 1));
    }
    if (fpsChanged) playback.fps = e.fps;
    if (e.deflicker > 0 && means == null && analyzing < 0) _analyze();
    _gains = means == null ? null : deflickerGains(means!, e.deflicker);
    if (!playback.playing && !interactive) _renderStill();
    if (interactive) _clearStill();
    _notify();
  }

  Future<void> _analyze() async {
    analyzing = 0;
    _notify();
    final m = await meanLuminances(frames, onProgress: (done) {
      analyzing = done / frames.length;
      _notify();
    });
    if (_disposed) return;
    means = m;
    analyzing = -1;
    _gains = deflickerGains(m, _edit.deflicker);
    if (!playback.playing) _renderStill();
    _notify();
  }

  void reset() {
    _edit = VideoEdit(trimStart: 0, trimEnd: frames.length - 1, fps: originalFps);
    _order = _edit.frameOrder();
    playback.length = _order.length;
    playback.fps = originalFps;
    _gains = null;
    dirty = false;
    _clearStill();
    _notify();
  }

  /// Exports the video: re-encoded with the edits, or copied as is.
  Future<String> save({required void Function(String stage, double fraction) onProgress, required EditExporter exporter}) async {
    final out = dirty
        ? await exporter.video(
            frames: frames,
            edit: _edit,
            width: width,
            height: height,
            outPath: await EditExporter.exportPath(videoPath, 'mp4'),
            means: means,
            onProgress: onProgress,
          )
        : await exporter.copyVideo(videoPath);
    dirty = false;
    _notify();
    return out;
  }

  @override
  void dispose() {
    _disposed = true;
    playback.dispose();
    disposeImageLater(still);
    super.dispose();
  }

  List<SideItem> sideItems() => [
        SideItem(
          id: 'trim',
          icon: Icons.content_cut,
          label: 'Trim',
          active: _edit.trimStart > 0 || _edit.trimEnd < frames.length - 1,
          panel: (_) => _TrimPanel(this),
        ),
        SideItem(
          id: 'speed',
          icon: Icons.speed,
          label: 'Speed & loop',
          active: _edit.fps != originalFps || _edit.loop != LoopMode.off,
          panel: (_) => _SpeedPanel(this),
        ),
        SideItem(
          id: 'vlooks',
          icon: Icons.auto_awesome_outlined,
          label: 'Looks',
          active: _edit.tone.look != null && _edit.tone.look != 'Original',
          panel: (_) => _VideoLooksPanel(this),
        ),
        SideItem(
          id: 'vlight',
          icon: Icons.light_mode_outlined,
          label: 'Light',
          active: _edit.tone.exposure != 0 || _edit.tone.contrast != 0 || _edit.tone.highlights != 0 || _edit.tone.shadows != 0 || _edit.tone.blacks != 0,
          panel: (_) => LightPanel(edit: _edit.tone, onChanged: (t, i) => update(_edit.copyWith(tone: t), interactive: i)),
        ),
        SideItem(
          id: 'vcolor',
          icon: Icons.palette_outlined,
          label: 'Color',
          active: _edit.tone.saturation != 0 || _edit.tone.warmth != 0 || _edit.tone.tint != 0,
          panel: (_) => ColorPanel(edit: _edit.tone, onChanged: (t, i) => update(_edit.copyWith(tone: t), interactive: i)),
        ),
        SideItem(
          id: 'vcurve',
          icon: Icons.show_chart,
          label: 'Curve',
          active: _edit.tone.hasCurve,
          panel: (_) => CurvePanel(edit: _edit.tone, onChanged: (t, i) => update(_edit.copyWith(tone: t), interactive: i)),
        ),
        SideItem(
          id: 'deflicker',
          icon: Icons.flare,
          label: 'Deflicker',
          active: _edit.deflicker > 0,
          panel: (_) => _DeflickerPanel(this),
        ),
      ];
}

String _secs(double s) => s < 60 ? '${s.toStringAsFixed(1)} s' : '${s ~/ 60} min ${(s % 60).round()} s';

class _TrimPanel extends StatelessWidget {
  const _TrimPanel(this.c);
  final VideoEditorController c;

  @override
  Widget build(BuildContext context) {
    final e = c.edit;
    final last = c.frames.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Frames ${e.trimStart + 1} – ${e.trimEnd + 1} of ${c.frames.length}',
            style: const TextStyle(fontSize: 13)),
        RangeSlider(
          values: RangeValues(e.trimStart.toDouble(), e.trimEnd.toDouble()),
          min: 0,
          max: last.toDouble(),
          divisions: last > 0 ? last : null,
          onChanged: (r) {
            final s = r.start.round(), en = r.end.round();
            if (en - s < 1) return;
            c.update(e.copyWith(trimStart: s, trimEnd: en), interactive: true);
            c.playback.seek(s == e.trimStart ? c.order.length - 1 : 0);
          },
          onChangeEnd: (_) => c.update(c.edit),
        ),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                final f = c.currentFrame;
                if (f < e.trimEnd) c.update(e.copyWith(trimStart: f));
              },
              child: const Text('Start here'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                final f = c.currentFrame;
                if (f > e.trimStart) c.update(e.copyWith(trimEnd: f));
              },
              child: const Text('End here'),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Video length: ${_secs(e.durationSeconds())}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ],
    );
  }
}

class _SpeedPanel extends StatelessWidget {
  const _SpeedPanel(this.c);
  final VideoEditorController c;

  @override
  Widget build(BuildContext context) {
    final e = c.edit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Frame rate', style: TextStyle(fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final f in const [12, 15, 24, 30, 48, 60])
            OptionChip(label: '$f fps', selected: e.fps == f, onTap: () => c.update(e.copyWith(fps: f))),
        ]),
        const SizedBox(height: 14),
        const Text('Loop', style: TextStyle(fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          OptionChip(label: 'Off', selected: e.loop == LoopMode.off, onTap: () => c.update(e.copyWith(loop: LoopMode.off))),
          OptionChip(
              label: 'Ping-pong', selected: e.loop == LoopMode.pingPong, onTap: () => c.update(e.copyWith(loop: LoopMode.pingPong))),
        ]),
        const SizedBox(height: 8),
        const Text('Ping-pong plays forward then backward, so the video loops smoothly.',
            style: TextStyle(fontSize: 11, color: Colors.white38)),
        const SizedBox(height: 8),
        Text('Video length: ${_secs(e.durationSeconds())}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ],
    );
  }
}

class _VideoLooksPanel extends StatelessWidget {
  const _VideoLooksPanel(this.c);
  final VideoEditorController c;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final look in kLooks)
            OptionChip(
              label: look.name,
              selected: (c.edit.tone.look ?? 'Original') == look.name,
              onTap: () => c.update(c.edit.copyWith(tone: const PhotoEdit().withLook(look).toneOnly)),
            ),
        ]),
        const SizedBox(height: 8),
        const Text('Video looks use light, colour and curve only (no astro tools).',
            style: TextStyle(fontSize: 11, color: Colors.white38)),
      ],
    );
  }
}

class _DeflickerPanel extends StatelessWidget {
  const _DeflickerPanel(this.c);
  final VideoEditorController c;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Smooths sudden brightness jumps between frames while keeping slow changes like dusk.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
        EditSlider(
          label: 'Strength',
          value: c.edit.deflicker,
          min: 0,
          onChanged: (v, i) => c.update(c.edit.copyWith(deflicker: v), interactive: i),
        ),
        if (c.analyzing >= 0) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(value: c.analyzing, minHeight: 3),
          const SizedBox(height: 4),
          const Text('Measuring brightness of each frame…', style: TextStyle(fontSize: 11, color: Colors.white54)),
        ] else if (c.means != null && c.edit.deflicker > 0)
          SizedBox(height: 60, child: CustomPaint(painter: _FlickerPainter(c.means!, deflickerGains(c.means!, c.edit.deflicker)))),
      ],
    );
  }
}

class _FlickerPainter extends CustomPainter {
  _FlickerPainter(this.means, this.gains);
  final List<double> means;
  final List<double> gains;

  @override
  void paint(Canvas canvas, Size size) {
    if (means.length < 2) return;
    final all = [...means, for (var i = 0; i < means.length; i++) means[i] * gains[i]];
    final lo = all.reduce((a, b) => a < b ? a : b), hi = all.reduce((a, b) => a > b ? a : b);
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    Path line(double Function(int) v) {
      final p = Path();
      for (var i = 0; i < means.length; i++) {
        final o = Offset(size.width * i / (means.length - 1), size.height * (1 - (v(i) - lo) / span));
        i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      return p;
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(line((i) => means[i]), stroke..color = Colors.white30);
    canvas.drawPath(line((i) => means[i] * gains[i]), stroke..color = kStudioAccent);
  }

  @override
  bool shouldRepaint(covariant _FlickerPainter old) => true;
}

/// Video preview with transport controls.
class VideoEditorCanvas extends StatelessWidget {
  const VideoEditorCanvas({super.key, required this.controller});
  final VideoEditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.playback]),
      builder: (context, _) {
        final frame = c.currentFrame;
        Widget view;
        if (!c.playback.playing && c.still != null) {
          view = RawImage(image: c.still, fit: BoxFit.contain);
        } else {
          view = Image.file(File(c.frames[frame]), fit: BoxFit.contain, cacheWidth: 1080, gaplessPlayback: true);
          final tone = c.edit.tone.toneOnly;
          if (!tone.isIdentity || c.currentGain != 1) {
            view = ColorFiltered(colorFilter: ColorFilter.matrix(approximateColorMatrix(tone, gain: c.currentGain)), child: view);
          }
        }
        final total = c.order.length;
        return Column(
          children: [
            Expanded(child: Center(child: view)),
            const SizedBox(height: 8),
            Glass(
              radius: 20,
              padding: const EdgeInsets.fromLTRB(4, 2, 14, 2),
              child: Row(children: [
                IconButton(
                  icon: Icon(c.playback.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: () => c.playback.playing ? c.playback.pause() : c.playback.play(),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                    child: Slider(
                      value: c.playback.position.clamp(0, total - 1).toDouble(),
                      max: (total - 1).clamp(1, 1 << 30).toDouble(),
                      onChanged: (v) {
                        c.playback.pause();
                        c.playback.seek(v.round());
                      },
                    ),
                  ),
                ),
                Text(
                  '${_secs(c.playback.position / c.edit.fps)} / ${_secs(c.edit.durationSeconds())}',
                  style: const TextStyle(fontSize: 11, color: Colors.white60, fontFeatures: [ui.FontFeature.tabularFigures()]),
                ),
              ]),
            ),
          ],
        );
      },
    );
  }
}
