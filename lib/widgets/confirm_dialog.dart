import 'package:flutter/material.dart';

import '../theme.dart';

/// Shows a small "Are you sure?" dialog for destructive actions.
///
/// Returns `true` when the user explicitly confirms via the danger-coloured
/// button. Tapping Cancel or dismissing the dialog (back / scrim tap)
/// resolves to `false`. Callers wire this in as a one-liner:
///
/// ```dart
/// if (!await confirmDelete(context,
///       title: 'Delete chat?',
///       message: 'This conversation will be lost forever.')) return;
/// store.removeChat(id);
/// ```
///
/// Use sparingly — only for actions that destroy persistent data the user
/// can't trivially recreate (entire chat, character, persona, lorebook,
/// preset). Individual messages already require a long-press to reach the
/// delete option, which is a sufficient guard.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  String cancelLabel = 'Cancel',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Text(title),
      content: Text(
        message,
        style: const TextStyle(color: EmberColors.textMid),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: EmberColors.danger),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
