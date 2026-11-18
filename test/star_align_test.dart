import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:valometer/studio/star_align.dart';

/// Synthetic night sky: noisy background + Gaussian stars at [stars].
Uint8List renderSky(int w, int h, List<(double, double, double)> stars, {int seed = 1}) {
  final rnd = Random(seed);
  final out = Uint8List(w * h * 4);
  final lum = Float64List(w * h);
  for (var i = 0; i < lum.length; i++) {
    lum[i] = 20 + rnd.nextDouble() * 6;
  }
  for (final (sx, sy, b) in stars) {
    for (var y = (sy - 4).floor(); y <= (sy + 4).ceil(); y++) {
      for (var x = (sx - 4).floor(); x <= (sx + 4).ceil(); x++) {
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        final d2 = (x - sx) * (x - sx) + (y - sy) * (y - sy);
        lum[y * w + x] += b * exp(-d2 / 2.0);
      }
    }
  }
  for (var i = 0; i < lum.length; i++) {
    final v = lum[i].clamp(0, 255).round();
    out[i * 4] = v;
    out[i * 4 + 1] = v;
    out[i * 4 + 2] = v;
    out[i * 4 + 3] = 255;
  }
  return out;
}

void main() {
  const w = 600, h = 400;
  final rnd = Random(42);
  final stars = [
    for (var i = 0; i < 80; i++) (20 + rnd.nextDouble() * (w - 40), 20 + rnd.nextDouble() * (h - 40), 40 + rnd.nextDouble() * 180),
  ];

  test('detects most stars at sub-pixel accuracy', () {
    final img = LumImage.fromRgba(renderSky(w, h, stars), w, h, 1);
    final found = detectStars(img, maxStars: 200);
    expect(found.length, greaterThan(60));
    // Brightest detection sits on a real star.
    final top = found.first;
    final closest = stars.map((s) => sqrt(pow(s.$1 - top.x, 2) + pow(s.$2 - top.y, 2))).reduce(min);
    expect(closest, lessThan(0.5));
  });

  test('recovers a rotation + shift between two frames', () {
    // Frame = reference rotated 3° about (250, 150) and shifted.
    const angle = 3 * pi / 180;
    const cx = 250.0, cy = 150.0;
    // Frame->reference transform is the inverse of what we apply to make the frame.
    final moved = [
      for (final (x, y, b) in stars)
        (
          cos(angle) * (x - cx) - sin(angle) * (y - cy) + cx + 7,
          sin(angle) * (x - cx) + cos(angle) * (y - cy) + cy - 4,
          b,
        ),
    ];
    final ref = detectStars(LumImage.fromRgba(renderSky(w, h, stars), w, h, 1));
    final frm = detectStars(LumImage.fromRgba(renderSky(w, h, moved, seed: 2), w, h, 1));
    final t = alignStars(ref, frm);
    expect(t, isNotNull);
    expect(t!.angleDegrees, closeTo(-3, 0.05));
    // A star in the frame maps back onto its reference position.
    final (rx, ry) = t.apply(moved[0].$1, moved[0].$2);
    expect(rx, closeTo(stars[0].$1, 0.3));
    expect(ry, closeTo(stars[0].$2, 0.3));
  });

  test('refuses to align unrelated star fields', () {
    final other = Random(7);
    final unrelated = [
      for (var i = 0; i < 80; i++) (20 + other.nextDouble() * (w - 40), 20 + other.nextDouble() * (h - 40), 40 + other.nextDouble() * 180),
    ];
    final ref = detectStars(LumImage.fromRgba(renderSky(w, h, stars), w, h, 1));
    final frm = detectStars(LumImage.fromRgba(renderSky(w, h, unrelated, seed: 3), w, h, 1));
    expect(alignStars(ref, frm, minInliers: 12), isNull);
  });

  test('transform found at 1/2 size works at full size', () {
    final small = Rigid(cos(0.1), sin(0.1), 10, -5);
    final full = small.toFullResolution(2);
    // A full-res point X maps to the small point (X - 0.5) / 2.
    const fx = 300.5, fy = 200.5;
    final (sx, sy) = small.apply((fx - 0.5) / 2, (fy - 0.5) / 2);
    final (bx, by) = full.apply(fx, fy);
    expect(bx, closeTo(sx * 2 + 0.5, 1e-9));
    expect(by, closeTo(sy * 2 + 0.5, 1e-9));
  });

  test('Rigid invert is the inverse of apply', () {
    final t = Rigid(cos(0.05), sin(0.05), 12.5, -3.25);
    final (x, y) = t.apply(100, 50);
    final (bx, by) = t.invert(x, y);
    expect(bx, closeTo(100, 1e-9));
    expect(by, closeTo(50, 1e-9));
  });
}
