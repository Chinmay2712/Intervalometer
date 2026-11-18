/// Background isolate that does the heavy pixel work for the Studio.
/// The main isolate decodes images (fast native decoder) and streams the raw
/// RGBA frames here one at a time.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'processing.dart';
import 'star_align.dart';

/// Main-isolate handle: one request at a time, each answered with a map.
class StudioWorker {
  StudioWorker._(this._isolate, this._send, this._replies);

  final Isolate _isolate;
  final SendPort _send;
  final StreamIterator<dynamic> _replies;

  static Future<StudioWorker> spawn() async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_main, receive.sendPort, errorsAreFatal: false);
    final replies = StreamIterator<dynamic>(receive);
    await replies.moveNext();
    return StudioWorker._(isolate, replies.current as SendPort, replies);
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    _send.send(message);
    if (!await _replies.moveNext()) throw StateError('Worker stopped.');
    final reply = (_replies.current as Map).cast<String, dynamic>();
    if (reply['error'] != null) throw StudioWorkerError(reply['error'] as String);
    return reply;
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
    _replies.cancel();
  }
}

class StudioWorkerError implements Exception {
  StudioWorkerError(this.message);
  final String message;
  @override
  String toString() => message;
}

void _main(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);
  final state = _WorkerState();
  port.listen((message) {
    try {
      toMain.send(state.handle((message as Map).cast<String, dynamic>()));
    } on OutOfMemoryError {
      toMain.send({'error': 'Out of memory. Choose "Fast" processing size or fewer photos.'});
    } catch (e) {
      toMain.send({'error': e.toString()});
    }
  });
}

class _WorkerState {
  late String tool;
  late int w, h;

  // Star trails
  TrailAccumulator? trails;
  bool growing = false;
  int videoW = 0, videoH = 0;
  String tempDir = '';

  // Stack
  StackAccumulator? stack;
  bool align = true;
  Uint8List? foreground; // full size, 0..255
  Uint8List? detectSkip; // detection size
  int factor = 1;
  List<Star> refStars = const [];
  final transforms = <int, Rigid?>{};
  Uint8List? warped;
  Uint8List? valid;

  Map<String, dynamic> handle(Map<String, dynamic> m) {
    switch (m['op']) {
      case 'init':
        return _init(m);
      case 'frame':
        final data = (m['data'] as TransferableTypedData).materialize().asUint8List();
        return tool == 'stack' ? _stackFrame(m['index'] as int, m['pass'] as int, data) : _trailFrame(data);
      case 'finishPass1':
        stack!.finishPass1();
        return {'ok': true};
      case 'finish':
        return _finish(m['outPath'] as String);
      case 'preview':
        return _preview(m['maxSide'] as int);
    }
    throw StateError('Unknown op ${m['op']}');
  }

  Map<String, dynamic> _init(Map<String, dynamic> m) {
    tool = m['tool'] as String;
    w = m['width'] as int;
    h = m['height'] as int;
    if (tool == 'trails') {
      trails = TrailAccumulator(w, h);
      growing = m['growing'] as bool? ?? false;
      videoW = m['videoWidth'] as int? ?? 0;
      videoH = m['videoHeight'] as int? ?? 0;
      tempDir = m['tempDir'] as String? ?? '';
    } else {
      align = m['align'] as bool? ?? true;
      stack = StackAccumulator(w, h, reject: m['reject'] as bool? ?? false, kappa: (m['kappa'] as num?)?.toDouble() ?? 2.5);
      warped = Uint8List(w * h * 3);
      valid = Uint8List(w * h);
      factor = max(1, (max(w, h) / 1600).ceil());
      final mask = m['mask'] as TransferableTypedData?;
      if (mask != null) {
        final small = mask.materialize().asUint8List();
        final fg = upscaleMask(small, m['maskWidth'] as int, m['maskHeight'] as int, w, h);
        featherMask(fg, w, h, max(2, w ~/ 300));
        foreground = fg;
        // Never use stars in (or near) the foreground for alignment.
        final dw = w ~/ factor, dh = h ~/ factor;
        final skip = Uint8List(dw * dh);
        for (var y = 0; y < dh; y++) {
          for (var x = 0; x < dw; x++) {
            if (fg[min(h - 1, y * factor) * w + min(w - 1, x * factor)] > 0) skip[y * dw + x] = 1;
          }
        }
        detectSkip = skip;
      }
    }
    return {'ok': true};
  }

  Map<String, dynamic> _trailFrame(Uint8List rgba) {
    final t = trails!;
    t.add(rgba);
    if (!growing) return {'ok': true};
    final frame = resizeRgba(t.rgba, w, h, videoW, videoH);
    final path = '$tempDir/trail_${t.frames.toString().padLeft(5, '0')}.jpg';
    final image = img.Image.fromBytes(width: videoW, height: videoH, bytes: frame.buffer, numChannels: 4);
    File(path).writeAsBytesSync(img.encodeJpg(image, quality: 90));
    return {'ok': true, 'videoFrame': path};
  }

  Map<String, dynamic> _stackFrame(int index, int pass, Uint8List rgba) {
    final acc = stack!;
    Rigid? t;
    if (pass == 1) {
      if (!align) {
        t = Rigid.identity;
      } else {
        final lum = LumImage.fromRgba(rgba, w, h, factor);
        final stars = detectStars(lum, skip: detectSkip);
        if (index == 0) {
          if (stars.length < 8) {
            throw StudioWorkerError(
                'Only ${stars.length} stars found in the first photo, not enough to align. '
                'Turn off "Align stars" for short sequences, or use darker, sharper photos.');
          }
          refStars = stars;
          t = Rigid.identity;
        } else {
          t = alignStars(refStars, stars)?.toFullResolution(factor);
        }
      }
      transforms[index] = t;
    } else {
      t = transforms[index];
    }
    if (t == null) return {'ok': true, 'skipped': true};

    warpFrame(src: rgba, w: w, h: h, t: t, foreground: foreground, dst: warped!, valid: valid!);
    if (pass == 1) {
      acc.addPass1(warped!, valid!);
    } else {
      acc.addPass2(warped!, valid!);
    }
    return {'ok': true, 'skipped': false, 'rotation': t.angleDegrees};
  }

  /// Small snapshot of the image so far (nearest-neighbour, fast).
  Map<String, dynamic> _preview(int maxSide) {
    final s = min(1.0, maxSide / max(w, h));
    final pw = max(1, (w * s).round()), ph = max(1, (h * s).round());
    final out = Uint8List(pw * ph * 4);
    final acc = stack;
    final trailRgba = trails?.rgba;
    for (var y = 0; y < ph; y++) {
      final sy = min(h - 1, (y / s).floor());
      for (var x = 0; x < pw; x++) {
        final sx = min(w - 1, (x / s).floor());
        final o = sy * w + sx, d = (y * pw + x) * 4;
        if (acc != null) {
          final n = acc.count[o];
          if (n > 0) {
            out[d] = acc.sum[o * 3] ~/ n;
            out[d + 1] = acc.sum[o * 3 + 1] ~/ n;
            out[d + 2] = acc.sum[o * 3 + 2] ~/ n;
          }
        } else if (trailRgba != null) {
          out[d] = trailRgba[o * 4];
          out[d + 1] = trailRgba[o * 4 + 1];
          out[d + 2] = trailRgba[o * 4 + 2];
        }
        out[d + 3] = 255;
      }
    }
    return {'width': pw, 'height': ph, 'data': TransferableTypedData.fromList([out])};
  }

  Map<String, dynamic> _finish(String outPath) {
    final rgba = tool == 'stack' ? stack!.result() : trails!.rgba;
    final image = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4);
    File(outPath).writeAsBytesSync(img.encodeJpg(image, quality: 95));
    return {'ok': true, 'path': outPath};
  }
}
