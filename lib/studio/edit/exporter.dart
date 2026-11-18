import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show PlatformException;
import 'package:image/image.dart' as imgpkg;
import 'package:path_provider/path_provider.dart';
import 'package:valometer_camera/valometer_camera.dart';

import '../../storage/gallery_sync.dart';
import 'photo_edit.dart';
import 'video_edit.dart';

/// Decodes [path] (orientation applied) into RGBA, at most [maxSide] px on
/// the long edge.
Future<RgbaImage> decodeImageFile(String path, {int? maxSide}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
  final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
    if (maxSide == null || max(w, h) <= maxSide) return ui.TargetImageSize(width: w, height: h);
    final s = maxSide / max(w, h);
    return ui.TargetImageSize(width: max(1, (w * s).round()), height: max(1, (h * s).round()));
  });
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = RgbaImage(data!.buffer.asUint8List(), image.width, image.height);
  image.dispose();
  codec.dispose();
  return out;
}

Future<ui.Image> toUiImage(RgbaImage img) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(img.data, img.width, img.height, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Average brightness (0..255) of a small version of each photo.
Future<List<double>> meanLuminances(List<String> paths, {void Function(int done)? onProgress}) async {
  final out = <double>[];
  for (var i = 0; i < paths.length; i++) {
    final img = await decodeImageFile(paths[i], maxSide: 48);
    final d = img.data;
    var sum = 0.0;
    for (var p = 0; p < d.length; p += 4) {
      sum += 0.2126 * d[p] + 0.7152 * d[p + 1] + 0.0722 * d[p + 2];
    }
    out.add(sum / (d.length / 4));
    onProgress?.call(i + 1);
  }
  return out;
}

Uint8List _encodeJpeg(RgbaImage img, int quality) => imgpkg.encodeJpg(
      imgpkg.Image.fromBytes(width: img.width, height: img.height, bytes: img.data.buffer, numChannels: 4),
      quality: quality,
    );

Uint8List _renderAndEncode(RgbaImage src, PhotoEdit e) => _encodeJpeg(renderEdit(src, e), 95);

Uint8List _toneAndEncode(RgbaImage src, PhotoEdit tone, double gain) {
  final img = src.copy();
  applyTone(img, tone, gain: gain);
  return _encodeJpeg(img, 92);
}

// Isolate entry points live in top-level functions so the closures only
// capture their own arguments (never UI callbacks).
Future<Uint8List> renderAndEncodeInBackground(RgbaImage src, PhotoEdit e) =>
    Isolate.run(() => _renderAndEncode(src, e));

Future<Uint8List> _toneInBackground(RgbaImage src, PhotoEdit tone, double gain) =>
    Isolate.run(() => _toneAndEncode(src, tone, gain));

/// Preview rendering for the editor.
Future<RgbaImage> renderInBackground(RgbaImage src, PhotoEdit e, {bool skipCrop = false}) =>
    Isolate.run(() => renderEdit(src, e, skipCrop: skipCrop));

class ExportCancelled implements Exception {}

/// Saves edited copies of Studio results (the originals are kept).
class EditExporter {
  bool _cancelled = false;
  bool _encoding = false;

  void cancel() {
    _cancelled = true;
    if (_encoding) ValometerCamera.instance.cancelEncode();
  }

  void _check() {
    if (_cancelled) throw ExportCancelled();
  }

  /// A free path in the app's Studio folder named after [original]
  /// (VAL_STACK_….jpg, then VAL_STACK_…_2.jpg on a second export).
  static Future<String> exportPath(String original, String ext) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/Studio')..createSync(recursive: true);
    final name = original.split(Platform.pathSeparator).last.split('/').last;
    final dot = name.lastIndexOf('.');
    final base = dot < 0 ? name : name.substring(0, dot);
    var path = '${dir.path}/$base.$ext';
    for (var n = 2; File(path).existsSync(); n++) {
      path = '${dir.path}/${base}_$n.$ext';
    }
    return path;
  }

  /// Renders [e] on the full-resolution [src] (or copies it when there are
  /// no edits) and saves it to the gallery.
  Future<String> photo(String src, PhotoEdit e) async {
    final out = await exportPath(src, 'jpg');
    if (e.isIdentity) {
      await File(src).copy(out);
    } else {
      final image = await decodeImageFile(src);
      _check();
      final bytes = await renderAndEncodeInBackground(image, e);
      _check();
      await File(out).writeAsBytes(bytes);
    }
    _check();
    await GallerySync.saveAndRecord(out);
    return out;
  }

  /// Saves an unedited video to the gallery.
  Future<String> copyVideo(String src) async {
    final out = await exportPath(src, 'mp4');
    await File(src).copy(out);
    _check();
    await GallerySync.saveAndRecord(out, mime: 'video/mp4');
    return out;
  }

  /// Re-encodes [frames] with [edit] and saves the video to the gallery.
  Future<String> video({
    required List<String> frames,
    required VideoEdit edit,
    required int width,
    required int height,
    required String outPath,
    List<double>? means,
    required void Function(String stage, double fraction) onProgress,
  }) async {
    final order = edit.frameOrder();
    final temp = Directory('${(await getTemporaryDirectory()).path}/edit_${DateTime.now().millisecondsSinceEpoch}');
    try {
      List<String> paths;
      final processing = !edit.passThroughPixels;
      if (!processing) {
        paths = [for (final i in order) frames[i]];
      } else {
        temp.createSync(recursive: true);
        final gains = edit.deflicker > 0 && means != null
            ? deflickerGains(means, edit.deflicker)
            : List<double>.filled(frames.length, 1);
        final unique = order.toSet().toList()..sort();
        final mapped = <int, String>{};
        final tone = edit.tone.toneOnly;
        for (var k = 0; k < unique.length; k++) {
          _check();
          final i = unique[k];
          onProgress('Applying edits: frame ${k + 1} of ${unique.length}', k / unique.length * 0.5);
          final src = await decodeImageFile(frames[i], maxSide: max(width, height));
          final gain = gains[i];
          final bytes = await _toneInBackground(src, tone, gain);
          final path = '${temp.path}/f_${i.toString().padLeft(5, '0')}.jpg';
          await File(path).writeAsBytes(bytes);
          mapped[i] = path;
        }
        paths = [for (final i in order) mapped[i]!];
      }
      _check();
      _encoding = true;
      final base = processing ? 0.5 : 0.0;
      try {
        await ValometerCamera.instance.encodeVideo(
          paths: paths,
          fps: edit.fps,
          width: width,
          height: height,
          outPath: outPath,
          onProgress: (done, total) =>
              onProgress('Encoding frame $done of $total', base + (1 - base) * done / total),
        );
      } on PlatformException catch (e) {
        if (e.code == 'cancelled') throw ExportCancelled();
        rethrow;
      } finally {
        _encoding = false;
      }
      onProgress('Saving to gallery…', 1);
      await GallerySync.saveAndRecord(outPath, mime: 'video/mp4');
      return outPath;
    } finally {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
