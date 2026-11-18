import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../studio/edit/exporter.dart';
import '../../studio/edit/photo_edit.dart';
import '../../studio/processing.dart' show resizeRgba;
import 'studio_widgets.dart';
import '../../studio/image_disposal.dart';

/// State of the photo editor: the edit, the rendered preview and helpers.
class PhotoEditorController extends ChangeNotifier {
  PhotoEditorController(this.path);

  final String path;
  PhotoEdit _edit = const PhotoEdit();
  PhotoEdit get edit => _edit;

  RgbaImage? _base; // preview size (≤1440)
  RgbaImage? _small; // while dragging (≤720)
  ui.Image? rendered;
  ui.Image? original;
  bool loading = true;
  String? error;

  /// While the crop panel is open the preview shows the uncropped photo.
  bool _cropMode = false;
  bool get cropMode => _cropMode;

  /// Aspect lock for the crop frame (width / height in pixels), null = free.
  double? cropAspect;

  final lookThumbs = <String, ui.Image>{};
  bool _thumbsRequested = false;

  int _generation = 0;
  bool _rendering = false;
  bool _pending = false;
  bool _pendingInteractive = false;
  bool _disposed = false;

  /// Edited since the last save.
  bool dirty = false;

  int get baseWidth => _base?.width ?? 1;
  int get baseHeight => _base?.height ?? 1;

  Future<void> load() async {
    try {
      final base = await decodeImageFile(path, maxSide: 1440);
      _base = base;
      final s = min(1.0, 720 / max(base.width, base.height));
      _small = s < 1
          ? RgbaImage(
              resizeRgba(
                base.data,
                base.width,
                base.height,
                max(1, (base.width * s).round()),
                max(1, (base.height * s).round()),
              ),
              max(1, (base.width * s).round()),
              max(1, (base.height * s).round()),
            )
          : base;
      original = await toUiImage(base);
      rendered = await toUiImage(base);
    } catch (e) {
      error = 'Could not open the image: $e';
    }
    loading = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void update(PhotoEdit e, {bool interactive = false}) {
    _edit = e;
    dirty = true;
    _schedule(interactive);
    _notify();
  }

  void reset() {
    _edit = const PhotoEdit();
    cropAspect = null;
    dirty = false;
    _schedule(false);
    _notify();
  }

  set cropMode(bool on) {
    if (on == _cropMode) return;
    _cropMode = on;
    _schedule(false);
    _notify();
  }

  void _schedule(bool interactive) {
    _generation++;
    _pending = true;
    _pendingInteractive = interactive;
    if (!_rendering) _renderLoop();
  }

  Future<void> _renderLoop() async {
    _rendering = true;
    while (_pending && !_disposed) {
      _pending = false;
      final gen = _generation;
      final src = _pendingInteractive ? _small : _base;
      if (src == null) break;
      try {
        final out = await renderInBackground(src, _edit, skipCrop: _cropMode);
        if (_disposed) break;
        final image = await toUiImage(out);
        if (_disposed) {
          image.dispose();
          break;
        }
        // Keep showing a newer result if one already arrived.
        if (gen <= _generation) {
          final old = rendered;
          rendered = image;
          if (old != original) disposeImageLater(old);
          _notify();
        }
      } catch (_) {}
    }
    _rendering = false;
  }

  Future<void> ensureLookThumbs() async {
    if (_thumbsRequested || _small == null) return;
    _thumbsRequested = true;
    final src = _small!;
    final s = 160 / max(src.width, src.height);
    final tw = max(1, (src.width * s).round()),
        th = max(1, (src.height * s).round());
    final tiny = RgbaImage(
      resizeRgba(src.data, src.width, src.height, tw, th),
      tw,
      th,
    );
    for (final look in kLooks) {
      final out = await renderInBackground(
        tiny,
        const PhotoEdit().withLook(look),
      );
      if (_disposed) return;
      lookThumbs[look.name] = await toUiImage(out);
      _notify();
    }
  }

  Future<String> save({EditExporter? exporter}) async {
    final out = await (exporter ?? EditExporter()).photo(path, _edit);
    dirty = false;
    _notify();
    return out;
  }

  @override
  void dispose() {
    _disposed = true;
    disposeImageLater(rendered);
    if (original != rendered) disposeImageLater(original);
    for (final t in lookThumbs.values) {
      disposeImageLater(t);
    }
    super.dispose();
  }

  // ------------------------------------------------------------ side bar

  List<SideItem> sideItems() => [
    SideItem(
      id: 'looks',
      icon: Icons.auto_awesome_outlined,
      label: 'Looks',
      active: edit.look != null && edit.look != 'Original',
      panel: (_) => _LooksPanel(this),
    ),
    SideItem(
      id: 'light',
      icon: Icons.light_mode_outlined,
      label: 'Light',
      active:
          edit.exposure != 0 ||
          edit.contrast != 0 ||
          edit.highlights != 0 ||
          edit.shadows != 0 ||
          edit.blacks != 0,
      panel: (_) => LightPanel(
        edit: edit,
        onChanged: (e, i) => update(e, interactive: i),
      ),
    ),
    SideItem(
      id: 'color',
      icon: Icons.palette_outlined,
      label: 'Color',
      active: edit.saturation != 0 || edit.warmth != 0 || edit.tint != 0,
      panel: (_) => ColorPanel(
        edit: edit,
        onChanged: (e, i) => update(e, interactive: i),
      ),
    ),
    SideItem(
      id: 'curve',
      icon: Icons.show_chart,
      label: 'Curve',
      active: edit.hasCurve,
      panel: (_) => CurvePanel(
        edit: edit,
        onChanged: (e, i) => update(e, interactive: i),
      ),
    ),
    SideItem(
      id: 'astro',
      icon: Icons.auto_fix_high_outlined,
      label: 'Astro tools',
      active: edit.hasAstro,
      panel: (_) => _AstroPanel(this),
    ),
    SideItem(
      id: 'crop',
      icon: Icons.crop_rotate,
      label: 'Crop & rotate',
      active: edit.hasGeometry,
      panel: (_) => _CropPanel(this),
    ),
  ];
}

// --------------------------------------------------------------- panels

class _LooksPanel extends StatelessWidget {
  const _LooksPanel(this.c);
  final PhotoEditorController c;

  @override
  Widget build(BuildContext context) {
    c.ensureLookThumbs();
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final look in kLooks)
          GestureDetector(
            onTap: () {
              c.update(c.edit.withLook(look));
              CapsuleScope.collapseSoon(context);
            },
            child: SizedBox(
              width: 76,
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 76,
                    height: 76,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: Colors.white10,
                      border: Border.all(
                        width: 2,
                        color: (c.edit.look ?? 'Original') == look.name
                            ? kStudioAccent
                            : Colors.transparent,
                      ),
                    ),
                    child: c.lookThumbs[look.name] == null
                        ? const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : RawImage(
                            image: c.lookThumbs[look.name],
                            fit: BoxFit.cover,
                          ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    look.name,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Exposure, contrast, highlights, shadows, black point.
class LightPanel extends StatelessWidget {
  const LightPanel({super.key, required this.edit, required this.onChanged});
  final PhotoEdit edit;
  final void Function(PhotoEdit e, bool interactive) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        EditSlider(
          label: 'Exposure',
          value: edit.exposure,
          min: -2,
          max: 2,
          format: (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)} EV',
          onChanged: (v, i) =>
              onChanged(edit.copyWith(exposure: v, clearLook: true), i),
        ),
        EditSlider(
          label: 'Contrast',
          value: edit.contrast,
          onChanged: (v, i) =>
              onChanged(edit.copyWith(contrast: v, clearLook: true), i),
        ),
        EditSlider(
          label: 'Highlights',
          value: edit.highlights,
          onChanged: (v, i) =>
              onChanged(edit.copyWith(highlights: v, clearLook: true), i),
        ),
        EditSlider(
          label: 'Shadows',
          value: edit.shadows,
          onChanged: (v, i) =>
              onChanged(edit.copyWith(shadows: v, clearLook: true), i),
        ),
        EditSlider(
          label: 'Black point',
          value: edit.blacks,
          onChanged: (v, i) =>
              onChanged(edit.copyWith(blacks: v, clearLook: true), i),
        ),
      ],
    );
  }
}

/// Saturation, warmth, tint.
class ColorPanel extends StatelessWidget {
  const ColorPanel({super.key, required this.edit, required this.onChanged});
  final PhotoEdit edit;
  final void Function(PhotoEdit e, bool interactive) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        EditSlider(
          label: 'Saturation',
          value: edit.saturation,
          onChanged: (v, i) =>
              onChanged(edit.copyWith(saturation: v, clearLook: true), i),
        ),
        EditSlider(
          label: 'Warmth',
          value: edit.warmth,
          onChanged: (v, i) =>
              onChanged(edit.copyWith(warmth: v, clearLook: true), i),
        ),
        EditSlider(
          label: 'Tint',
          value: edit.tint,
          onChanged: (v, i) =>
              onChanged(edit.copyWith(tint: v, clearLook: true), i),
        ),
      ],
    );
  }
}

class CurvePanel extends StatelessWidget {
  const CurvePanel({super.key, required this.edit, required this.onChanged});
  final PhotoEdit edit;
  final void Function(PhotoEdit e, bool interactive) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Drag the points. Lower-left = shadows, upper-right = highlights.',
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
        const SizedBox(height: 10),
        AspectRatio(
          aspectRatio: 1,
          child: CurveEditor(
            values: edit.curve,
            onChanged: (v, i) =>
                onChanged(edit.copyWith(curve: v, clearLook: true), i),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: edit.hasCurve
                ? () => onChanged(
                    edit.copyWith(curve: const [0.25, 0.5, 0.75]),
                    false,
                  )
                : null,
            child: const Text('Reset curve'),
          ),
        ),
      ],
    );
  }
}

class _AstroPanel extends StatelessWidget {
  const _AstroPanel(this.c);
  final PhotoEditorController c;

  @override
  Widget build(BuildContext context) {
    final e = c.edit;
    return Column(
      children: [
        EditSlider(
          label: 'Remove light pollution',
          value: e.background,
          min: 0,
          onChanged: (v, i) => c.update(
            e.copyWith(background: v, clearLook: true),
            interactive: i,
          ),
        ),
        EditSlider(
          label: 'Noise reduction',
          value: e.noise,
          min: 0,
          onChanged: (v, i) =>
              c.update(e.copyWith(noise: v, clearLook: true), interactive: i),
        ),
        EditSlider(
          label: 'Star reduction',
          value: e.starReduction,
          min: 0,
          onChanged: (v, i) => c.update(
            e.copyWith(starReduction: v, clearLook: true),
            interactive: i,
          ),
        ),
        EditSlider(
          label: 'Sharpen',
          value: e.sharpen,
          min: 0,
          onChanged: (v, i) =>
              c.update(e.copyWith(sharpen: v, clearLook: true), interactive: i),
        ),
        EditSlider(
          label: 'Clarity',
          value: e.clarity,
          onChanged: (v, i) =>
              c.update(e.copyWith(clarity: v, clearLook: true), interactive: i),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'The live view is a smaller copy, so noise and star sizes look slightly different from the saved photo.',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ),
      ],
    );
  }
}

class _CropPanel extends StatelessWidget {
  const _CropPanel(this.c);
  final PhotoEditorController c;

  static const _aspects = <String, double?>{
    'Free': null,
    'Original': -1,
    '1:1': 1,
    '4:5': 4 / 5,
    '3:2': 3 / 2,
    '16:9': 16 / 9,
    '9:16': 9 / 16,
  };

  /// Largest centred crop with [aspect] (pixels) inside the oriented photo.
  CropRect _cropFor(double aspect) {
    final (ow, oh) = orientedSize(
      c.baseWidth,
      c.baseHeight,
      c.edit.quarterTurns,
    );
    final na = aspect * oh / ow; // normalised width / height
    var w = 1.0, h = 1.0;
    if (na > 1) {
      h = 1 / na;
    } else {
      w = na;
    }
    return CropRect((1 - w) / 2, (1 - h) / 2, (1 + w) / 2, (1 + h) / 2);
  }

  @override
  Widget build(BuildContext context) {
    final e = c.edit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final entry in _aspects.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: OptionChip(
                    collapse: false,
                    label: entry.key,
                    selected: c.cropAspect == entry.value,
                    onTap: () {
                      c.cropAspect = entry.value;
                      if (entry.value == null) {
                        c.update(e);
                      } else {
                        final (ow, oh) = orientedSize(
                          c.baseWidth,
                          c.baseHeight,
                          e.quarterTurns,
                        );
                        c.update(
                          e.copyWith(
                            crop: _cropFor(
                              entry.value! < 0 ? ow / oh : entry.value!,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => c.update(
                  e.copyWith(
                    quarterTurns: (e.quarterTurns + 1) % 4,
                    crop: CropRect.full,
                  ),
                ),
                icon: const Icon(Icons.rotate_90_degrees_cw_outlined, size: 18),
                label: const Text('Rotate'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => c.update(e.copyWith(flip: !e.flip)),
                icon: const Icon(Icons.flip, size: 18),
                label: const Text('Flip'),
              ),
            ),
            IconButton(
              tooltip: 'Reset crop & rotation',
              onPressed: e.hasGeometry
                  ? () {
                      c.cropAspect = null;
                      c.update(
                        e.copyWith(
                          quarterTurns: 0,
                          flip: false,
                          straighten: 0,
                          crop: CropRect.full,
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
        EditSlider(
          label: 'Straighten',
          value: e.straighten,
          min: -15,
          max: 15,
          format: (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}°',
          onChanged: (v, i) =>
              c.update(e.copyWith(straighten: v), interactive: i),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------ curve editor

class CurveEditor extends StatefulWidget {
  const CurveEditor({super.key, required this.values, required this.onChanged});
  final List<double> values;
  final void Function(List<double> values, bool interactive) onChanged;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor> {
  int? _drag;

  void _update(Offset local, Size size, bool interactive) {
    final i = _drag;
    if (i == null) return;
    final v = List<double>.of(widget.values);
    v[i] = (1 - local.dy / size.height).clamp(0.0, 1.0);
    widget.onChanged(v, interactive);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          onPanStart: (d) {
            final x = d.localPosition.dx / size.width;
            var best = 0;
            for (var i = 1; i < 3; i++) {
              if ((x - (i + 1) * 0.25).abs() < (x - (best + 1) * 0.25).abs()) {
                best = i;
              }
            }
            _drag = best;
            _update(d.localPosition, size, true);
          },
          onPanUpdate: (d) => _update(d.localPosition, size, true),
          onPanEnd: (_) {
            widget.onChanged(widget.values, false);
            _drag = null;
          },
          child: CustomPaint(size: size, painter: _CurvePainter(widget.values)),
        );
      },
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.values);
  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(12),
    );
    canvas.drawRRect(r, Paint()..color = Colors.black26);
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(
        Offset(size.width * i / 4, 0),
        Offset(size.width * i / 4, size.height),
        grid,
      );
      canvas.drawLine(
        Offset(0, size.height * i / 4),
        Offset(size.width, size.height * i / 4),
        grid,
      );
    }
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, 0),
      Paint()..color = Colors.white24,
    );
    final lut = curveLut(values);
    final path = Path();
    for (var i = 0; i < 256; i++) {
      final p = Offset(size.width * i / 255, size.height * (1 - lut[i]));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = kStudioAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    for (var i = 0; i < 3; i++) {
      final p = Offset(size.width * (i + 1) / 4, size.height * (1 - values[i]));
      canvas.drawCircle(p, 8, Paint()..color = Colors.black);
      canvas.drawCircle(p, 6, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) => old.values != values;
}

// ------------------------------------------------------------------ canvas

/// The edited photo, zoomable, with hold-to-compare and the crop frame.
class PhotoEditorCanvas extends StatefulWidget {
  const PhotoEditorCanvas({super.key, required this.controller});
  final PhotoEditorController controller;

  @override
  State<PhotoEditorCanvas> createState() => _PhotoEditorCanvasState();
}

class _PhotoEditorCanvasState extends State<PhotoEditorCanvas> {
  bool _comparing = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c.loading) return const Center(child: CircularProgressIndicator());
    if (c.error != null) {
      return Center(child: Text(c.error!, textAlign: TextAlign.center));
    }
    final image = _comparing ? c.original : c.rendered;
    if (image == null) return const SizedBox.shrink();

    if (c.cropMode) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final fitted = applyBoxFit(
            BoxFit.contain,
            Size(image.width.toDouble(), image.height.toDouble()),
            constraints.biggest,
          );
          final rect = Alignment.center.inscribe(
            fitted.destination,
            Offset.zero & constraints.biggest,
          );
          return Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: RawImage(image: image, fit: BoxFit.fill),
              ),
              Positioned.fromRect(
                rect: rect,
                child: CropFrame(
                  crop: c.edit.crop,
                  aspect: c.cropAspect == null
                      ? null
                      : (c.cropAspect! < 0
                            ? 1.0
                            : c.cropAspect! * image.height / image.width),
                  onChanged: (crop, interactive) => c.update(
                    c.edit.copyWith(crop: crop),
                    interactive: interactive,
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          maxScale: 10,
          child: Center(
            child: RawImage(image: image, fit: BoxFit.contain),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: GestureDetector(
            onTapDown: (_) => setState(() => _comparing = true),
            onTapUp: (_) => setState(() => _comparing = false),
            onTapCancel: () => setState(() => _comparing = false),
            child: Glass(
              radius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.compare,
                    size: 16,
                    color: _comparing ? kStudioAccent : Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _comparing ? 'Before' : 'Hold to compare',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Draggable crop rectangle in normalised coordinates of its parent.
/// [aspect] = locked normalised width / height, or null for free.
class CropFrame extends StatefulWidget {
  const CropFrame({
    super.key,
    required this.crop,
    required this.onChanged,
    this.aspect,
  });
  final CropRect crop;
  final double? aspect;
  final void Function(CropRect crop, bool interactive) onChanged;

  @override
  State<CropFrame> createState() => _CropFrameState();
}

class _CropFrameState extends State<CropFrame> {
  int _handle = -1; // 0 tl, 1 tr, 2 br, 3 bl, 4 move
  late CropRect _start;
  Offset _startPos = Offset.zero;

  static const _minSize = 0.08;

  void _begin(Offset p, Size size) {
    final c = widget.crop;
    final corners = [
      Offset(c.left * size.width, c.top * size.height),
      Offset(c.right * size.width, c.top * size.height),
      Offset(c.right * size.width, c.bottom * size.height),
      Offset(c.left * size.width, c.bottom * size.height),
    ];
    _handle = 4;
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - p).distance < 36) _handle = i;
    }
    _start = c;
    _startPos = p;
  }

  void _move(Offset p, Size size, bool interactive) {
    final dx = (p.dx - _startPos.dx) / size.width,
        dy = (p.dy - _startPos.dy) / size.height;
    final s = _start;
    double l = s.left, t = s.top, r = s.right, b = s.bottom;
    if (_handle == 4) {
      final mx = dx.clamp(-l, 1 - r), my = dy.clamp(-t, 1 - b);
      l += mx;
      r += mx;
      t += my;
      b += my;
    } else {
      if (_handle == 0 || _handle == 3) l = (l + dx).clamp(0.0, r - _minSize);
      if (_handle == 1 || _handle == 2) r = (r + dx).clamp(l + _minSize, 1.0);
      if (_handle == 0 || _handle == 1) t = (t + dy).clamp(0.0, b - _minSize);
      if (_handle == 2 || _handle == 3) b = (b + dy).clamp(t + _minSize, 1.0);
      final a = widget.aspect;
      if (a != null) {
        // Keep the ratio: height follows width, anchored at the opposite edge.
        var h = (r - l) / a;
        final top = _handle == 2 || _handle == 3;
        if (top) {
          if (t + h > 1) {
            h = 1 - t;
          }
        } else if (b - h < 0) {
          h = b;
        }
        final w = h * a;
        if (_handle == 0 || _handle == 3) {
          l = r - w;
        } else {
          r = l + w;
        }
        if (top) {
          b = t + h;
        } else {
          t = b - h;
        }
      }
    }
    widget.onChanged(CropRect(l, t, r, b), interactive);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _begin(d.localPosition, size),
          onPanUpdate: (d) => _move(d.localPosition, size, true),
          onPanEnd: (_) => widget.onChanged(widget.crop, false),
          child: CustomPaint(size: size, painter: _CropPainter(widget.crop)),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.crop);
  final CropRect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(
      shade,
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );
    final line = Paint()
      ..color = Colors.white38
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(r.left + r.width * i / 3, r.top),
        Offset(r.left + r.width * i / 3, r.bottom),
        line,
      );
      canvas.drawLine(
        Offset(r.left, r.top + r.height * i / 3),
        Offset(r.right, r.top + r.height * i / 3),
        line,
      );
    }
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final corner = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const k = 18.0;
    for (final (p, sx, sy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomRight, -1.0, -1.0),
      (r.bottomLeft, 1.0, -1.0),
    ]) {
      canvas.drawLine(p, p + Offset(k * sx, 0), corner);
      canvas.drawLine(p, p + Offset(0, k * sy), corner);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.crop != crop;
}
