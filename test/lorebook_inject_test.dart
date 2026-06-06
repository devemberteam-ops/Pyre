// Wave 1.1 (F3): matching engine for the SillyTavern-style lorebook keyword
// options. The pure `evaluateLoreEntryTrigger` is exercised directly for each
// selectiveLogic mode + probability boundaries, plus regressions that a
// default-options entry triggers EXACTLY as it did before 1.1.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_inject.dart';

void main() {
  // The scanned window text used across the logic tests.
  const text = 'The Sunken Gate yawned open as the siege began at dawn.';

  LoreEntry entry({
    List<String> keys = const ['Gate'],
    List<String> secondary = const [],
    LoreSelectiveLogic logic = LoreSelectiveLogic.andAny,
    bool? caseSensitive,
    bool? wholeWords,
    int probability = 100,
    bool useProbability = false,
  }) =>
      LoreEntry(
        id: 'e',
        keys: keys,
        secondaryKeys: secondary,
        selectiveLogic: logic,
        caseSensitive: caseSensitive,
        matchWholeWords: wholeWords,
        probability: probability,
        useProbability: useProbability,
      );

  group('regression: default options = pre-1.1 behaviour', () {
    test('primary match with no secondary keys → triggers (case-insensitive)',
        () {
      // "Gate" appears as "Gate"; default is case-insensitive whole-word.
      expect(evaluateLoreEntryTrigger(text, entry()).triggered, isTrue);
    });

    test('no primary match → never triggers', () {
      expect(
        evaluateLoreEntryTrigger(text, entry(keys: const ['dragon'])).triggered,
        isFalse,
      );
    });

    test('short key does NOT match inside a larger word (word boundary)', () {
      // "at" must not fire inside "Gate"/"dawn". Default whole-word.
      expect(
        evaluateLoreEntryTrigger('Gate at dawn', entry(keys: const ['at']))
            .triggered,
        isTrue, // standalone "at" present
      );
      expect(
        evaluateLoreEntryTrigger('Gateway', entry(keys: const ['Gate']))
            .triggered,
        isFalse, // "Gate" inside "Gateway" must NOT fire
      );
    });
  });

  group('per-entry case / whole-word overrides', () {
    test('caseSensitive=true only matches exact case', () {
      expect(
        evaluateLoreEntryTrigger('the gate', entry(keys: const ['Gate']))
            .triggered,
        isTrue, // default case-insensitive
      );
      expect(
        evaluateLoreEntryTrigger('the gate',
                entry(keys: const ['Gate'], caseSensitive: true))
            .triggered,
        isFalse, // case-sensitive: 'Gate' != 'gate'
      );
    });

    test('matchWholeWords=false allows substring match', () {
      expect(
        evaluateLoreEntryTrigger('Gateway',
                entry(keys: const ['Gate'], wholeWords: false))
            .triggered,
        isTrue,
      );
    });
  });

  group('selectiveLogic on secondary keys (primary already matched)', () {
    // primary "Gate" matches in `text`. secondary present: "siege"; absent:
    // "ambush".
    test('andAny: at least one secondary present → fires', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'ambush'],
                    logic: LoreSelectiveLogic.andAny))
            .triggered,
        isTrue,
      );
    });

    test('andAny: NO secondary present → does not fire', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['ambush', 'volcano'],
                    logic: LoreSelectiveLogic.andAny))
            .triggered,
        isFalse,
      );
    });

    test('andAll: all secondaries present → fires; one absent → no', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'dawn'],
                    logic: LoreSelectiveLogic.andAll))
            .triggered,
        isTrue,
      );
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'ambush'],
                    logic: LoreSelectiveLogic.andAll))
            .triggered,
        isFalse,
      );
    });

    test('notAny: none present → fires; one present → no', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['ambush', 'volcano'],
                    logic: LoreSelectiveLogic.notAny))
            .triggered,
        isTrue,
      );
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege'],
                    logic: LoreSelectiveLogic.notAny))
            .triggered,
        isFalse,
      );
    });

    test('notAll: at least one absent → fires; all present → no', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'ambush'],
                    logic: LoreSelectiveLogic.notAll))
            .triggered,
        isTrue, // ambush absent
      );
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    secondary: const ['siege', 'dawn'],
                    logic: LoreSelectiveLogic.notAll))
            .triggered,
        isFalse, // both present
      );
    });

    test('secondary logic never fires when the primary did not match', () {
      expect(
        evaluateLoreEntryTrigger(
                text,
                entry(
                    keys: const ['dragon'],
                    secondary: const ['siege'],
                    logic: LoreSelectiveLogic.andAny))
            .triggered,
        isFalse,
      );
    });
  });

  group('probability gate', () {
    test('useProbability=false → probability ignored, always fires', () {
      // roll would say "no" but useProbability is off, so it must fire.
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 0, useProbability: false),
        roll: (_) => 0,
      );
      expect(d.triggered, isTrue);
    });

    test('probability 100 always fires (never consults the roll)', () {
      var rolled = false;
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 100, useProbability: true),
        roll: (_) {
          rolled = true;
          return 99;
        },
      );
      expect(d.triggered, isTrue);
      expect(rolled, isFalse, reason: 'p>=100 short-circuits the roll');
    });

    test('probability 0 never fires', () {
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 0, useProbability: true),
        roll: (_) => 0,
      );
      expect(d.triggered, isFalse);
    });

    test('roll < probability → fires', () {
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 50, useProbability: true),
        roll: (_) => 49,
      );
      expect(d.triggered, isTrue);
    });

    test('roll >= probability → does not fire', () {
      final d = evaluateLoreEntryTrigger(
        text,
        entry(probability: 50, useProbability: true),
        roll: (_) => 50,
      );
      expect(d.triggered, isFalse);
    });

    test('probability gate runs AFTER selective logic (logic fail = no roll)',
        () {
      var rolled = false;
      final d = evaluateLoreEntryTrigger(
        text,
        entry(
          secondary: const ['ambush'], // absent → andAny fails
          logic: LoreSelectiveLogic.andAny,
          probability: 100,
          useProbability: true,
        ),
        roll: (_) {
          rolled = true;
          return 0;
        },
      );
      expect(d.triggered, isFalse);
      expect(rolled, isFalse);
    });
  });

  group('scanLorebookHits integration (defaults unchanged)', () {
    Message msg(String t) => Message(id: t, kind: MessageKind.user, variants: [t]);

    test('a default-options entry fires off the scanned window', () {
      final book = Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LoreEntry(id: 'e1', keys: const ['Gate'], content: 'lore'),
        ],
      );
      final res = scanLorebookHits([book], [msg('Through the Gate we go.')]);
      expect(res.hits.length, 1);
      expect(res.hits.first.content, 'lore');
    });

    test('constant entry always fires; disabled is skipped', () {
      final book = Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LoreEntry(id: 'c', content: 'always', constant: true),
          LoreEntry(
              id: 'd', keys: const ['Gate'], content: 'off', enabled: false),
        ],
      );
      final res = scanLorebookHits([book], [msg('no keyword here')]);
      expect(res.hits.map((e) => e.content), const ['always']);
      expect(res.skippedDisabled, 1);
    });

    test('secondary-key entry honours selectiveLogic in a full scan', () {
      final book = Lorebook(
        id: 'b',
        name: 'Book',
        entries: [
          LoreEntry(
            id: 'e',
            keys: const ['Gate'],
            content: 'siege lore',
            secondaryKeys: const ['siege'],
            selectiveLogic: LoreSelectiveLogic.andAny,
          ),
        ],
      );
      expect(
        scanLorebookHits([book], [msg('Gate and siege')]).hits.length,
        1,
      );
      expect(
        scanLorebookHits([book], [msg('Gate alone, no second word')]).hits,
        isEmpty,
      );
    });
  });

  group('H-9: deterministic, stable injection order', () {
    Message msg(String t) =>
        Message(id: t, kind: MessageKind.user, variants: [t]);

    test('equal order (all-zero) preserves scan order, stable across repeats',
        () {
      // Three constant entries across two books, all order:0 (the common
      // hand-made case). The documented stable sequence is SCAN ORDER:
      // book A entry a1, a2, then book B entry b1.
      final bookA = Lorebook(id: 'A', name: 'A', entries: [
        LoreEntry(id: 'a1', content: 'A1', constant: true),
        LoreEntry(id: 'a2', content: 'A2', constant: true),
      ]);
      final bookB = Lorebook(id: 'B', name: 'B', entries: [
        LoreEntry(id: 'b1', content: 'B1', constant: true),
      ]);
      const expected = ['a1', 'a2', 'b1'];
      // Repeat many times: the order must be identical every build.
      for (var i = 0; i < 25; i++) {
        final res = scanLorebookHits([bookA, bookB], [msg('window $i')]);
        expect(res.hits.map((e) => e.id).toList(), expected,
            reason: 'equal-order entries must inject in stable scan order');
      }
    });

    test('explicit higher order still wins over scan order', () {
      final book = Lorebook(id: 'b', name: 'b', entries: [
        LoreEntry(id: 'low', content: 'low', constant: true, order: 1),
        LoreEntry(id: 'high', content: 'high', constant: true, order: 5),
        LoreEntry(id: 'mid', content: 'mid', constant: true, order: 3),
      ]);
      final res = scanLorebookHits([book], [msg('anything')]);
      // Descending by order: high(5), mid(3), low(1).
      expect(res.hits.map((e) => e.id).toList(), ['high', 'mid', 'low']);
    });

    test('equal-order ties tie-break on scan order, not on the unstable sort',
        () {
      // Two order:2 entries bracketing an order:5: high must lead, then the
      // two order:2 entries IN SCAN ORDER (t1 before t2).
      final book = Lorebook(id: 'b', name: 'b', entries: [
        LoreEntry(id: 't1', content: 't1', constant: true, order: 2),
        LoreEntry(id: 'high', content: 'high', constant: true, order: 5),
        LoreEntry(id: 't2', content: 't2', constant: true, order: 2),
      ]);
      for (var i = 0; i < 25; i++) {
        final res = scanLorebookHits([book], [msg('x $i')]);
        expect(res.hits.map((e) => e.id).toList(), ['high', 't1', 't2']);
      }
    });

    test('trace stays aligned with the reordered hits', () {
      final book = Lorebook(id: 'b', name: 'World', entries: [
        LoreEntry(id: 'low', content: 'low', constant: true, order: 1),
        LoreEntry(id: 'high', content: 'high', constant: true, order: 9),
      ]);
      final res = scanLorebookHits([book], [msg('anything')]);
      expect(res.hits.length, 2);
      expect(res.trace.length, 2);
      // Both are constant entries from "World" → trace text identical, but the
      // count/alignment invariant must hold post-sort.
      expect(res.trace.every((t) => t.startsWith('World')), isTrue);
    });
  });

  group('compiled keyword-RegExp cache (perf-at-scale #5)', () {
    Message msg(String t) =>
        Message(id: t, kind: MessageKind.user, variants: [t]);

    setUp(debugClearKeyRegexCache);

    test('repeated scans of the same key compile its regex once', () {
      final book = Lorebook(
        id: 'b',
        name: 'World',
        entries: [LoreEntry(id: 'e', keys: const ['Gate'])],
      );
      expect(debugKeyRegexCacheSize, 0);
      // Simulate many prompt builds over the same lorebook.
      for (var i = 0; i < 20; i++) {
        scanLorebookHits([book], [msg('window text $i')]);
      }
      // One key → exactly one cached compiled regex (default flags).
      expect(debugKeyRegexCacheSize, 1);
    });

    test('distinct keys / flag combos get distinct entries', () {
      final book = Lorebook(
        id: 'b',
        name: 'World',
        entries: [
          LoreEntry(id: 'a', keys: const ['Gate']),
          LoreEntry(id: 'b', keys: const ['Vael']),
          LoreEntry(id: 'c', keys: const ['Gate'], caseSensitive: true),
        ],
      );
      scanLorebookHits([book], [msg('nothing matches here')]);
      // 'Gate'(default), 'Vael'(default), 'Gate'(caseSensitive) → 3 distinct.
      expect(debugKeyRegexCacheSize, 3);
    });

    test('caching does not change match results', () {
      final book = Lorebook(
        id: 'b',
        name: 'World',
        entries: [LoreEntry(id: 'e', keys: const ['Gate'])],
      );
      // Whole-word boundary still applies from cache: "Gateway" must NOT hit.
      expect(scanLorebookHits([book], [msg('Through the Gate')]).hits.length, 1);
      expect(scanLorebookHits([book], [msg('Gateway open')]).hits, isEmpty);
    });
  });
}
