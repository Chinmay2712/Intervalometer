import 'package:flutter/material.dart';

import 'ui/tokens.dart';

/// App-wide toggle for the red night-vision mode.
final ValueNotifier<bool> nightVision = ValueNotifier<bool>(false);

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: V.ion,
    onPrimary: V.onIon,
    primaryContainer: V.raised,
    onPrimaryContainer: V.text,
    secondary: V.nebula,
    onSecondary: V.onIon,
    secondaryContainer: V.raised,
    onSecondaryContainer: V.text,
    tertiary: V.aurora,
    error: V.signal,
    onError: V.onIon,
    surface: V.surface,
    onSurface: V.text,
    onSurfaceVariant: V.textDim,
    surfaceContainerLowest: V.night,
    surfaceContainerLow: V.surface,
    surfaceContainer: V.surface,
    surfaceContainerHigh: V.raised,
    surfaceContainerHighest: V.raised,
    outline: Color(0x33FFFFFF),
    outlineVariant: V.line,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = base.textTheme.apply(bodyColor: V.text, displayColor: V.text).copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2, color: V.text),
        titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: V.text),
        bodySmall: base.textTheme.bodySmall?.copyWith(color: V.textDim),
      );
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rMedium));
  const minTouch = Size(V.touch, V.touch);
  const outline = BorderSide(color: Color(0x33FFFFFF));

  return base.copyWith(
    scaffoldBackgroundColor: V.night,
    canvasColor: V.surface,
    textTheme: text,
    dividerTheme: const DividerThemeData(color: V.line, thickness: 1, space: 1),
    iconTheme: const IconThemeData(color: V.text),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: minTouch, foregroundColor: V.text, disabledForegroundColor: V.textFaint),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: V.ion,
        foregroundColor: V.onIon,
        disabledBackgroundColor: V.raised,
        disabledForegroundColor: V.textFaint,
        minimumSize: const Size(64, V.touch),
        shape: rounded,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 0.2),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: V.text,
        minimumSize: const Size(64, V.touch),
        side: outline,
        shape: rounded,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: V.ion,
        minimumSize: minTouch,
        shape: rounded,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: V.raised,
        foregroundColor: V.text,
        elevation: 0,
        shape: rounded,
        side: const BorderSide(color: V.line),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, V.touch)),
        side: const WidgetStatePropertyAll(outline),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? V.ion : V.surface.withValues(alpha: 0.6),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? V.textFaint
              : s.contains(WidgetState.selected)
                  ? V.onIon
                  : V.textDim,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? V.onIon : V.textDim,
        ),
        textStyle: WidgetStatePropertyAll(text.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 14)),
        shape: WidgetStatePropertyAll(rounded),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: V.surface,
      selectedColor: V.ion,
      secondarySelectedColor: V.ion,
      labelStyle: text.labelLarge?.copyWith(color: V.text, fontWeight: FontWeight.w600),
      secondaryLabelStyle: text.labelLarge?.copyWith(color: V.onIon, fontWeight: FontWeight.w700),
      checkmarkColor: V.onIon,
      side: outline,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rSmall)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    sliderTheme: const SliderThemeData(
      showValueIndicator: ShowValueIndicator.onDrag,
      activeTrackColor: V.ion,
      inactiveTrackColor: Color(0x26FFFFFF),
      thumbColor: V.text,
      trackHeight: 3,
      overlayColor: Color(0x228DB8FF),
      valueIndicatorColor: V.raised,
      valueIndicatorTextStyle: TextStyle(color: V.text, fontWeight: FontWeight.w700),
    ),
    switchTheme: SwitchThemeData(
      // On = dark thumb on the bright accent track, off = dim thumb on a dark
      // track: readable by brightness alone (night vision).
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? V.onIon : V.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? V.ion : V.raised),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? V.ion : const Color(0x33FFFFFF),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: V.surface,
      modalBackgroundColor: V.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: Color(0x55FFFFFF),
      dragHandleSize: Size(36, 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(V.rLarge)),
        side: BorderSide(color: V.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: V.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rLarge), side: const BorderSide(color: V.line)),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium?.copyWith(color: V.textDim, height: 1.4),
    ),
    cardTheme: CardThemeData(
      color: V.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rLarge), side: const BorderSide(color: V.line)),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: V.textDim,
      textColor: V.text,
      minVerticalPadding: 10,
      subtitleTextStyle: TextStyle(color: V.textDim, fontSize: 13),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: V.raised,
      contentTextStyle: const TextStyle(color: V.text, fontSize: 14),
      actionTextColor: V.ion,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rMedium), side: const BorderSide(color: V.line)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: V.raised, borderRadius: BorderRadius.circular(8), border: Border.all(color: V.line)),
      textStyle: const TextStyle(color: V.text, fontSize: 12),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: V.ion, linearTrackColor: V.raised),
    popupMenuTheme: PopupMenuThemeData(
      color: V.raised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V.rMedium), side: const BorderSide(color: V.line)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: V.raised,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(V.rMedium), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(V.rMedium),
        borderSide: const BorderSide(color: V.ion, width: 1.5),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: V.night,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontSize: 20),
    ),
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
