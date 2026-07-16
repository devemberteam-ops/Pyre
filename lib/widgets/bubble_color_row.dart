// Customization audit follow-up (2026-07-15): the bubble color swatch row,
// EXTRACTED from chat_appearance_screen (where it was private) so the
// character editor's per-character bubble tint reuses the exact same palette
// and interaction — one source, no drift.

import 'package:flutter/material.dart';

import '../theme.dart';

/// Pyre 1.1 — F2: the curated bubble palette. A few Ember-warm tones plus
/// dark neutrals — enough to differentiate speakers without a full
/// color-picker dependency. The leading `null` entry is the "Default" chip
/// (clears the override).
const List<int?> kBubbleColorPalette = <int?>[
  null, // Default
  0xFF14141B, // bgPanel (the legacy base, explicit)
  0xFF1B1B24, // bgElevated (slightly lighter neutral)
  0xFF2A1D17, // warm umber
  0xFF3A2018, // ember brown
  0xFF1A2230, // cool slate blue
  0xFF152619, // deep green
  0xFF241526, // muted plum
  0xFF2C2233, // dusk violet
];

/// A row of tappable color swatches plus a leading "Default" chip. Tapping a
/// swatch reports its ARGB int; tapping Default reports `null`. The
/// currently-selected entry gets a ring.
class BubbleColorRow extends StatelessWidget {
  final int? selected;
  final List<int?> palette;
  final ValueChanged<int?> onPick;
  const BubbleColorRow({
    super.key,
    required this.selected,
    this.palette = kBubbleColorPalette,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final argb in palette)
          if (argb == null)
            ChoiceChip(
              label: const Text('Default'),
              selected: selected == null,
              selectedColor: EmberColors.primary.withValues(alpha: 0.25),
              onSelected: (_) => onPick(null),
            )
          else
            BubbleColorSwatch(
              color: Color(argb),
              selected: selected == argb,
              onTap: () => onPick(argb),
            ),
      ],
    );
  }
}

/// A single circular color swatch with a selection ring.
class BubbleColorSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const BubbleColorSwatch({
    super.key,
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
            ? Icon(Icons.check, size: 16, color: EmberColors.textHigh)
            : null,
      ),
    );
  }
}
