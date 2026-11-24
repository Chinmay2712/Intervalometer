import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:valometer_camera/valometer_camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../auth/auth_service.dart';
import '../intervalometer.dart';
import '../widgets/account_sheet.dart';
import '../storage/gallery_sync.dart';
import '../theme.dart';
import '../ui/scale_dial.dart';
import '../ui/tokens.dart';
import '../utils/exposure.dart';
import '../utils/histogram.dart';
import '../widgets/exposure_calculator_sheet.dart';
import '../widgets/format_sheet.dart';
import '../widgets/histogram_view.dart';
import '../widgets/interval_sheet.dart';
import 'review_screen.dart';
import 'sky_screen.dart';
import 'studio/studio_screen.dart';

enum _Control { iso, shutter, wb, focus, lens }

enum _Mode { single, interval }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final ValometerCamera _cam = ValometerCamera.instance;

  CameraCapabilities? _caps;
  String? _error;
  bool _opening = false;
  String? _lensId;

  // Manual settings (kept across lens switches and app restarts of the camera).
  bool _autoExposure = true;
  double _iso = 1600;
  double _shutter = 1;
  bool _autoWb = true;
  double _kelvin = 4000;
  bool _autoFocus = true;
  double _focus = 1.0; // 1 = infinity
  FormatChoice _output = const FormatChoice(PhotoFormat.jpeg);

  /// Setting whose bottom drawer is open (null = none).
  _Control? _active;

  /// Bumped on every setState so open drawers rebuild with the new values.
  final ValueNotifier<int> _rev = ValueNotifier(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _rev.value++;
  }
  _Mode _mode = _Mode.single;
  IntervalSettings _interval = const IntervalSettings();
  late final Intervalometer _seq = Intervalometer(shoot: _shootOnce)..addListener(_onSequenceChanged);

  bool _capturing = false;
  DateTime? _captureStart;
  Timer? _ticker;
  int _flashCount = 0;

  // Focus helpers
  final TransformationController _zoomCtrl = TransformationController();
  static const _zoomSteps = [1.0, 3.0, 6.0, 10.0];
  double _zoom = 1;
  Size _previewSize = Size.zero;
  CaptureResult? _lastShot;
  Histogram? _histogram;
  bool _showHistogram = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadOutput().whenComplete(() async {
      await _open();
      unawaited(GallerySync.sync());
    });
  }

  static const _formatKey = 'photo_format';
  static const _alsoRawKey = 'photo_also_raw';

  Future<void> _loadOutput() async {
    try {
      final p = await SharedPreferences.getInstance();
      final f = PhotoFormat.fromName(p.getString(_formatKey) ?? '') ?? PhotoFormat.jpeg;
      _output = FormatChoice(f, alsoRaw: p.getBool(_alsoRawKey) ?? false);
    } catch (_) {}
  }

  Future<void> _pickFormat() async {
    final caps = _caps;
    if (caps == null) return;
    final next = await showFormatSheet(context, initial: _output, caps: caps);
    if (next == null || !mounted) return;
    setState(() => _output = next.fitTo(caps));
    final p = await SharedPreferences.getInstance();
    await p.setString(_formatKey, _output.format.name);
    await p.setBool(_alsoRawKey, _output.alsoRaw);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _seq.dispose();
    _zoomCtrl.dispose();
    _rev.dispose();
    WakelockPlus.disable();
    _cam.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Phones don't allow camera use in the background.
      if (_seq.isRunning) _seq.stop();
      _cam.close();
      setState(() => _caps = null);
    } else if (state == AppLifecycleState.resumed && _caps == null) {
      // The user may have deleted photos in the gallery meanwhile.
      _open().whenComplete(() => unawaited(GallerySync.sync()));
    }
  }

  // ---------------------------------------------------------------- camera

  Future<void> _open() async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final caps = await _cam.open(lensId: _lensId);
      if (!mounted) return;
      _caps = caps;
      _lensId = caps.activeLensId;
      _iso = _iso.clamp(caps.minIso, caps.maxIso);
      _shutter = _shutter.clamp(caps.minShutter, caps.maxShutter);
      _kelvin = _kelvin.clamp(caps.minKelvin, caps.maxKelvin);
      _output = _output.fitTo(caps);
      await _applyExposure();
      await _applyWhiteBalance();
      await _applyFocus();
    } on PlatformException catch (e) {
      _error = e.message ?? e.code;
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } on PlatformException catch (e) {
      _toast(e.message ?? e.code);
    }
  }

  Future<void> _applyExposure() => _safe(() => _cam.setExposure(
        auto: _autoExposure || !(_caps?.supportsManualExposure ?? false),
        iso: _iso,
        shutterSeconds: _shutter,
      ));

  Future<void> _applyWhiteBalance() => _safe(() => _cam.setWhiteBalance(
        auto: _autoWb || !(_caps?.supportsManualWhiteBalance ?? false),
        kelvin: _kelvin,
      ));

  Future<void> _applyFocus() => _safe(() => _cam.setFocus(
        auto: _autoFocus || !(_caps?.supportsManualFocus ?? false),
        position: _focus,
      ));

  Future<void> _switchLens(String id) async {
    if (id == _lensId || _seq.isRunning) return;
    _lensId = id;
    _setZoom(1);
    await _cam.close();
    setState(() => _caps = null);
    await _open();
  }

  // --------------------------------------------------------------- capture

  /// One photo. Used by the shutter button and by the intervalometer.
  Future<void> _shootOnce() async {
    setState(() {
      _capturing = true;
      _captureStart = DateTime.now();
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    try {
      final shot = await _cam.capture(format: _output.format, raw: _output.savesRaw);
      unawaited(GallerySync.recordCapture(shot));
      if (mounted) {
        setState(() {
          _flashCount++;
          _lastShot = shot;
        });
      }
      final jpeg = shot.jpegPath;
      if (jpeg != null) {
        unawaited(Histogram.fromFile(jpeg).then((h) {
          if (mounted && _lastShot == shot) setState(() => _histogram = h);
        }));
      }
    } finally {
      _ticker?.cancel();
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _onShutterPressed() async {
    if (_caps == null) return;
    HapticFeedback.mediumImpact();
    if (_mode == _Mode.interval) {
      if (_seq.isRunning) {
        _seq.stop();
      } else {
        WakelockPlus.enable();
        unawaited(_seq.start(_interval));
      }
      return;
    }
    if (_capturing) return;
    try {
      await _shootOnce();
      _toast(_output.format == PhotoFormat.dng
          ? 'Saved RAW'
          : 'Saved ${_output.format.label}${_output.savesRaw ? ' + RAW' : ''}');
    } on PlatformException catch (e) {
      _toast(e.message ?? e.code);
    }
  }

  void _onSequenceChanged() {
    if (!_seq.isRunning) WakelockPlus.disable();
    switch (_seq.phase) {
      case SequencePhase.done:
        _toast('Sequence finished: ${_seq.shotsTaken} photos');
      case SequencePhase.failed:
        _toast('Sequence stopped after errors: ${_seq.lastError}');
      case SequencePhase.stopped:
        _toast('Sequence stopped: ${_seq.shotsTaken} photos');
      default:
        break;
    }
    if (mounted) setState(() {});
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }

  // ---------------------------------------------------------- focus helpers

  /// Digital magnifier on the live view (centre). Pinch to zoom/pan too.
  void _setZoom(double z) {
    final w = _previewSize.width, h = _previewSize.height;
    _zoomCtrl.value = Matrix4.diagonal3Values(z, z, 1)
      ..setTranslationRaw(-(z - 1) * w / 2, -(z - 1) * h / 2, 0);
    setState(() => _zoom = z);
  }

  void _cycleZoom() {
    final i = _zoomSteps.indexWhere((z) => z > _zoom + 0.01);
    _setZoom(i < 0 ? 1 : _zoomSteps[i]);
  }

  Future<void> _openCalculator() async {
    final caps = _caps;
    if (caps == null) return;
    final seconds = await showExposureCalculator(context, caps);
    if (seconds == null || !mounted) return;
    setState(() {
      _autoExposure = false;
      _shutter = seconds;
    });
    await _applyExposure();
  }

  void _openReview() {
    final jpeg = _lastShot?.jpegPath;
    if (jpeg == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReviewScreen(
        path: jpeg,
        histogram: _histogram,
        savedAs: [
          if (_lastShot?.photoPath case final p?) p.split('.').last.toUpperCase().replaceAll('TIF', 'TIFF'),
          if (_lastShot?.rawPath != null) 'DNG',
        ],
      ),
    ));
  }

  /// Last photo; tap to review it full-screen at up to 12x zoom.
  Widget _thumbnail() {
    final jpeg = _lastShot?.jpegPath;
    return GestureDetector(
      onTap: jpeg == null ? null : _openReview,
      child: Container(
        width: 52,
        height: 52,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(V.rSmall + 2),
          border: Border.all(color: const Color(0x40FFFFFF)),
          color: V.surface.withValues(alpha: 0.7),
        ),
        child: jpeg == null
            ? const Icon(Icons.photo_outlined, size: 22, color: V.textFaint)
            : Image.file(File(jpeg), fit: BoxFit.cover, cacheWidth: 132, gaplessPlayback: true),
      ),
    );
  }

  Widget _overlayButton({required String label, required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: V.surface.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(V.rSmall),
        side: const BorderSide(color: V.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(V.rSmall),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 6),
                Text(label, style: V.readout(14, weight: FontWeight.w400)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // the viewfinder stays true black
      body: Stack(
        fit: StackFit.expand,
        children: [
          _previewArea(),
          Positioned(left: 0, top: 0, right: 0, child: _topOverlay()),
          Positioned(left: 0, right: 0, bottom: 0, child: _bottomOverlay()),
        ],
      ),
    );
  }

  /// Title bar, pro-mode icons and (optionally) the histogram, over the preview.
  Widget _topOverlay() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _topBar(),
            _controlRow(),
            if (_showHistogram && _histogram != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: SizedBox(
                  width: 150,
                  child: IgnorePointer(
                    child: HudPanel(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(height: 50, child: HistogramView(histogram: _histogram!, showRgb: false)),
                            const SizedBox(height: 4),
                            Text(_histogram!.astroAdvice, style: const TextStyle(fontSize: 11, color: V.textDim)),
                          ],
                        ),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final caps = _caps;
    final info = <String>[
      if (caps?.aperture != null) 'f/${caps!.aperture!.toStringAsFixed(2)}',
      if (caps?.focalLength != null) '${caps!.focalLength!.toStringAsFixed(1)}mm',
      if (caps != null) 'max ${formatShutter(caps.maxShutter)}',
    ].join(' · ');
    // 44 pt icons: Apple's minimum touch target, and they still fit on a
    // 360-wide phone next to the title.
    const dense = VisualDensity(horizontal: -1, vertical: -1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('INTERVALOMETER',
                      maxLines: 1,
                      style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 3.2, fontSize: 16, color: V.text)),
                ),
                const SizedBox(height: 2),
                Text(info,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: V.readout(12, color: V.textDim, weight: FontWeight.w400)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Studio (stack, star trails, timelapse)',
            visualDensity: dense,
            icon: const Icon(Icons.auto_awesome_motion_outlined),
            onPressed: _seq.isRunning
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const StudioScreen()),
                    ),
          ),
          IconButton(
            tooltip: 'Sky conditions (moon, twilight, clouds)',
            visualDensity: dense,
            icon: const Icon(Icons.nights_stay_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SkyScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Star-trail calculator (500 / NPF)',
            visualDensity: dense,
            icon: const Icon(Icons.calculate_outlined),
            onPressed: _caps == null ? null : _openCalculator,
          ),
          IconButton(
            tooltip: 'Histogram of last photo',
            visualDensity: dense,
            icon: Icon(_showHistogram ? Icons.bar_chart : Icons.bar_chart_outlined),
            color: _showHistogram ? V.ion : null,
            isSelected: _showHistogram,
            onPressed: () => setState(() => _showHistogram = !_showHistogram),
          ),
          if (AuthService.instance.enabled)
            IconButton(
              tooltip: 'Account',
              visualDensity: dense,
              icon: Icon(AuthService.instance.isSignedIn ? Icons.account_circle : Icons.account_circle_outlined),
              onPressed: () => showAccountSheet(context),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: nightVision,
            builder: (_, on, _) => IconButton(
              tooltip: 'Red night-vision mode',
              visualDensity: dense,
              isSelected: on,
              icon: Icon(on ? Icons.remove_red_eye : Icons.remove_red_eye_outlined),
              onPressed: () => nightVision.value = !on,
            ),
          ),
        ],
      ),
    );
  }

  /// Full-screen live view (cropped to fill, like the system camera app).
  Widget _previewArea() {
    final caps = _caps;
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _open, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    if (caps == null) return const Center(child: CircularProgressIndicator());

    Widget texture = Texture(textureId: caps.textureId);
    if (caps.previewQuarterTurns % 4 != 0) {
      texture = RotatedBox(quarterTurns: caps.previewQuarterTurns, child: texture);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          _previewSize = constraints.biggest;
          return InteractiveViewer(
            transformationController: _zoomCtrl,
            minScale: 1,
            maxScale: 12,
            onInteractionEnd: (_) => setState(() => _zoom = _zoomCtrl.value.getMaxScaleOnAxis()),
            child: SizedBox.expand(
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(width: 1000 * caps.previewAspect, height: 1000, child: texture),
                ),
              ),
            ),
          );
        }),
        if (_zoom < 1.05) const IgnorePointer(child: CustomPaint(painter: _ThirdsPainter())),
        // Brief white flash after each saved photo.
        IgnorePointer(
          child: TweenAnimationBuilder<double>(
            key: ValueKey(_flashCount),
            tween: Tween(begin: _flashCount == 0 ? 0 : 0.5, end: 0),
            duration: const Duration(milliseconds: 300),
            builder: (_, v, _) => ColoredBox(color: Colors.white.withValues(alpha: v)),
          ),
        ),
      ],
    );
  }

  /// iPhones cap a single exposure (about 1 s). Longer shutters are shot as
  /// back-to-back frames added into one photo; say so where it's set.
  Widget _stackHint() {
    final caps = _caps;
    if (caps == null || _autoExposure) return const SizedBox.shrink();
    final n = caps.framesFor(_shutter);
    if (n <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Stacked: $n × ${formatShutter(_shutter / n)} frames added into one photo '
          '(this camera\'s single exposure stops at ${formatShutter(caps.nativeMaxShutter)})',
          style: const TextStyle(fontSize: 12, color: V.textDim),
        ),
      ),
    );
  }

  Widget _exposureBadge() {
    final elapsed = DateTime.now().difference(_captureStart!);
    final label = _shutter >= 1 && !_autoExposure
        ? 'Exposing ${elapsed.inSeconds}s / ${formatShutter(_shutter)}'
        : 'Capturing…';
    final fraction = _shutter >= 1 && !_autoExposure ? (elapsed.inMilliseconds / (_shutter * 1000)).clamp(0.0, 1.0) : null;
    return HudPanel(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, value: fraction, backgroundColor: V.line),
        ),
        const SizedBox(width: 8),
        Text(label, style: V.readout(14, weight: FontWeight.w400)),
      ]),
    );
  }

  Widget _statusLine() {
    String text = '';
    if (_seq.isRunning) {
      final total = _seq.totalShots == null ? '∞' : '${_seq.totalShots}';
      final shot = 'Shot ${_seq.shotsTaken + (_seq.phase == SequencePhase.exposing ? 1 : 0)}/$total';
      text = switch (_seq.phase) {
        SequencePhase.countdown => 'Starting in ${formatDuration(_seq.remaining)}',
        SequencePhase.exposing => '$shot · exposing',
        SequencePhase.waiting => '$shot · next in ${formatDuration(_seq.remaining)}',
        _ => '',
      };
      if (_seq.failures > 0) text += ' · ${_seq.failures} failed';
    }
    if (text.isEmpty) return const SizedBox.shrink();
    final total = _seq.totalShots;
    // Progress through the sequence (goal gradient): the bar fills shot by shot.
    final progress = total == null || total == 0 ? null : (_seq.shotsTaken / total).clamp(0.0, 1.0);
    return HudPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(color: V.signal, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(text, style: V.readout(15)),
          ]),
          if (progress != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              width: 180,
              child: LinearProgressIndicator(value: progress, minHeight: 3, borderRadius: BorderRadius.circular(2)),
            ),
          ],
        ],
      ),
    );
  }

  String get _lensLabel {
    final caps = _caps;
    if (caps == null) return '—';
    return caps.lenses
        .firstWhere((l) => l.id == caps.activeLensId, orElse: () => const LensInfo(id: '', name: 'Lens'))
        .name;
  }

  /// (control, icon, title, value, isManual)
  List<(_Control, IconData, String, String, bool)> get _controlItems => [
        (_Control.iso, Icons.iso, 'ISO', _autoExposure ? 'AUTO' : formatIso(_iso), !_autoExposure),
        (
          _Control.shutter,
          Icons.shutter_speed_outlined,
          'Shutter speed',
          _autoExposure ? 'AUTO' : formatShutter(_shutter),
          !_autoExposure,
        ),
        (
          _Control.wb,
          _autoWb ? Icons.wb_auto_outlined : Icons.wb_sunny_outlined,
          'White balance',
          _autoWb ? 'AWB' : '${_kelvin.round()}K',
          !_autoWb,
        ),
        (
          _Control.focus,
          _autoFocus ? Icons.center_focus_strong_outlined : Icons.center_focus_weak_outlined,
          'Focus',
          _autoFocus ? 'AF' : (_focus >= 0.999 ? 'MF ∞' : 'MF ${(_focus * 100).round()}'),
          !_autoFocus,
        ),
        (_Control.lens, Icons.camera_outlined, 'Lens', _lensLabel, false),
      ];

  /// Pro-mode icons under the title bar; each opens a drawer from the bottom.
  /// One bounded strip groups them (common region). A manual value is bright
  /// with an underline; auto values are dim, so the state reads by brightness
  /// and shape, also under the red night-vision filter.
  Widget _controlRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
      child: HudPanel(
        radius: V.rMedium,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            for (final (control, icon, title, value, manual) in _controlItems)
              Expanded(
                child: Tooltip(
                  message: title,
                  child: Semantics(
                    button: true,
                    label: '$title, $value',
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(V.rSmall),
                      onTap: _caps == null ? null : () => _openDrawer(control),
                      child: AnimatedContainer(
                        duration: V.fast,
                        constraints: const BoxConstraints(minHeight: V.touch + 4),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(V.rSmall),
                          color: _active == control ? V.raised : Colors.transparent,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 22, color: manual ? V.ion : V.textDim),
                            const SizedBox(height: 3),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                value,
                                maxLines: 1,
                                style: V.readout(14, color: manual ? V.text : V.textDim,
                                    weight: manual ? FontWeight.w700 : FontWeight.w400),
                              ),
                            ),
                            const SizedBox(height: 3),
                            AnimatedContainer(
                              duration: V.fast,
                              width: manual ? 16 : 0,
                              height: 2,
                              decoration: BoxDecoration(color: V.ion, borderRadius: BorderRadius.circular(1)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDrawer(_Control control) async {
    setState(() => _active = control);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      barrierColor: Colors.black26,
      builder: (context) => SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: _rev,
          builder: (context, _, _) {
            final item = _controlItems.firstWhere((i) => i.$1 == control);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Icon(item.$2, size: 20, color: V.textDim),
                        const SizedBox(width: 8),
                        Text(item.$3, style: Theme.of(context).textTheme.titleMedium),
                        const Spacer(),
                        AnimatedSwitcher(
                          duration: V.fast,
                          child: Text(item.$4,
                              key: ValueKey(item.$4),
                              style: V.readout(24, color: item.$5 ? V.ion : V.textDim)),
                        ),
                      ],
                    ),
                  ),
                  if (control == _Control.shutter) _stackHint(),
                  const SizedBox(height: 8),
                  SizedBox(height: 96, child: _activePanel()),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (mounted) setState(() => _active = null);
  }

  Widget _activePanel() {
    final caps = _caps;
    if (caps == null || _active == null) return const SizedBox.shrink();

    switch (_active!) {
      case _Control.iso:
      case _Control.shutter:
        if (!caps.supportsManualExposure) return _unsupported('Manual exposure isn\'t available on this lens.');
        final isIso = _active == _Control.iso;
        final stops = isIso
            ? stopsWithin(kIsoStops, caps.minIso, caps.maxIso)
            : stopsWithin(kShutterStops, caps.minShutter, caps.maxShutter);
        final current = isIso ? _iso : _shutter;
        final index = nearestIndex(stops, current);
        return _panel(
          auto: _autoExposure,
          onAuto: (v) {
            setState(() => _autoExposure = v);
            _applyExposure();
          },
          slider: ScaleDial(
            semanticsLabel: isIso ? 'ISO' : 'Shutter speed',
            count: stops.length,
            index: index,
            label: (i) => isIso ? formatIso(stops[i]) : formatShutter(stops[i]),
            onChanged: (i) {
              setState(() {
                _autoExposure = false;
                if (isIso) {
                  _iso = stops[i];
                } else {
                  _shutter = stops[i];
                }
              });
              _applyExposure();
            },
          ),
        );

      case _Control.wb:
        if (!caps.supportsManualWhiteBalance) return _unsupported('Manual white balance isn\'t available.');
        return _panel(
          auto: _autoWb,
          onAuto: (v) {
            setState(() => _autoWb = v);
            _applyWhiteBalance();
          },
          slider: ScaleDial(
            semanticsLabel: 'White balance',
            count: ((caps.maxKelvin - caps.minKelvin) / 100).round().clamp(1, 1000) + 1,
            index: ((_kelvin - caps.minKelvin) / 100).round(),
            spacing: 12,
            majorEvery: 10,
            label: (i) => '${(caps.minKelvin + i * 100).round()}K',
            onChanged: (i) {
              setState(() {
                _autoWb = false;
                _kelvin = (caps.minKelvin + i * 100).clamp(caps.minKelvin, caps.maxKelvin);
              });
              _applyWhiteBalance();
            },
          ),
        );

      case _Control.focus:
        if (!caps.supportsManualFocus) return _unsupported('Manual focus isn\'t available on this lens.');
        return _panel(
          auto: _autoFocus,
          onAuto: (v) {
            setState(() => _autoFocus = v);
            _applyFocus();
          },
          slider: ScaleDial(
            semanticsLabel: 'Focus',
            count: 201,
            index: (_focus * 200).round(),
            spacing: 8,
            majorEvery: 20,
            label: (i) => i >= 200 ? '∞' : '${(i / 2).round()}',
            onChanged: (i) {
              setState(() {
                _autoFocus = false;
                _focus = i / 200;
              });
              _applyFocus();
            },
          ),
          trailing: TextButton(
            onPressed: () {
              setState(() {
                _autoFocus = false;
                _focus = 1.0;
              });
              _applyFocus();
            },
            child: const Text('∞', style: TextStyle(fontSize: 22)),
          ),
          leading: IconButton(
            tooltip: 'Magnify live view',
            icon: const Icon(Icons.zoom_in),
            onPressed: _cycleZoom,
          ),
        );

      case _Control.lens:
        return Center(
          child: Wrap(
            spacing: 8,
            children: [
              for (final lens in caps.lenses)
                ChoiceChip(
                  label: Text(lens.name),
                  selected: lens.id == caps.activeLensId,
                  onSelected: _seq.isRunning ? null : (_) => _switchLens(lens.id),
                ),
            ],
          ),
        );
    }
  }

  Widget _panel({
    required bool auto,
    required ValueChanged<bool> onAuto,
    required Widget slider,
    Widget? trailing,
    Widget? leading,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _AutoToggle(value: auto, onChanged: onAuto),
          const SizedBox(width: 8),
          ?leading,
          Expanded(child: slider),
          ?trailing,
        ],
      ),
    );
  }

  Widget _unsupported(String text) =>
      Center(child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: V.textDim)));

  /// Status, focus zoom, mode switch, thumbnail/format, shutter.
  Widget _bottomOverlay() {
    final running = _seq.isRunning;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xB3000000), Color(0xE6000000)],
          stops: [0, 0.35, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _capturing && _captureStart != null ? _exposureBadge() : _statusLine(),
                    ),
                  ),
                  if (_caps != null)
                    _overlayButton(
                      label: _zoom < 1.05 ? 'Focus zoom' : '${_zoom.toStringAsFixed(_zoom < 10 ? 1 : 0)}×',
                      icon: Icons.center_focus_strong,
                      onTap: _cycleZoom,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<_Mode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Mode.single, label: Text('Single'), icon: Icon(Icons.photo_camera_outlined)),
                  ButtonSegment(value: _Mode.interval, label: Text('Interval'), icon: Icon(Icons.timer_outlined)),
                ],
                selected: {_mode},
                onSelectionChanged: running ? null : (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        _thumbnail(),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(left: 2, bottom: 2),
                                child: Text('FORMAT',
                                    style: TextStyle(fontSize: 10, letterSpacing: 1.4, color: V.textDim)),
                              ),
                              ElevatedButton(
                                onPressed: _caps != null && !running ? _pickFormat : null,
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(0, 40),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  backgroundColor: V.surface.withValues(alpha: 0.72),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rSmall)),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    _output.label,
                                    maxLines: 1,
                                    style: V.readout(15),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  _ShutterButton(
                    running: running,
                    busy: _capturing,
                    intervalMode: _mode == _Mode.interval,
                    onPressed: _caps == null ? null : _onShutterPressed,
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _mode == _Mode.interval
                          ? OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 44),
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                backgroundColor: V.surface.withValues(alpha: 0.72),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rSmall)),
                              ),
                              onPressed: running
                                  ? null
                                  : () async {
                                      final next = await showIntervalSheet(
                                        context,
                                        initial: _interval,
                                        shutterSeconds: _autoExposure ? 0 : _shutter,
                                      );
                                      if (next != null) setState(() => _interval = next);
                                    },
                              icon: const Icon(Icons.tune, size: 18),
                              label: Text(
                                '${_interval.shots == 0 ? '∞' : _interval.shots}×${formatShutter(_interval.intervalSeconds)}',
                                style: V.readout(15),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.running,
    required this.busy,
    required this.intervalMode,
    required this.onPressed,
  });

  final bool running;
  final bool busy;
  final bool intervalMode;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // The one big, distinct control (Fitts's law, Von Restorff): white disc
    // for a photo, ringed timer for interval, a square while running.
    final label = running ? 'Stop sequence' : (intervalMode ? 'Start interval sequence' : 'Take photo');
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onPressed == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onPressed!();
              },
        child: SizedBox(
          width: 84,
          height: 84,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: onPressed == null ? V.textFaint : V.text, width: 3),
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 84,
                  height: 84,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              AnimatedContainer(
                duration: V.motion(context, const Duration(milliseconds: 200)),
                curve: Curves.easeOutCubic,
                width: running ? 30 : 66,
                height: running ? 30 : 66,
                decoration: BoxDecoration(
                  color: running ? V.signal : (intervalMode ? V.ion : V.text),
                  borderRadius: BorderRadius.circular(running ? 7 : 33),
                ),
                child: intervalMode && !running ? const Icon(Icons.timer_outlined, color: V.onIon, size: 26) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Labelled Auto on/off button for the pro-mode drawers. "Auto" filled =
/// automatic; outlined = manual.
class _AutoToggle extends StatelessWidget {
  const _AutoToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: 'Automatic',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onChanged(!value);
        },
        child: AnimatedContainer(
          duration: V.fast,
          width: 64,
          height: V.touch,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: value ? V.ion : Colors.transparent,
            borderRadius: BorderRadius.circular(V.rSmall),
            border: Border.all(color: value ? V.ion : const Color(0x40FFFFFF)),
          ),
          child: Text('Auto',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: value ? V.onIon : V.textDim)),
        ),
      ),
    );
  }
}

/// Rule-of-thirds grid to help compose the horizon and Milky Way.
class _ThirdsPainter extends CustomPainter {
  const _ThirdsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 0.6;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
