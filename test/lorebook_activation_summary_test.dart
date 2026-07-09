// Chat info sheet — "Lore active: N of M entries" diagnostic (1.2.1).
//
// The chat info sheet runs a DISPLAY-ONLY scanLorebookHits pass to show the
// user which lorebook entries are actually firing (and why), so "lorebooks
// don't seem to activate" stops being a black box. This test locks down the
// fired-vs-total counting contract the sheet relies on:
//   - fired (N)  = res.hits.length — constant entries always count, keyword
//     entries count only when their keyword is present in the scanned
//     window.
//   - total (M)  = res.totalScanned - res.skippedDisabled — every ENABLED
//     entry across the attached books, regardless of whether it fired.
//
// scanLorebookHits already exposes totalScanned/skippedDisabled, so no new
// helper is extracted here (see wave note in lib/services/lorebook_inject.dart
// scanLorebookHits doc) — the sheet needs the SAME scan's trace too, so a
// separate summary-only helper would just force a second, redundant scan.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_inject.dart';

void main() {
  Message msg(String t) => Message(id: t, kind: MessageKind.user, variants: [t]);

  group('lore activation summary (N of M) via scanLorebookHits', () {
    test('constant entry + present keyword fire; absent keyword does not; '
        'disabled entry excluded from the total', () {
      final book = Lorebook(
        id: 'b',
        name: 'World',
        entries: [
          LoreEntry(id: 'const', content: 'always on', constant: true),
          LoreEntry(id: 'present', keys: const ['dragon'], content: 'p'),
          LoreEntry(id: 'absent', keys: const ['griffin'], content: 'a'),
          LoreEntry(
              id: 'off',
              keys: const ['whatever'],
              content: 'o',
              enabled: false),
        ],
      );

      final res = scanLorebookHits(
        [book],
        [msg('A dragon appeared over the ridge.')],
      );

      final fired = res.hits.length;
      final total = res.totalScanned - res.skippedDisabled;

      // Fired: constant + the present-keyword entry. NOT the absent-keyword
      // one, NOT the disabled one.
      expect(fired, 2);
      expect(res.hits.map((e) => e.id).toSet(), {'const', 'present'});

      // Total counts every ENABLED entry (3), the disabled one is excluded.
      expect(total, 3);
      expect(res.skippedDisabled, 1);
      expect(res.totalScanned, 4);
    });

    test('no attached books → zero fired, zero total', () {
      final res = scanLorebookHits(const [], [msg('anything')]);
      expect(res.hits.length, 0);
      expect(res.totalScanned - res.skippedDisabled, 0);
    });

    test('books attached but nothing matches → 0 fired, M > 0 total', () {
      final book = Lorebook(
        id: 'b',
        name: 'World',
        entries: [
          LoreEntry(id: 'a', keys: const ['griffin'], content: 'a'),
          LoreEntry(id: 'b', keys: const ['phoenix'], content: 'b'),
        ],
      );
      final res = scanLorebookHits([book], [msg('nothing relevant here')]);
      expect(res.hits, isEmpty);
      expect(res.totalScanned - res.skippedDisabled, 2);
    });

    test('total spans multiple attached books', () {
      final bookA = Lorebook(id: 'A', name: 'A', entries: [
        LoreEntry(id: 'a1', content: 'a1', constant: true),
      ]);
      final bookB = Lorebook(id: 'B', name: 'B', entries: [
        LoreEntry(id: 'b1', keys: const ['dragon'], content: 'b1'),
        LoreEntry(id: 'b2', keys: const ['griffin'], content: 'b2'),
      ]);
      final res =
          scanLorebookHits([bookA, bookB], [msg('a dragon flies by')]);
      expect(res.hits.map((e) => e.id).toSet(), {'a1', 'b1'});
      expect(res.totalScanned - res.skippedDisabled, 3);
    });
  });
}
