import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../ui/tokens.dart';

import '../../studio/edit/exporter.dart';
import '../../studio/frame_sources.dart';
import '../../studio/processing.dart';
import '../../studio/studio_engine.dart';
import '../../storage/gallery_sync.dart';
import 'mask_painter_screen.dart';
import 'photo_editor.dart';
import 'studio_widgets.dart';
import 'video_editor.dart';

enum _Phase { setup, running, result }

enum _ResultView { image, video }

/// Star trails, timelapse and stacking: pick photos, tune options in the
/// side bar, watch the result build up live, then edit and save it.
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key, this.initialResult, this.initialPaths = const []});

  /// Opens straight into the editor (used by tests).
  @visibleForTesting
  final StudioResult? initialResult;

  /// Starts with these photos chosen (used by tests).
  @visibleForTesting
  final List<String> initialPaths;

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  static const _toolOrder = [StudioTool.stack, StudioTool.starTrails, StudioTool.timelapse];
  static const _toolItems = [
    ToolBarItem(Icons.layers_outlined, 'Stack'),
    ToolBarItem(Icons.blur_circular, 'Star trails'),
    ToolBarItem(Icons.movie_outlined, 'Timelapse'),
  ];

  StudioTool _tool = StudioTool.stack;
  final _paths = <String>[];
  int _previewIndex = 0;

  // Options
  bool _growingVideo = false;
  int _fps = 30;
  int _videoLongSide = 1920;
  bool _align = true;
  bool _reject = true;
  bool _splitForeground = false;
  ForegroundMask? _mask;
  bool _fast = false;

  _Phase _phase = _Phase.setup;
  String? _openItem;

  StudioEngine? _engine;
  StudioResult? _result;
  PhotoEditorController? _photo;
  VideoEditorController? _video;
  _ResultView _view = _ResultView.image;

  /// Sequence preview in setup (plays the chosen photos).
  FramePlayback? _setupPlayer;

  EditExporter? _exporter;
  String _exportStage = '';
  double _exportFraction = 0;

  bool get _exporting => _exporter != null;

  @override
  void initState() {
    super.initState();
    final r = widget.initialResult;
    _paths.addAll(widget.initialPaths);
    if (r != null) WidgetsBinding.instance.addPostFrameCallback((_) => _showResult(r));
    // Drop app copies of photos that were deleted from the gallery.
    if (r == null) unawaited(GallerySync.sync());
  }

  @override
  void dispose() {
    _engine?.cancel();
    _engine?.dispose();
    _exporter?.cancel();
    _disposeResult(now: true);
    _setupPlayer?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  /// Frees the result. Unless [now], the editors are disposed only after the
  /// canvas has faded out, since the old canvas still listens to them.
  void _disposeResult({bool now = false}) {
    final photo = _photo, video = _video;
    video?.playback.pause();
    if (now) {
      photo?.dispose();
      video?.dispose();
    } else if (photo != null || video != null) {
      Timer(const Duration(milliseconds: 700), () {
        photo?.dispose();
        video?.dispose();
      });
    }
    _photo = null;
    _video = null;
    _result?.cleanUp();
    _result = null;
  }

  // ------------------------------------------------------------- photos

  Future<void> _addFromValometer() async {
    await GallerySync.sync();
    final sequences = await loadValometerSequences();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<FrameSequence>(
      context: context,
      showDragHandle: true,
      builder: (_) => _SequenceSheet(sequences: sequences),
    );
    if (chosen != null) {
      setState(() {
        _paths
          ..clear()
          ..addAll(chosen.paths);
        _mask = null;
        _previewIndex = 0;
        _resetSetupPlayer();
      });
    }
  }

  Future<void> _addFromGallery() async {
    final picked = await pickFromGallery();
    if (picked.isEmpty) return;
    setState(() {
      for (final p in picked) {
        if (!_paths.contains(p)) _paths.add(p);
      }
      _resetSetupPlayer();
    });
  }

  void _removePhoto(int i) {
    setState(() {
      _paths.removeAt(i);
      if (i == 0) _mask = null;
      _previewIndex = _previewIndex.clamp(0, _paths.isEmpty ? 0 : _paths.length - 1);
      _resetSetupPlayer();
    });
  }

  void _clearPhotos() {
    setState(() {
      _paths.clear();
      _mask = null;
      _previewIndex = 0;
      _resetSetupPlayer();
    });
  }

  void _resetSetupPlayer() {
    _setupPlayer?.dispose();
    _setupPlayer = null;
  }

  void _toggleSetupPlay() {
    if (_paths.length < 2) return;
    final p = _setupPlayer ??= FramePlayback(length: _paths.length, fps: _tool == StudioTool.timelapse ? _fps : 12)
      ..addListener(() {
        if (mounted) setState(() => _previewIndex = _setupPlayer!.position);
      });
    p.playing ? p.pause() : p.play();
    setState(() {});
  }

  Future<void> _openPhotosSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => _PhotosSheet(
          paths: _paths,
          onRemove: (i) {
            _removePhoto(i);
            setSheet(() {});
          },
          onClear: () {
            _clearPhotos();
            Navigator.pop(context);
          },
          onGallery: () async {
            Navigator.pop(context);
            await _addFromGallery();
          },
          onSequence: () async {
            Navigator.pop(context);
            await _addFromValometer();
          },
        ),
      ),
    );
  }

  Future<void> _paintMask() async {
    if (_paths.isEmpty) return;
    final mask = await Navigator.of(context).push<ForegroundMask>(
      MaterialPageRoute(
        builder: (_) => MaskPainterScreen(imagePath: _paths.first, initial: _mask),
      ),
    );
    if (mask != null) {
      setState(() {
        _mask = mask;
        _splitForeground = mask.coverage > 0;
      });
    }
  }

  // ------------------------------------------------------------- run

  String? get _problem {
    if (_paths.length < 2) return _paths.isEmpty ? null : 'Add at least 2 photos';
    if (_tool == StudioTool.stack && _paths.length > kMaxStackFrames) {
      return 'Stack up to $kMaxStackFrames photos at a time';
    }
    if (_tool == StudioTool.stack && _align && _splitForeground && (_mask == null || _mask!.coverage == 0)) {
      return 'Paint the foreground, or turn off "Keep foreground sharp"';
    }
    return null;
  }

  Future<void> _start() async {
    _setupPlayer?.pause();
    final useMask = _tool == StudioTool.stack && _align && _splitForeground && _mask != null;
    final options = StudioOptions(
      tool: _tool,
      growingVideo: _growingVideo,
      fps: _fps,
      videoLongSide: _videoLongSide,
      align: _align,
      rejectOutliers: _reject,
      foregroundMask: useMask ? _mask!.data : null,
      maskWidth: useMask ? _mask!.width : 0,
      maskHeight: useMask ? _mask!.height : 0,
      fastSize: _fast,
    );
    final engine = StudioEngine();
    setState(() {
      _disposeResult();
      _engine = engine;
      _phase = _Phase.running;
      _openItem = null;
    });
    WakelockPlus.enable();
    try {
      final r = await engine.run(List.of(_paths), options);
      if (!mounted) {
        r.cleanUp();
        return;
      }
      _showResult(r);
    } on StudioCancelled {
      _backToSetup('Stopped. Nothing was saved.');
    } on StudioFailure catch (e) {
      _backToSetup(e.message, error: true);
    } catch (e) {
      _backToSetup('Something went wrong: $e', error: true);
    } finally {
      WakelockPlus.disable();
      engine.dispose();
      if (_engine == engine) _engine = null;
    }
  }

  void _showResult(StudioResult r) {
    final photo = r.imagePath == null ? null : (PhotoEditorController(r.imagePath!)..load());
    final video = r.videoPath == null || r.videoFrames.length < 2
        ? null
        : VideoEditorController(
            frames: r.videoFrames,
            videoPath: r.videoPath!,
            width: r.videoWidth,
            height: r.videoHeight,
            fps: r.fps,
          );
    setState(() {
      _result = r;
      _photo = photo;
      _video = video;
      _view = photo != null ? _ResultView.image : _ResultView.video;
      _phase = _Phase.result;
      _openItem = null;
    });
    _exported = false;
    _snack('Ready. Edit it if you like, then tap Export to save it to $_where.');
  }

  void _backToSetup(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() => _phase = _Phase.setup);
    if (error) {
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Couldn\'t finish'),
          content: Text(message),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
        ),
      );
    } else {
      _snack(message);
    }
  }

  Future<bool> _confirm(String title, String body, String ok) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _stop() async {
    if (await _confirm('Stop processing?', 'Nothing will be saved.', 'Stop')) _engine?.cancel();
  }

  bool get _unsavedEdits => (_photo?.dirty ?? false) || (_video?.dirty ?? false);

  /// The result was exported (and not edited since).
  bool _exported = false;

  /// There is a result that isn't in the gallery in its current form.
  bool get _unsaved => _phase == _Phase.result && (!_exported || _unsavedEdits);

  static String get _where => Platform.isIOS ? 'Photos' : 'your gallery';

  Future<bool> _confirmDiscard() => _confirm(
    'Discard this result?',
    _exported ? 'Your latest edits haven\'t been exported.' : 'It hasn\'t been exported to $_where yet.',
    'Discard',
  );

  Future<void> _newRun({StudioTool? tool}) async {
    if (_unsaved && !await _confirmDiscard()) return;
    setState(() {
      _disposeResult();
      _phase = _Phase.setup;
      _openItem = null;
      if (tool != null) _tool = tool;
    });
  }

  // ------------------------------------------------------------- save

  /// Saves the (edited) image and video to the gallery.
  Future<void> _export() async {
    final r = _result;
    if (r == null) return;
    final exporter = EditExporter();
    setState(() {
      _exporter = exporter;
      _exportStage = 'Exporting…';
      _exportFraction = 0;
      _openItem = null;
    });
    _syncCropMode();
    WakelockPlus.enable();
    void progress(String stage, double f) {
      if (mounted) {
        setState(() {
          _exportStage = stage;
          _exportFraction = f;
        });
      }
    }

    try {
      final photo = _photo;
      if (photo != null) {
        progress(photo.edit.isIdentity ? 'Saving photo…' : 'Rendering full-resolution photo…', 0);
        await photo.save(exporter: exporter);
      }
      final video = _video;
      if (video != null) {
        await video.save(exporter: exporter, onProgress: progress);
      } else if (r.videoPath != null) {
        progress('Saving video…', 0);
        await exporter.copyVideo(r.videoPath!);
      }
      _exported = true;
      final what = [if (r.imagePath != null) 'Image', if (r.videoPath != null) 'video'].join(' and ');
      _snack('${what[0].toUpperCase()}${what.substring(1)} exported to $_where.');
    } on ExportCancelled {
      _snack('Export cancelled.');
    } catch (e) {
      _snack('Couldn\'t export: $e');
    } finally {
      WakelockPlus.disable();
      if (mounted) setState(() => _exporter = null);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.paddingOf(context).bottom + 96),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  // ------------------------------------------------------------- side bar

  List<SideItem> _sideItems() {
    switch (_phase) {
      case _Phase.running:
        return const [];
      case _Phase.result:
        if (_view == _ResultView.image) return _photo?.sideItems() ?? const [];
        return _video?.sideItems() ?? const [];
      case _Phase.setup:
        return _setupItems();
    }
  }

  List<SideItem> _setupItems() {
    SideItem quality() => SideItem(
      id: 'quality',
      icon: Icons.speed,
      label: 'Processing size',
      active: _fast,
      panel: (_) => Column(
        children: [
          Wrap(
            spacing: 6,
            children: [
              OptionChip(label: 'Full resolution', selected: !_fast, onTap: () => setState(() => _fast = false)),
              OptionChip(label: 'Fast (3 MP)', selected: _fast, onTap: () => setState(() => _fast = true)),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Full keeps every pixel of your photos (a 48 MP shot stays 48 MP). '
            'Fast works at 3 MP: about 4× quicker and uses much less memory.',
            style: TextStyle(fontSize: 12, color: V.textDim),
          ),
        ],
      ),
    );

    SideItem video({required String id, required String label}) => SideItem(
      id: id,
      icon: Icons.video_settings,
      label: label,
      active: _fps != 30 || _videoLongSide != 1920,
      panel: (_) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Frame rate', style: TextStyle(fontSize: 12, color: V.textDim)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final f in const [24, 30, 60])
                OptionChip(label: '$f fps', selected: _fps == f, onTap: () => setState(() => _fps = f)),
            ],
          ),
          const SizedBox(height: 14),
          const Text('Resolution', style: TextStyle(fontSize: 12, color: V.textDim)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              OptionChip(
                label: 'Full HD',
                selected: _videoLongSide == 1920,
                onTap: () => setState(() => _videoLongSide = 1920),
              ),
              OptionChip(
                label: '4K',
                selected: _videoLongSide == 3840,
                onTap: () => setState(() => _videoLongSide = 3840),
              ),
            ],
          ),
          if (_paths.length >= 2) ...[
            const SizedBox(height: 12),
            Text(
              '${_paths.length} frames → ${(_paths.length / _fps).toStringAsFixed(1)} s of video',
              style: const TextStyle(fontSize: 12, color: V.textDim),
            ),
          ],
        ],
      ),
    );

    switch (_tool) {
      case StudioTool.stack:
        return [
          SideItem(
            id: 'align',
            icon: Icons.track_changes,
            label: 'Align stars',
            active: _align,
            panel: (_) => OptionSwitch(
              title: 'Align stars',
              subtitle: 'Follows the sky\'s rotation so stars stay sharp. Turn off only for a few short frames.',
              value: _align,
              onChanged: (v) => setState(() => _align = v),
            ),
          ),
          SideItem(
            id: 'reject',
            icon: Icons.satellite_alt_outlined,
            label: 'Remove planes & satellites',
            active: _reject,
            panel: (_) => OptionSwitch(
              title: 'Remove planes & satellites',
              subtitle: 'Ignores pixels that stand out in only a few frames. Takes about twice as long.',
              value: _reject,
              onChanged: (v) => setState(() => _reject = v),
            ),
          ),
          SideItem(
            id: 'foreground',
            icon: Icons.landscape_outlined,
            label: 'Keep foreground sharp',
            active: _splitForeground && _align,
            panel: (_) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OptionSwitch(
                  title: 'Keep foreground sharp',
                  subtitle: _align
                      ? 'Paint the ground: the sky is aligned, the ground stays still.'
                      : 'Only needed when aligning stars.',
                  value: _splitForeground && _align,
                  onChanged: _align
                      ? (v) {
                          setState(() => _splitForeground = v);
                          if (v && _mask == null) _paintMask();
                        }
                      : null,
                ),
                if (_splitForeground && _align)
                  Row(
                    children: [
                      Icon(
                        _mask == null ? Icons.warning_amber : Icons.check,
                        size: 16,
                        color: _mask == null ? V.amber : kStudioAccent,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _mask == null ? 'Nothing painted yet' : 'Foreground: ${(_mask!.coverage * 100).round()}%',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: _paths.isEmpty ? null : _paintMask,
                        child: Text(_mask == null ? 'Paint' : 'Edit'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          quality(),
        ];
      case StudioTool.starTrails:
        return [
          SideItem(
            id: 'growing',
            icon: Icons.movie_filter_outlined,
            label: 'Growing-trails video',
            active: _growingVideo,
            panel: (_) => OptionSwitch(
              title: 'Growing-trails video',
              subtitle: 'Also make a video where the trails build up frame by frame.',
              value: _growingVideo,
              onChanged: (v) => setState(() => _growingVideo = v),
            ),
          ),
          if (_growingVideo) video(id: 'trailvideo', label: 'Video settings'),
          quality(),
        ];
      case StudioTool.timelapse:
        return [video(id: 'video', label: 'Video settings')];
    }
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final listen = Listenable.merge([?_photo, ?_video]);
    return Scaffold(
      backgroundColor: kStudioBg,
      body: ListenableBuilder(
        listenable: listen,
        // Inside the builder so "unsaved edits" is always current.
        builder: (context, _) => PopScope(
          canPop: _phase != _Phase.running && !_exporting && !_unsaved,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            if (_phase == _Phase.running) {
              _stop();
            } else if (_exporting) {
              _exporter?.cancel();
            } else if (_unsaved && await _confirmDiscard() && context.mounted) {
              _photo?.dirty = false;
              _video?.dirty = false;
              _exported = true;
              Navigator.of(context).pop();
            }
          },
          child: _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    final items = _sideItems();
    if (_openItem != null && !items.any((i) => i.id == _openItem)) _openItem = null;
    final topInset = pad.top + 64;
    final bottomInset = pad.bottom + 96;
    // While editing, the open capsule drops to the bottom and the photo
    // shrinks above it, so every change stays visible.
    final docked = _phase == _Phase.result && _openItem != null;
    final available = size.height - topInset - bottomInset;
    // Tall enough for the whole icon column (6 × 50 + padding).
    final dockHeight = (available * 0.46).clamp(316.0, 340.0);
    final panelWidth = (size.width - 24 - 56 - 16).clamp(200.0, 320.0);

    return Stack(
      children: [
        const Positioned.fill(child: StarfieldBackground()),
        // Main canvas, full width; the capsule floats over it.
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          left: 12,
          right: 12,
          top: topInset,
          bottom: docked ? bottomInset + dockHeight + 8 : bottomInset,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: KeyedSubtree(key: ValueKey('$_phase$_view${_paths.isEmpty}'), child: _canvas()),
          ),
        ),
        Positioned(left: 12, right: 12, top: pad.top + 8, child: _topBar()),
        // While the capsule is open, a tap anywhere else just closes it.
        if (_openItem != null && !docked)
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closeCapsule),
          ),
        if (items.isNotEmpty)
          Positioned(
            left: 12,
            right: 12,
            top: topInset,
            bottom: bottomInset,
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: docked ? Alignment.bottomLeft : Alignment.centerLeft,
              child: ExpandingCapsule(
                items: items,
                openId: _openItem,
                onTap: _onSideTap,
                onCollapse: _closeCapsule,
                panelWidth: panelWidth,
                maxHeight: docked ? dockHeight : available,
              ),
            ),
          ),
        if (_phase == _Phase.setup && _problem != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset - 2,
            child: Center(
              child: Glass(
                radius: 14,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(_problem!, style: const TextStyle(fontSize: 12, color: V.amber)),
              ),
            ),
          ),
        Positioned(left: 12, right: 12, bottom: pad.bottom + 12, child: _toolSwitcher()),
        if (_exporting) _exportOverlay(),
      ],
    );
  }

  void _onSideTap(String id) {
    // A message bar would sit on top of the opened controls.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _openItem = _openItem == id ? null : id);
    _syncCropMode();
  }

  void _closeCapsule() {
    if (_openItem == null || !mounted) return;
    setState(() => _openItem = null);
    _syncCropMode();
  }

  void _syncCropMode() {
    final p = _photo;
    if (p != null) p.cropMode = _phase == _Phase.result && _view == _ResultView.image && _openItem == 'crop';
  }

  // ------------------------------------------------------------- top bar

  Widget _topBar() {
    final subtitle = switch (_phase) {
      _Phase.setup => switch (_tool) {
        StudioTool.stack => 'Stack · less noise, more stars',
        StudioTool.starTrails => 'Star trails · draw the sky\'s motion',
        StudioTool.timelapse => 'Timelapse · turn photos into video',
      },
      _Phase.running => 'Working…',
      _Phase.result => _view == _ResultView.image ? 'Edit image' : 'Edit video',
    };
    final Widget action = switch (_phase) {
      _Phase.setup => ActionPill(
        key: const ValueKey('process'),
        label: 'Process',
        icon: Icons.play_arrow_rounded,
        onPressed: _paths.length >= 2 && _problem == null ? _start : null,
      ),
      _Phase.running => ActionPill(
        key: const ValueKey('stop'),
        label: 'Stop',
        icon: Icons.stop_rounded,
        danger: true,
        onPressed: _stop,
      ),
      _Phase.result => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ActionPill(
            key: const ValueKey('export'),
            label: 'Export',
            icon: Icons.ios_share_rounded,
            busy: _exporting,
            onPressed: _exporting ? null : _export,
          ),
          const SizedBox(width: 6),
          _moreMenu(),
        ],
      ),
    };
    return Row(
      children: [
        GlassIconButton(
          icon: Icons.arrow_back_ios_new_rounded,
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ShaderMask(
                shaderCallback: (r) => kStudioGradient.createShader(r),
                child: const Text(
                  'Studio',
                  maxLines: 1,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: Colors.white),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  subtitle,
                  key: ValueKey(subtitle),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: V.textDim),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: action),
      ],
    );
  }

  Widget _moreMenu() {
    return Glass(
      radius: 22,
      child: SizedBox(
        width: 44,
        height: 44,
        child: PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert, size: 20),
          enabled: !_exporting,
          onSelected: (v) {
            switch (v) {
              case 'reset':
                _view == _ResultView.image ? _photo?.reset() : _video?.reset();
              case 'details':
                _showNotes();
              case 'new':
                _newRun();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'reset',
              enabled: !(_photo?.edit.isIdentity ?? true) || (_video?.dirty ?? false),
              child: const ListTile(leading: Icon(Icons.restart_alt), title: Text('Reset edits'), dense: true),
            ),
            const PopupMenuItem(
              value: 'details',
              child: ListTile(leading: Icon(Icons.info_outline), title: Text('Details'), dense: true),
            ),
            const PopupMenuItem(
              value: 'new',
              child: ListTile(
                leading: Icon(Icons.add_photo_alternate_outlined),
                title: Text('Start over'),
                dense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showNotes() {
    final r = _result;
    if (r == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text('${r.framesUsed} photos used', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'The original ${[if (r.imagePath != null) 'image', if (r.videoPath != null) 'video'].join(' and ')} '
              '${_exported ? 'was exported to' : 'is not in'} ${Platform.isIOS ? 'Photos' : 'your gallery (Valometer album)'}'
              '${_exported ? '' : ' yet'}. Export saves it with your edits; each export adds a new copy.',
              style: const TextStyle(color: V.textDim, fontSize: 13),
            ),
            for (final n in r.notes)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('• $n', style: const TextStyle(color: V.textDim, fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _toolSwitcher() {
    return ToolSwitcher(
      items: _toolItems,
      selected: _toolOrder.indexOf(_tool),
      onSelect: _phase == _Phase.running || _exporting
          ? null
          : (i) {
              final tool = _toolOrder[i];
              if (tool == _tool && _phase != _Phase.result) return;
              if (_phase == _Phase.result) {
                _newRun(tool: tool);
              } else {
                setState(() {
                  _tool = tool;
                  _openItem = null;
                  // Playback speed depends on the tool.
                  _resetSetupPlayer();
                });
              }
            },
    );
  }

  // ------------------------------------------------------------- canvas

  Widget _canvas() {
    switch (_phase) {
      case _Phase.setup:
        return _paths.isEmpty ? _emptyCanvas() : _setupCanvas();
      case _Phase.running:
        return _runningCanvas();
      case _Phase.result:
        return _resultCanvas();
    }
  }

  /// Width kept free on each side for the floating capsule, so centred
  /// content stays centred on the screen instead of shifting right.
  static const _rail = 64.0;

  Widget _emptyCanvas() {
    final (title, body) = switch (_tool) {
      StudioTool.stack => ('Stack', 'Average many photos of the same sky to cut noise and bring out faint stars.'),
      StudioTool.starTrails => ('Star trails', 'Blend a sequence so each star draws its path across the sky.'),
      StudioTool.timelapse => ('Timelapse', 'Turn a sequence into a smooth video of the night.'),
    };
    final icon = _toolItems[_toolOrder.indexOf(_tool)].icon;
    final hero = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 168,
          height: 168,
          child: CustomPaint(
            painter: const _OrbitPainter(),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Container(
                  key: ValueKey(icon),
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [kStudioAccent.withValues(alpha: 0.30), kStudioViolet.withValues(alpha: 0.22)],
                    ),
                    border: Border.all(color: Colors.white24),
                    boxShadow: [BoxShadow(color: kStudioAccent.withValues(alpha: 0.35), blurRadius: 34)],
                  ),
                  child: Icon(icon, size: 32, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Column(
            key: ValueKey(title),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, height: 1.4, color: V.textDim),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final sources = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Container(height: 1, color: Colors.white10)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('CHOOSE PHOTOS', style: TextStyle(fontSize: 11, letterSpacing: 1.8, color: V.textFaint)),
            ),
            Expanded(child: Container(height: 1, color: Colors.white10)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _SourceTile(
                icon: Icons.burst_mode_outlined,
                title: 'Sequence',
                subtitle: 'Shot in Valometer',
                onTap: _addFromValometer,
                primary: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SourceTile(
                icon: Icons.photo_library_outlined,
                title: 'Gallery',
                subtitle: 'Pick photos',
                onTap: _addFromGallery,
              ),
            ),
          ],
        ),
      ],
    );
    // Hero in the upper part (inset equally on both sides, so it is centred
    // on the screen), photo sources full width at the bottom, below the
    // capsule.
    return LayoutBuilder(
      builder: (context, c) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: _rail),
                    child: hero,
                  ),
                  const Spacer(flex: 2),
                  const SizedBox(height: 16),
                  sources,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _setupCanvas() {
    final index = _previewIndex.clamp(0, _paths.length - 1);
    final playing = _setupPlayer?.playing ?? false;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 24)],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.file(File(_paths[index]), fit: BoxFit.contain, cacheWidth: 1080, gaplessPlayback: true),
                ),
              ),
              // Count (opens the photo list) top-left, play top-right and the
              // position centred at the bottom: balanced around the photo.
              Positioned(
                left: 8,
                top: 8,
                child: Glass(
                  radius: 18,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: _openPhotosSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.photo_library_outlined, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            '${_paths.length} photos',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_paths.length >= 2)
                Positioned(
                  right: 8,
                  top: 8,
                  child: GlassIconButton(
                    size: 38,
                    tooltip: playing ? 'Pause' : 'Play the sequence',
                    icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    onPressed: _toggleSetupPlay,
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: Center(
                  child: Glass(
                    radius: 12,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Text(
                      index == 0 ? 'Reference · 1 / ${_paths.length}' : '${index + 1} / ${_paths.length}',
                      style: const TextStyle(fontSize: 11, color: V.textDim),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 52,
          // Centred while the strip is shorter than the screen.
          child: Center(
            child: ListView.separated(
              shrinkWrap: true,
              scrollDirection: Axis.horizontal,
              itemCount: _paths.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                if (i == _paths.length) {
                  return GestureDetector(
                    onTap: _openPhotosSheet,
                    child: Container(
                      width: 52,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.white.withValues(alpha: 0.05),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Icon(Icons.add, color: V.textDim),
                    ),
                  );
                }
                return GestureDetector(
                  onTap: () {
                    _setupPlayer?.pause();
                    setState(() => _previewIndex = i);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 52,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(width: 2, color: i == index ? kStudioAccent : Colors.transparent),
                    ),
                    child: Image.file(File(_paths[i]), fit: BoxFit.cover, cacheWidth: 104),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _runningCanvas() {
    final engine = _engine;
    if (engine == null) return const SizedBox.shrink();
    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: ValueListenableBuilder(
              valueListenable: engine.preview,
              builder: (_, image, _) => image != null
                  ? RawImage(image: image, fit: BoxFit.contain)
                  : ValueListenableBuilder<String?>(
                      valueListenable: engine.previewPath,
                      builder: (_, path, _) => path == null
                          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                          : Image.file(File(path), fit: BoxFit.contain, cacheWidth: 1080, gaplessPlayback: true),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Glass(
          radius: 22,
          padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
          child: ValueListenableBuilder<StudioProgress>(
            valueListenable: engine.progress,
            builder: (_, p, _) => Row(
              children: [
                SizedBox(
                  width: 46,
                  height: 46,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: p.fraction,
                          strokeWidth: 3.5,
                          color: kStudioAccent,
                          backgroundColor: Colors.white12,
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                      if (p.fraction != null)
                        Text(
                          '${(p.fraction! * 100).round()}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.stage, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500), maxLines: 2),
                      const SizedBox(height: 3),
                      const Text(
                        'Keep Valometer open. The screen stays on until it finishes.',
                        style: TextStyle(fontSize: 11, color: V.textFaint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _resultCanvas() {
    final both = _photo != null && _video != null;
    Widget body;
    if (_view == _ResultView.image && _photo != null) {
      body = PhotoEditorCanvas(controller: _photo!);
    } else if (_video != null) {
      body = VideoEditorCanvas(controller: _video!);
    } else {
      body = const Center(child: Text('Nothing to show.'));
    }
    if (!both) return body;
    return Column(
      children: [
        Glass(
          radius: 18,
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (v, label, icon) in [
                (_ResultView.image, 'Image', Icons.image_outlined),
                (_ResultView.video, 'Video', Icons.movie_outlined),
              ])
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _view = v;
                      _openItem = null;
                    });
                    _video?.playback.pause();
                    _syncCropMode();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: _view == v
                          ? LinearGradient(
                              colors: [kStudioAccent.withValues(alpha: 0.3), kStudioViolet.withValues(alpha: 0.2)],
                            )
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(icon, size: 16, color: _view == v ? Colors.white : V.textDim),
                        const SizedBox(width: 6),
                        Text(label, style: TextStyle(fontSize: 12, color: _view == v ? Colors.white : V.textDim)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: body),
      ],
    );
  }

  Widget _exportOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Glass(
              radius: 24,
              opacity: 0.9,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Exporting', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(_exportStage, style: const TextStyle(fontSize: 13, color: V.textDim)),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _view == _ResultView.video && _exportFraction > 0 ? _exportFraction : null,
                    minHeight: 4,
                    color: kStudioAccent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: () => _exporter?.cancel(), child: const Text('Cancel')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Faint orbit rings with small "planets" behind the empty-state icon.
class _OrbitPainter extends CustomPainter {
  const _OrbitPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final (r, a) in const [(44.0, 0.22), (60.0, 0.14), (74.0, 0.08)]) {
      ring.color = kStudioAccent.withValues(alpha: a);
      canvas.drawCircle(c, r, ring);
    }
    final dot = Paint();
    for (final (r, angle, s, color) in const [
      (60.0, -0.6, 3.0, kStudioAccent),
      (74.0, 2.3, 2.2, kStudioViolet),
      (44.0, 3.9, 2.0, V.textDim),
    ]) {
      dot.color = color;
      canvas.drawCircle(c + Offset(cos(angle) * r, sin(angle) * r), s, dot);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 20,
      highlight: primary,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: primary ? kStudioGradient : null,
                  color: primary ? null : Colors.white.withValues(alpha: 0.08),
                ),
                child: Icon(icon, size: 20, color: primary ? V.onIon : V.text),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: V.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ sheets

class _PhotosSheet extends StatelessWidget {
  const _PhotosSheet({
    required this.paths,
    required this.onRemove,
    required this.onClear,
    required this.onGallery,
    required this.onSequence,
  });

  final List<String> paths;
  final ValueChanged<int> onRemove;
  final VoidCallback onClear;
  final VoidCallback onGallery;
  final VoidCallback onSequence;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Text('${paths.length} photos', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(onPressed: paths.isEmpty ? null : onClear, child: const Text('Clear all')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onSequence,
                      icon: const Icon(Icons.burst_mode_outlined, size: 18),
                      label: const Text('Sequence'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onGallery,
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('Add more'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 96,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemCount: paths.length,
                itemBuilder: (_, i) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(paths[i]), fit: BoxFit.cover, cacheWidth: 192),
                    ),
                    Positioned(
                      right: 2,
                      top: 2,
                      child: GestureDetector(
                        onTap: () => onRemove(i),
                        child: const CircleAvatar(
                          radius: 11,
                          backgroundColor: Colors.black54,
                          child: Icon(Icons.close, size: 13),
                        ),
                      ),
                    ),
                    if (i == 0)
                      const Positioned(
                        left: 4,
                        bottom: 4,
                        child: Text(
                          'REF',
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kStudioAccent),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Sorted by time taken. The first photo is the reference for alignment.',
                style: TextStyle(fontSize: 11, color: V.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SequenceSheet extends StatelessWidget {
  const _SequenceSheet({required this.sequences});
  final List<FrameSequence> sequences;

  static String _when(DateTime t) =>
      '${t.day}/${t.month}/${t.year}  ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (sequences.isEmpty) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No sequences yet. Shoot a few photos in Interval mode and they\'ll appear here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Valometer sequences', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          for (final s in sequences)
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(s.paths.first), width: 52, height: 52, fit: BoxFit.cover, cacheWidth: 104),
              ),
              title: Text('${s.length} photos'),
              subtitle: Text('${_when(s.start)} · ${s.duration.inMinutes} min'),
              onTap: () => Navigator.pop(context, s),
            ),
        ],
      ),
    );
  }
}
