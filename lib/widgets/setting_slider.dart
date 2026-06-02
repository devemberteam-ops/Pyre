import 'package:flutter/material.dart';

import '../theme.dart';

/// Wave CY.18.192: a labelled slider Card with a subtitle, a tap-to-type
/// numeric input dialog (bypasses the slider's snap-grid for precise
/// values), and an optional "preset override" badge.
///
/// Extracted from the now-deleted Model Settings screen so it can be
/// reused by the Presets screen (global sampling defaults) and the
/// Character Creator (creator knobs). The `overrideValue` param is
/// optional and defaults off — only the Presets screen passes it (to
/// show when the active preset overrides a global default).
class SliderCard extends StatelessWidget {
  final String label;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// When set, this slider is currently being overridden by the active
  /// preset — we dim the slider's own value, show the preset value in
  /// primary colour, and append an "overridden" badge so the user knows
  /// their change here won't take effect while the preset is selected.
  final String? overrideValue;

  const SliderCard({
    super.key,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    this.onChangeEnd,
    this.overrideValue,
  });

  /// Format a min/max bound for the dialog hint. Integer bounds drop
  /// the decimals; fractional bounds show 2 decimal places.
  String _fmtBound(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  /// Open an inline number-input dialog so the user can type the value
  /// directly instead of fighting the slider for precision. Out-of-range
  /// values get clamped silently; invalid input is ignored. Bypasses
  /// the slider's `divisions` snap-grid — useful for precise tokens.
  Future<void> _openEditDialog(BuildContext context) async {
    final controller = TextEditingController(text: display);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: display.length,
    );
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Enter a number',
                isDense: true,
              ),
              onSubmitted: (s) => Navigator.pop(ctx, s),
            ),
            const SizedBox(height: 8),
            Text(
              'Range: ${_fmtBound(min)} – ${_fmtBound(max)}',
              style: const TextStyle(
                color: EmberColors.textDim,
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (raw == null) return;
    // Accept either `.` or `,` as decimal separator (PT-BR habit).
    final parsed = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (parsed == null) return;
    final clamped = parsed.clamp(min, max);
    onChanged(clamped);
    onChangeEnd?.call(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final isOverridden = overrideValue != null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(label,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          if (isOverridden) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: EmberColors.primary
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'PRESET OVERRIDE',
                                style: TextStyle(
                                  color: EmberColors.primary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            color: EmberColors.textMid, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (isOverridden)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        overrideValue!,
                        style: const TextStyle(
                          color: EmberColors.primary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      // Underlying value (dimmed) — tap to type, even
                      // though the preset override takes precedence.
                      InkWell(
                        onTap: () => _openEditDialog(context),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'was $display',
                                style: const TextStyle(
                                  color: EmberColors.textDim,
                                  fontSize: 10,
                                  fontFeatures: [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                              const SizedBox(width: 3),
                              const Icon(Icons.edit,
                                  size: 10, color: EmberColors.textDim),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  // Tap-to-type: bypasses the slider grid for precise
                  // values (especially useful for max_tokens where a
                  // 512-token step snap is annoying when you want
                  // exactly 12000).
                  InkWell(
                    onTap: () => _openEditDialog(context),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            display,
                            style: const TextStyle(
                              color: EmberColors.textMid,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.edit,
                              size: 12, color: EmberColors.textDim),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            Opacity(
              opacity: isOverridden ? 0.45 : 1.0,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8),
                ),
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  activeColor: EmberColors.primary,
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
