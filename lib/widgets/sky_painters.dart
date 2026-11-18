import 'dart:math';

import 'package:flutter/material.dart';

import '../astro/astronomy.dart';
import '../astro/night_report.dart';

/// Draws the moon's lit portion for a given phase (0 new … 0.5 full … 1).
class MoonIcon extends StatelessWidget {
  const MoonIcon({super.key, required this.phase, this.size = 64});
  final double phase;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MoonPainter(phase));
}

class _MoonPainter extends CustomPainter {
  _MoonPainter(this.phase);
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF2A2F3A));

    // Terminator is an ellipse with horizontal radius |cos(2π·phase)|·r.
    final k = cos(2 * pi * phase);
    final waxing = phase < 0.5;
    final lit = Path();
    // Lit limb: right half when waxing (northern hemisphere view), left when waning.
    lit.addArc(Rect.fromCircle(center: c, radius: r), -pi / 2, waxing ? pi : -pi);
    final ellipse = Rect.fromCenter(center: c, width: 2 * r * k.abs(), height: 2 * r);
    // Close through the terminator back to the top. A crescent's terminator
    // bulges towards the lit limb, a gibbous one away from it.
    final sweepBack = (waxing ? -1 : 1) * (k > 0 ? 1 : -1) * pi;
    lit.arcTo(ellipse, pi / 2, sweepBack, false);
    lit.close();
    canvas.drawPath(lit, Paint()..color = const Color(0xFFF2EBD9));
  }

  @override
  bool shouldRepaint(covariant _MoonPainter old) => old.phase != phase;
}

/// Horizontal timeline from sunset to sunrise: sky darkness bands with the
/// moon-up periods drawn as a strip underneath.
class NightTimeline extends StatelessWidget {
  const NightTimeline({super.key, required this.report, required this.formatTime});
  final NightReport report;
  final String Function(DateTime) formatTime;

  @override
  Widget build(BuildContext context) {
    final start = (report.sunset ?? report.windowStart.add(const Duration(hours: 6)))
        .subtract(const Duration(minutes: 30));
    final end = (report.sunrise ?? report.windowEnd.subtract(const Duration(hours: 6)))
        .add(const Duration(minutes: 30));
    final ticks = <DateTime>[];
    var t = DateTime.utc(start.year, start.month, start.day, start.hour).add(const Duration(hours: 1));
    while (t.isBefore(end)) {
      ticks.add(t);
      t = t.add(const Duration(hours: 2));
    }
    return Column(
      children: [
        SizedBox(
          height: 54,
          child: CustomPaint(
            size: Size.infinite,
            painter: _TimelinePainter(report, start, end),
          ),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (context, c) {
          final total = end.difference(start).inSeconds;
          return SizedBox(
            height: 14,
            child: Stack(
              children: [
                for (final tick in ticks)
                  Positioned(
                    left: (tick.difference(start).inSeconds / total * c.maxWidth - 16).clamp(0, c.maxWidth - 32),
                    width: 32,
                    child: Text(formatTime(tick).substring(0, 2),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10, color: Colors.white54)),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.r, this.start, this.end);
  final NightReport r;
  final DateTime start;
  final DateTime end;

  static const _day = Color(0xFF4A6FA5);
  static const _civil = Color(0xFF33507A);
  static const _nautical = Color(0xFF1F3150);
  static const _astro = Color(0xFF131C30);
  static const _dark = Color(0xFF05070C);

  @override
  void paint(Canvas canvas, Size size) {
    final totalMin = end.difference(start).inMinutes;
    double x(DateTime t) => t.difference(start).inMinutes / totalMin * size.width;
    final barH = size.height - 22; // leaves room for the moon and core strips

    // Sky colour sampled every 5 minutes from the sun's altitude.
    for (var m = 0; m < totalMin; m += 5) {
      final t = start.add(Duration(minutes: m));
      final alt = sunAltitude(t, r.lat, r.lon);
      final color = alt > Horizon.sun
          ? _day
          : alt > Horizon.civil
              ? _civil
              : alt > Horizon.nautical
                  ? _nautical
                  : alt > Horizon.astronomical
                      ? _astro
                      : _dark;
      canvas.drawRect(Rect.fromLTWH(x(t), 0, size.width * 5 / totalMin + 0.5, barH), Paint()..color = color);
    }

    // Moon-up strip.
    final moonY = barH + 6;
    final moonPaint = Paint()..color = const Color(0xFFF2EBD9).withValues(alpha: 0.25 + 0.6 * r.moon.fraction);
    for (var m = 0; m < totalMin; m += 5) {
      final t = start.add(Duration(minutes: m));
      if (moonAltitude(t, r.lat, r.lon) > Horizon.moon) {
        canvas.drawRect(Rect.fromLTWH(x(t), moonY, size.width * 5 / totalMin + 0.5, 6), moonPaint);
      }
    }

    // Milky Way core strip (core high enough to photograph).
    final coreY = moonY + 9;
    final corePaint = Paint()..color = const Color(0xFFB98CFF);
    for (var m = 0; m < totalMin; m += 5) {
      final t = start.add(Duration(minutes: m));
      if (coreAltitude(t, r.lat, r.lon) >= Horizon.coreUseful) {
        canvas.drawRect(Rect.fromLTWH(x(t), coreY, size.width * 5 / totalMin + 0.5, 6), corePaint);
      }
    }

    // Outline of the darkness bar.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, barH), const Radius.circular(4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white24,
    );
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => old.r != r;
}
