// Lorebook import & embedded-book extraction helpers.
//
// Two import sources land here:
//
//   1. Standalone JSON file picked from More → Lorebooks → Import.
//      Accepted shapes: bare chara_card_v2 `character_book` object
//      (entries as an array), SillyTavern's standalone World Info export
//      (entries as an object keyed by uid, ST field names), or Pyre's own
//      Lorebook.toJson shape.
//
//   2. Embedded `character_book` extracted from a chara_card_v2 PNG / JSON
//      during character import (handled via [showEmbeddedBookDialog] which
//      asks the user whether to extract or keep hidden).
//
// All paths funnel into a single Lorebook model that lives in
// AppStore.lorebooks — hidden ones don't appear in the management UI
// but still participate in chat injection when bound to a character.
//
// Wave CA.
//
// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';

/// Wave CY.18.42: in-memory log for lorebook-import failures that the
/// importer used to silently fall through on. Pre-Wave a malformed
/// Pyre-native lorebook export hit `catch (_)` and got routed into
/// the chara_card_v2 path, where it then produced an empty / mostly-
/// empty book — and the user thought "huh, the import worked but lost
/// most of my entries" without any in-app diagnostic.
///
/// The importer still falls through to alternate shapes on a real
/// shape mismatch (so legacy formats keep working), but now it
/// records the exception when a shape that LOOKED native blew up
/// during decode. Read [LorebookImportErrors.log] from a caller (UI
/// snackbar) right after [tryParseLorebookJson] returns to surface
/// these to the user.
class LorebookImportErrors {
  LorebookImportErrors._();
  static final List<String> log = [];
  static const int _max = 20;

  static void record(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[LorebookImport] $msg');
    log.insert(0, msg);
    if (log.length > _max) {
      log.removeRange(_max, log.length);
    }
  }

  static void clear() => log.clear();
}

/// Convert a chara_card_v2 `character_book` JSON object into a Pyre
/// Lorebook. Tolerates partial / off-spec shapes — ST and Chub variants
/// disagree on field names for the same concepts:
///   - `keys` vs `key` vs `keywords`
///   - `content` vs `entry`
///   - `enabled` vs `disable` (inverted)
///   - `constant` (always-on) and `order` (priority) are also stable
///
/// `hidden` controls whether the resulting book shows in the management
/// UI. Pass `true` when the user picked "keep embedded only" so the
/// book is bound to its character but doesn't pollute the Lorebooks
/// list.
Lorebook lorebookFromCharacterBook(
  Map<String, dynamic> book, {
  bool hidden = false,
  String? nameFallback,
}) {
  // Wave CY.18.54: scope error log to THIS import so stale entries
  // from a previous failed import don't pollute the user-visible
  // diagnostics on the Storage screen.
  LorebookImportErrors.clear();
  final rawEntries = book['entries'];
  // chara_card_v2 `character_book` stores entries as a JSON ARRAY. A
  // standalone SillyTavern World Info / lorebook export instead stores them
  // as a JSON OBJECT keyed by uid ("0","1",…) — this is what ST's "Export"
  // button writes. Accept BOTH by normalising to a flat list of entry maps
  // before the shared field-mapping loop below. (Map iteration preserves
  // file order via LinkedHashMap; injection priority is `order`, applied
  // later at scan time, so iteration order here is cosmetic.)
  final entryMaps = <Map<String, dynamic>>[];
  if (rawEntries is List) {
    for (final raw in rawEntries) {
      if (raw is Map) entryMaps.add(raw.cast<String, dynamic>());
    }
  } else if (rawEntries is Map) {
    for (final raw in rawEntries.values) {
      if (raw is Map) entryMaps.add(raw.cast<String, dynamic>());
    }
  }
  final entries = <LoreEntry>[];
  for (var i = 0; i < entryMaps.length; i++) {
    final m = entryMaps[i];
    // Keys: try `keys` (chara_card_v2 standard), then `key` (ST
    // standalone), then `keywords` (some Risu cards). All accept either
    // a String[] or a comma-separated String.
    final keys = _readKeyList(m['keys']) ??
        _readKeyList(m['key']) ??
        _readKeyList(m['keywords']) ??
        <String>[];
    // Content: `content` (standard) or `entry` (ST world-info legacy).
    final content = (m['content'] as String?) ??
        (m['entry'] as String?) ??
        '';
    if (content.isEmpty && keys.isEmpty) continue; // skip dud
    // Enabled defaults to TRUE if absent. Some exports use a
    // `disable: true` inverted flag — honour both.
    final enabled = m['enabled'] is bool
        ? m['enabled'] as bool
        : (m['disable'] is bool ? !(m['disable'] as bool) : true);
    final constant = m['constant'] == true;
    // Order — chara_card_v2 stores `insertion_order` (lower = inject
    // first), Risu uses `priority`, ST standalone + Pyre use `order`
    // (higher = more important). Map across them; default 0.
    final order = (m['insertion_order'] as num?)?.toInt() ??
        (m['priority'] as num?)?.toInt() ??
        (m['order'] as num?)?.toInt() ??
        0;
    entries.add(LoreEntry(
      id: 'lore_${DateTime.now().millisecondsSinceEpoch}_$i',
      keys: keys,
      content: content,
      constant: constant,
      enabled: enabled,
      order: order,
    ));
  }
  // Wave CY.18.44: empty-entries diagnostic. Pre-Wave a malformed book
  // (every entry's `keys` and `content` both missing/empty so the loop
  // skipped them all) produced a Lorebook with `entries: []` that the
  // UI cheerfully listed as "Imported Lorebook" — except it injected
  // nothing during chat, and the user thought the import was working.
  // We still RETURN the empty book (some workflows want to import the
  // metadata even if entries didn't survive), but the failure shows
  // up in the diagnostic log so the UI can surface a snackbar.
  if (entries.isEmpty) {
    LorebookImportErrors.record(
      'lorebookFromCharacterBook',
      'parsed 0 valid entries from book "${book['name'] ?? "(unnamed)"}" '
          '— every entry was missing both keys and content',
    );
  }
  return Lorebook(
    id: 'book_${DateTime.now().millisecondsSinceEpoch}',
    name: (book['name'] as String?)?.trim().isNotEmpty == true
        ? book['name'] as String
        : (nameFallback?.trim().isNotEmpty == true
            ? nameFallback!
            : 'Imported Lorebook'),
    description: (book['description'] as String?) ?? '',
    entries: entries,
    hidden: hidden,
  );
}

/// Extract a `character_book` object from a parsed chara_card_v2 card.
/// Returns null when the card has no embedded book or the field has an
/// unexpected shape. Looks at both `data.character_book` (V2 spec
/// location) and root-level `character_book` (some legacy exports).
Map<String, dynamic>? extractCharacterBook(Map<String, dynamic> card) {
  final cb = card['character_book'];
  if (cb is Map) return cb.cast<String, dynamic>();
  return null;
}

/// Try to parse an arbitrary JSON blob as a lorebook. Returns null if
/// the structure doesn't look like one. Recognised shapes:
///   - `{ "spec": "chara_card_v2", "data": { "character_book": {...} } }`
///     → extracts and parses character_book
///   - `{ "character_book": {...} }`
///     → uses the inner object
///   - `{ "entries": [...] }` (chara_card_v2 array) OR
///     `{ "entries": {"0": {...}} }` (standalone SillyTavern World Info,
///     keyed by uid) → parsed as a bare book
///   - Pyre's own Lorebook.toJson shape (has `id`, `entries`, `hidden`)
///     → round-trips losslessly via Lorebook.fromJson
Lorebook? tryParseLorebookJson(
  Map<String, dynamic> root, {
  String? nameFallback,
}) {
  // Pyre-native shape (round-trip from our own export).
  if (root['id'] is String &&
      root['entries'] is List &&
      root.containsKey('name')) {
    try {
      // Always reset hidden to false on re-import — we want explicit
      // user choice via the embedded dialog, not whatever the JSON
      // claimed.
      return Lorebook.fromJson(root)..hidden = false;
    } catch (e) {
      // Wave CY.18.42: the shape gate already matched (has `id`,
      // `entries`, `name`) so this is NOT a shape mismatch — it's a
      // real decode failure inside a payload that LOOKS native. Log
      // it so the user can see "your Pyre-native export couldn't
      // parse" instead of silently getting a near-empty book via the
      // chara_card_v2 fallback. We still fall through, in case some
      // odd hybrid file does happen to round-trip via the legacy path.
      LorebookImportErrors.record(
        'Lorebook.fromJson (native shape)',
        e,
      );
    }
  }
  // chara_card_v2 full card shape.
  if (root['data'] is Map) {
    final book = extractCharacterBook(
        (root['data'] as Map).cast<String, dynamic>());
    if (book != null) {
      return lorebookFromCharacterBook(book, nameFallback: nameFallback);
    }
  }
  // Nested character_book at root.
  if (root['character_book'] is Map) {
    return lorebookFromCharacterBook(
      (root['character_book'] as Map).cast<String, dynamic>(),
      nameFallback: nameFallback,
    );
  }
  // Bare book shape (entries directly at root). chara_card_v2 uses a List;
  // standalone SillyTavern World Info uses an object keyed by uid — accept
  // both (lorebookFromCharacterBook normalises the two shapes).
  if (root['entries'] is List || root['entries'] is Map) {
    return lorebookFromCharacterBook(root, nameFallback: nameFallback);
  }
  return null;
}

/// User choice from [showEmbeddedBookDialog].
enum EmbeddedBookChoice {
  /// Create the lorebook as a normal visible entry, then link it to
  /// the character so it auto-activates in chats. Default best path.
  extract,

  /// Create the lorebook with `hidden=true` (doesn't appear in More
  /// → Lorebooks) and link it to the character. Keeps the management
  /// UI uncluttered for cards that brought their own lore.
  embedded,

  /// Discard the embedded book entirely. The character imports without
  /// it. Useful when the embedded book is bloated or obsolete.
  skip,
}

/// Show the modal that asks the user how to handle a character_book
/// found inside an imported chara_card_v2 card. Returns the user's
/// choice, or `null` if they cancelled / dismissed (treated as Skip).
///
/// Title shows the character name + the book's name and entry count so
/// the user knows what they're about to add.
Future<EmbeddedBookChoice?> showEmbeddedBookDialog({
  required BuildContext context,
  required String characterName,
  required String bookName,
  required int entryCount,
}) async {
  return showDialog<EmbeddedBookChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('"$characterName" carries a lorebook'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"$bookName" — $entryCount '
            '${entryCount == 1 ? "entry" : "entries"}',
            style: const TextStyle(
              color: EmberColors.textHigh,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'What should Pyre do with it?',
            style: TextStyle(color: EmberColors.textMid),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, EmbeddedBookChoice.skip),
          child: const Text('Skip'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, EmbeddedBookChoice.embedded),
          child: const Text('Embedded only'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(ctx, EmbeddedBookChoice.extract),
          child: const Text('Extract & link'),
        ),
      ],
    ),
  );
}

/// Orchestrate the post-import embedded-book flow for a freshly
/// imported character. Looks at the card's `character_book` field; if
/// present and non-empty, prompts the user with [showEmbeddedBookDialog]
/// and acts on the result:
///
///   - extract  → adds a visible lorebook + links it via lorebookIds
///   - embedded → adds a hidden lorebook + links it via lorebookIds
///   - skip / dismiss → no-op
///
/// MUTATES the passed `character` (appends to `lorebookIds`) so the
/// caller's subsequent `store.addCharacter(character)` persists the
/// linkage in one go. Idempotent if there's no embedded book or its
/// entries list is empty.
Future<void> handleEmbeddedBookForCharacter({
  required BuildContext context,
  required AppStore store,
  required Character character,
  required Map<String, dynamic> charaCardData,
}) async {
  final book = extractCharacterBook(charaCardData);
  if (book == null) return;
  final entryList = book['entries'];
  final entryCount = entryList is List ? entryList.length : 0;
  if (entryCount == 0) return;
  final rawName = (book['name'] as String?)?.trim();
  final displayName = (rawName == null || rawName.isEmpty)
      ? '${character.name} world'
      : rawName;
  if (!context.mounted) return;
  final choice = await showEmbeddedBookDialog(
    context: context,
    characterName: character.name,
    bookName: displayName,
    entryCount: entryCount,
  );
  if (choice == null || choice == EmbeddedBookChoice.skip) return;
  final lorebook = lorebookFromCharacterBook(
    book,
    hidden: choice == EmbeddedBookChoice.embedded,
    nameFallback: displayName,
  );
  store.addLorebook(lorebook);
  // Append the new book to the character's bound list. Caller is
  // responsible for the subsequent store.addCharacter so the linkage
  // lands on disk.
  character.lorebookIds.add(lorebook.id);
}

/// Parse a comma-separated string OR a list of strings into a clean
/// `List<String>` (trimmed, empties dropped). Returns null on unknown
/// shapes so callers can fall through to other field names.
List<String>? _readKeyList(dynamic v) {
  if (v is List) {
    return v
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (v is String) {
    return v
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  return null;
}
