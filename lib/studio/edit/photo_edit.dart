/// Non-destructive photo editing for Studio results: geometry (crop, rotate,
/// straighten, flip), astro tools (background neutralise, noise reduction,
/// star reduction, sharpen, clarity), tone and colour, and a tone curve.
///
/// Everything here is pure Dart on RGBA bytes so it can run in an isolate.
library;

import 'dart:math';
import 'dart:typed_data';

class RgbaImage {
  const RgbaImage(this.data, this.width, this.height);
  final Uint8List data;
  final int width;
  final int height;

  RgbaImage copy() => RgbaImage(Uint8List.fromList(data), width, height);
}

/// Crop in normalised coordinates (0..1) of the rotated/straightened photo.
class CropRect {
  const CropRect(this.left, this.top, this.right, this.bottom);
  static const full = CropRect(0, 0, 1, 1);

  final double left, top, right, bottom;
  double get width => right - left;
  double get height => bottom - top;
  bool get isFull => left <= 0.0005 && top <= 0.0005 && right >= 0.9995 && bottom >= 0.9995;

  @override
  bool operator ==(Object other) =>
      other is CropRect && other.left == left && other.top == top && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

class PhotoEdit {
  const PhotoEdit({
    this.exposure = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.blacks = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.tint = 0,
    this.curve = const [0.25, 0.5, 0.75],
    this.background = 0,
    this.noise = 0,
    this.starReduction = 0,
    this.sharpen = 0,
    this.clarity = 0,
    this.quarterTurns = 0,
    this.flip = false,
    this.straighten = 0,
    this.crop = CropRect.full,
    this.look,
  });

  // Light
  final double exposure; // EV, -2..2
  final double contrast; // -1..1
  final double highlights; // -1..1
  final double shadows; // -1..1
  final double blacks; // -1 (lift) .. 1 (crush)

  // Colour
  final double saturation; // -1..1
  final double warmth; // -1 (blue) .. 1 (amber)
  final double tint; // -1 (green) .. 1 (magenta)

  /// Tone curve outputs at inputs 0.25, 0.5 and 0.75 (ends fixed at 0 and 1).
  final List<double> curve;

  // Astro
  final double background; // 0..1 light-pollution / gradient removal
  final double noise; // 0..1
  final double starReduction; // 0..1
  final double sharpen; // 0..1
  final double clarity; // -1..1

  // Geometry
  final int quarterTurns; // clockwise
  final bool flip; // horizontal
  final double straighten; // degrees, -15..15
  final CropRect crop;

  /// Name of the look last applied (for highlighting in the UI).
  final String? look;

  bool get hasGeometry => quarterTurns % 4 != 0 || flip || straighten != 0 || !crop.isFull;
  bool get hasAstro => background > 0 || noise > 0 || starReduction > 0 || sharpen > 0 || clarity != 0;
  bool get hasCurve => (curve[0] - 0.25).abs() > 1e-3 || (curve[1] - 0.5).abs() > 1e-3 || (curve[2] - 0.75).abs() > 1e-3;
  bool get hasTone =>
      exposure != 0 ||
      contrast != 0 ||
      highlights != 0 ||
      shadows != 0 ||
      blacks != 0 ||
      saturation != 0 ||
      warmth != 0 ||
      tint != 0 ||
      hasCurve;
  bool get isIdentity => !hasGeometry && !hasAstro && !hasTone;

  PhotoEdit copyWith({
    double? exposure,
    double? contrast,
    double? highlights,
    double? shadows,
    double? blacks,
    double? saturation,
    double? warmth,
    double? tint,
    List<double>? curve,
    double? background,
    double? noise,
    double? starReduction,
    double? sharpen,
    double? clarity,
    int? quarterTurns,
    bool? flip,
    double? straighten,
    CropRect? crop,
    String? look,
    bool clearLook = false,
  }) =>
      PhotoEdit(
        exposure: exposure ?? this.exposure,
        contrast: contrast ?? this.contrast,
        highlights: highlights ?? this.highlights,
        shadows: shadows ?? this.shadows,
        blacks: blacks ?? this.blacks,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
        tint: tint ?? this.tint,
        curve: curve ?? this.curve,
        background: background ?? this.background,
        noise: noise ?? this.noise,
        starReduction: starReduction ?? this.starReduction,
        sharpen: sharpen ?? this.sharpen,
        clarity: clarity ?? this.clarity,
        quarterTurns: quarterTurns ?? this.quarterTurns,
        flip: flip ?? this.flip,
        straighten: straighten ?? this.straighten,
        crop: crop ?? this.crop,
        look: clearLook ? null : (look ?? this.look),
      );

  /// Applies a look's light, colour, curve and astro settings; keeps geometry.
  PhotoEdit withLook(Look l) {
    final e = l.edit;
    return PhotoEdit(
      exposure: e.exposure,
      contrast: e.contrast,
      highlights: e.highlights,
      shadows: e.shadows,
      blacks: e.blacks,
      saturation: e.saturation,
      warmth: e.warmth,
      tint: e.tint,
      curve: e.curve,
      background: e.background,
      noise: e.noise,
      starReduction: e.starReduction,
      sharpen: e.sharpen,
      clarity: e.clarity,
      quarterTurns: quarterTurns,
      flip: flip,
      straighten: straighten,
      crop: crop,
      look: l.name,
    );
  }

  /// Only light, colour and curve (what video frames get).
  PhotoEdit get toneOnly => PhotoEdit(
        exposure: exposure,
        contrast: contrast,
        highlights: highlights,
        shadows: shadows,
        blacks: blacks,
        saturation: saturation,
        warmth: warmth,
        tint: tint,
        curve: curve,
        look: look,
      );
}

class Look {
  const Look(this.name, this.edit);
  final String name;
  final PhotoEdit edit;
}

/// One-tap astro looks.
const kLooks = <Look>[
  Look('Original', PhotoEdit()),
  Look('Natural', PhotoEdit(contrast: 0.1, saturation: 0.1, background: 0.6, noise: 0.25, clarity: 0.15)),
  Look('Deep blue', PhotoEdit(warmth: -0.4, tint: 0.05, contrast: 0.22, blacks: 0.15, saturation: 0.2, background: 0.7, curve: [0.22, 0.5, 0.78])),
  Look('Warm core', PhotoEdit(warmth: 0.3, saturation: 0.3, clarity: 0.4, contrast: 0.15, shadows: 0.2, background: 0.5)),
  Look('Punchy', PhotoEdit(contrast: 0.35, clarity: 0.5, saturation: 0.25, highlights: -0.3, blacks: 0.2, sharpen: 0.3, background: 0.6)),
  Look('Soft', PhotoEdit(contrast: -0.1, noise: 0.55, starReduction: 0.4, shadows: 0.15)),
  Look('Mono', PhotoEdit(saturation: -1, contrast: 0.3, clarity: 0.3, blacks: 0.1, curve: [0.2, 0.5, 0.8])),
];

// ------------------------------------------------------------------ render

/// Applies [e] to [src] (never modified). With [skipCrop] the crop is not
/// applied (used while the crop frame is being edited).
RgbaImage renderEdit(RgbaImage src, PhotoEdit e, {bool skipCrop = false}) {
  var img = (e.hasGeometry && !(skipCrop && e.quarterTurns % 4 == 0 && !e.flip && e.straighten == 0))
      ? applyGeometry(src, e, skipCrop: skipCrop)
      : src.copy();
  if (e.background > 0) neutraliseBackground(img, e.background);
  if (e.noise > 0) reduceNoise(img, e.noise);
  if (e.starReduction > 0) reduceStars(img, e.starReduction);
  if (e.sharpen > 0) sharpenImage(img, e.sharpen);
  if (e.clarity != 0) addClarity(img, e.clarity);
  if (e.hasTone) applyTone(img, e);
  return img;
}

/// Zoom needed so a frame rotated by [radians] still covers [w]×[h].
double straightenScale(int w, int h, double radians) {
  final c = cos(radians).abs(), s = sin(radians).abs();
  return max((w * c + h * s) / w, (w * s + h * c) / h);
}

/// Size of the photo after quarter turns (before crop).
(int, int) orientedSize(int w, int h, int quarterTurns) => quarterTurns.isOdd ? (h, w) : (w, h);

RgbaImage applyGeometry(RgbaImage s, PhotoEdit e, {bool skipCrop = false}) {
  final q = e.quarterTurns % 4;
  final sw = s.width, sh = s.height, src = s.data;
  final (ow, oh) = orientedSize(sw, sh, q);
  final a = e.straighten * pi / 180;
  final ca = cos(a), sa = sin(a);
  final scale = straightenScale(ow, oh, a);
  final crop = skipCrop ? CropRect.full : e.crop;
  final outW = max(1, (crop.width * ow).round());
  final outH = max(1, (crop.height * oh).round());
  final out = Uint8List(outW * outH * 4);
  final cx = ow / 2, cy = oh / 2;
  final x0 = crop.left * ow, y0 = crop.top * oh;

  for (var y = 0; y < outH; y++) {
    for (var x = 0; x < outW; x++) {
      final u = x0 + x + 0.5 - cx, v = y0 + y + 0.5 - cy;
      var px = (u * ca + v * sa) / scale + cx - 0.5;
      final py = (-u * sa + v * ca) / scale + cy - 0.5;
      if (e.flip) px = ow - 1 - px;
      double sx, sy;
      switch (q) {
        case 1:
          sx = py;
          sy = sh - 1 - px;
        case 2:
          sx = sw - 1 - px;
          sy = sh - 1 - py;
        case 3:
          sx = sw - 1 - py;
          sy = px;
        default:
          sx = px;
          sy = py;
      }
      sx = sx.clamp(0.0, sw - 1.0);
      sy = sy.clamp(0.0, sh - 1.0);
      final ix = sx.floor(), iy = sy.floor();
      final ix1 = min(ix + 1, sw - 1), iy1 = min(iy + 1, sh - 1);
      final fx = sx - ix, fy = sy - iy;
      final p00 = (iy * sw + ix) * 4, p10 = (iy * sw + ix1) * 4;
      final p01 = (iy1 * sw + ix) * 4, p11 = (iy1 * sw + ix1) * 4;
      final o = (y * outW + x) * 4;
      for (var c = 0; c < 3; c++) {
        final top = src[p00 + c] + (src[p10 + c] - src[p00 + c]) * fx;
        final bottom = src[p01 + c] + (src[p11 + c] - src[p01 + c]) * fx;
        out[o + c] = (top + (bottom - top) * fy).round();
      }
      out[o + 3] = 255;
    }
  }
  return RgbaImage(out, outW, outH);
}

// ------------------------------------------------------------- astro tools

int _clamp8(num v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

Float32List _luminance(Uint8List d, int n) {
  final l = Float32List(n);
  for (var i = 0, p = 0; i < n; i++, p += 4) {
    l[i] = 0.2126 * d[p] + 0.7152 * d[p + 1] + 0.0722 * d[p + 2];
  }
  return l;
}

/// Separable box blur of one float channel, radius [r].
Float32List boxBlurF(Float32List src, int w, int h, int r) {
  if (r < 1) return Float32List.fromList(src);
  final tmp = Float32List(w * h), out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    var acc = 0.0;
    for (var x = -r; x <= r; x++) {
      acc += src[row + x.clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      tmp[row + x] = acc / (2 * r + 1);
      acc += src[row + min(x + r + 1, w - 1)] - src[row + max(x - r, 0)];
    }
  }
  for (var x = 0; x < w; x++) {
    var acc = 0.0;
    for (var y = -r; y <= r; y++) {
      acc += tmp[y.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = acc / (2 * r + 1);
      acc += tmp[min(y + r + 1, h - 1) * w + x] - tmp[max(y - r, 0) * w + x];
    }
  }
  return out;
}

/// Box blur of the RGB channels (alpha untouched), radius [r].
Uint8List boxBlurRgba(Uint8List d, int w, int h, int r) {
  final n = w * h;
  final out = Uint8List(n * 4);
  final ch = Float32List(n);
  for (var c = 0; c < 3; c++) {
    for (var i = 0; i < n; i++) {
      ch[i] = d[i * 4 + c].toDouble();
    }
    final b = boxBlurF(ch, w, h, r);
    for (var i = 0; i < n; i++) {
      out[i * 4 + c] = _clamp8(b[i]);
    }
  }
  for (var i = 3; i < out.length; i += 4) {
    out[i] = 255;
  }
  return out;
}

/// Removes light-pollution colour casts and gradients: estimates the sky
/// background on a coarse grid (25th percentile per channel, robust to stars
/// and the Milky Way) and subtracts it down to a dark neutral grey.
void neutraliseBackground(RgbaImage img, double amount) {
  final w = img.width, h = img.height, d = img.data;
  final cell = max(8, (max(w, h) / 12).ceil());
  final gx = (w / cell).ceil(), gy = (h / cell).ceil();
  final bg = Float32List(gx * gy * 3);
  final hist = Int32List(256 * 3);
  final step = max(1, cell ~/ 24);
  for (var cyi = 0; cyi < gy; cyi++) {
    for (var cxi = 0; cxi < gx; cxi++) {
      hist.fillRange(0, hist.length, 0);
      var count = 0;
      for (var y = cyi * cell; y < min(h, (cyi + 1) * cell); y += step) {
        for (var x = cxi * cell; x < min(w, (cxi + 1) * cell); x += step) {
          final p = (y * w + x) * 4;
          hist[d[p]]++;
          hist[256 + d[p + 1]]++;
          hist[512 + d[p + 2]]++;
          count++;
        }
      }
      final target = max(1, count ~/ 4);
      for (var c = 0; c < 3; c++) {
        var acc = 0, v = 0;
        while (v < 255 && acc + hist[c * 256 + v] < target) {
          acc += hist[c * 256 + v];
          v++;
        }
        bg[(cyi * gx + cxi) * 3 + c] = v.toDouble();
      }
    }
  }
  // 3×3 median of cells per channel: ignores a single bright cell (moon glow, core).
  final smooth = Float32List(bg.length);
  final window = <double>[];
  for (var cyi = 0; cyi < gy; cyi++) {
    for (var cxi = 0; cxi < gx; cxi++) {
      for (var c = 0; c < 3; c++) {
        window.clear();
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final yy = cyi + dy, xx = cxi + dx;
            if (yy >= 0 && yy < gy && xx >= 0 && xx < gx) window.add(bg[(yy * gx + xx) * 3 + c]);
          }
        }
        window.sort();
        smooth[(cyi * gx + cxi) * 3 + c] = window[window.length ~/ 2];
      }
    }
  }
  var targetGrey = double.infinity;
  for (var i = 0; i < gx * gy; i++) {
    targetGrey = min(targetGrey, (smooth[i * 3] + smooth[i * 3 + 1] + smooth[i * 3 + 2]) / 3);
  }
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) / cell - 0.5).clamp(0.0, gy - 1.0);
    final y0 = fy.floor(), y1 = min(y0 + 1, gy - 1);
    final ty = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = ((x + 0.5) / cell - 0.5).clamp(0.0, gx - 1.0);
      final x0 = fx.floor(), x1 = min(x0 + 1, gx - 1);
      final tx = fx - x0;
      final p = (y * w + x) * 4;
      for (var c = 0; c < 3; c++) {
        final a = smooth[(y0 * gx + x0) * 3 + c], b = smooth[(y0 * gx + x1) * 3 + c];
        final cc = smooth[(y1 * gx + x0) * 3 + c], dd = smooth[(y1 * gx + x1) * 3 + c];
        final v = (a + (b - a) * tx) * (1 - ty) + (cc + (dd - cc) * tx) * ty;
        d[p + c] = _clamp8(d[p + c] - amount * (v - targetGrey));
      }
    }
  }
}

/// Edge-aware smoothing: blurs flat sky, leaves stars and edges alone.
void reduceNoise(RgbaImage img, double amount) {
  final w = img.width, h = img.height, d = img.data;
  final blurred = boxBlurRgba(d, w, h, amount > 0.5 ? 2 : 1);
  for (var p = 0; p < d.length; p += 4) {
    final l = 0.2126 * d[p] + 0.7152 * d[p + 1] + 0.0722 * d[p + 2];
    final lb = 0.2126 * blurred[p] + 0.7152 * blurred[p + 1] + 0.0722 * blurred[p + 2];
    final wgt = amount * (1 - ((l - lb).abs() / 40)).clamp(0.0, 1.0);
    if (wgt <= 0) continue;
    for (var c = 0; c < 3; c++) {
      d[p + c] = _clamp8(d[p + c] + (blurred[p + c] - d[p + c]) * wgt);
    }
  }
}

/// Shrinks stars (3×3 minimum filter blended in only where stars are).
void reduceStars(RgbaImage img, double amount) {
  final w = img.width, h = img.height, d = img.data, n = w * h;
  final passes = amount > 0.6 ? 2 : 1;
  var eroded = Uint8List.fromList(d);
  for (var pass = 0; pass < passes; pass++) {
    final tmp = Uint8List.fromList(eroded);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = (y * w + x) * 4;
        for (var c = 0; c < 3; c++) {
          var m = eroded[p + c];
          if (x > 0 && eroded[p - 4 + c] < m) m = eroded[p - 4 + c];
          if (x < w - 1 && eroded[p + 4 + c] < m) m = eroded[p + 4 + c];
          tmp[p + c] = m;
        }
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = (y * w + x) * 4;
        for (var c = 0; c < 3; c++) {
          var m = tmp[p + c];
          if (y > 0 && tmp[p - w * 4 + c] < m) m = tmp[p - w * 4 + c];
          if (y < h - 1 && tmp[p + w * 4 + c] < m) m = tmp[p + w * 4 + c];
          eroded[p + c] = m;
        }
      }
    }
  }
  final lum = _luminance(d, n);
  final local = boxBlurF(lum, w, h, max(4, min(w, h) ~/ 200));
  var star = Float32List(n);
  for (var i = 0; i < n; i++) {
    star[i] = ((lum[i] - local[i] - 6) / 30).clamp(0.0, 1.0);
  }
  star = boxBlurF(star, w, h, 1); // include the star's halo
  for (var i = 0; i < n; i++) {
    final k = (amount * star[i] * 2.5).clamp(0.0, 1.0);
    if (k <= 0) continue;
    final p = i * 4;
    for (var c = 0; c < 3; c++) {
      d[p + c] = _clamp8(d[p + c] + (eroded[p + c] - d[p + c]) * k);
    }
  }
}

/// Unsharp mask, radius 1.
void sharpenImage(RgbaImage img, double amount) {
  final blurred = boxBlurRgba(img.data, img.width, img.height, 1);
  final d = img.data;
  for (var p = 0; p < d.length; p += 4) {
    for (var c = 0; c < 3; c++) {
      d[p + c] = _clamp8(d[p + c] + (d[p + c] - blurred[p + c]) * amount * 1.5);
    }
  }
}

/// Local midtone contrast (large-radius unsharp mask on luminance).
void addClarity(RgbaImage img, double amount) {
  final w = img.width, h = img.height, d = img.data, n = w * h;
  final lum = _luminance(d, n);
  final r = max(3, min(w, h) ~/ 60);
  final blur = boxBlurF(boxBlurF(lum, w, h, r), w, h, r);
  for (var i = 0; i < n; i++) {
    final l = lum[i] / 255;
    final mid = 1 - pow((2 * l - 1).abs(), 2);
    final delta = amount * (lum[i] - blur[i]) * mid * 0.9;
    final p = i * 4;
    d[p] = _clamp8(d[p] + delta);
    d[p + 1] = _clamp8(d[p + 1] + delta);
    d[p + 2] = _clamp8(d[p + 2] + delta);
  }
}

// ------------------------------------------------------------ tone & colour

double _srgbToLinear(double v) => v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
double _linearToSrgb(double v) => v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055;

double _smoothstep(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Monotone cubic (Fritsch–Carlson) through (0,0),(.25,c0),(.5,c1),(.75,c2),(1,1).
List<double> curveLut(List<double> c) {
  final xs = [0.0, 0.25, 0.5, 0.75, 1.0];
  final ys = [0.0, c[0], c[1], c[2], 1.0];
  final n = xs.length;
  final dk = List<double>.generate(n - 1, (i) => (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]));
  final m = List<double>.filled(n, 0);
  m[0] = dk[0];
  m[n - 1] = dk[n - 2];
  for (var i = 1; i < n - 1; i++) {
    m[i] = dk[i - 1] * dk[i] <= 0 ? 0 : (dk[i - 1] + dk[i]) / 2;
  }
  for (var i = 0; i < n - 1; i++) {
    if (dk[i] == 0) {
      m[i] = 0;
      m[i + 1] = 0;
      continue;
    }
    final a = m[i] / dk[i], b = m[i + 1] / dk[i];
    final s = a * a + b * b;
    if (s > 9) {
      final t = 3 / sqrt(s);
      m[i] = t * a * dk[i];
      m[i + 1] = t * b * dk[i];
    }
  }
  return List<double>.generate(256, (i) {
    final x = i / 255;
    var k = min((x / 0.25).floor(), n - 2);
    final hh = xs[k + 1] - xs[k];
    final t = (x - xs[k]) / hh;
    final t2 = t * t, t3 = t2 * t;
    final y = (2 * t3 - 3 * t2 + 1) * ys[k] +
        (t3 - 2 * t2 + t) * hh * m[k] +
        (-2 * t3 + 3 * t2) * ys[k + 1] +
        (t3 - t2) * hh * m[k + 1];
    return y.clamp(0.0, 1.0);
  });
}

/// Light, colour and curve, in place. [gain] scales brightness (deflicker).
void applyTone(RgbaImage img, PhotoEdit e, {double gain = 1}) {
  final evScale = pow(2, e.exposure).toDouble() * gain;
  final bp = e.blacks * 0.12;
  final lut1 = Float64List(256);
  for (var i = 0; i < 256; i++) {
    var v = _linearToSrgb((_srgbToLinear(i / 255) * evScale).clamp(0.0, 1.0));
    v = bp >= 0 ? (v - bp) / (1 - bp) : -bp + v * (1 + bp);
    lut1[i] = v.clamp(0.0, 1.0);
  }
  final k = tan((e.contrast * 0.8 + 1) * pi / 4);
  final curve = curveLut(e.curve);
  final lut2 = Uint8List(1024); // 4× resolution for smoother gradients
  for (var i = 0; i < 1024; i++) {
    var v = ((i / 1023 - 0.5) * k + 0.5).clamp(0.0, 1.0);
    final f = v * 255;
    final lo = f.floor().clamp(0, 254);
    v = curve[lo] + (curve[lo + 1] - curve[lo]) * (f - lo);
    lut2[i] = _clamp8(v * 255);
  }
  final hl = e.highlights, sh = e.shadows, sat = 1 + e.saturation;
  final wr = 1 + 0.12 * e.warmth, wb = 1 - 0.12 * e.warmth, tg = 1 - 0.10 * e.tint;
  final d = img.data;
  for (var p = 0; p < d.length; p += 4) {
    var r = lut1[d[p]], g = lut1[d[p + 1]], b = lut1[d[p + 2]];
    if (hl != 0 || sh != 0) {
      final l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      var l2 = l;
      if (hl != 0) l2 += hl * _smoothstep(0.45, 1, l) * (hl < 0 ? (l - 0.45) * 0.7 : (1 - l) * 0.5);
      if (sh != 0) l2 += sh * (1 - _smoothstep(0, 0.5, l)) * (sh > 0 ? (0.5 - l) * 0.6 : l * 0.6);
      if (l > 0.02) {
        final gn = l2 / l;
        r *= gn;
        g *= gn;
        b *= gn;
      } else {
        r += l2 - l;
        g += l2 - l;
        b += l2 - l;
      }
    }
    if (sat != 1) {
      final l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      r = l + (r - l) * sat;
      g = l + (g - l) * sat;
      b = l + (b - l) * sat;
    }
    r *= wr;
    b *= wb;
    g *= tg;
    d[p] = lut2[(r.clamp(0.0, 1.0) * 1023).round()];
    d[p + 1] = lut2[(g.clamp(0.0, 1.0) * 1023).round()];
    d[p + 2] = lut2[(b.clamp(0.0, 1.0) * 1023).round()];
  }
}

/// Fast 4×5 colour-matrix approximation of the tone settings (for live video
/// playback, where per-pixel rendering every frame would be too slow).
List<double> approximateColorMatrix(PhotoEdit e, {double gain = 1}) {
  final s = pow(pow(2, e.exposure) * gain, 1 / 2.2).toDouble();
  final k = tan((e.contrast * 0.8 + 1) * pi / 4);
  final sat = 1 + e.saturation;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final mr = [1 + 0.12 * e.warmth, 1 - 0.10 * e.tint, 1 - 0.12 * e.warmth];
  final lift = -e.blacks * 0.12 * 255 + e.shadows * 10;
  final rows = <double>[];
  for (var row = 0; row < 3; row++) {
    final coeffs = [
      (row == 0 ? sat : 0) + (1 - sat) * lr,
      (row == 1 ? sat : 0) + (1 - sat) * lg,
      (row == 2 ? sat : 0) + (1 - sat) * lb,
    ];
    for (var c = 0; c < 3; c++) {
      rows.add(coeffs[c] * s * k * mr[row]);
    }
    rows.add(0);
    rows.add(127.5 * (1 - k) + lift);
  }
  rows.addAll([0, 0, 0, 1, 0]);
  return rows;
}
