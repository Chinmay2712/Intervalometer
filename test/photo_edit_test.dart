import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/studio/edit/photo_edit.dart';
import 'package:valometer/studio/edit/video_edit.dart';

RgbaImage solid(int w, int h, int r, int g, int b) {
  final d = Uint8List(w * h * 4);
  for (var i = 0; i < d.length; i += 4) {
    d[i] = r;
    d[i + 1] = g;
    d[i + 2] = b;
    d[i + 3] = 255;
  }
  return RgbaImage(d, w, h);
}

List<int> px(RgbaImage img, int x, int y) {
  final p = (y * img.width + x) * 4;
  return [img.data[p], img.data[p + 1], img.data[p + 2]];
}

void main() {
  test('identity edit returns an equal copy', () {
    final src = solid(8, 6, 10, 20, 30);
    final out = renderEdit(src, const PhotoEdit());
    expect(out.data, src.data);
    expect(identical(out.data, src.data), isFalse);
  });

  test('quarter turns and flip move pixels correctly', () {
    final src = solid(4, 2, 0, 0, 0);
    src.data[0] = 255; // red at top-left
    final cw = applyGeometry(src, const PhotoEdit(quarterTurns: 1));
    expect((cw.width, cw.height), (2, 4));
    expect(px(cw, 1, 0)[0], 255, reason: 'top-left goes to top-right after 90° clockwise');
    final flipped = applyGeometry(src, const PhotoEdit(flip: true));
    expect(px(flipped, 3, 0)[0], 255);
    final half = applyGeometry(src, const PhotoEdit(quarterTurns: 2));
    expect(px(half, 3, 1)[0], 255);
    final ccw = applyGeometry(src, const PhotoEdit(quarterTurns: 3));
    expect(px(ccw, 0, 3)[0], 255);
  });

  test('crop size and straighten zoom', () {
    final src = solid(100, 50, 1, 2, 3);
    final out = applyGeometry(src, const PhotoEdit(crop: CropRect(0.1, 0.2, 0.6, 0.8)));
    expect((out.width, out.height), (50, 30));
    expect(straightenScale(100, 50, 0), closeTo(1, 1e-9));
    expect(straightenScale(100, 50, 10 * pi / 180), greaterThan(1.1));
    // A straightened solid image stays solid (no empty corners).
    final s = applyGeometry(src, const PhotoEdit(straighten: 12));
    expect(px(s, 0, 0), [1, 2, 3]);
    expect(px(s, 99, 49), [1, 2, 3]);
  });

  test('background neutralise removes a colour cast and gradient', () {
    final w = 120, h = 80;
    final img = solid(w, h, 0, 0, 0);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = (y * w + x) * 4;
        img.data[p] = 70 + x ~/ 4; // orange glow growing to the right
        img.data[p + 1] = 45 + x ~/ 8;
        img.data[p + 2] = 30;
      }
    }
    // A few stars.
    for (final (x, y) in [(10, 10), (60, 40), (100, 70)]) {
      final p = (y * w + x) * 4;
      img.data[p] = img.data[p + 1] = img.data[p + 2] = 250;
    }
    neutraliseBackground(img, 1);
    for (final x in [5, 60, 115]) {
      final c = px(img, x, 30);
      expect((c[0] - c[2]).abs(), lessThan(8), reason: 'neutral at x=$x: $c');
    }
    expect((px(img, 5, 30)[0] - px(img, 115, 30)[0]).abs(), lessThan(8), reason: 'gradient flattened');
    expect(px(img, 60, 40)[0], greaterThan(150), reason: 'star kept');
  });

  test('tone: exposure brightens, saturation -1 makes grey, curve keeps ends', () {
    final img = solid(4, 4, 100, 60, 40);
    applyTone(img, const PhotoEdit(exposure: 1));
    expect(px(img, 0, 0)[0], greaterThan(120));

    final grey = solid(4, 4, 200, 50, 50);
    applyTone(grey, const PhotoEdit(saturation: -1));
    final c = px(grey, 0, 0);
    expect((c[0] - c[1]).abs(), lessThanOrEqualTo(1));

    final lut = curveLut(const [0.15, 0.5, 0.85]);
    expect(lut.first, 0);
    expect(lut.last, closeTo(1, 1e-9));
    for (var i = 1; i < 256; i++) {
      expect(lut[i], greaterThanOrEqualTo(lut[i - 1] - 1e-9));
    }
  });

  test('astro tools run and shrink a star', () {
    final img = solid(64, 64, 20, 20, 25);
    for (var y = 30; y <= 33; y++) {
      for (var x = 30; x <= 33; x++) {
        final p = (y * 64 + x) * 4;
        img.data[p] = img.data[p + 1] = img.data[p + 2] = 230;
      }
    }
    final before = img.data.where((v) => v > 200).length;
    final out = renderEdit(img, const PhotoEdit(starReduction: 1, noise: 0.5, sharpen: 0.3, clarity: 0.3));
    final after = out.data.where((v) => v > 200).length;
    expect(after, lessThan(before));
  });

  test('looks keep geometry', () {
    const e = PhotoEdit(quarterTurns: 1, crop: CropRect(0, 0, 0.5, 0.5));
    final l = e.withLook(kLooks.firstWhere((l) => l.name == 'Mono'));
    expect(l.quarterTurns, 1);
    expect(l.crop, const CropRect(0, 0, 0.5, 0.5));
    expect(l.saturation, -1);
    expect(l.look, 'Mono');
  });

  test('video frame order, duration and deflicker', () {
    const v = VideoEdit(trimStart: 2, trimEnd: 5, fps: 2, loop: LoopMode.pingPong);
    expect(v.frameOrder(), [2, 3, 4, 5, 4, 3]);
    expect(v.durationSeconds(), 3);
    expect(v.copyWith(loop: LoopMode.off).frameOrder(), [2, 3, 4, 5]);

    final means = <double>[100, 100, 100, 160, 100, 100, 100];
    final g = deflickerGains(means, 1);
    expect(means[3] * g[3], lessThan(130), reason: 'flash pulled down');
    expect(g[0], closeTo(1, 0.15));
    expect(deflickerGains(means, 0), everyElement(1.0));
  });
}
