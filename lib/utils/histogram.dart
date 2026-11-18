import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 256-bin luminance + RGB histogram of a photo.
class Histogram {
  Histogram._(this.luma, this.red, this.green, this.blue, this.total);

  final List<int> luma;
  final List<int> red;
  final List<int> green;
  final List<int> blue;
  final int total;

  /// Builds a histogram from raw RGBA8888 pixels.
  factory Histogram.fromRgba(Uint8List rgba) {
    final l = List<int>.filled(256, 0);
    final r = List<int>.filled(256, 0);
    final g = List<int>.filled(256, 0);
    final b = List<int>.filled(256, 0);
    var n = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      final rv = rgba[i], gv = rgba[i + 1], bv = rgba[i + 2];
      r[rv]++;
      g[gv]++;
      b[bv]++;
      l[(0.2126 * rv + 0.7152 * gv + 0.0722 * bv).round().clamp(0, 255)]++;
      n++;
    }
    return Histogram._(l, r, g, b, n);
  }

  /// Decodes a downscaled copy of the photo at [path] and measures it.
  static Future<Histogram?> fromFile(String path, {int width = 320}) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: width);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      codec.dispose();
      return data == null ? null : Histogram.fromRgba(data.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  /// Share of pixels at or above 250 (blown stars/light pollution).
  double get clippedHighlights => _share(250, 255);

  /// Share of pixels at or below 4 (crushed shadows: lost faint stars).
  double get clippedShadows => _share(0, 4);

  /// Position of the main peak, 0..1 (ignores the clipped ends).
  double get peakPosition {
    var best = 5;
    for (var i = 6; i < 250; i++) {
      if (luma[i] > luma[best]) best = i;
    }
    return best / 255;
  }

  double _share(int from, int to) {
    if (total == 0) return 0;
    var s = 0;
    for (var i = from; i <= to; i++) {
      s += luma[i];
    }
    return s / total;
  }

  /// Night-sky exposure advice. The usual target is a sky peak around
  /// 1/4 to 1/3 from the left.
  String get astroAdvice {
    final peak = peakPosition;
    // Check highlights first: a blown-out frame has no mid-tone peak at all.
    if (clippedHighlights > 0.02 || peak > 0.55) {
      return 'Too bright: lower ISO or shutter';
    }
    if (clippedShadows > 0.5 || peak < 0.08) {
      return 'Underexposed: raise ISO or shutter';
    }
    if (peak < 0.15) return 'A bit dark (peak ${(peak * 100).round()}%)';
    if (peak > 0.40) return 'A bit bright (peak ${(peak * 100).round()}%)';
    return 'Good sky exposure (peak ${(peak * 100).round()}%)';
  }

  int get maxCount => [for (var i = 1; i < 255; i++) luma[i]].fold(1, max);
}
