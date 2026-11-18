import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Horizontal ruler picker, like the dials in pro camera apps: drag the
/// scale under the fixed centre marker, or tap either side to step by one.
/// Each stop clicks (haptics), and the value applies while you drag.
class ScaleDial extends StatefulWidget {
  const ScaleDial({
    super.key,
    required this.count,
    required this.index,
    required this.onChanged,
    required this.label,
    this.majorEvery = 1,
    this.spacing = 56,
    this.enabled = true,
    this.semanticsLabel,
  });

  /// Number of stops.
  final int count;
  final int index;
  final ValueChanged<int> onChanged;

  /// Text for a stop (major tick labels and screen readers).
  final String Function(int index) label;

  /// Label every n-th stop.
  final int majorEvery;

  /// Pixels between stops.
  final double spacing;
  final bool enabled;
  final String? semanticsLabel;

  @override
  State<ScaleDial> createState() => _ScaleDialState();
}

class _ScaleDialState extends State<ScaleDial> with SingleTickerProviderStateMixin {
  late final AnimationController _snap;
  double? _dragPos; // fractional position while dragging/snapping

  double get _pos => _dragPos ?? widget.index.toDouble();
  int get _max => max(0, widget.count - 1);

  @override
  void initState() {
    super.initState();
    _snap = AnimationController.unbounded(vsync: this)..addListener(_onSnapTick);
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _onSnapTick() => setState(() => _dragPos = _snap.value);

  void _emit(int i) {
    final clamped = i.clamp(0, _max);
    if (clamped != widget.index) {
      HapticFeedback.selectionClick();
      widget.onChanged(clamped);
    }
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _snap.stop();
    final next = (_pos - d.delta.dx / widget.spacing).clamp(0.0, _max.toDouble());
    setState(() => _dragPos = next);
    _emit(next.round());
  }

  void _onDragEnd(DragEndDetails d) {
    // A flick carries on a little, then lands on a stop.
    final fling = -(d.primaryVelocity ?? 0) / widget.spacing * 0.12;
    final target = (_pos + fling).round().clamp(0, _max);
    _emit(target);
    final duration = V.motion(context, const Duration(milliseconds: 220));
    if (duration == Duration.zero) {
      setState(() => _dragPos = null);
      return;
    }
    _snap.value = _pos;
    _snap.animateTo(target.toDouble(), duration: duration, curve: Curves.easeOutCubic).whenComplete(() {
      if (mounted) setState(() => _dragPos = null);
    });
  }

  void _step(int dir) {
    _snap.stop();
    setState(() => _dragPos = null);
    _emit(widget.index + dir);
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.index;
    return Semantics(
      slider: true,
      label: widget.semanticsLabel,
      value: widget.label(i),
      increasedValue: i < _max ? widget.label(i + 1) : null,
      decreasedValue: i > 0 ? widget.label(i - 1) : null,
      onIncrease: widget.enabled && i < _max ? () => _step(1) : null,
      onDecrease: widget.enabled && i > 0 ? () => _step(-1) : null,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, c) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: widget.enabled ? _onDragUpdate : null,
              onHorizontalDragEnd: widget.enabled ? _onDragEnd : null,
              onTapUp: widget.enabled ? (d) => _step(d.localPosition.dx < c.maxWidth / 2 ? -1 : 1) : null,
              child: ClipRect(
                child: ShaderMask(
                  // Ticks fade out towards the edges.
                  shaderCallback: (r) => const LinearGradient(
                    colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
                    stops: [0, 0.18, 0.82, 1],
                  ).createShader(r),
                  blendMode: BlendMode.dstIn,
                  child: CustomPaint(
                    size: Size(c.maxWidth, 84),
                    painter: _DialPainter(
                      pos: _pos,
                      count: widget.count,
                      spacing: widget.spacing,
                      majorEvery: widget.majorEvery,
                      label: widget.label,
                      enabled: widget.enabled,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.pos,
    required this.count,
    required this.spacing,
    required this.majorEvery,
    required this.label,
    required this.enabled,
  });

  final double pos;
  final int count;
  final double spacing;
  final int majorEvery;
  final String Function(int) label;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    const tickTop = 14.0;
    final tick = Paint()..strokeCap = StrokeCap.round;
    final current = pos.round();
    // Minor ticks between stops when stops are far apart.
    final minor = spacing >= 40 ? 3 : 0;
    final first = max(0, (pos - cx / spacing).floor() - 1);
    final last = min(count - 1, (pos + cx / spacing).ceil() + 1);
    for (var i = first; i <= last; i++) {
      final x = cx + (i - pos) * spacing;
      final major = i % majorEvery == 0;
      tick
        ..strokeWidth = major ? 1.6 : 1
        ..color = (enabled ? V.text : V.textFaint).withValues(alpha: major ? 0.75 : 0.35);
      canvas.drawLine(Offset(x, tickTop), Offset(x, tickTop + (major ? 18 : 10)), tick);
      if (minor > 0 && i < count - 1) {
        tick
          ..strokeWidth = 1
          ..color = V.text.withValues(alpha: 0.22);
        for (var m = 1; m <= minor; m++) {
          final mx = x + spacing * m / (minor + 1);
          canvas.drawLine(Offset(mx, tickTop), Offset(mx, tickTop + 7), tick);
        }
      }
      if (major) {
        final selected = i == current;
        final tp = TextPainter(
          text: TextSpan(
            text: label(i),
            style: V.readout(
              selected ? 15 : 12,
              color: selected ? V.text : V.textDim,
              weight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: max(spacing * majorEvery - 4, 24));
        tp.paint(canvas, Offset(x - tp.width / 2, tickTop + 26));
      }
    }
    // Fixed centre marker: a bright bar with a small notch on top.
    final marker = Paint()
      ..color = enabled ? V.ion : V.textFaint
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, tickTop - 6), Offset(cx, tickTop + 24), marker);
    final notch = Path()
      ..moveTo(cx - 5, 0)
      ..lineTo(cx + 5, 0)
      ..lineTo(cx, 6)
      ..close();
    canvas.drawPath(notch, Paint()..color = enabled ? V.ion : V.textFaint);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.pos != pos || old.count != count || old.enabled != enabled || old.spacing != spacing;
}
