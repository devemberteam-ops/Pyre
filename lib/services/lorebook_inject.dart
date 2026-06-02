// Lorebook gathering + keyword scanning for chat injection.
//
// Pure functions, no AppStore / BuildContext dependency. The chat
// completion builder calls these to:
//   1. Collect all bound lorebooks (per-chat + character + persona)
//   2. Scan the recent message window for keyword hits
//   3. Return the entries to inject into the prompt
//
// Wave CB.

import '../models/models.dart';

/// Combine the three sources of bound lorebooks for [chat] (per-chat,
/// character-bound, persona-bound) and resolve them to actual Lorebook
/// objects via [lookupBook]. Dedupes by id so a book bound to BOTH a
/// character and a persona doesn't double-inject.
///
/// For group chats with multiple characters in `chat.characterIds`,
/// EVERY member contributes their bound books — not just the current
/// responder. That matches user intuition: if Goku and Vegeta are both
/// in a chat and both carry the Dragon Ball lorebook, the book is
/// active regardless of who's responding.
///
/// [lookupBook] / [lookupCharacter] are passed as callbacks (rather
/// than an AppStore reference) so the function stays pure and unit-
/// testable without booting platform channels. In production these
/// resolve to `store.lorebookById` and `store.characterById`.
List<Lorebook> collectBoundLorebooks({
  required Chat chat,
  required Persona? persona,
  required Lorebook? Function(String id) lookupBook,
  required Character? Function(String id) lookupCharacter,
  String? responderId,
}) {
  // Wave CD: per-chat attached books are ALWAYS additive — the user
  // explicitly attached them to this chat, the disabled-inherited list
  // doesn't affect them. Only inherited (char + persona) bindings are
  // subject to the override.
  final disabled = chat.disabledInheritedLorebookIds.toSet();
  final ids = <String>{...chat.attachedLorebookIds};
  if (persona != null) {
    for (final id in persona.lorebookIds) {
      if (!disabled.contains(id)) ids.add(id);
    }
  }
  final chatCharIds = chat.characterIds.isNotEmpty
      ? chat.characterIds
      : (responderId != null ? <String>[responderId] : const <String>[]);
  for (final cid in chatCharIds) {
    final snap = chat.characterSnapshots[cid] ?? lookupCharacter(cid);
    if (snap == null) continue;
    for (final id in snap.lorebookIds) {
      if (!disabled.contains(id)) ids.add(id);
    }
  }
  return ids.map(lookupBook).whereType<Lorebook>().toList();
}

/// Result of [scanLorebookHits] — both the matching entries and a
/// human-readable trace of which entries fired and why. The trace is
/// used by the in-chat diagnostic badge so the user can SEE which
/// lorebook entries influenced a turn without inspecting prompts.
class LorebookScanResult {
  /// Entries that should be injected into the prompt, sorted by
  /// descending `order` (higher = more important = appears first).
  final List<LoreEntry> hits;

  /// Diagnostic lines for the UI / debug log, one per fired entry.
  /// Format: `"book_name • entry_keys (reason)"` or
  /// `"book_name • constant entry"`.
  final List<String> trace;

  /// Total entries considered (across all books, enabled or not).
  /// Useful for the "scanned N entries, M fired" indicator.
  final int totalScanned;

  /// Disabled entries that were skipped — counted separately so the
  /// UI can warn the user if all their entries are off by mistake.
  final int skippedDisabled;

  const LorebookScanResult({
    required this.hits,
    required this.trace,
    required this.totalScanned,
    required this.skippedDisabled,
  });

  bool get isEmpty => hits.isEmpty;
}

/// Run keyword scanning across [books] using the last [window] message
/// texts from [messages] (defaults to 6 — same as the legacy inline
/// implementation). Returns the entries to inject plus a trace.
///
/// Matching rules:
///   - `entry.enabled == false` → skipped (counted in skippedDisabled)
///   - `entry.constant == true` → ALWAYS fires, no keyword scan
///   - otherwise: case-insensitive WORD-BOUNDARY match across keys; first
///     hit wins, entry fires once even if multiple keys match
///
/// Final order: hits sorted by `order` descending (chara_card_v2
/// convention: higher order = higher injection priority).
LorebookScanResult scanLorebookHits(
  List<Lorebook> books,
  List<Message> messages, {
  int window = 6,
}) {
  final windowText = messages.reversed
      .take(window)
      .map((m) => m.text)
      .join(' ')
      .toLowerCase();
  final hits = <LoreEntry>[];
  final trace = <String>[];
  var totalScanned = 0;
  var skippedDisabled = 0;
  for (final book in books) {
    for (final e in book.entries) {
      totalScanned++;
      if (!e.enabled) {
        skippedDisabled++;
        continue;
      }
      if (e.constant) {
        hits.add(e);
        trace.add('${book.name} • constant entry');
        continue;
      }
      String? matchedKey;
      for (final k in e.keys) {
        if (k.isEmpty) continue;
        if (_keyMatchesAtWordBoundary(windowText, k)) {
          matchedKey = k;
          break;
        }
      }
      if (matchedKey != null) {
        hits.add(e);
        trace.add('${book.name} • matched `$matchedKey`');
      }
    }
  }
  hits.sort((a, b) => b.order.compareTo(a.order));
  return LorebookScanResult(
    hits: hits,
    trace: trace,
    totalScanned: totalScanned,
    skippedDisabled: skippedDisabled,
  );
}

/// Wave CY.18.255 (FIX 4): word-boundary keyword match.
///
/// The previous logic did a raw case-insensitive substring `contains`, so a
/// short key like "Al" fired inside "always" / "normal" — over-injecting
/// the lore entry on unrelated text. We now require the key NOT to be
/// flanked by alphanumerics on either side, i.e. it must sit at a word
/// boundary.
///
/// Threshold choice: applied to ALL keys, not just short ones. Word-
/// boundary matching is strictly safer for short keys (the false-positive
/// class) and stays correct for longer / multi-word keys — "Sunken Gate"
/// still matches "...the Sunken Gate..." because the boundary check only
/// guards the OUTER edges (spaces inside the key match literally). Keeping
/// it uniform avoids a surprising cliff where a 3-char key behaves
/// differently from a 4-char one, and it matches the chara_card_v2 /
/// SillyTavern whole-word convention.
///
/// Implementation: case-insensitive `(?<![A-Za-z0-9])KEY(?![A-Za-z0-9])`
/// with the key escaped. Lookarounds (not `\b`) so keys that START or END
/// with a non-word character — punctuation, emoji, CJK — still match
/// (a bare `\b` would wrongly fail there, since `\b` needs a word char on
/// one side). [text] is already lowercased by the caller; we lowercase the
/// key here for parity and keep the regex case-insensitive defensively.
bool _keyMatchesAtWordBoundary(String text, String key) {
  final lower = key.toLowerCase();
  final pattern = RegExp(
    '(?<![A-Za-z0-9])${RegExp.escape(lower)}(?![A-Za-z0-9])',
    caseSensitive: false,
  );
  return pattern.hasMatch(text);
}
