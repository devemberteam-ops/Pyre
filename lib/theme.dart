import 'package:flutter/material.dart';

// ============================================================================
// EmberPalette — the 11-color theme model
// ============================================================================

/// A named color palette that drives the whole-app appearance.
///
/// Every color in [EmberColors] reads from [EmberColors.active], so switching
/// the active palette (via [EmberColors.applyTheme]) recolors the entire app
/// on the next rebuild.
class EmberPalette {
  final String id;
  final String name;
  final Color primary;
  final Color primaryDim;
  final Color bgDeep;
  final Color bgPanel;
  final Color bgElevated;
  final Color stroke;
  final Color textHigh;
  final Color textMid;
  final Color textDim;
  final Color danger;
  final Color success;

  const EmberPalette({
    required this.id,
    required this.name,
    required this.primary,
    required this.primaryDim,
    required this.bgDeep,
    required this.bgPanel,
    required this.bgElevated,
    required this.stroke,
    required this.textHigh,
    required this.textMid,
    required this.textDim,
    required this.danger,
    required this.success,
  });

  /// Returns a copy of this palette with [primary] and [primaryDim] replaced
  /// by [accent] and a derived dim shade (80% brightness of the accent).
  EmberPalette withAccent(Color accent) {
    // Derive primaryDim: 80% brightness of the accent value.
    // We darken by scaling all RGB components to 80% and keeping full alpha.
    final dimmed = Color.fromARGB(
      255,
      (accent.r * 0.80 * 255).round().clamp(0, 255),
      (accent.g * 0.80 * 255).round().clamp(0, 255),
      (accent.b * 0.80 * 255).round().clamp(0, 255),
    );
    return EmberPalette(
      id: id,
      name: name,
      primary: accent,
      primaryDim: dimmed,
      bgDeep: bgDeep,
      bgPanel: bgPanel,
      bgElevated: bgElevated,
      stroke: stroke,
      textHigh: textHigh,
      textMid: textMid,
      textDim: textDim,
      danger: danger,
      success: success,
    );
  }
}

// ============================================================================
// Curated palettes
// ============================================================================

/// **Ember** — the original/default palette. Values are byte-identical to
/// the previous `static const Color` definitions. Existing users see no
/// visual change.
const EmberPalette _kEmber = EmberPalette(
  id: 'ember',
  name: 'Ember',
  primary: Color(0xFFFF6A3D),
  primaryDim: Color(0xFFE6552B),
  bgDeep: Color(0xFF0B0B0F),
  bgPanel: Color(0xFF14141B),
  bgElevated: Color(0xFF1B1B24),
  stroke: Color(0xFF26262F),
  textHigh: Color(0xFFF2EDE6),
  textMid: Color(0xFFAAA499),
  textDim: Color(0xFF6E6A60),
  danger: Color(0xFFE5484D),
  success: Color(0xFF22C55E),
);

/// **Moonlit** — cool periwinkle / midnight blue.
const EmberPalette _kMoonlit = EmberPalette(
  id: 'moonlit',
  name: 'Moonlit',
  primary: Color(0xFF8FA8FF),
  primaryDim: Color(0xFF6E86E0),
  bgDeep: Color(0xFF0A0C14),
  bgPanel: Color(0xFF121624),
  bgElevated: Color(0xFF1A1F30),
  stroke: Color(0xFF2A3042),
  textHigh: Color(0xFFECF0F8),
  textMid: Color(0xFF9AA3B5),
  textDim: Color(0xFF636B7D),
  danger: Color(0xFFE5484D),
  success: Color(0xFF34D399),
);

/// **Hearth** — warm sepia / amber dark.
const EmberPalette _kHearth = EmberPalette(
  id: 'hearth',
  name: 'Hearth',
  primary: Color(0xFFE8A24C),
  primaryDim: Color(0xFFC9863A),
  bgDeep: Color(0xFF100C0A),
  bgPanel: Color(0xFF1A1410),
  bgElevated: Color(0xFF221A14),
  stroke: Color(0xFF33271F),
  textHigh: Color(0xFFF3EADF),
  textMid: Color(0xFFB3A595),
  textDim: Color(0xFF75695C),
  danger: Color(0xFFE5484D),
  success: Color(0xFF22C55E),
);

/// Ordered list of all built-in palettes. Wave 2 UI iterates this list to
/// build the theme picker.
const List<EmberPalette> kCuratedPalettes = [
  _kEmber,
  _kMoonlit,
  _kHearth,
];

/// Returns the curated palette with the given [id], falling back to [_kEmber]
/// for any unknown id (including empty string).
EmberPalette paletteById(String id) {
  for (final p in kCuratedPalettes) {
    if (p.id == id) return p;
  }
  return _kEmber;
}

// ============================================================================
// EmberColors — runtime getters backed by the active palette
// ============================================================================

/// App-wide color API. Every widget reads `EmberColors.*`; switching the
/// active palette (via [applyTheme]) recolors the whole app on the next
/// rebuild triggered by [AppStore.notifyListeners].
///
/// The field names and public API are preserved exactly — the only change
/// from the original `static const Color` declarations is that these are
/// now `static Color get` getters. All 1 288 call sites across 62 files
/// continue to compile unchanged (minus `const` qualifiers — see NOTES below).
///
/// NOTES ON const BREAKAGE
/// -----------------------
/// Making these getters means they are no longer compile-time constants.
/// Every `Widget(color: EmberColors.x)` that Flutter previously
/// considered a const expression now needs the `const` keyword dropped.
/// The fix is purely mechanical (drop `const`); no layout or color value
/// is changed. The `emberTheme()` function itself can no longer use `const`
/// on its inner objects, which is also fixed below.
class EmberColors {
  EmberColors._();

  /// The currently active palette. Starts as [_kEmber] so the app looks
  /// identical to the previous hard-coded constants on first run.
  static EmberPalette active = _kEmber;

  // ── Getters ──────────────────────────────────────────────────────────────

  static Color get primary => active.primary;
  static Color get primaryDim => active.primaryDim;
  static Color get bgDeep => active.bgDeep;
  static Color get bgPanel => active.bgPanel;
  static Color get bgElevated => active.bgElevated;
  static Color get stroke => active.stroke;
  static Color get textHigh => active.textHigh;
  static Color get textMid => active.textMid;
  static Color get textDim => active.textDim;
  static Color get danger => active.danger;
  static Color get success => active.success;

  // ── applyTheme ───────────────────────────────────────────────────────────

  /// Switches the active palette to [themeId] (falls back to Ember for
  /// unknown ids) and optionally replaces primary + primaryDim with a
  /// custom [accentArgb] color.
  ///
  /// Pure / deterministic: the same (themeId, accentArgb) inputs always
  /// produce the same [active] state. Call [AppStore.notifyListeners] after
  /// this to trigger a rebuild of the whole app.
  static void applyTheme({required String themeId, int? accentArgb}) {
    EmberPalette palette = paletteById(themeId);
    if (accentArgb != null) {
      palette = palette.withAccent(Color(accentArgb));
    }
    active = palette;
  }
}

// ============================================================================
// ThemeData builder — palette-driven, called on every rebuild
// ============================================================================

/// Builds the app-wide [ThemeData] from the current [EmberColors.active]
/// palette. Called in the root [MaterialApp] `theme:` parameter on every
/// rebuild, so a palette switch takes effect immediately.
///
/// NOTE: none of the inner objects can be `const` any more because they
/// reference [EmberColors.*] getters (runtime values). This is intentional.
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
    appBarTheme: AppBarTheme(
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
    cardTheme: CardThemeData(
      color: EmberColors.bgPanel,
      elevation: 0,
      shape: const RoundedRectangleBorder(
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
        borderSide: BorderSide(color: EmberColors.stroke),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: EmberColors.stroke),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: EmberColors.primary, width: 1.5),
      ),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: EmberColors.textHigh,
      displayColor: EmberColors.textHigh,
    ),
  );
}
