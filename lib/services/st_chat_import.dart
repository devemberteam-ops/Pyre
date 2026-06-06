// SillyTavern chat `.jsonl` → Pyre [Chat]. The inverse of
// `chatToSillyTavernJsonl` (chat_export.dart) — read that file for the field
// map this importer mirrors.
//
// A ST chat log is newline-delimited JSON:
//   - Line 0   : a metadata header ({ user_name, character_name, create_date,
//                chat_metadata }). The `user_name` / `character_name` are often
//                the literal "unused" in modern ST, so we IGNORE the header for
//                identity and bind the chat to the [Character] the backup
//                importer matched by the chat's parent folder name.
//   - Lines 1..N : one message per line. The canonical text is `mes`; a
//                message that was re-rolled carries a `swipes[]` array (the
//                alternates) + `swipe_id` (which one is shown). `is_user` /
//                `is_system` flags pick the [MessageKind]; `send_date` (ISO or
//                ST's quirky `MMMM d, yyyy h:mm a`) becomes `createdAt`.
//
// PURE: no Flutter, no AppStore. Tolerant of blank / garbage lines (they're
// skipped, never thrown). The UI layer (st_bulk_import_flow.dart) persists the
// returned chat via `store.addImportedChat`.

import 'dart:convert';

import '../models/models.dart';

/// Parse the lines of ONE SillyTavern chat `.jsonl` file into a Pyre [Chat]
/// bound to [character]. Returns `null` when nothing usable survives (no
/// parseable message lines). Never throws — malformed lines are skipped.
///
/// [lines] should be the file split on newlines (the caller may include the
/// header line 0; we skip the FIRST non-blank line as the header).
Chat? chatFromStJsonl(
  List<String> lines, {
  required Character character,
}) {
  final messages = <Message>[];
  var headerSkipped = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue; // tolerate blank lines
    final dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      continue; // tolerate garbage lines
    }
    if (decoded is! Map) continue;
    final obj = decoded.cast<String, dynamic>();
    // The first valid JSON object is the metadata header — skip it. We detect
    // it structurally (no `mes` / `swipes`, has header-ish keys) but, to match
    // the ST format faithfully, simply skip the FIRST object outright.
    if (!headerSkipped) {
      headerSkipped = true;
      // Only treat it as a header when it looks like one (no message body).
      // Some hand-made logs might omit the header entirely — if the first
      // object IS a message, fall through and parse it.
      if (_looksLikeHeader(obj)) continue;
    }
    final msg = _messageFromStLine(obj, character: character);
    if (msg != null) messages.add(msg);
  }

  if (messages.isEmpty) return null;

  return Chat(
    id: newId('chat'),
    characterIds: [character.id],
    characterSnapshots: {
      character.id: Character.fromJson(character.toJson()),
    },
    messages: messages,
  );
}

/// A header object carries no message body (`mes` / `swipes`) and typically
/// has `user_name` / `character_name` / `create_date` / `chat_metadata`.
bool _looksLikeHeader(Map<String, dynamic> obj) {
  if (obj.containsKey('mes') || obj.containsKey('swipes')) return false;
  return obj.containsKey('user_name') ||
      obj.containsKey('character_name') ||
      obj.containsKey('create_date') ||
      obj.containsKey('chat_metadata');
}

Message? _messageFromStLine(
  Map<String, dynamic> obj, {
  required Character character,
}) {
  // Variants: prefer the ST `swipes[]` array (the re-roll alternates); fall
  // back to a single-element list of `mes` when there are no swipes.
  final swipesRaw = obj['swipes'];
  final variants = <String>[];
  if (swipesRaw is List) {
    for (final s in swipesRaw) {
      if (s is String) variants.add(s);
    }
  }
  if (variants.isEmpty) {
    final mes = obj['mes'];
    if (mes is String) variants.add(mes);
  }
  // A message with no text at all (no swipes, no mes) carries nothing usable.
  if (variants.isEmpty) return null;

  // swipe_id → selectedVariant, clamped into range.
  var selected = 0;
  final swipeId = obj['swipe_id'];
  if (swipeId is num) selected = swipeId.toInt();
  if (selected < 0 || selected >= variants.length) selected = 0;

  final isUser = obj['is_user'] == true;
  final isSystem = obj['is_system'] == true;
  final kind = isUser
      ? MessageKind.user
      : (isSystem ? MessageKind.system : MessageKind.char);

  final createdAt = _parseStDate(obj['send_date']);

  return Message(
    id: newId('msg'),
    kind: kind,
    // Bind non-user / non-system turns to the imported character so group-
    // aware UI attributes them correctly. User / system turns leave it null.
    characterId: kind == MessageKind.char ? character.id : null,
    variants: variants,
    selectedVariant: selected,
    createdAt: createdAt,
  );
}

/// A persona "hint" extracted from a SillyTavern chat log: the persona's
/// DisplayName and/or the bare avatar filename. The backup importer uses this
/// to LINK an imported chat to the persona it was role-played with. Either
/// field may be empty when the log didn't carry it; an all-empty hint means
/// "no persona could be inferred".
class StPersonaHint {
  /// The persona DisplayName from the first `is_user: true` message's `name`
  /// field (NOT the header `user_name`, which is often the literal "unused").
  final String name;

  /// The bare avatar filename (e.g. `Serena.png`) parsed from the first
  /// `is_user: true` message's `force_avatar`
  /// (`/thumbnail?type=persona&file=...`). Matches the keys of
  /// `power_user.personas`.
  final String avatarFile;

  const StPersonaHint({this.name = '', this.avatarFile = ''});

  /// True when neither field carries anything usable to match a persona by.
  bool get isEmpty => name.isEmpty && avatarFile.isEmpty;
}

/// Scan [lines] for the FIRST message with `is_user: true` and build a
/// [StPersonaHint] from its `name` (DisplayName) + `force_avatar` (parsed for
/// the `file=` query param). Returns an empty hint when there is no user
/// message or it carries neither field. PURE — never throws (garbage lines are
/// skipped just like in [chatFromStJsonl]).
StPersonaHint stPersonaHintFromJsonl(List<String> lines) {
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      continue;
    }
    if (decoded is! Map) continue;
    if (decoded['is_user'] != true) continue;
    final name = (decoded['name'] as String?)?.trim() ?? '';
    final avatarFile = stForceAvatarFile(decoded['force_avatar']);
    return StPersonaHint(name: name, avatarFile: avatarFile);
  }
  return const StPersonaHint();
}

/// Extract the bare avatar filename from a ST `force_avatar` value such as
/// `/thumbnail?type=persona&file=Serena.png`. Parses the `file=` query param
/// (URL-decoding it). Returns '' when [v] isn't a String, has no `file=`
/// param, or the param is empty. PURE — never throws.
String stForceAvatarFile(dynamic v) {
  if (v is! String || v.trim().isEmpty) return '';
  final s = v.trim();
  // Prefer a structured parse of the query string; fall back to a manual
  // `file=` scan if the value isn't a well-formed URI.
  final qIdx = s.indexOf('?');
  final query = qIdx >= 0 ? s.substring(qIdx + 1) : s;
  for (final pair in query.split('&')) {
    final eq = pair.indexOf('=');
    if (eq < 0) continue;
    final key = pair.substring(0, eq);
    if (key != 'file') continue;
    final value = pair.substring(eq + 1);
    try {
      return Uri.decodeQueryComponent(value).trim();
    } catch (_) {
      return value.trim();
    }
  }
  return '';
}

/// Best-effort `send_date` → epoch millis. Accepts ISO-8601 (what Pyre's own
/// export writes) and a numeric epoch; everything else falls back to "now".
int _parseStDate(dynamic v) {
  if (v is num) return v.toInt();
  if (v is String && v.trim().isNotEmpty) {
    final iso = DateTime.tryParse(v.trim());
    if (iso != null) return iso.millisecondsSinceEpoch;
  }
  return DateTime.now().millisecondsSinceEpoch;
}
