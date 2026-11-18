/// Pixel-level processing for the Studio. Pure Dart on plain byte buffers so
/// it can run in a background isolate and be unit-tested.
library;

import 'dart:math';
import 'dart:typed_data';

import 'star_align.dart';

/// Max frames for stacking: sums are 16-bit and counts 8-bit to keep memory
/// low enough for full-resolution photos.
const kMaxStackFrames = 255;

/// Upscales a small foreground mask (0 = sky, 255 = foreground) to w×h with
/// bilinear filtering, which also softens the edge.
Uint8List upscaleMask(Uint8List small, int sw, int sh, int w, int h) {
  final out = Uint8List(w * h);
  final kx = (sw - 1) / max(1, w - 1), ky = (sh - 1) / max(1, h - 1);
  for (var y = 0; y < h; y++) {
    final fy = y * ky;
    final y0 = fy.floor(), y1 = min(y0 + 1, sh - 1);
    final wy = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = x * kx;
      final x0 = fx.floor(), x1 = min(x0 + 1, sw - 1);
      final wx = fx - x0;
      final top = small[y0 * sw + x0] * (1 - wx) + small[y0 * sw + x1] * wx;
      final bottom = small[y1 * sw + x0] * (1 - wx) + small[y1 * sw + x1] * wx;
      out[y * w + x] = (top * (1 - wy) + bottom * wy).round();
    }
  }
  return out;
}

/// Box-blurs a mask in place (feathers the sky/foreground edge).
void featherMask(Uint8List m, int w, int h, int radius) {
  if (radius <= 0) return;
  final tmp = Uint8List(m.length);
  final n = radius * 2 + 1;
  for (var y = 0; y < h; y++) {
    var acc = 0;
    for (var x = -radius; x <= radius; x++) {
      acc += m[y * w + x.clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      tmp[y * w + x] = acc ~/ n;
      acc += m[y * w + min(x + radius + 1, w - 1)] - m[y * w + max(x - radius, 0)];
    }
  }
  for (var x = 0; x < w; x++) {
    var acc = 0;
    for (var y = -radius; y <= radius; y++) {
      acc += tmp[y.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      m[y * w + x] = acc ~/ n;
      acc += tmp[min(y + radius + 1, h - 1) * w + x] - tmp[max(y - radius, 0) * w + x];
    }
  }
}

/// Resamples [src] (RGBA, w×h) into reference coordinates.
///
/// Sky pixels use [t] (frame → reference). Where [foreground] is set the
/// frame is used as-is, because the ground doesn't move on a tripod. Output
/// is RGB in [dst]; [valid] marks pixels the frame actually covered.
void warpFrame({
  required Uint8List src,
  required int w,
  required int h,
  required Rigid t,
  Uint8List? foreground,
  required Uint8List dst,
  required Uint8List valid,
}) {
  final identity = t.c == 1 && t.s == 0 && t.tx == 0 && t.ty == 0;
  for (var y = 0; y < h; y++) {
    // Inverse mapping, stepped incrementally along the row.
    var (sx, sy) = t.invert(0, y.toDouble());
    for (var x = 0; x < w; x++, sx += t.c, sy -= t.s) {
      final o = y * w + x;
      final fg = foreground == null ? 0 : foreground[o];
      final si = o * 4;
      final d = o * 3;

      if (identity || fg == 255) {
        dst[d] = src[si];
        dst[d + 1] = src[si + 1];
        dst[d + 2] = src[si + 2];
        valid[o] = 1;
        continue;
      }

      double r, g, b;
      var ok = sx >= 0 && sy >= 0 && sx <= w - 1 && sy <= h - 1;
      if (ok) {
        final x0 = sx.floor(), y0 = sy.floor();
        final x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1);
        final fx = sx - x0, fy = sy - y0;
        final i00 = (y0 * w + x0) * 4, i10 = (y0 * w + x1) * 4;
        final i01 = (y1 * w + x0) * 4, i11 = (y1 * w + x1) * 4;
        final w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy;
        r = src[i00] * w00 + src[i10] * w10 + src[i01] * w01 + src[i11] * w11;
        g = src[i00 + 1] * w00 + src[i10 + 1] * w10 + src[i01 + 1] * w01 + src[i11 + 1] * w11;
        b = src[i00 + 2] * w00 + src[i10 + 2] * w10 + src[i01 + 2] * w01 + src[i11 + 2] * w11;
      } else {
        r = g = b = 0;
      }

      if (fg > 0) {
        // Feathered edge: blend the fixed foreground with the aligned sky.
        final a = fg / 255;
        if (!ok) {
          r = src[si].toDouble();
          g = src[si + 1].toDouble();
          b = src[si + 2].toDouble();
        } else {
          r = src[si] * a + r * (1 - a);
          g = src[si + 1] * a + g * (1 - a);
          b = src[si + 2] * a + b * (1 - a);
        }
        ok = true;
      }

      if (ok) {
        dst[d] = r.round();
        dst[d + 1] = g.round();
        dst[d + 2] = b.round();
      }
      valid[o] = ok ? 1 : 0;
    }
  }
}

/// Star trails: keeps the brightest value of every pixel ("lighten" blend).
class TrailAccumulator {
  TrailAccumulator(this.width, this.height) : rgba = Uint8List(width * height * 4) {
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255;
    }
  }

  final int width;
  final int height;
  final Uint8List rgba;
  int frames = 0;

  void add(Uint8List frame) {
    for (var i = 0; i < rgba.length; i += 4) {
      if (frame[i] > rgba[i]) rgba[i] = frame[i];
      if (frame[i + 1] > rgba[i + 1]) rgba[i + 1] = frame[i + 1];
      if (frame[i + 2] > rgba[i + 2]) rgba[i + 2] = frame[i + 2];
    }
    frames++;
  }
}

/// Mean stack with optional kappa-sigma outlier rejection (two passes).
///
/// Pass 1 builds the mean and the brightness spread of every pixel. Pass 2
/// re-adds each frame but skips pixels further than [kappa]·σ from the mean,
/// which removes planes, satellites and meteors.
///
/// Memory is kept low so full-resolution (48 MP+) photos fit: after pass 1
/// the mean and σ are packed into bytes and the sum buffers are reused for
/// pass 2 (about 10 bytes per pixel, 14 during pass 1 with rejection).
class StackAccumulator {
  StackAccumulator(this.width, this.height, {this.reject = false, this.kappa = 2.5})
      : sum = Uint16List(width * height * 3),
        count = Uint8List(width * height),
        _lumSq = reject ? Float32List(width * height) : null;

  final int width;
  final int height;
  final bool reject;
  final double kappa;

  /// Running sums and counts (pass 1, then reused for the clipped pass 2).
  final Uint16List sum;
  final Uint8List count;

  Float32List? _lumSq; // pass 1 only: Σ lum²
  Uint8List? _mean; // pass-1 mean RGB (fallback where pass 2 kept nothing)
  Uint8List? _sigma; // pass-1 brightness σ
  bool _inPass2 = false;

  static int _lum(int r, int g, int b) => (r * 77 + g * 150 + b * 29) >> 8;

  void addPass1(Uint8List rgb, Uint8List valid) {
    final sq = _lumSq;
    for (var o = 0; o < count.length; o++) {
      if (valid[o] == 0) continue;
      final d = o * 3;
      final r = rgb[d], g = rgb[d + 1], b = rgb[d + 2];
      sum[d] += r;
      sum[d + 1] += g;
      sum[d + 2] += b;
      count[o]++;
      if (sq != null) {
        final l = _lum(r, g, b);
        sq[o] += l * l;
      }
    }
  }

  /// Packs the pass-1 mean and σ into bytes and clears the sums for pass 2.
  void finishPass1() {
    final sq = _lumSq;
    if (sq == null) return;
    final n = count.length;
    final mean = Uint8List(n * 3), sigma = Uint8List(n);
    for (var o = 0; o < n; o++) {
      final c = count[o];
      if (c == 0) continue;
      final d = o * 3;
      final r = (sum[d] / c).round(), g = (sum[d + 1] / c).round(), b = (sum[d + 2] / c).round();
      mean[d] = r;
      mean[d + 1] = g;
      mean[d + 2] = b;
      final m = (sum[d] * 77 + sum[d + 1] * 150 + sum[d + 2] * 29) / (256 * c);
      sigma[o] = min(255, sqrt(max(0, sq[o] / c - m * m)).ceil());
    }
    _lumSq = null;
    _mean = mean;
    _sigma = sigma;
    sum.fillRange(0, sum.length, 0);
    count.fillRange(0, count.length, 0);
    _inPass2 = true;
  }

  void addPass2(Uint8List rgb, Uint8List valid) {
    final mean = _mean!, sigma = _sigma!;
    for (var o = 0; o < count.length; o++) {
      if (valid[o] == 0) continue;
      final d = o * 3;
      final r = rgb[d], g = rgb[d + 1], b = rgb[d + 2];
      final limit = max(kappa * sigma[o], 3.0);
      if ((_lum(r, g, b) - _lum(mean[d], mean[d + 1], mean[d + 2])).abs() > limit) continue;
      sum[d] += r;
      sum[d + 1] += g;
      sum[d + 2] += b;
      count[o]++;
    }
  }

  /// Final RGBA image. Pixels no frame covered stay black.
  Uint8List result() {
    final out = Uint8List(width * height * 4);
    final mean = _inPass2 ? _mean : null;
    for (var o = 0; o < count.length; o++) {
      final d = o * 3, p = o * 4;
      final n = count[o];
      if (n > 0) {
        out[p] = (sum[d] / n).round();
        out[p + 1] = (sum[d + 1] / n).round();
        out[p + 2] = (sum[d + 2] / n).round();
      } else if (mean != null) {
        out[p] = mean[d];
        out[p + 1] = mean[d + 1];
        out[p + 2] = mean[d + 2];
      }
      out[p + 3] = 255;
    }
    return out;
  }
}

/// Bilinear downscale of RGBA (for growing-trail video frames).
Uint8List resizeRgba(Uint8List src, int w, int h, int ow, int oh) {
  final out = Uint8List(ow * oh * 4);
  final kx = w / ow, ky = h / oh;
  for (var y = 0; y < oh; y++) {
    final sy = min((y + 0.5) * ky - 0.5, h - 1.0).clamp(0.0, h - 1.0);
    final y0 = sy.floor(), y1 = min(y0 + 1, h - 1);
    final fy = sy - y0;
    for (var x = 0; x < ow; x++) {
      final sx = min((x + 0.5) * kx - 0.5, w - 1.0).clamp(0.0, w - 1.0);
      final x0 = sx.floor(), x1 = min(x0 + 1, w - 1);
      final fx = sx - x0;
      final o = (y * ow + x) * 4;
      for (var c = 0; c < 3; c++) {
        final top = src[(y0 * w + x0) * 4 + c] * (1 - fx) + src[(y0 * w + x1) * 4 + c] * fx;
        final bottom = src[(y1 * w + x0) * 4 + c] * (1 - fx) + src[(y1 * w + x1) * 4 + c] * fx;
        out[o + c] = (top * (1 - fy) + bottom * fy).round();
      }
      out[o + 3] = 255;
    }
  }
  return out;
}
