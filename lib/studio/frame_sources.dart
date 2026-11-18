import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:valometer_camera/valometer_camera.dart';

/// A run of photos Valometer shot close together (an interval sequence).
class FrameSequence {
  FrameSequence(this.paths, this.start, this.end);
  final List<String> paths;
  final DateTime start;
  final DateTime end;
  int get length => paths.length;
  Duration get duration => end.difference(start);
}

/// Parses Valometer's capture names: VAL_yyyyMMdd_HHmmss_SSS.jpg
DateTime? captureTime(String path) {
  final m = RegExp(r'VAL_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_(\d{3})\.jpg$').firstMatch(path);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 7; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5], v[6]);
}

/// Groups captures into sequences: a gap of more than [maxGap] starts a new one.
List<FrameSequence> groupSequences(Iterable<String> paths, {Duration maxGap = const Duration(minutes: 15)}) {
  final timed = [
    for (final p in paths)
      if (captureTime(p) case final t?) (p, t),
  ]..sort((a, b) => a.$2.compareTo(b.$2));

  final out = <FrameSequence>[];
  var current = <(String, DateTime)>[];
  void flush() {
    if (current.length >= 2) {
      out.add(FrameSequence([for (final c in current) c.$1], current.first.$2, current.last.$2));
    }
    current = [];
  }

  for (final item in timed) {
    if (current.isNotEmpty && item.$2.difference(current.last.$2) > maxGap) flush();
    current.add(item);
  }
  flush();
  return out.reversed.toList(); // newest first
}

/// Interval sequences shot with Valometer (JPEG copies kept by the app).
Future<List<FrameSequence>> loadValometerSequences() async {
  final dir = Directory(await ValometerCamera.instance.framesDirectory());
  if (!dir.existsSync()) return const [];
  final files = dir.listSync().whereType<File>().map((f) => f.path).where((p) => p.endsWith('.jpg'));
  return groupSequences(files);
}

/// Multi-select from the phone's gallery, sorted by when each photo was
/// taken (EXIF), falling back to the order picked.
Future<List<String>> pickFromGallery() async {
  final picked = await ImagePicker().pickMultiImage(requestFullMetadata: true);
  if (picked.isEmpty) return const [];
  final withTime = <(String, DateTime?, int)>[];
  for (var i = 0; i < picked.length; i++) {
    withTime.add((picked[i].path, await _exifTime(picked[i].path), i));
  }
  withTime.sort((a, b) {
    if (a.$2 != null && b.$2 != null) {
      final c = a.$2!.compareTo(b.$2!);
      if (c != 0) return c;
    }
    return a.$3.compareTo(b.$3);
  });
  return [for (final w in withTime) w.$1];
}

/// "Date taken" from the JPEG's EXIF block (only the file header is read).
Future<DateTime?> _exifTime(String path) async {
  try {
    final file = await File(path).open();
    final head = await file.read(256 * 1024);
    await file.close();
    final exif = img.decodeJpgExif(Uint8List.fromList(head));
    final raw = exif?.exifIfd['DateTimeOriginal']?.toString() ?? exif?.imageIfd['DateTime']?.toString();
    if (raw == null) return null;
    final m = RegExp(r'(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})').firstMatch(raw);
    if (m == null) return null;
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
  } catch (_) {
    return null;
  }
}
