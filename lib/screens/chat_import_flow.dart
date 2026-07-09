// UI flow for importing a single Pyre chat file (1.2.1 #3). Pyre can EXPORT a
// chat (chat_screen → "Export chat") as either a full-fidelity `pyre.chat.v1`
// JSON or a SillyTavern-compatible `.jsonl`; this is the missing IMPORT side.
//
// Thin shell around the PURE services/chat_import.dart: pick a file, run
// importChat (format auto-detected), add the reconstructed chat via
// store.addImportedChat (the SAME method the ST-backup path uses), then show a
// summary dialog — or a readable error snackbar on failure. Nothing is ever
// half-imported: importChat throws BEFORE returning a chat on unusable input.
//
// ignore_for_file: use_build_context_synchronously

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/chat_import.dart';
import '../state/app_store.dart';
import '../theme.dart';

/// Hard cap on a chat import — a single chat file is small; anything past this
/// is almost certainly corrupt or a JSON bomb. Refusing early avoids an OOM /
/// pathological decode. Matches the spirit of the backup-import cap.
const int _kMaxChatImportBytes = 25 * 1024 * 1024;

/// Entry point wired from Backup & Restore. Picks ONE `.json` / `.jsonl` chat
/// file, imports it, and reports the outcome. Safe to call with a stale
/// context — every async gap is guarded.
Future<void> runPyreChatImport(BuildContext context, AppStore store) async {
  final messenger = ScaffoldMessenger.of(context);

  final FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json', 'jsonl'],
      withData: true,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open picker: $e')));
    return;
  }
  if (result == null || result.files.isEmpty) return;

  final file = result.files.single;
  final bytes = file.bytes;
  if (bytes == null) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Could not read the chat file.')));
    return;
  }
  if (bytes.length > _kMaxChatImportBytes) {
    messenger.showSnackBar(SnackBar(
        content: Text(
            'Chat file is too large (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB). Max 25 MB.')));
    return;
  }

  final String content;
  try {
    content = utf8.decode(bytes);
  } catch (_) {
    messenger.showSnackBar(const SnackBar(
        content: Text("This file isn't valid text — it may be corrupted.")));
    return;
  }

  final ChatImportResult imported;
  try {
    imported = importChat(
      content,
      knownCharacterIds: store.characters.map((c) => c.id).toSet(),
      existingChatIds: store.chats.map((c) => c.id).toSet(),
    );
  } on ChatImportException catch (e) {
    // Typed, human-readable reason — no crash, nothing added.
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    return;
  }

  // Freeze a per-chat snapshot from the live card when the chat bound to a
  // library character but carries no snapshot (the JSONL path) — parity with
  // how the ST-backup importer builds self-contained chats, so the chat still
  // renders if the card is later edited/deleted.
  final chat = imported.chat;
  final primary = chat.primaryCharacterId;
  if (imported.summary.characterBound &&
      primary != null &&
      chat.characterSnapshots.isEmpty) {
    final live = store.characterById(primary);
    if (live != null) {
      chat.characterSnapshots[primary] = Character.fromJson(live.toJson());
    }
  }

  store.addImportedChat(chat);

  if (!context.mounted) return;
  await _showChatImportSummary(context, imported.summary);
}

Future<void> _showChatImportSummary(
  BuildContext context,
  ChatImportSummary summary,
) async {
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';

  final formatLabel = switch (summary.format) {
    ChatImportFormat.pyreJson => 'Pyre JSON (full fidelity)',
    ChatImportFormat.pyreJsonl => 'Pyre JSONL',
    ChatImportFormat.foreignJsonl => 'SillyTavern JSONL',
  };

  final lines = <String>[
    'Imported "${summary.title}" — ${plural(summary.messageCount, 'message')}.',
  ];
  if (summary.variantCount > 0) {
    lines.add('${plural(summary.variantCount, 'message')} with saved '
        'alternates restored.');
  }
  lines.add(summary.characterBound
      ? 'Linked to its character in your library.'
      : 'Imported as a standalone chat.');
  lines.add('Format: $formatLabel.');
  lines.addAll(summary.warnings);

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Row(
        children: [
          Icon(Icons.download_done, color: EmberColors.primary, size: 22),
          const SizedBox(width: 10),
          const Expanded(child: Text('Chat imported')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              Text(
                lines[i],
                style: TextStyle(
                  color: i == 0 ? EmberColors.textHigh : EmberColors.textMid,
                  fontSize: 14,
                  height: 1.4,
                  fontWeight: i == 0 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}
