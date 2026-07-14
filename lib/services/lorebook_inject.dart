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
  // Persona party (2026-07-03, audit I-2): EVERY roster persona contributes
  // its bound books — the same "every member contributes" contract the
  // characters below have always had. Empty = classic single [persona],
  // byte-identical off-party.
  List<Persona> personaParty = const [],
}) {
  // Wave CD: per-chat attached books are ALWAYS additive — the user
  // explicitly attached them to this chat, the disabled-inherited list
  // doesn't affect them. Only inherited (char + persona) bindings are
  // subject to the override.
  final disabled = chat.disabledInheritedLorebookIds.toSet();
  final ids = <String>{...chat.attachedLorebookIds};
  final personas = personaParty.isNotEmpty ? personaParty : [?persona];
  for (final p in personas) {
    for (final id in p.lorebookIds) {
      if (!disabled.contains(id)) ids.add(id);
    }
  }
  final chatCharIds = chat.characterIds.isNotEmpty
      ? chat.characterIds
      : (responderId != null ? <String>[responderId] : const <String>[]);
  for (final cid in chatCharIds) {
    // Lorebook BINDINGS are live config, not frozen narrative content: read
    // them from the CURRENT library character when it exists, falling back to
    // the chat's frozen snapshot only for a snapshot-only member (library card
    // since deleted). This mirrors the persona path (always live) and fixes a
    // silent failure — a lorebook bound to a character AFTER a chat was created
    // never activated in that chat, because the snapshot was frozen (with an
    // empty/older `lorebookIds`) at creation and, being read FIRST, suppressed
    // the live binding. Narrative CONTENT (description/personality/scenario)
    // still reads snapshot-first at the assembly sites so an in-progress
    // roleplay isn't retroactively rewritten by later card edits — only the
    // binding list is taken live here.
    final source = lookupCharacter(cid) ?? chat.characterSnapshots[cid];
    if (source == null) continue;
    for (final id in source.lorebookIds) {
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
  /// Entries that should be injected into the prompt, sorted by ASCENDING
  /// `order` (2026-07-13 fix #1 — ST semantics: higher order = later in the
  /// block = closer to the history = more model attention).
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
///   - `entry.constant == true` → fires WITHOUT a keyword scan, but (lore
///     family fix #2, 2026-07-13) still subject to its own probability when
///     `useProbability` is set — SillyTavern semantics: an author who wrote
///     "constant, 30%" asked for a 30% ambient entry, not an always-on one.
///     Constant entries WITHOUT useProbability never consult the roller, so
///     seeded roll sequences (golden fixtures) are unchanged.
///   - otherwise: delegated to [evaluateLoreEntryTrigger] (primary
///     case-insensitive WORD-BOUNDARY match by default, plus optional
///     secondary-key selective logic + probability, all opt-in per entry)
///
/// [fillMacros], when provided, is applied to BOTH the scanned window text
/// and each key before matching (lore family fix #4, 2026-07-13): a key
/// written as `{{user}}` matched only the literal characters, and the raw
/// window still contained unresolved macros — so name-based keys silently
/// never fired. The caller supplies the same {{user}}/{{char}} filler the
/// prompt itself uses. Null = raw matching (older callers unchanged).
///
/// Final order (lore family fix #1, 2026-07-13): hits sorted by `order`
/// ASCENDING — higher order = LATER in the block = closer to the chat
/// history = more model attention. This is SillyTavern's insertion-order
/// semantics, which imported cards are authored against; the previous
/// descending sort put the author's most important entry FARTHEST from the
/// history, inverting the intent. Equal orders keep stable scan order.
LorebookScanResult scanLorebookHits(
  List<Lorebook> books,
  List<Message> messages, {
  int window = 6,
  Random? rng,
  String Function(String)? fillMacros,
}) {
  // Wave 1.1 (F3): keep the RAW (un-lowercased) window text. Case folding
  // now happens INSIDE the per-key match so a per-entry `caseSensitive`
  // override can opt out of it. Default behaviour (caseSensitive == null →
  // false) still folds case, identical to pre-1.1.
  final rawWindow = messages.reversed
      .take(window)
      .map((m) => m.text)
      .join(' ');
  final windowText = fillMacros == null ? rawWindow : fillMacros(rawWindow);
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
        // Fix #2 (2026-07-13): constant entries honour their OWN probability
        // — same gate semantics as evaluateLoreEntryTrigger (<=0 never,
        // <100 roll, >=100 always). The roller is consulted ONLY when
        // useProbability is on, so existing constant entries (and seeded
        // golden fixtures) behave byte-identically.
        if (e.useProbability) {
          final p = e.probability;
          if (p <= 0) {
            continue;
          }
          if (p < 100) {
            final value = roller.nextInt(100); // 0..99
            if (value >= p) {
              continue;
            }
            hits.add(e);
            trace.add(
                '${book.name} • constant entry (probability roll $value < $p%)');
            continue;
          }
        }
        hits.add(e);
        trace.add('${book.name} • constant entry');
        continue;
      }
      final decision = evaluateLoreEntryTrigger(
        windowText,
        e,
        roll: (max) => roller.nextInt(max),
        fillMacros: fillMacros,
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
  // build-to-build sequence was implementation-defined. We sort an INDEX
  // list by `order`, tie-breaking on the original index ASCENDING, so
  // equal-order entries inject in a fixed, documented sequence (scan order)
  // every time. `trace` is reordered in lockstep.
  //
  // Lore family fix #1 (2026-07-13, Codex-confirmed audit finding): the sort
  // is now ASCENDING — higher `order` = LATER in the assembled block =
  // closest to the chat history = most model attention. The previous
  // DESCENDING sort ("higher = appears first") inverted SillyTavern's
  // insertion-order semantics, so imported cards' most important entries
  // landed farthest from the history. All-equal-order books (every
  // hand-made entry) are byte-identical either way.
  final idx = List<int>.generate(hits.length, (i) => i);
  idx.sort((a, b) {
    final byOrder = hits[a].order.compareTo(hits[b].order); // asc
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
  String Function(String)? fillMacros,
}) {
  final caseSensitive = entry.caseSensitive ?? false;
  final wholeWords = entry.matchWholeWords ?? true;
  // Lore family fix #4 (2026-07-13): expand {{user}}/{{char}} in the KEY
  // before matching — a key authored as `{{user}}` used to match only the
  // literal braces, never the persona's name. The expanded key is what feeds
  // the compile cache, so a persona change naturally re-keys the cache.
  String expandKey(String k) => fillMacros == null ? k : fillMacros(k);

  String? matchedKey;
  for (final k in entry.keys) {
    if (k.isEmpty) continue;
    if (_keyMatches(text, expandKey(k),
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
      if (_keyMatches(text, expandKey(s),
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
