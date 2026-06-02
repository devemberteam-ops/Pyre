// Export a Pyre chat to disk so the user can back it up, move it to
// another device, or share it with a friend.
//
// Two formats are supported:
//
//   - SillyTavern `.jsonl`  — portable, opens in SillyTavern / chub.ai.
//     One JSON object per line. The first line is a metadata header,
//     subsequent lines are messages. Lossy on Pyre features that have
//     no ST equivalent (variants, downstream snapshots, group
//     attribution, OOC distinction). The selected variant of each
//     message is exported as the canonical text.
//
//   - Pyre `.json`         — full fidelity. Direct `Chat.toJson()`
//     dump. Round-trips into Pyre's own restore path without losing
//     variants, branches, snapshots, or anything else. The format
//     other clients won't recognise, but it's the right choice for
//     "I want to keep this chat forever" backups.

import 'dart:convert';
import 'dart:io';

import '../models/models.dart';

/// Lossy SillyTavern-compatible JSONL export.
///
/// `userName` defaults to "User" when no persona is bound — ST treats
/// the absence of a user name as "anonymous", which renders awkwardly.
String chatToSillyTavernJsonl({
  required Chat chat,
  required String userName,
  required String characterName,
}) {
  final buf = StringBuffer();
  final created = DateTime.fromMillisecondsSinceEpoch(chat.createdAt);
  // Header line. ST tolerates extra keys, so the round-trip via the
  // Pyre side stays informative without breaking the import path on
  // their end. The `chat_metadata` block matches what ST writes.
  buf.writeln(jsonEncode({
    'user_name': userName,
    'character_name': characterName,
    'create_date': _stDate(created),
    'chat_metadata': {
      'note_prompt': '',
      'note_interposition': 1,
      'objective': {},
      'chat_id_hash': chat.id.hashCode.abs(),
      'tainted': false,
      'lastInContextMessageId': -1,
      // Hint to a curious importer that this file came from Pyre.
      'pyre_origin': true,
      'pyre_chat_id': chat.id,
    },
  }));
  for (final m in chat.messages) {
    // The selected variant is the canonical message text — alternates
    // are a Pyre-only concept and have no ST equivalent.
    final text = m.text;
    if (text.isEmpty) continue;
    final isUser = m.kind == MessageKind.user;
    final isSystem = m.kind == MessageKind.ooc ||
        m.kind == MessageKind.scene ||
        m.kind == MessageKind.system;
    final name = isUser
        ? userName
        : (isSystem ? 'System' : characterName);
    final sendDate = _stDate(
        DateTime.fromMillisecondsSinceEpoch(m.createdAt));
    final mes = switch (m.kind) {
      MessageKind.ooc => '[OOC]: $text',
      MessageKind.scene => '[Scene]: $text',
      _ => text,
    };
    buf.writeln(jsonEncode({
      'name': name,
      'is_user': isUser,
      'is_system': isSystem,
      'send_date': sendDate,
      'mes': mes,
      'extra': {
        if (m.variants.length > 1) 'pyre_variants': m.variants,
        if (m.characterId != null && m.characterId!.isNotEmpty)
          'pyre_character_id': m.characterId,
        'pyre_kind': m.kind.name,
      },
    }));
  }
  return buf.toString();
}

/// Full-fidelity Pyre JSON export. Round-trips back into the app
/// without losing branches / variants / snapshots.
String chatToPyreJson(Chat chat) {
  final encoder = const JsonEncoder.withIndent('  ');
  return encoder.convert({
    'format': 'pyre.chat.v1',
    'exported_at': DateTime.now().toIso8601String(),
    'chat': chat.toJson(),
  });
}

/// Sanitised filename stem — strip anything but ASCII alphanumerics
/// and a few safe punctuation characters. Falls back to "chat" when
/// nothing survives.
String safeExportStem(String input) {
  final stripped = input
      .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return stripped.isEmpty ? 'chat' : stripped;
}

/// SillyTavern uses a quirky `MMMM d, yyyy h:mm a` format internally
/// for `create_date` / `send_date`. We emit ISO-8601 — ST tolerates
/// it, and any importer that doesn't can pull the ms timestamp out
/// of the `pyre_origin` hint anyway.
String _stDate(DateTime dt) => dt.toIso8601String();

/// Write [content] (text) to a file under [PyreExports] and return
/// the absolute path. Used by both export formats — the caller picks
/// the extension. Throws on I/O failure.
Future<String> writeExportFile({
  required Directory baseDir,
  required String stem,
  required String extension,
  required String content,
}) async {
  final outDir = Directory('${baseDir.path}/PyreExports');
  if (!await outDir.exists()) await outDir.create(recursive: true);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final file = File('${outDir.path}/${stem}_$stamp.$extension');
  // Wave CY.18.42: atomic write — same pattern as JsonStorage. Writes
  // to a `.tmp` file first, then atomic-renames it onto the final
  // path. A crash mid-write leaves the .tmp as harmless garbage; the
  // user's exported file is either fully intact OR doesn't exist —
  // never half-written / unreadable. Critical for multi-MB chat
  // exports where the write window is non-trivial.
  final tmp = File('${file.path}.tmp');
  try {
    await tmp.writeAsString(content, flush: true);
  } catch (e) {
    if (await tmp.exists()) {
      try { await tmp.delete(); } catch (_) {}
    }
    rethrow;
  }
  await tmp.rename(file.path);
  return file.path;
}
