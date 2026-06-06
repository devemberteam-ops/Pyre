// Mega-audit 2026-06-05 (H-4): the WARNING dialog shown before a pull is
// applied when the user picked SyncConflictMode.ask and a genuine conflict
// (the same item changed on BOTH devices since the last sync) was detected.
//
// It lists the conflicting items (type + name + which side is newer) and lets
// the user choose, GLOBALLY, to keep This device or take the Other device.
// Dismissing (tapping outside / back) returns null → the engine aborts the
// apply this tick rather than silently last-writer-wins.

import 'package:flutter/material.dart';

import '../services/sync_conflict.dart';
import '../theme.dart';

/// Human label for a conflict's collection kind.
String _kindLabel(String kind) {
  switch (kind) {
    case 'character':
      return 'Character';
    case 'persona':
      return 'Persona';
    case 'chat':
      return 'Chat';
    case 'preset':
      return 'Preset';
    case 'lorebook':
      return 'Lorebook';
    case 'regexRule':
      return 'Regex rule';
    case 'folder':
      return 'Folder';
    case 'creatorPreset':
      return 'Creator preset';
    default:
      return kind;
  }
}

/// Show the conflict warning. Returns:
///   * `true`  → take the OTHER device (apply incoming),
///   * `false` → keep THIS device (skip incoming),
///   * `null`  → dismissed → caller aborts the apply.
Future<bool?> showSyncConflictDialog(
  BuildContext context,
  List<SyncConflict> conflicts,
) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Sync conflict'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360, maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                conflicts.length == 1
                    ? '1 item was changed on both this device and the other '
                        'device since the last sync. Choose which copy to keep.'
                    : '${conflicts.length} items were changed on both this '
                        'device and the other device since the last sync. '
                        'Choose which copy to keep (applies to all).',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: conflicts.length,
                  itemBuilder: (_, i) {
                    final c = conflicts[i];
                    final name = c.remote.name.isNotEmpty
                        ? c.remote.name
                        : (c.local.name.isNotEmpty ? c.local.name : c.id);
                    final newer = c.newerSideLabel; // "This device"/"Other device"
                    final deletedNote = c.remote.deleted
                        ? ' · deleted on other device'
                        : (c.local.deleted ? ' · deleted on this device' : '');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '• ${_kindLabel(c.kind)}: $name  '
                        '(newer: $newer$deletedNote)',
                        style: const TextStyle(
                          fontSize: 12,
                          color: EmberColors.textMid,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep this device'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Take other device'),
          ),
        ],
      );
    },
  );
}
