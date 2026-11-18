import 'package:flutter/material.dart';

/// App-wide toggle for the red night-vision mode.
final ValueNotifier<bool> nightVision = ValueNotifier<bool>(false);

ThemeData buildTheme() {
  const accent = Color(0xFF7FB2FF);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(surface: const Color(0xFF0B0D12));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.black,
    sliderTheme: const SliderThemeData(showValueIndicator: ShowValueIndicator.onDrag),
  );
}

/// Turns everything on screen (UI *and* camera preview) into dim red, which
/// keeps your eyes dark-adapted at night.
class NightVisionFilter extends StatelessWidget {
  const NightVisionFilter({super.key, required this.child});
  final Widget child;

  static const _redOnly = ColorFilter.matrix(<double>[
    0.30, 0.59, 0.11, 0, 0, // R = luminance
    0, 0, 0, 0, 0, //          G = 0
    0, 0, 0, 0, 0, //          B = 0
    0, 0, 0, 1, 0, //          A
  ]);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: nightVision,
      builder: (context, on, _) =>
          on ? ColorFiltered(colorFilter: _redOnly, child: child) : child,
    );
  }
}
