import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/services.dart' show PlatformException;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:valometer_camera/valometer_camera.dart';

import 'processing.dart';
import 'studio_worker.dart';
import 'image_disposal.dart';

enum StudioTool { starTrails, timelapse, stack }

class StudioOptions {
  const StudioOptions({
    required this.tool,
    this.growingVideo = false,
    this.fps = 30,
    this.videoLongSide = 1920,
    this.align = true,
    this.rejectOutliers = true,
    this.foregroundMask,
    this.maskWidth = 0,
    this.maskHeight = 0,
    this.fastSize = false,
  });

  final StudioTool tool;

  /// Star trails: also build a video where the trails grow frame by frame.
  final bool growingVideo;

  final int fps;

  /// 1920 (Full HD) or 3840 (4K) on the long side.
  final int videoLongSide;

  // Stacker
  final bool align;
  final bool rejectOutliers;

  /// Foreground (0 sky … 255 ground), painted by the user at maskWidth×maskHeight.
  final Uint8List? foregroundMask;
  final int maskWidth;
  final int maskHeight;

  /// Process at ~3 MP instead of full resolution (much faster, less memory).
  final bool fastSize;
}

class StudioProgress {
  const StudioProgress(this.stage, [this.fraction]);
  final String stage;
  final double? fraction; // null = indeterminate
}

class StudioResult {
  StudioResult({
    this.imagePath,
    this.videoPath,
    required this.framesUsed,
    this.notes = const [],
    this.videoFrames = const [],
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.fps = 30,
    this.cleanupDir,
  });
  final String? imagePath;
  final String? videoPath;
  final int framesUsed;
  final List<String> notes;

  /// Frames the video was made from (for re-encoding after edits).
  final List<String> videoFrames;
  final int videoWidth;
  final int videoHeight;
  final int fps;

  /// Draft folder holding the result (and any growing-trails frames). It is
  /// not in the gallery until exported; delete it when done.
  final String? cleanupDir;

  StudioResult withCleanupDir(String dir) => StudioResult(
        imagePath: imagePath,
        videoPath: videoPath,
        framesUsed: framesUsed,
        notes: notes,
        videoFrames: videoFrames,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        fps: fps,
        cleanupDir: dir,
      );

  void cleanUp() {
    final dir = cleanupDir;
    if (dir == null) return;
    try {
      Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
  }
}

class StudioCancelled implements Exception {}

class StudioFailure implements Exception {
  StudioFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Frame {
  _Frame(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

/// Runs one Studio job: star trails, timelapse or stack.
class StudioEngine {
  final progress = ValueNotifier(const StudioProgress('Starting…', 0));

  /// Live view of the image being built (stack / trails), updated as frames
  /// are added.
  final preview = ValueNotifier<ui.Image?>(null);

  /// Photo currently being processed (shown before the first live preview,
  /// and while a timelapse encodes).
  final previewPath = ValueNotifier<String?>(null);

  DateTime _lastPreview = DateTime.fromMillisecondsSinceEpoch(0);
  bool _keepTemp = false;
  bool _cancelled = false;
  bool _encoding = false;
  StudioWorker? _worker;

  void cancel() {
    _cancelled = true;
    if (_encoding) ValometerCamera.instance.cancelEncode();
  }

  void _check() {
    if (_cancelled) throw StudioCancelled();
  }

  /// Releases the preview image. The notifiers stay usable, because widgets
  /// that are fading out may still be listening to them.
  void dispose() {
    disposeImageLater(preview.value);
    preview.value = null;
  }

  /// Asks the worker for a small snapshot at most every [every].
  Future<void> _maybePreview(StudioWorker worker, {bool force = false, Duration every = const Duration(milliseconds: 900)}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastPreview) < every) return;
    _lastPreview = now;
    final reply = await worker.request({'op': 'preview', 'maxSide': 1080});
    final data = (reply['data'] as TransferableTypedData).materialize().asUint8List();
    final w = reply['width'] as int, h = reply['height'] as int;
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(data, w, h, ui.PixelFormat.rgba8888, c.complete);
    final image = await c.future;
    if (_cancelled) {
      image.dispose();
      return;
    }
    final old = preview.value;
    preview.value = image;
    disposeImageLater(old);
  }

  Future<StudioResult> run(List<String> paths, StudioOptions o) async {
    if (paths.length < 2) throw StudioFailure('Choose at least 2 photos.');
    final tempRoot = await getTemporaryDirectory();
    _removeOldDrafts(tempRoot);
    final temp = Directory('${tempRoot.path}/studio_${DateTime.now().millisecondsSinceEpoch}')
      ..createSync(recursive: true);
    // Results stay here as a draft until the user exports them.
    final outDir = Directory('${temp.path}/out')..createSync();
    final stamp = _stamp();
    previewPath.value = paths.first;
    try {
      final StudioResult r;
      switch (o.tool) {
        case StudioTool.timelapse:
          r = await _timelapse(paths, o, '${outDir.path}/VAL_TIMELAPSE_$stamp.mp4');
        case StudioTool.starTrails:
          r = await _trails(paths, o, outDir.path, stamp, temp.path);
        case StudioTool.stack:
          r = await _stack(paths, o, '${outDir.path}/VAL_STACK_$stamp.jpg');
      }
      _keepTemp = true;
      return r.withCleanupDir(temp.path);
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') throw StudioCancelled();
      throw StudioFailure(e.message ?? e.code);
    } on StudioWorkerError catch (e) {
      throw StudioFailure(e.message);
    } finally {
      _worker?.dispose();
      _worker = null;
      if (!_keepTemp) {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Drafts left behind when the app was closed before exporting.
  static void _removeOldDrafts(Directory tempRoot) {
    final cutoff = DateTime.now().subtract(const Duration(hours: 12));
    try {
      for (final d in tempRoot.listSync().whereType<Directory>()) {
        final name = d.path.split(Platform.pathSeparator).last;
        if (name.startsWith('studio_') && d.statSync().modified.isBefore(cutoff)) {
          d.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
  }

  // --------------------------------------------------------------- decode

  /// Full: the photo's own resolution (48 MP stays 48 MP). Fast: ~3 MP.
  int? _targetWidth(int width, int height, bool fast) {
    if (!fast) return null;
    const cap = 3.2e6;
    final area = width * height;
    if (area <= cap) return null;
    return (width * sqrt(cap / area)).round();
  }

  Future<(int, int)> _encodedSize(String path) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return size;
  }

  Future<_Frame> _decode(String path, {int? targetWidth}) async {
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes(), targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = _Frame(data!.buffer.asUint8List(), image.width, image.height);
    image.dispose();
    codec.dispose();
    return result;
  }

  /// Even video size with the photo's aspect ratio, [longSide] on the long edge.
  (int, int) _videoSize(int w, int h, int longSide) {
    int even8(double v) => max(16, (v / 8).round() * 8);
    return w >= h ? (longSide, even8(longSide * h / w)) : (even8(longSide * w / h), longSide);
  }

  Future<String> _encode(List<String> frames, StudioOptions o, int w, int h, String out, String label,
      {void Function(int index)? onFrame}) async {
    var lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
    _check();
    _encoding = true;
    progress.value = StudioProgress('$label: encoding video…', 0);
    try {
      return await ValometerCamera.instance.encodeVideo(
        paths: frames,
        fps: o.fps,
        width: w,
        height: h,
        outPath: out,
        onProgress: (done, total) {
          progress.value = StudioProgress('$label: encoding frame $done of $total', done / total);
          final now = DateTime.now();
          if (onFrame != null && done > 0 && now.difference(lastFrame) > const Duration(milliseconds: 150)) {
            lastFrame = now;
            onFrame(min(done, frames.length) - 1);
          }
        },
      );
    } finally {
      _encoding = false;
    }
  }

  // ------------------------------------------------------------ timelapse

  Future<StudioResult> _timelapse(List<String> paths, StudioOptions o, String out) async {
    progress.value = const StudioProgress('Reading photos…');
    final first = await _decode(paths.first, targetWidth: 64); // orientation-correct aspect
    final (vw, vh) = _videoSize(first.width, first.height, o.videoLongSide);
    await _encode(paths, o, vw, vh, out, 'Timelapse', onFrame: (i) => previewPath.value = paths[i]);
    return StudioResult(
      videoPath: out,
      framesUsed: paths.length,
      videoFrames: List.of(paths),
      videoWidth: vw,
      videoHeight: vh,
      fps: o.fps,
      notes: ['${paths.length} frames at ${o.fps} fps = ${(paths.length / o.fps).toStringAsFixed(1)} s of video, $vw×$vh.'],
    );
  }

  // ---------------------------------------------------------- star trails

  Future<StudioResult> _trails(List<String> paths, StudioOptions o, String outDir, String stamp, String temp) async {
    final (ew, eh) = await _encodedSize(paths.first);
    final tw = _targetWidth(ew, eh, o.fastSize);
    final first = await _decode(paths.first, targetWidth: tw);
    final w = first.width, h = first.height;
    var (vw, vh) = _videoSize(w, h, o.videoLongSide);

    final worker = _worker = await StudioWorker.spawn();
    await worker.request({
      'op': 'init',
      'tool': 'trails',
      'width': w,
      'height': h,
      'growing': o.growingVideo,
      'videoWidth': vw,
      'videoHeight': vh,
      'tempDir': temp,
    });

    final videoFrames = <String>[];
    final notes = <String>[];
    var used = 0;
    for (var i = 0; i < paths.length; i++) {
      _check();
      progress.value = StudioProgress('Star trails: photo ${i + 1} of ${paths.length}', i / paths.length);
      final f = i == 0 ? first : await _decode(paths[i], targetWidth: tw);
      if (f.width != w || f.height != h) {
        notes.add('Skipped ${_name(paths[i])}: different size or orientation.');
        continue;
      }
      final reply = await worker.request({
        'op': 'frame',
        'index': i,
        'pass': 1,
        'data': TransferableTypedData.fromList([f.rgba]),
      });
      used++;
      if (reply['videoFrame'] != null) videoFrames.add(reply['videoFrame'] as String);
      previewPath.value = paths[i];
      await _maybePreview(worker, force: i == 0);
    }
    await _maybePreview(worker, force: true);

    _check();
    progress.value = const StudioProgress('Star trails: finishing image…');
    final imagePath = '$outDir/VAL_TRAILS_$stamp.jpg';
    await worker.request({'op': 'finish', 'outPath': imagePath});

    String? videoPath;
    if (o.growingVideo && videoFrames.length >= 2) {
      videoPath = await _encode(videoFrames, o, vw, vh, '$outDir/VAL_TRAILS_$stamp.mp4', 'Growing trails');
    }
    return StudioResult(
      imagePath: imagePath,
      videoPath: videoPath,
      framesUsed: used,
      notes: notes,
      videoFrames: videoPath == null ? const [] : videoFrames,
      videoWidth: vw,
      videoHeight: vh,
      fps: o.fps,
    );
  }

  // ---------------------------------------------------------------- stack

  Future<StudioResult> _stack(List<String> paths, StudioOptions o, String out) async {
    if (paths.length > kMaxStackFrames) {
      throw StudioFailure('Stack up to $kMaxStackFrames photos at a time (you chose ${paths.length}).');
    }
    final (ew, eh) = await _encodedSize(paths.first);
    final tw = _targetWidth(ew, eh, o.fastSize);
    final first = await _decode(paths.first, targetWidth: tw);
    final w = first.width, h = first.height;

    final worker = _worker = await StudioWorker.spawn();
    await worker.request({
      'op': 'init',
      'tool': 'stack',
      'width': w,
      'height': h,
      'align': o.align,
      'reject': o.rejectOutliers,
      'kappa': 2.5,
      'mask': o.foregroundMask == null ? null : TransferableTypedData.fromList([o.foregroundMask!]),
      'maskWidth': o.maskWidth,
      'maskHeight': o.maskHeight,
    });

    final passes = o.rejectOutliers ? 2 : 1;
    final total = paths.length * passes;
    final notes = <String>[];
    final usable = <int>{};
    var maxRotation = 0.0;

    for (var pass = 1; pass <= passes; pass++) {
      for (var i = 0; i < paths.length; i++) {
        if (pass == 2 && !usable.contains(i)) continue;
        _check();
        final label = pass == 1
            ? (o.align ? 'Aligning and stacking' : 'Stacking')
            : 'Removing planes and satellites';
        progress.value = StudioProgress('$label: photo ${i + 1} of ${paths.length}', ((pass - 1) * paths.length + i) / total);
        final f = (i == 0 && pass == 1) ? first : await _decode(paths[i], targetWidth: tw);
        if (f.width != w || f.height != h) {
          if (pass == 1) notes.add('Skipped ${_name(paths[i])}: different size or orientation.');
          continue;
        }
        final reply = await worker.request({
          'op': 'frame',
          'index': i,
          'pass': pass,
          'data': TransferableTypedData.fromList([f.rgba]),
        });
        if (pass == 1) {
          previewPath.value = paths[i];
          if (reply['skipped'] != true) await _maybePreview(worker, force: usable.isEmpty);
          if (reply['skipped'] == true) {
            notes.add('Skipped ${_name(paths[i])}: stars didn\'t match (clouds, blur, or a different scene).');
          } else {
            usable.add(i);
            maxRotation = max(maxRotation, ((reply['rotation'] as num?) ?? 0).abs().toDouble());
          }
        }
      }
      if (pass == 1) await _maybePreview(worker, force: true);
      if (pass == 1 && passes == 2) await worker.request({'op': 'finishPass1'});
    }
    if (usable.length < 2) throw StudioFailure('Fewer than 2 photos could be stacked.');

    _check();
    progress.value = const StudioProgress('Finishing stacked image…');
    await worker.request({'op': 'finish', 'outPath': out});
    if (o.align) notes.insert(0, 'Sky rotated up to ${maxRotation.toStringAsFixed(2)}° between frames and was aligned.');
    return StudioResult(imagePath: out, framesUsed: usable.length, notes: notes);
  }

  static String _name(String path) => path.split(Platform.pathSeparator).last;

  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }
}
