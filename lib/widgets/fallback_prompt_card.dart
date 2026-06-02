// Wave CY.18.99: inline card shown in a failed assistant-message slot,
// asking whether to retry the generation on another provider. Replaces
// the snackbar+Retry error UX for fallback-eligible cases. Stateless —
// the chat screen owns the decision and the regeneration.

import 'package:flutter/material.dart';
import '../theme.dart';

enum FallbackReason { infra, refusal }

class FallbackPromptCard extends StatelessWidget {
  final FallbackReason reason;

  /// Display name of the provider that just failed.
  final String failedName;

  /// Display name of the next provider in the chain (the default target).
  final String nextName;

  /// Optional clean-record alternative (refusal case only). When non-null
  /// the card leads with it and demotes "next" to a secondary action.
  final String? cleanName;

  final VoidCallback onTryNext;
  final VoidCallback? onTryClean;
  final VoidCallback onKeep;

  const FallbackPromptCard({
    super.key,
    required this.reason,
    required this.failedName,
    required this.nextName,
    required this.onTryNext,
    required this.onKeep,
    this.cleanName,
    this.onTryClean,
  });

  @override
  Widget build(BuildContext context) {
    final isRefusal = reason == FallbackReason.refusal;
    final title = isRefusal
        ? 'Looks like $failedName declined this.'
        : '$failedName didn\'t respond.';
    final icon = isRefusal ? Icons.block : Icons.cloud_off;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: EmberColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Refusal + clean alternative: lead with the clean one.
              if (isRefusal && cleanName != null && onTryClean != null)
                ElevatedButton(
                  onPressed: onTryClean,
                  child: Text('Try $cleanName'),
                ),
              // Primary/next action. Demoted to outlined when a clean
              // alternative is leading.
              (isRefusal && cleanName != null)
                  ? OutlinedButton(
                      onPressed: onTryNext,
                      child: Text('Try $nextName anyway'),
                    )
                  : ElevatedButton(
                      onPressed: onTryNext,
                      child: Text('Try $nextName'),
                    ),
              TextButton(
                onPressed: onKeep,
                child: const Text('Keep'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
