// Import a Pyre chat file back into the app — the inverse of
// services/chat_export.dart. A user who exported a chat (to move it to another
// device, share it, or keep a "forever" backup) can now load it back.
//
// Three shapes are recognised, in this order:
//
//   1. pyre.chat.v1 JSON (`{format: "pyre.chat.v1", chat: <Chat.toJson()>}`)
//      — FULL FIDELITY. Reconstructed via `Chat.fromJson`, so variants,
//      per-variant downstream snapshots, checkpoints, live-sheet snapshots,
//      the manual title, and character/persona bindings all survive.
//
//   2. Pyre JSONL (SillyTavern-compatible, `chat_metadata.pyre_origin: true`)
//      — one JSON object per line. Line 0 is the header; each following line is
//      a message. We rebuild messages in order using `extra.pyre_kind` for the
//      MessageKind, `extra.pyre_variants` to restore alternates, and strip the
//      `[OOC]:`/`[Scene]:` prefix the exporter adds to the canonical `mes`.
//      Lossy vs. pyre.chat.v1: the JSONL export carries NO chat title, no
//      memory checkpoints, live-sheet snapshots, story beats, per-chat
//      settings, or per-variant downstream branches — only the visible message
//      timeline (text, kind, variants, selection, timestamps, speaker id).
//
//   3. Foreign SillyTavern JSONL (no Pyre hints) — best-effort: `is_user` /
//      `is_system` pick the kind, `swipes[]` become variants. Imported as an
//      UNBOUND chat (no character binding).
//
// PURE: no Flutter, no store, no file I/O. Detection + reconstruction only.
// Callers pass the set of library character ids (for the binding decision) and
// existing chat ids (for collision-safe id assignment). On any unusable input
// this THROWS a typed [ChatImportException] BEFORE returning a chat, so a
// caller never half-imports — either it gets a complete [ChatImportResult] or a
// readable error.

import 'dart:convert';

import '../models/models.dart';

/// Which of the three recognised shapes a file was.
enum ChatImportFormat { pyreJson, pyreJsonl, foreignJsonl }

/// Why an import could not proceed. The UI maps these to a readable reason.
enum ChatImportErrorKind {
  /// Not a Pyre JSON and not parseable as newline-delimited JSON at all.
  notReadable,

  /// Recognised as a Pyre file but the payload was structurally invalid
  /// (e.g. `format: pyre.chat.v1` with a missing / malformed `chat` block).
  unsupported,

  /// Parsed fine but held no messages — nothing to import.
  empty,
}

/// A typed, human-readable import failure. Thrown (never returned) so the
/// caller can't accidentally persist a partial chat.
class ChatImportException implements Exception {
  final ChatImportErrorKind kind;
  final String message;
  const ChatImportException(this.kind, this.message);

  @override
  String toString() => 'ChatImportException($kind): $message';
}

/// A short, user-facing rollup of what an import produced.
class ChatImportSummary {
  final ChatImportFormat format;

  /// A display label for the imported chat (manual title when present, else
  /// the character name from the file, else a generic fallback).
  final String title;

  /// Number of messages reconstructed.
  final int messageCount;

  /// Number of messages that carried more than one variant (saved alternates /
  /// re-rolls) preserved on the way in.
  final int variantCount;

  /// True when the chat's character resolved to one already in the library, so
  /// the binding was kept. False when the character is absent (imported as a
  /// standalone / unbound chat — see [warnings]).
  final bool characterBound;

  /// Non-fatal notes (unknown character, id collision, lossy JSONL fields).
  final List<String> warnings;

  const ChatImportSummary({
    required this.format,
    required this.title,
    required this.messageCount,
    required this.variantCount,
    required this.characterBound,
    required this.warnings,
  });
}

/// The successful result of an import: the reconstructed [Chat] plus a
/// [ChatImportSummary]. The chat is NOT yet persisted — the caller adds it to
/// the store (via `addImportedChat`).
class ChatImportResult {
  final Chat chat;
  final ChatImportSummary summary;
  const ChatImportResult({required this.chat, required this.summary});
}

/// Detect the format of [content], reconstruct the [Chat], and return a
/// [ChatImportResult]. Throws [ChatImportException] on unusable input.
///
/// [knownCharacterIds] — ids of characters currently in the library. Used ONLY
/// to decide whether to keep the chat's character binding; a self-contained
/// pyre.chat.v1 chat still imports (with its frozen snapshot) when the id is
/// absent, just flagged unbound.
///
/// [existingChatIds] — ids of chats currently in the store. If the imported
/// chat's own id collides, a fresh id is assigned and a warning is added, so
/// an import never clobbers an existing chat.
ChatImportResult importChat(
  String content, {
  Set<String> knownCharacterIds = const {},
  Set<String> existingChatIds = const {},
}) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) {
    throw const ChatImportException(
        ChatImportErrorKind.notReadable, 'The chat file is empty.');
  }

  // A pretty-printed pyre.chat.v1 file decodes as ONE JSON object. A JSONL log
  // has multiple top-level objects and fails a whole-file decode — that's the
  // discriminator.
  Map<String, dynamic>? whole;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) whole = decoded.cast<String, dynamic>();
  } catch (_) {
    // Not a single JSON value → treat as JSONL below.
  }

  if (whole != null && whole['format'] == 'pyre.chat.v1') {
    return _importPyreJson(whole,
        knownCharacterIds: knownCharacterIds,
        existingChatIds: existingChatIds);
  }

  // Everything else is line-delimited JSON (Pyre JSONL or foreign ST).
  return _importJsonl(content,
      knownCharacterIds: knownCharacterIds, existingChatIds: existingChatIds);
}

// ---------------------------------------------------------------------------
// pyre.chat.v1 — full fidelity via Chat.fromJson.

ChatImportResult _importPyreJson(
  Map<String, dynamic> root, {
  required Set<String> knownCharacterIds,
  required Set<String> existingChatIds,
}) {
  final chatJson = root['chat'];
  if (chatJson is! Map) {
    throw const ChatImportException(ChatImportErrorKind.unsupported,
        'This looks like a Pyre chat file but its data block is missing or '
        'corrupted.');
  }

  final Chat chat;
  try {
    chat = Chat.fromJson(chatJson.cast<String, dynamic>());
  } catch (e) {
    throw ChatImportException(ChatImportErrorKind.unsupported,
        'This Pyre chat file could not be read (corrupted data): $e');
  }

  if (chat.messages.isEmpty) {
    throw const ChatImportException(
        ChatImportErrorKind.empty, 'This chat file has no messages.');
  }

  final warnings = <String>[];

  // Collision-safe id.
  if (existingChatIds.contains(chat.id)) {
    chat.id = newId('chat');
    warnings.add('A chat with the same id already exists — imported as a new '
        'copy.');
  }

  // Character binding. pyre.chat.v1 is self-contained (it carries the frozen
  // characterSnapshots), so an absent library character is NOT fatal — we keep
  // the snapshot and just flag it unbound.
  final primary = chat.primaryCharacterId;
  final bound = primary != null && knownCharacterIds.contains(primary);
  if (primary != null && !bound) {
    final name = chat.characterSnapshots[primary]?.name;
    warnings.add(name != null && name.isNotEmpty
        ? "The character '$name' isn't in your library — imported as a "
            'standalone copy (it uses the snapshot saved in the file).'
        : "This chat's character isn't in your library — imported as a "
            'standalone copy.');
  }

  final title = _titleFor(chat, chat.characterSnapshots[primary]?.name);

  return ChatImportResult(
    chat: chat,
    summary: ChatImportSummary(
      format: ChatImportFormat.pyreJson,
      title: title,
      messageCount: chat.messages.length,
      variantCount: _countVariantMessages(chat.messages),
      characterBound: bound,
      warnings: warnings,
    ),
  );
}

// ---------------------------------------------------------------------------
// JSONL — Pyre-flavoured or foreign SillyTavern.

ChatImportResult _importJsonl(
  String content, {
  required Set<String> knownCharacterIds,
  required Set<String> existingChatIds,
}) {
  // Parse each non-blank line; tolerate garbage lines (skip them). Track
  // whether ANY line parsed so we can distinguish "not JSONL at all" from
  // "JSONL with no messages".
  final objects = <Map<String, dynamic>>[];
  var anyLineParsed = false;
  for (final raw in const LineSplitter().convert(content)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      continue;
    }
    if (decoded is! Map) continue;
    anyLineParsed = true;
    objects.add(decoded.cast<String, dynamic>());
  }

  if (!anyLineParsed) {
    throw const ChatImportException(
        ChatImportErrorKind.notReadable,
        "This file isn't a Pyre or SillyTavern chat — it couldn't be read as "
        'JSON or JSONL.');
  }

  // The first object is the header when it looks like one (no message body).
  Map<String, dynamic>? header;
  var start = 0;
  if (objects.isNotEmpty && _looksLikeHeader(objects.first)) {
    header = objects.first;
    start = 1;
  }

  // pyre_origin in the header's chat_metadata → this is a Pyre JSONL export.
  final meta = header?['chat_metadata'];
  final pyreOrigin = meta is Map && meta['pyre_origin'] == true;
  final format =
      pyreOrigin ? ChatImportFormat.pyreJsonl : ChatImportFormat.foreignJsonl;

  final warnings = <String>[];
  final messages = <Message>[];
  String? candidateCharacterId;

  for (var i = start; i < objects.length; i++) {
    final obj = objects[i];
    final msg = pyreOrigin
        ? _messageFromPyreLine(obj)
        : _messageFromForeignLine(obj);
    if (msg == null) continue;
    // Remember the first char-speaker id (Pyre JSONL carries it in
    // extra.pyre_character_id) for the binding decision.
    if (candidateCharacterId == null &&
        msg.kind == MessageKind.char &&
        msg.characterId != null &&
        msg.characterId!.isNotEmpty) {
      candidateCharacterId = msg.characterId;
    }
    messages.add(msg);
  }

  if (messages.isEmpty) {
    throw const ChatImportException(
        ChatImportErrorKind.empty, 'This chat file has no messages.');
  }

  // Binding: keep the character only when it's in the library. Otherwise import
  // an unbound chat and null out the dangling per-message speaker ids so
  // nothing points at a character that isn't there.
  final bound = candidateCharacterId != null &&
      knownCharacterIds.contains(candidateCharacterId);
  final characterIds = <String>[];
  if (bound) {
    characterIds.add(candidateCharacterId!);
  } else {
    for (final m in messages) {
      m.characterId = null;
    }
    if (candidateCharacterId != null) {
      final name = (header?['character_name'] as String?)?.trim();
      warnings.add(name != null && name.isNotEmpty
          ? "The character '$name' isn't in your library — imported as a "
              'standalone chat.'
          : "This chat's character isn't in your library — imported as a "
              'standalone chat.');
    }
  }

  // Id: reuse pyre_chat_id when present and non-colliding, else a fresh id.
  var chatId = newId('chat');
  if (pyreOrigin && meta is Map) {
    final savedId = meta['pyre_chat_id'];
    if (savedId is String && savedId.isNotEmpty) {
      if (existingChatIds.contains(savedId)) {
        warnings.add('A chat with the same id already exists — imported as a '
            'new copy.');
      } else {
        chatId = savedId;
      }
    }
  }

  // createdAt from the header's create_date when available (else the earliest
  // message time, else now via the Chat ctor default).
  final createdAt = _parseDate(header?['create_date']);

  final chat = Chat(
    id: chatId,
    characterIds: characterIds,
    messages: messages,
    createdAt: createdAt,
  );

  if (format == ChatImportFormat.pyreJsonl) {
    warnings.add('JSONL import restores the message timeline only — chat '
        'title, memory, and branch snapshots are in the full-fidelity Pyre '
        'JSON export.');
  }

  final title = (header?['character_name'] as String?)?.trim();
  return ChatImportResult(
    chat: chat,
    summary: ChatImportSummary(
      format: format,
      title: (title != null && title.isNotEmpty) ? title : 'Imported chat',
      messageCount: messages.length,
      variantCount: _countVariantMessages(messages),
      characterBound: bound,
      warnings: warnings,
    ),
  );
}

/// A Pyre-exported message line. The canonical `mes` is the selected variant
/// (prefixed `[OOC]:`/`[Scene]:` for those kinds); `extra.pyre_variants` holds
/// the raw (unprefixed) alternates; `extra.pyre_kind` is authoritative for the
/// MessageKind; `extra.pyre_character_id` is the speaker.
Message? _messageFromPyreLine(Map<String, dynamic> obj) {
  final mes = obj['mes'];
  final extra = obj['extra'];
  final extraMap = extra is Map ? extra : const {};

  final kind = _kindFromName(extraMap['pyre_kind']) ??
      _kindFromFlags(obj['is_user'] == true, obj['is_system'] == true);

  // Canonical text = mes with the export's kind prefix removed.
  final canonical = mes is String ? _stripKindPrefix(mes, kind) : '';

  // Variants: prefer the exported raw list; else a single-element canonical.
  final rawVariants = extraMap['pyre_variants'];
  final variants = <String>[];
  if (rawVariants is List) {
    for (final v in rawVariants) {
      if (v is String) variants.add(v);
    }
  }
  var selected = 0;
  if (variants.isEmpty) {
    variants.add(canonical);
  } else {
    // The canonical (stripped) text identifies which alternate was selected.
    final idx = variants.indexOf(canonical);
    selected = idx >= 0 ? idx : 0;
  }
  // A truly empty message carries nothing usable (the exporter skips empties,
  // but be defensive against hand-edited files).
  if (variants.every((v) => v.isEmpty)) return null;

  final characterId = extraMap['pyre_character_id'];
  return Message(
    id: newId('msg'),
    kind: kind,
    characterId: (kind == MessageKind.char &&
            characterId is String &&
            characterId.isNotEmpty)
        ? characterId
        : null,
    variants: variants,
    selectedVariant: selected,
    createdAt: _parseDate(obj['send_date']),
  );
}

/// A foreign SillyTavern message line: `swipes[]`→variants (fall back to
/// single `mes`), `swipe_id`→selection, `is_user`/`is_system`→kind.
Message? _messageFromForeignLine(Map<String, dynamic> obj) {
  final variants = <String>[];
  final swipes = obj['swipes'];
  if (swipes is List) {
    for (final s in swipes) {
      if (s is String) variants.add(s);
    }
  }
  if (variants.isEmpty) {
    final mes = obj['mes'];
    if (mes is String) variants.add(mes);
  }
  if (variants.isEmpty) return null;

  var selected = 0;
  final swipeId = obj['swipe_id'];
  if (swipeId is num) selected = swipeId.toInt();
  if (selected < 0 || selected >= variants.length) selected = 0;

  final kind = _kindFromFlags(obj['is_user'] == true, obj['is_system'] == true);
  return Message(
    id: newId('msg'),
    kind: kind,
    variants: variants,
    selectedVariant: selected,
    createdAt: _parseDate(obj['send_date']),
  );
}

// ---------------------------------------------------------------------------
// Helpers.

/// A header object carries no message body and has header-ish keys — mirrors
/// st_chat_import.dart's detector so the two importers agree on what a header
/// looks like.
bool _looksLikeHeader(Map<String, dynamic> obj) {
  if (obj.containsKey('mes') || obj.containsKey('swipes')) return false;
  return obj.containsKey('user_name') ||
      obj.containsKey('character_name') ||
      obj.containsKey('create_date') ||
      obj.containsKey('chat_metadata');
}

/// Map an exported `pyre_kind` name back to a [MessageKind]. Returns null when
/// the value is absent / unrecognised so the caller can fall back to the ST
/// flags.
MessageKind? _kindFromName(dynamic name) {
  if (name is! String) return null;
  for (final k in MessageKind.values) {
    if (k.name == name) return k;
  }
  return null;
}

MessageKind _kindFromFlags(bool isUser, bool isSystem) => isUser
    ? MessageKind.user
    : (isSystem ? MessageKind.system : MessageKind.char);

/// Strip the exporter's `[OOC]: ` / `[Scene]: ` prefix from the canonical text
/// for those kinds (the real kind lives in `extra.pyre_kind`). Leaves any other
/// text untouched.
String _stripKindPrefix(String mes, MessageKind kind) {
  const oocPrefix = '[OOC]: ';
  const scenePrefix = '[Scene]: ';
  if (kind == MessageKind.ooc && mes.startsWith(oocPrefix)) {
    return mes.substring(oocPrefix.length);
  }
  if (kind == MessageKind.scene && mes.startsWith(scenePrefix)) {
    return mes.substring(scenePrefix.length);
  }
  return mes;
}

/// Count messages carrying more than one variant (preserved alternates).
int _countVariantMessages(List<Message> messages) =>
    messages.where((m) => m.variants.length > 1).length;

/// A display title for a full-fidelity chat: the manual title when set, else
/// the character name, else a generic fallback.
String _titleFor(Chat chat, String? characterName) {
  final t = chat.title?.trim();
  if (t != null && t.isNotEmpty) return t;
  if (characterName != null && characterName.isNotEmpty) return characterName;
  return 'Imported chat';
}

/// Best-effort date → epoch millis. Accepts ISO-8601 (what Pyre exports), a
/// numeric epoch, and falls back to "now" for anything else. Mirrors the
/// tolerant parser in st_chat_import.dart.
int _parseDate(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String && v.trim().isNotEmpty) {
    final iso = DateTime.tryParse(v.trim());
    if (iso != null) return iso.millisecondsSinceEpoch;
  }
  return DateTime.now().millisecondsSinceEpoch;
}
