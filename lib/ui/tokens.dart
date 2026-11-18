import 'package:flutter/material.dart';

/// Valometer's design tokens: an "observatory instrument" look. Dim
/// blue-black surfaces that keep your eyes dark-adapted, hairline outlines,
/// one cool accent and condensed readouts for numbers.
///
/// Every state is also shown by brightness, shape or text, never by hue
/// alone, so it still reads through the red night-vision filter.
abstract final class V {
  // ---------------------------------------------------------------- colour
  /// Page background (blue-black, not pure black).
  static const night = Color(0xFF05070D);

  /// Sheets, cards, panels.
  static const surface = Color(0xFF0D1220);

  /// Raised elements on a surface (inputs, selected chips).
  static const raised = Color(0xFF161D2F);

  /// Primary text (contrast 16:1 on [surface]).
  static const text = Color(0xFFE6ECF7);

  /// Secondary text (7:1 on [surface]).
  static const textDim = Color(0xFF9AA4B8);

  /// Hints and disabled text (4.6:1 on [surface]).
  static const textFaint = Color(0xFF7A8499);

  /// Hairline outlines and dividers.
  static const line = Color(0x1FFFFFFF);

  /// The one accent: active, manual and primary actions.
  static const ion = Color(0xFF8DB8FF);

  /// Dark text/icons on top of [ion].
  static const onIon = Color(0xFF07101F);

  /// Second stop of the primary gradient.
  static const nebula = Color(0xFFB59CFF);

  /// Recording, stop and errors.
  static const signal = Color(0xFFFF6B6B);

  /// Warnings ("interval too short").
  static const amber = Color(0xFFFFB86B);

  /// Good / ready.
  static const aurora = Color(0xFF7FE0B5);

  static const ionGradient = LinearGradient(colors: [ion, nebula]);

  // ---------------------------------------------------------------- shape
  static const rSmall = 10.0;
  static const rMedium = 16.0;
  static const rLarge = 24.0;

  /// Minimum touch target (Fitts's law; Apple and Material both use ~44–48).
  static const touch = 48.0;

  // ---------------------------------------------------------------- type
  /// Condensed instrument face for values like ISO 3200, 1/30 s, 00:42.
  static const readoutFamily = 'Readout';

  static TextStyle readout(double size, {Color color = text, FontWeight weight = FontWeight.w700}) => TextStyle(
        fontFamily: readoutFamily,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: 0.4,
        height: 1.1,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  // ---------------------------------------------------------------- motion
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 280);

  /// Respects the system "reduce motion" setting.
  static Duration motion(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;
}

/// A frosted outline panel floating over the camera preview.
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    this.radius = V.rSmall,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (color ?? V.surface).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: V.line),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
