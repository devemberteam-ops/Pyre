// Lorebook gathering + keyword scanning for chat injection.
//
// Pure functions, no AppStore / BuildContext dependency. The chat
// completion builder calls these to:
//   1. Collect all bound lorebooks (per-chat + character + persona)
//   2. Scan the recent message window for keyword hits
//   3. Return the entries to inject into the prompt
//
// Wave CB.

import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/models.dart';

// ── Compiled keyword-RegExp cache ──────────────────────────────────────
//
// Audit 2026-06-05 (perf-at-scale, finding #5): every send/regen/continue
// re-scans all bound lorebooks, compiling a fresh RegExp per key per entry.
// A big world-info import (200+ entries, several keys each) means
// hundreds-to-thousands of `RegExp(...)` builds synchronously in the
// pre-send window. Keys change rarely (only on lorebook edit/import), so we
// memoize the compiled key RegExp keyed by (key, caseSensitive, wholeWords).
// Bounded so a pathological book can't grow it unbounded.
const _kKeyRegexCacheMax = 2048;
final Map<String, RegExp> _keyRegexCache = <String, RegExp>{};

RegExp _compileKeyCached(String key, bool caseSensitive, bool wholeWords) {
  // \x00 is never a valid key/flag char → unambiguous composite key.
  final cacheKey = '${caseSensitive ? 1 : 0}\x00${wholeWords ? 1 : 0}\x00$key';
  final hit = _keyRegexCache[cacheKey];
  if (hit != null) return hit;
  final escaped = RegExp.escape(key);
  final pattern =
      wholeWords ? '(?<![A-Za-z0-9])$escaped(?![A-Za-z0-9])' : escaped;
  final re = RegExp(pattern, caseSensitive: caseSensitive);
  if (_keyRegexCache.length >= _kKeyRegexCacheMax) _keyRegexCache.clear();
  _keyRegexCache[cacheKey] = re;
  return re;
}

/// Test-only: number of distinct (key,caseSensitive,wholeWords) regexes cached.
@visibleForTesting
int get debugKeyRegexCacheSize => _keyRegexCache.length;

/// Test-only: drop the compiled keyword-RegExp cache.
@visibleForTesting
void debugClearKeyRegexCache() => _keyRegexCache.clear();

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
///   - otherwise: delegated to [evaluateLoreEntryTrigger] (primary
///     case-insensitive WORD-BOUNDARY match by default, plus optional
///     secondary-key selective logic + probability, all opt-in per entry)
///
/// Final order: hits sorted by `order` descending (chara_card_v2
/// convention: higher order = higher injection priority).
LorebookScanResult scanLorebookHits(
  List<Lorebook> books,
  List<Message> messages, {
  int window = 6,
  Random? rng,
}) {
  // Wave 1.1 (F3): keep the RAW (un-lowercased) window text. Case folding
  // now happens INSIDE the per-key match so a per-entry `caseSensitive`
  // override can opt out of it. Default behaviour (caseSensitive == null →
  // false) still folds case, identical to pre-1.1.
  final windowText = messages.reversed
      .take(window)
      .map((m) => m.text)
      .join(' ');
  final roller = rng ?? Random();
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
      final decision = evaluateLoreEntryTrigger(
        windowText,
        e,
        roll: (max) => roller.nextInt(max),
      );
      if (decision.triggered) {
        hits.add(e);
        trace.add('${book.name} • ${decision.reason}');
      }
    }
  }
  // Wave 1.1 fix (H-9): DETERMINISTIC, STABLE injection order. Dart's
  // `List.sort` is NOT a stable sort, so for the overwhelmingly common
  // all-`order:0` case (every hand-made entry — `order` is import-only) the
  // build-to-build sequence was implementation-defined: it could reshuffle
  // equal-order entries between runs, which (a) reads non-deterministically
  // and (b) busts provider prompt caching by changing the assembled prompt
  // bytes. We sort an INDEX list (the insertion order = scan order = book
  // order then entry order) by `order` DESCENDING, tie-breaking on the
  // original index ASCENDING. Equal-order entries therefore inject in a
  // fixed, documented sequence (scan order) every time; an explicit higher
  // `order` still wins. We reorder `trace` in lockstep so the diagnostic
  // trace stays aligned with the reordered hits.
  //
  // (Optional future affordance — intentionally NOT built here to respect the
  // app's minimalism: a drag-to-reorder editor for `order`. Today `order` is
  // only set on import; this fix makes the equal-`order` default stable.)
  final idx = List<int>.generate(hits.length, (i) => i);
  idx.sort((a, b) {
    final byOrder = hits[b].order.compareTo(hits[a].order); // desc
    if (byOrder != 0) return byOrder;
    return a.compareTo(b); // stable tie-break: original scan order
  });
  final sortedHits = [for (final i in idx) hits[i]];
  final sortedTrace = [for (final i in idx) trace[i]];
  return LorebookScanResult(
    hits: sortedHits,
    trace: sortedTrace,
    totalScanned: totalScanned,
    skippedDisabled: skippedDisabled,
  );
}

/// Outcome of [evaluateLoreEntryTrigger] — whether the entry fires plus a
/// short human-readable reason for the diagnostic trace.
class LoreTriggerDecision {
  final bool triggered;
  final String reason;
  const LoreTriggerDecision(this.triggered, this.reason);
}

/// Wave 1.1 (F3): pure per-entry trigger decision for a NON-constant,
/// ENABLED entry. (Constant + disabled handling stays in [scanLorebookHits]
/// because they short-circuit the scan and the trace wording differs.)
///
/// Logic, layered so that the pre-1.1 path is byte-for-byte unchanged:
///   1. Primary match — at least one of [LoreEntry.keys] is present in
///      [text], using the entry's case/whole-word overrides (defaulting to
///      case-insensitive whole-word, today's behaviour). No primary match →
///      never fires.
///   2. Selective logic — ONLY when [LoreEntry.secondaryKeys] is non-empty,
///      combine the secondary presence with the primary match per
///      [LoreEntry.selectiveLogic]. Empty secondary keys → primary decides
///      alone (unchanged from today).
///   3. Probability — ONLY when [LoreEntry.useProbability] is true, roll
///      `roll(100)` (0..99) and fire iff `roll < probability`. `>= 100`
///      always fires, `<= 0` never. When useProbability is false the entry
///      always fires on a logic match (unchanged from today).
///
/// [roll] is injected for deterministic tests; production passes a real
/// `Random().nextInt`. It is only consulted when probability would actually
/// gate the result, so a pure-match test never needs to supply it.
LoreTriggerDecision evaluateLoreEntryTrigger(
  String text,
  LoreEntry entry, {
  int Function(int max)? roll,
}) {
  final caseSensitive = entry.caseSensitive ?? false;
  final wholeWords = entry.matchWholeWords ?? true;

  String? matchedKey;
  for (final k in entry.keys) {
    if (k.isEmpty) continue;
    if (_keyMatches(text, k,
        caseSensitive: caseSensitive, wholeWords: wholeWords)) {
      matchedKey = k;
      break;
    }
  }
  if (matchedKey == null) {
    return const LoreTriggerDecision(false, 'no primary key matched');
  }

  // Selective logic on secondary keys (only when present).
  var reason = 'matched `$matchedKey`';
  final secondaries =
      entry.secondaryKeys.where((s) => s.isNotEmpty).toList(growable: false);
  if (secondaries.isNotEmpty) {
    final present = <String>[];
    final absent = <String>[];
    for (final s in secondaries) {
      if (_keyMatches(text, s,
          caseSensitive: caseSensitive, wholeWords: wholeWords)) {
        present.add(s);
      } else {
        absent.add(s);
      }
    }
    final bool selectivePass;
    switch (entry.selectiveLogic) {
      case LoreSelectiveLogic.andAny:
        selectivePass = present.isNotEmpty;
        break;
      case LoreSelectiveLogic.andAll:
        selectivePass = absent.isEmpty;
        break;
      case LoreSelectiveLogic.notAny:
        selectivePass = present.isEmpty;
        break;
      case LoreSelectiveLogic.notAll:
        selectivePass = absent.isNotEmpty;
        break;
    }
    if (!selectivePass) {
      return LoreTriggerDecision(
        false,
        'primary `$matchedKey` matched but secondary logic '
        '(${entry.selectiveLogic.name}) failed',
      );
    }
    reason = 'matched `$matchedKey` + secondary (${entry.selectiveLogic.name})';
  }

  // Probability gate (only when explicitly enabled).
  if (entry.useProbability) {
    final p = entry.probability;
    if (p <= 0) {
      return const LoreTriggerDecision(false, 'probability 0% — skipped');
    }
    if (p < 100) {
      final rollFn = roll ?? Random().nextInt;
      final value = rollFn(100); // 0..99
      if (value >= p) {
        return LoreTriggerDecision(
            false, 'probability roll $value >= $p% — skipped');
      }
      reason = '$reason (probability roll $value < $p%)';
    }
    // p >= 100 → always fire.
  }

  return LoreTriggerDecision(true, reason);
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
/// Implementation: `(?<![A-Za-z0-9])KEY(?![A-Za-z0-9])` with the key escaped.
/// Lookarounds (not `\b`) so keys that START or END with a non-word character
/// — punctuation, emoji, CJK — still match (a bare `\b` would wrongly fail
/// there, since `\b` needs a word char on one side).
///
/// Wave 1.1 (F3): generalised from the old `_keyMatchesAtWordBoundary` to
/// honour per-entry overrides. The DEFAULTS reproduce the pre-1.1 path
/// exactly:
///   - [caseSensitive] `false` → `caseSensitive: false` regex (today).
///   - [wholeWords] `true` → the boundary lookarounds (today).
/// When [wholeWords] is false the key matches anywhere (raw substring /
/// `contains`-style) — the old short-key over-matching behaviour, opted into
/// deliberately per entry.
bool _keyMatches(
  String text,
  String key, {
  bool caseSensitive = false,
  bool wholeWords = true,
}) {
  // Reuse a cached compiled RegExp for this (key, caseSensitive, wholeWords)
  // — the scan recompiles per key per entry per prompt build otherwise.
  return _compileKeyCached(key, caseSensitive, wholeWords).hasMatch(text);
}
