// Wave B — Theme settings screen.
//
// Lets the user pick one of the three curated palettes (Ember / Moonlit /
// Hearth) and optionally override the primary accent color on top of the
// chosen palette. Both controls call the already-shipped AppStore methods
// (setActiveTheme / setAccentColor) so the whole app recolors live.
//
// Section layout:
//   1. Theme tiles — one card per palette in kCuratedPalettes.  Each tile
//      shows the palette name and a 5-chip swatch row preview
//      (bgDeep / bgPanel / bgElevated / primary / textHigh).  The active
//      theme gets a primary-colored border + check icon.
//   2. Accent color — a "Match theme" chip (accent = null) plus a curated
//      row of tinted accent swatches.  The same circular-swatch widget used
//      in chat_appearance_screen.dart's bubble-color row, for consistency.
//
// Constraints observed:
//   • Does NOT modify theme.dart, models.dart, or app_store.dart.
//   • Does NOT touch bubble / chat appearance behavior.
//   • Uses EmberColors.* for its own chrome (screen follows active theme).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../theme.dart';

// ---------------------------------------------------------------------------
// Accent swatch palette (curated, ~10 options).
// Mirrors the _bubblePalette spirit from chat_appearance_screen.dart but
// with theme-appropriate accent-grade hues rather than dark bubble tones.
// A leading `null` entry = "Match theme" (clears the accent override).
// ---------------------------------------------------------------------------
const List<int?> _kAccentPalette = <int?>[
  null, // Match theme — accent = null → primary comes from the palette itself
  0xFFFF6A3D, // Ember orange
  0xFF8FA8FF, // Moonlit periwinkle
  0xFFE8A24C, // Hearth amber
  0xFFD46A9E, // Rose pink
  0xFF64C8A0, // Mint teal
  0xFF6EC6FF, // Sky blue
  0xFFB388FF, // Lavender
  0xFFFF7B7B, // Coral red
  0xFFFFC84A, // Sunflower
  0xFF80CBC4, // Seafoam
];

// ---------------------------------------------------------------------------
// Public screen widget
// ---------------------------------------------------------------------------

class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final activeId = store.uiPrefs.activeThemeId;
    final accentArgb = store.uiPrefs.accentArgb;

    return Scaffold(
      appBar: AppBar(title: const Text('Theme')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          // ── Section: Theme ───────────────────────────────────────────────
          _SectionLabel(label: 'Theme'),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (int i = 0; i < kCuratedPalettes.length; i++) ...[
                  if (i > 0)
                    Divider(
                      color: EmberColors.stroke,
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                    ),
                  _ThemeTile(
                    palette: kCuratedPalettes[i],
                    isSelected: kCuratedPalettes[i].id == activeId,
                    onTap: () =>
                        context.read<AppStore>().setActiveTheme(kCuratedPalettes[i].id),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          // ── Section: Accent color ─────────────────────────────────────────
          _SectionLabel(label: 'Accent color'),
          const SizedBox(height: 4),
          Text(
            'Replaces the primary color across the active theme. '
            '"Match theme" restores the theme\'s built-in accent.',
            style: TextStyle(color: EmberColors.textMid, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: _AccentRow(
                selectedArgb: accentArgb,
                onPick: (argb) =>
                    context.read<AppStore>().setAccentColor(argb),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section label — matches the "YOUR BUBBLE COLOR" label style used by the
// chat appearance screen but adopts the More-screen card header style
// (textMid, all-caps, small).
// ---------------------------------------------------------------------------
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: EmberColors.textDim,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ThemeTile — one row per palette.  Shows the name, a 5-chip swatch
// preview, and a selected-state border + check.
// ---------------------------------------------------------------------------
class _ThemeTile extends StatelessWidget {
  final EmberPalette palette;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeTile({
    required this.palette,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: isSelected
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: EmberColors.primary,
                  width: 2,
                ),
              )
            : null,
        child: Row(
          children: [
            // Palette name + swatch preview
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    palette.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _PaletteSwatchRow(palette: palette),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Check or empty placeholder
            if (isSelected)
              Icon(Icons.check_circle_rounded,
                  color: EmberColors.primary, size: 22)
            else
              const SizedBox(width: 22),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _PaletteSwatchRow — 5 rectangular chips showing bgDeep / bgPanel /
// bgElevated / primary / textHigh for at-a-glance preview.
// ---------------------------------------------------------------------------
class _PaletteSwatchRow extends StatelessWidget {
  final EmberPalette palette;
  const _PaletteSwatchRow({required this.palette});

  @override
  Widget build(BuildContext context) {
    // 5 chips: three backgrounds, the accent, and the text color.
    final chips = [
      palette.bgDeep,
      palette.bgPanel,
      palette.bgElevated,
      palette.primary,
      palette.textHigh,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < chips.length; i++)
          Container(
            width: 28,
            height: 20,
            margin: EdgeInsets.only(right: i < chips.length - 1 ? 4 : 0),
            decoration: BoxDecoration(
              color: chips[i],
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: EmberColors.stroke.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _AccentRow — "Match theme" ChoiceChip + circular color swatches.
// Reuses the same circular-swatch pattern as chat_appearance_screen.dart's
// _BubbleColorRow / _Swatch, kept private here to avoid coupling.
// ---------------------------------------------------------------------------
class _AccentRow extends StatelessWidget {
  final int? selectedArgb;
  final ValueChanged<int?> onPick;

  const _AccentRow({
    required this.selectedArgb,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final argb in _kAccentPalette)
          if (argb == null)
            // "Match theme" chip
            ChoiceChip(
              label: const Text('Match theme'),
              selected: selectedArgb == null,
              selectedColor: EmberColors.primary.withValues(alpha: 0.22),
              onSelected: (_) => onPick(null),
            )
          else
            _AccentSwatch(
              color: Color(argb),
              selected: selectedArgb == argb,
              onTap: () => onPick(argb),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _AccentSwatch — circular tappable swatch with a selection ring + check.
// Identical behaviour to chat_appearance_screen.dart's _Swatch; kept private
// so that screen's internals are not imported.
// ---------------------------------------------------------------------------
class _AccentSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _AccentSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? EmberColors.primary : EmberColors.stroke,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            // 2026-07-03 review (L3): accent swatches include light hues
            // (Sunflower/Sky/Seafoam) where the cream check was invisible —
            // pick the readable foreground per swatch.
            ? Icon(Icons.check, size: 16, color: foregroundOnAccent(color))
            : null,
      ),
    );
  }
}
