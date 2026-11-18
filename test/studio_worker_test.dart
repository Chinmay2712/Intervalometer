import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:valometer/studio/studio_worker.dart';

import 'star_align_test.dart' show renderSky;

void main() {
  const w = 480, h = 320;
  final rnd = Random(5);
  final stars = [
    for (var i = 0; i < 70; i++) (20 + rnd.nextDouble() * (w - 40), 20 + rnd.nextDouble() * (h - 40), 60 + rnd.nextDouble() * 160),
  ];

  /// Frame i: sky rotated i × 0.4° about (200, 140) and drifted, like a real
  /// sequence. Frame 3 has a satellite streak across row 60.
  Uint8List frame(int i) {
    final a = i * 0.4 * pi / 180;
    final moved = [
      for (final (x, y, b) in stars)
        (cos(a) * (x - 200) - sin(a) * (y - 140) + 200 + i * 1.5, sin(a) * (x - 200) + cos(a) * (y - 140) + 140, b),
    ];
    final rgba = renderSky(w, h, moved, seed: 100 + i);
    if (i == 3) {
      for (var x = 0; x < w; x++) {
        final p = (60 * w + x) * 4;
        rgba[p] = rgba[p + 1] = rgba[p + 2] = 250;
      }
    }
    return rgba;
  }

  test('stack worker aligns rotating frames and removes a satellite', () async {
    final dir = Directory.systemTemp.createTempSync('valometer_stack');
    final worker = await StudioWorker.spawn();
    try {
      await worker.request({'op': 'init', 'tool': 'stack', 'width': w, 'height': h, 'align': true, 'reject': true});
      const n = 8;
      for (var pass = 1; pass <= 2; pass++) {
        for (var i = 0; i < n; i++) {
          final r = await worker.request({
            'op': 'frame',
            'index': i,
            'pass': pass,
            'data': TransferableTypedData.fromList([frame(i)]),
          });
          expect(r['skipped'], isFalse, reason: 'frame $i pass $pass');
        }
        if (pass == 1) await worker.request({'op': 'finishPass1'});
      }
      final out = '${dir.path}/stack.jpg';
      await worker.request({'op': 'finish', 'outPath': out});

      final result = img.decodeJpg(File(out).readAsBytesSync())!;
      // Brightest reference star is still a sharp, bright point (frames were aligned).
      final brightest = stars.reduce((a, b) => a.$3 > b.$3 ? a : b);
      final peak = result.getPixel(brightest.$1.round(), brightest.$2.round()).r;
      expect(peak, greaterThan(120));
      // Satellite streak (row 60, away from stars) is gone.
      var streak = 0.0, count = 0;
      for (var x = 40; x < w - 40; x += 7) {
        if (stars.any((s) => (s.$1 - x).abs() < 6 && (s.$2 - 60).abs() < 6)) continue;
        streak += result.getPixel(x, 60).r;
        count++;
      }
      expect(streak / count, lessThan(40)); // background ≈ 23; an unrejected streak would add ~28
    } finally {
      worker.dispose();
      dir.deleteSync(recursive: true);
    }
  });

  test('trail worker writes the image and growing-trail frames', () async {
    final dir = Directory.systemTemp.createTempSync('valometer_trails');
    final worker = await StudioWorker.spawn();
    try {
      await worker.request({
        'op': 'init',
        'tool': 'trails',
        'width': w,
        'height': h,
        'growing': true,
        'videoWidth': 240,
        'videoHeight': 160,
        'tempDir': dir.path,
      });
      final frames = <String>[];
      for (var i = 0; i < 4; i++) {
        final r = await worker.request({'op': 'frame', 'index': i, 'pass': 1, 'data': TransferableTypedData.fromList([frame(i)])});
        frames.add(r['videoFrame'] as String);
      }
      expect(frames.every((f) => File(f).existsSync()), isTrue);
      expect(img.decodeJpg(File(frames.last).readAsBytesSync())!.width, 240);
      await worker.request({'op': 'finish', 'outPath': '${dir.path}/trails.jpg'});
      final trails = img.decodeJpg(File('${dir.path}/trails.jpg').readAsBytesSync())!;
      expect(trails.width, w);
      // The satellite in frame 3 is kept in a trails image (lighten blend keeps everything bright).
      expect(trails.getPixel(5, 60).r, greaterThan(200));
    } finally {
      worker.dispose();
      dir.deleteSync(recursive: true);
    }
  });
}
