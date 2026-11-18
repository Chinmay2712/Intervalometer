import 'dart:math';

import 'photo_edit.dart';

enum LoopMode { off, pingPong }

/// Edits for a timelapse or growing-trails video, applied by re-encoding
/// the source frames.
class VideoEdit {
  const VideoEdit({
    required this.trimStart,
    required this.trimEnd,
    required this.fps,
    this.loop = LoopMode.off,
    this.tone = const PhotoEdit(),
    this.deflicker = 0,
  });

  /// First and last frame index used (inclusive).
  final int trimStart;
  final int trimEnd;
  final int fps;
  final LoopMode loop;

  /// Light, colour and curve applied to every frame.
  final PhotoEdit tone;

  /// 0 = off … 1 = strongest smoothing of brightness jumps.
  final double deflicker;

  VideoEdit copyWith({int? trimStart, int? trimEnd, int? fps, LoopMode? loop, PhotoEdit? tone, double? deflicker}) =>
      VideoEdit(
        trimStart: trimStart ?? this.trimStart,
        trimEnd: trimEnd ?? this.trimEnd,
        fps: fps ?? this.fps,
        loop: loop ?? this.loop,
        tone: tone ?? this.tone,
        deflicker: deflicker ?? this.deflicker,
      );

  /// Frame indices in playback order.
  List<int> frameOrder() {
    final forward = [for (var i = trimStart; i <= trimEnd; i++) i];
    if (loop == LoopMode.off || forward.length < 3) return forward;
    return [...forward, ...forward.reversed.skip(1).take(forward.length - 2)];
  }

  double durationSeconds() => frameOrder().length / fps;

  /// True if every output frame is an untouched source frame.
  bool get passThroughPixels => tone.toneOnly.isIdentity && deflicker == 0;
}

/// Per-frame brightness gains that pull each frame towards a moving average
/// of its neighbours (removes flicker, keeps slow changes like dusk).
List<double> deflickerGains(List<double> meanLuminance, double strength) {
  final n = meanLuminance.length;
  if (n == 0 || strength <= 0) return List.filled(n, 1.0);
  final radius = 1 + (strength * 10).round();
  final gains = List<double>.filled(n, 1);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    var count = 0;
    for (var j = max(0, i - radius); j <= min(n - 1, i + radius); j++) {
      sum += meanLuminance[j];
      count++;
    }
    final target = sum / count;
    final m = meanLuminance[i];
    final full = m < 0.5 ? 1.0 : target / m;
    gains[i] = (1 + (full - 1) * strength.clamp(0.0, 1.0)).clamp(0.5, 2.0);
  }
  return gains;
}
