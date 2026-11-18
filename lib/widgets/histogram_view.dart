import 'dart:math';

import 'package:flutter/material.dart';

import '../utils/histogram.dart';

/// Draws a histogram: filled luminance plus thin R/G/B lines.
/// Uses a square-root scale so the dark night-sky peak stays readable.
class HistogramView extends StatelessWidget {
  const HistogramView({super.key, required this.histogram, this.showRgb = true});
  final Histogram histogram;
  final bool showRgb;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _HistogramPainter(histogram, showRgb), size: Size.infinite);
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.h, this.showRgb);
  final Histogram h;
  final bool showRgb;

  @override
  void paint(Canvas canvas, Size size) {
    final top = sqrt(h.maxCount.toDouble());
    double y(int count) => size.height - (sqrt(count.toDouble()) / top).clamp(0.0, 1.0) * size.height;
    double x(int i) => i / 255 * size.width;

    // Guides at 1/4 and 1/3: the usual target zone for a night sky.
    final zone = Paint()..color = Colors.white.withValues(alpha: 0.08);
    canvas.drawRect(Rect.fromLTRB(size.width / 4, 0, size.width / 3, size.height), zone);

    final fill = Path()..moveTo(0, size.height);
    for (var i = 0; i < 256; i++) {
      fill.lineTo(x(i), y(h.luma[i]));
    }
    fill
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = Colors.white.withValues(alpha: 0.55));

    if (showRgb) {
      for (final (bins, color) in [
        (h.red, Colors.redAccent),
        (h.green, Colors.greenAccent),
        (h.blue, Colors.lightBlueAccent),
      ]) {
        final line = Path()..moveTo(0, y(bins[0]));
        for (var i = 1; i < 256; i++) {
          line.lineTo(x(i), y(bins[i]));
        }
        canvas.drawPath(
          line,
          Paint()
            ..color = color.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter old) => old.h != h || old.showRgb != showRgb;
}
