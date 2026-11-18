/// Star detection and frame alignment for stacking.
///
/// Frames are matched to a reference with a rigid transform (rotation +
/// shift): the sky turns about the celestial pole by ~15°/hour, which shows up
/// in a photo as a rotation plus a translation. Pure Dart, runs in an isolate.
library;

import 'dart:math';
import 'dart:typed_data';

class Star {
  const Star(this.x, this.y, this.flux);
  final double x;
  final double y;
  final double flux;
}

/// Maps frame coordinates to reference coordinates:
/// xr = c·x − s·y + tx,  yr = s·x + c·y + ty.
class Rigid {
  const Rigid(this.c, this.s, this.tx, this.ty);
  static const identity = Rigid(1, 0, 0, 0);

  final double c;
  final double s;
  final double tx;
  final double ty;

  double get angleDegrees => atan2(s, c) * 180 / pi;

  /// Converts a transform found on an image box-downsampled by [f] to full
  /// resolution. A small pixel x covers full pixels f·x … f·x+f−1, whose
  /// centre is X = f·x + k with k = (f−1)/2.
  Rigid toFullResolution(int f) {
    final k = (f - 1) / 2;
    return Rigid(c, s, f * tx + k - (c * k - s * k), f * ty + k - (s * k + c * k));
  }

  (double, double) apply(double x, double y) => (c * x - s * y + tx, s * x + c * y + ty);

  /// Reference → frame (used when warping: for each output pixel, where to sample).
  (double, double) invert(double xr, double yr) {
    final dx = xr - tx, dy = yr - ty;
    return (c * dx + s * dy, -s * dx + c * dy);
  }
}

/// Greyscale, box-downsampled copy of an RGBA frame.
class LumImage {
  LumImage(this.data, this.width, this.height);
  final Float32List data;
  final int width;
  final int height;

  double at(int x, int y) => data[y * width + x];

  factory LumImage.fromRgba(Uint8List rgba, int w, int h, int factor) {
    final ow = w ~/ factor, oh = h ~/ factor;
    final out = Float32List(ow * oh);
    final norm = 1 / (factor * factor);
    for (var oy = 0; oy < oh; oy++) {
      for (var ox = 0; ox < ow; ox++) {
        var sum = 0.0;
        for (var dy = 0; dy < factor; dy++) {
          var i = ((oy * factor + dy) * w + ox * factor) * 4;
          for (var dx = 0; dx < factor; dx++, i += 4) {
            sum += 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
          }
        }
        out[oy * ow + ox] = sum * norm;
      }
    }
    return LumImage(out, ow, oh);
  }
}

/// Finds point-like stars, brightest first.
///
/// [skip] (same size as [img], non-zero = ignore) masks out the foreground so
/// city lights or a lit tree are never used for sky alignment.
List<Star> detectStars(LumImage img, {Uint8List? skip, int maxStars = 60}) {
  final w = img.width, h = img.height, d = img.data;
  if (w < 32 || h < 32) return const [];

  // Background: median of each 32×32 block (handles light-pollution gradients).
  const block = 32;
  final bw = (w + block - 1) ~/ block, bh = (h + block - 1) ~/ block;
  final bg = Float32List(bw * bh);
  final samples = <double>[];
  for (var by = 0; by < bh; by++) {
    for (var bx = 0; bx < bw; bx++) {
      samples.clear();
      for (var y = by * block; y < min(h, by * block + block); y += 2) {
        for (var x = bx * block; x < min(w, bx * block + block); x += 2) {
          samples.add(d[y * w + x]);
        }
      }
      samples.sort();
      bg[by * bw + bx] = samples[samples.length ~/ 2];
    }
  }
  double bgAt(int x, int y) => bg[(y ~/ block) * bw + (x ~/ block)];

  // Noise: median absolute deviation from the background.
  final dev = <double>[];
  for (var y = 0; y < h; y += 3) {
    for (var x = 0; x < w; x += 3) {
      dev.add((d[y * w + x] - bgAt(x, y)).abs());
    }
  }
  dev.sort();
  final sigma = max(1.0, dev[dev.length ~/ 2] * 1.4826);
  final threshold = max(5 * sigma, 8.0);

  final candidates = <Star>[];
  for (var y = 3; y < h - 3; y++) {
    for (var x = 3; x < w - 3; x++) {
      final i = y * w + x;
      final v = d[i];
      final b = bgAt(x, y);
      if (v - b < threshold) continue;
      if (skip != null && skip[i] != 0) continue;
      // Strict local maximum (ties broken towards top-left).
      if (v <= d[i - 1] || v <= d[i - w] || v <= d[i - w - 1] || v <= d[i - w + 1] ||
          v < d[i + 1] || v < d[i + w] || v < d[i + w - 1] || v < d[i + w + 1]) {
        continue;
      }
      var sx = 0.0, sy = 0.0, sf = 0.0;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final f = d[i + dy * w + dx] - b;
          if (f > 0) {
            sx += f * (x + dx);
            sy += f * (y + dy);
            sf += f;
          }
        }
      }
      if (sf > 0) candidates.add(Star(sx / sf, sy / sf, sf));
    }
  }

  candidates.sort((a, b) => b.flux.compareTo(a.flux));
  final out = <Star>[];
  for (final c in candidates) {
    if (out.any((s) => (s.x - c.x).abs() < 4 && (s.y - c.y).abs() < 4)) continue;
    out.add(c);
    if (out.length >= maxStars) break;
  }
  return out;
}

/// Finds the rotation + shift that maps [frame] stars onto [reference] stars.
/// Returns null when too few stars agree (clouds, wrong frame, too few stars).
Rigid? alignStars(
  List<Star> reference,
  List<Star> frame, {
  double tolerance = 1.5,
  int minInliers = 6,
  double maxRotationDegrees = 45,
}) {
  if (reference.length < minInliers || frame.length < minInliers) return null;
  final a = reference.take(30).toList();
  final b = frame.take(30).toList();
  final allRef = reference;
  final allFrame = frame;

  // Spatial hash of reference stars for fast nearest-neighbour checks.
  final cell = tolerance * 2;
  final grid = <int, List<Star>>{};
  int key(int cx, int cy) => cx * 100003 + cy;
  for (final s in allRef) {
    grid.putIfAbsent(key((s.x / cell).floor(), (s.y / cell).floor()), () => []).add(s);
  }
  Star? nearest(double x, double y) {
    final cx = (x / cell).floor(), cy = (y / cell).floor();
    Star? best;
    var bestD = tolerance * tolerance * 4;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final s in grid[key(cx + dx, cy + dy)] ?? const <Star>[]) {
          final dd = (s.x - x) * (s.x - x) + (s.y - y) * (s.y - y);
          if (dd < bestD) {
            bestD = dd;
            best = s;
          }
        }
      }
    }
    return best;
  }

  // Reference star pairs sorted by separation.
  final pairs = <(double, int, int)>[];
  for (var i = 0; i < a.length; i++) {
    for (var j = i + 1; j < a.length; j++) {
      final dd = sqrt(pow(a[i].x - a[j].x, 2) + pow(a[i].y - a[j].y, 2));
      if (dd >= 15) pairs.add((dd, i, j));
    }
  }
  pairs.sort((p, q) => p.$1.compareTo(q.$1));
  int lowerBound(double v) {
    var lo = 0, hi = pairs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (pairs[mid].$1 < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  final maxRot = maxRotationDegrees * pi / 180;
  Rigid? best;
  var bestCount = 0;
  List<(Star, Star)> bestMatches = const [];

  List<(Star, Star)> matchesFor(Rigid t) {
    final m = <(Star, Star)>[];
    for (final s in allFrame) {
      final (x, y) = t.apply(s.x, s.y);
      final r = nearest(x, y);
      if (r != null) m.add((s, r));
    }
    return m;
  }

  outer:
  for (var p = 0; p < b.length; p++) {
    for (var q = p + 1; q < b.length; q++) {
      final db = sqrt(pow(b[p].x - b[q].x, 2) + pow(b[p].y - b[q].y, 2));
      if (db < 15) continue;
      for (var k = lowerBound(db - tolerance); k < pairs.length && pairs[k].$1 <= db + tolerance; k++) {
        final (_, i, j) = pairs[k];
        for (final (r1, r2) in [(a[i], a[j]), (a[j], a[i])]) {
          final angle = atan2(r2.y - r1.y, r2.x - r1.x) - atan2(b[q].y - b[p].y, b[q].x - b[p].x);
          final norm = atan2(sin(angle), cos(angle));
          if (norm.abs() > maxRot) continue;
          final c = cos(norm), s = sin(norm);
          final t = Rigid(c, s, r1.x - (c * b[p].x - s * b[p].y), r1.y - (s * b[p].x + c * b[p].y));
          final m = matchesFor(t);
          if (m.length > bestCount) {
            bestCount = m.length;
            best = t;
            bestMatches = m;
            if (bestCount >= 0.8 * min(allRef.length, allFrame.length)) break outer;
          }
        }
      }
    }
  }

  if (best == null || bestCount < minInliers) return null;

  // Least-squares refinement on all matched stars (2-D Kabsch).
  for (var iter = 0; iter < 2; iter++) {
    var mfx = 0.0, mfy = 0.0, mrx = 0.0, mry = 0.0;
    for (final (f, r) in bestMatches) {
      mfx += f.x;
      mfy += f.y;
      mrx += r.x;
      mry += r.y;
    }
    final n = bestMatches.length;
    mfx /= n;
    mfy /= n;
    mrx /= n;
    mry /= n;
    var sxx = 0.0, sxy = 0.0;
    for (final (f, r) in bestMatches) {
      final fx = f.x - mfx, fy = f.y - mfy, rx = r.x - mrx, ry = r.y - mry;
      sxx += fx * rx + fy * ry;
      sxy += fx * ry - fy * rx;
    }
    final theta = atan2(sxy, sxx);
    final c = cos(theta), s = sin(theta);
    best = Rigid(c, s, mrx - (c * mfx - s * mfy), mry - (s * mfx + c * mfy));
    bestMatches = matchesFor(best);
    if (bestMatches.length < minInliers) return null;
  }
  return best;
}
