// Helpers that convert a parsed chara_card_v2 payload into a Character model.

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/models.dart';
import 'attachment_store.dart';
import 'png_parser.dart';

/// Wave CY.18.43: card-import diagnostics. Pre-Wave a malformed
/// `extensions` field (string / list / number where a Map was
/// expected) was silently coerced to an empty `{}` — the card looked
/// "fully valid" in the UI but any extension data (depth_prompt,
/// ST world-info hooks, etc.) was lost without a trace. Now we log
/// the corruption so the user can see "this card had ext data we
/// couldn't read" and decide whether to re-import from source.
class CardImportErrors {
  CardImportErrors._();
  static final List<String> log = [];
  static const int _max = 20;

  static void record(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[CardImport] $msg');
    log.insert(0, msg);
    if (log.length > _max) {
      log.removeRange(_max, log.length);
    }
  }

  static void clear() => log.clear();
}

List<String> _stringList(dynamic v) {
  if (v is List) return v.whereType<String>().toList();
  return const [];
}

String _str(dynamic v, [String fallback = '']) =>
    v is String ? v : fallback;

Character characterFromCharaCard(CharaCard card, {String? overrideAvatar}) {
  // Wave CY.18.54: clear the per-import error log at entry. Pre-Wave,
  // a user who imported a bad card then a good one would still see
  // the OLD error in the Storage screen — totally misleading
  // ("the new card failed too?"). Clearing here scopes the log to
  // THIS specific import. Same pattern in lorebook_import.dart.
  CardImportErrors.clear();
  final c = card.card;
  // Tavern V2 fields live on `data.*`; some legacy cards use top-level keys.
  final talkRaw = c['talkativeness'];
  // Wave CY.18.43: detect malformed `extensions` (anything that isn't
  // a Map but isn't simply absent) and log it. Spec says extensions is
  // an arbitrary Map; some scuffed exports drop a JSON-stringified
  // object here, or null it out, which previously coerced silently to
  // `{}` and the user never knew their card lost ext data.
  final extRaw = c['extensions'];
  if (extRaw != null && extRaw is! Map) {
    CardImportErrors.record(
      'characterFromCharaCard',
      'extensions field is ${extRaw.runtimeType}, expected Map — '
          'silently dropped',
    );
  }
  final depthRaw = c['extensions'] is Map
      ? (c['extensions'] as Map)['depth_prompt']
      : null;
  // chara_card_v2 has no first-class `tagline`. Prefer a top-level one
  // (some cards put it there), else read back the value Pyre stashes in
  // `extensions.pyre.tagline` on export so our own round-trip survives.
  final pyreExt = c['extensions'] is Map
      ? (c['extensions'] as Map)['pyre']
      : null;
  final pyreTagline =
      pyreExt is Map ? _str(pyreExt['tagline']) : '';
  final taglineRaw = _str(c['tagline']).isNotEmpty
      ? _str(c['tagline'])
      : pyreTagline;
  return Character(
    id: newId('char'),
    name: _str(c['name'], 'Unnamed'),
    tagline: taglineRaw.isNotEmpty ? taglineRaw : null,
    description: _str(c['description']),
    personality: _str(c['personality']),
    scenario: _str(c['scenario']),
    firstMes: _str(c['first_mes']),
    mesExample: _str(c['mes_example']),
    systemPrompt: _str(c['system_prompt']),
    postHistoryInstructions: _str(c['post_history_instructions']),
    alternateGreetings: _stringList(c['alternate_greetings']),
    tags: _stringList(c['tags']),
    creator: _str(c['creator']),
    characterVersion: _str(c['character_version'], '1.0'),
    creatorNotes: _str(c['creator_notes']),
    talkativeness: talkRaw is num ? talkRaw.toDouble() : null,
    // depth_prompt is part of the `extensions` block per spec — accept both
    // a flat string and the `{prompt, depth}` object form.
    depthPrompt: depthRaw is Map
        ? _str(depthRaw['prompt'])
        : (depthRaw is String ? depthRaw : ''),
    depthPromptDepth: depthRaw is Map
        ? (depthRaw['depth'] is num
            ? (depthRaw['depth'] as num).toInt()
            : 4)
        : 4,
    extensions: c['extensions'] is Map
        ? (c['extensions'] as Map).cast<String, dynamic>()
        : <String, dynamic>{},
    avatar: overrideAvatar ?? card.avatarDataUrl,
  );
}

/// Audit 2026-06-05: restore the fields the chara_card_v2 canvas rebuild
/// drops on the Creator's "Edit with AI" save path. The canvas only carries
/// the chara_card `data` block, so the extra [Character.gallery] images, the
/// [Character.favorite] star, and the top-level [Character.talkativeness] are
/// at their empty defaults on a `characterFromCharaCard` rebuild. Without
/// this, an AI edit silently WIPED a BotBooru card's gallery, un-starred a
/// favourited card, and dropped talkativeness. Mirrors the persona edit path,
/// which already restores its extras from the existing record.
///
/// Mutates [rebuilt] in place and returns it for chaining.
///
/// [keepFavorite] is true for an in-place OVERWRITE (the edited card IS the
/// original record, so its star carries over) and false for a "Save as a
/// copy" fork (a fresh copy is its own new record and starts unstarred).
Character restoreCanvasDroppedExtras(
  Character rebuilt,
  Character original, {
  required bool keepFavorite,
}) {
  rebuilt.gallery = List<String>.from(original.gallery);
  rebuilt.talkativeness = original.talkativeness;
  if (keepFavorite) rebuilt.favorite = original.favorite;
  return rebuilt;
}

/// Mega-audit 2026-06-05 (B-2 / H-6): externalise a freshly-imported
/// character's INLINE images (avatar + gallery) into the AttachmentStore so
/// they enter state as `pyre://attachment/<hash>` refs instead of inline
/// base64. Pre-fix, `characterFromCharaCard` set the avatar to an inline
/// `data:` URL and `addCharacter` never externalised it, so every imported
/// avatar stayed inline forever — re-encoded on each debounced save and
/// copied into all rolling backups. This mirrors the persona ST import path
/// (`st_bulk_import_flow.dart`).
///
/// Idempotent: already-external `pyre://` refs and empty values are left
/// untouched. On web (no fs → store returns null) the inline URLs stay as-is,
/// which is correct. Best-effort: a single image that fails to externalise
/// keeps its inline form rather than aborting the import.
Future<void> externalizeCharacterImages(Character c) async {
  final nextAvatar = await externalizeInlineImageRef(c.avatar);
  if (nextAvatar != null) c.avatar = nextAvatar;
  if (c.gallery.isNotEmpty) {
    for (var i = 0; i < c.gallery.length; i++) {
      final next = await externalizeInlineImageRef(c.gallery[i]);
      if (next != null) c.gallery[i] = next;
    }
  }
}

/// Mega-audit 2026-06-05 (B-2 / H-6): persona counterpart of
/// [externalizeCharacterImages]. A persona imported FROM a card (the
/// `_personaFromImportedCard` path) inherits the card's inline `data:`
/// avatar; this externalises it (+ any inline gallery entries) into the
/// AttachmentStore. Idempotent / web-safe (see [externalizeInlineImageRef]).
Future<void> externalizePersonaImages(Persona p) async {
  final nextAvatar = await externalizeInlineImageRef(p.avatar);
  if (nextAvatar != null) p.avatar = nextAvatar;
  if (p.gallery.isNotEmpty) {
    for (var i = 0; i < p.gallery.length; i++) {
      final next = await externalizeInlineImageRef(p.gallery[i]);
      if (next != null) p.gallery[i] = next;
    }
  }
}
