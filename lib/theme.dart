import 'package:flutter/material.dart';

class EmberColors {
  static const Color primary = Color(0xFFFF6A3D);
  static const Color primaryDim = Color(0xFFE6552B);
  static const Color bgDeep = Color(0xFF0B0B0F);
  static const Color bgPanel = Color(0xFF14141B);
  static const Color bgElevated = Color(0xFF1B1B24);
  static const Color stroke = Color(0xFF26262F);
  static const Color textHigh = Color(0xFFF2EDE6);
  static const Color textMid = Color(0xFFAAA499);
  static const Color textDim = Color(0xFF6E6A60);
  static const Color danger = Color(0xFFE5484D);
  static const Color success = Color(0xFF22C55E);
}

ThemeData emberTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  final scheme = ColorScheme.dark(
    primary: EmberColors.primary,
    onPrimary: Colors.white,
    secondary: EmberColors.primaryDim,
    onSecondary: Colors.white,
    surface: EmberColors.bgPanel,
    onSurface: EmberColors.textHigh,
    error: EmberColors.danger,
    onError: Colors.white,
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: EmberColors.bgDeep,
    appBarTheme: const AppBarTheme(
      backgroundColor: EmberColors.bgDeep,
      foregroundColor: EmberColors.textHigh,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: EmberColors.textHigh,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: EmberColors.bgPanel,
      indicatorColor: EmberColors.primary.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? EmberColors.primary : EmberColors.textMid,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? EmberColors.primary : EmberColors.textMid,
          size: 22,
        );
      }),
    ),
    dividerColor: EmberColors.stroke,
    cardTheme: const CardThemeData(
      color: EmberColors.bgPanel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: EmberColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: EmberColors.bgElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: EmberColors.stroke),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: EmberColors.stroke),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: EmberColors.primary, width: 1.5),
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: EmberColors.textHigh,
      displayColor: EmberColors.textHigh,
    ),
  );
}
