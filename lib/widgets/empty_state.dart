import 'package:flutter/material.dart';

import '../theme.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  /// Optional CTA shown below the subtitle. Pair with [ctaLabel] to
  /// surface the canonical action right where the empty state explains
  /// what's missing.
  final VoidCallback? onCta;
  final String? ctaLabel;
  final IconData? ctaIcon;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onCta,
    this.ctaLabel,
    this.ctaIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: EmberColors.bgElevated,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: EmberColors.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: EmberColors.textHigh,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: EmberColors.textMid,
                height: 1.4,
              ),
            ),
            if (onCta != null && ctaLabel != null) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: onCta,
                icon: Icon(ctaIcon ?? Icons.add, size: 16),
                label: Text(ctaLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
