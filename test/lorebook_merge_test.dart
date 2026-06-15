// TDD for mergeBoundLorebooksForExport (Wave 3 — Lorebook Creator integrations).
//
// Covers:
//   - empty list → null
//   - single book with no entries → null
//   - single book with entries → correct passthrough
//   - multiple books → entries concatenated
//   - exact duplicate (same keys + content) → deduplicated (first wins)
//   - same content different keys → NOT a duplicate
//   - same keys different content → NOT a duplicate
//   - key-order-insensitive dedup (["a","b"] == ["b","a"])
//   - merged book name = first book's name
//   - merged book description = joined descriptions (skips blanks)

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_merge.dart';

LoreEntry _e(String id, {List<String> keys = const [], String content = ''}) =>
    LoreEntry(id: id, keys: keys, content: content);

void main() {
  group('mergeBoundLorebooksForExport', () {
    test('empty list → null', () {
      expect(mergeBoundLorebooksForExport([]), isNull);
    });

    test('single book with no entries → null', () {
      final b = Lorebook(id: 'b1', name: 'Empty');
      expect(mergeBoundLorebooksForExport([b]), isNull);
    });

    test('single book → entries passed through', () {
      final b = Lorebook(
        id: 'b1',
        name: 'World',
        entries: [_e('e1', keys: ['gate'], content: 'A gate is…')],
      );
      final merged = mergeBoundLorebooksForExport([b]);
      expect(merged, isNotNull);
      expect(merged!.entries.length, 1);
      expect(merged.entries.first.content, 'A gate is…');
    });

    test('multiple books → entries concatenated in order', () {
      final b1 = Lorebook(
        id: 'b1',
        name: 'Book A',
        entries: [_e('e1', content: 'alpha')],
      );
      final b2 = Lorebook(
        id: 'b2',
        name: 'Book B',
        entries: [_e('e2', content: 'beta'), _e('e3', content: 'gamma')],
      );
      final merged = mergeBoundLorebooksForExport([b1, b2]);
      expect(merged!.entries.length, 3);
      expect(merged.entries.map((e) => e.content), ['alpha', 'beta', 'gamma']);
    });

    test('exact duplicate (keys + content) → deduplicated, first occurrence kept', () {
      final dup = _e('e1', keys: ['elf'], content: 'Elves are tall.');
      final dup2 = LoreEntry(id: 'e2', keys: ['elf'], content: 'Elves are tall.');
      final b1 = Lorebook(id: 'b1', name: 'A', entries: [dup]);
      final b2 = Lorebook(id: 'b2', name: 'B', entries: [dup2, _e('e3', content: 'unique')]);
      final merged = mergeBoundLorebooksForExport([b1, b2]);
      expect(merged!.entries.length, 2, reason: 'duplicate dropped, unique kept');
      expect(merged.entries.first.id, 'e1', reason: 'first occurrence wins');
    });

    test('same content different keys → NOT a duplicate', () {
      final b1 = Lorebook(
        id: 'b1', name: 'A',
        entries: [_e('e1', keys: ['elf'], content: 'Description.')],
      );
      final b2 = Lorebook(
        id: 'b2', name: 'B',
        entries: [_e('e2', keys: ['elven'], content: 'Description.')],
      );
      final merged = mergeBoundLorebooksForExport([b1, b2]);
      expect(merged!.entries.length, 2);
    });

    test('same keys different content → NOT a duplicate', () {
      final b1 = Lorebook(
        id: 'b1', name: 'A',
        entries: [_e('e1', keys: ['elf'], content: 'Version A.')],
      );
      final b2 = Lorebook(
        id: 'b2', name: 'B',
        entries: [_e('e2', keys: ['elf'], content: 'Version B.')],
      );
      final merged = mergeBoundLorebooksForExport([b1, b2]);
      expect(merged!.entries.length, 2);
    });

    test('key-order-insensitive dedup: ["a","b"] same as ["b","a"]', () {
      final e1 = LoreEntry(id: 'e1', keys: ['a', 'b'], content: 'same');
      final e2 = LoreEntry(id: 'e2', keys: ['b', 'a'], content: 'same');
      final b1 = Lorebook(id: 'b1', name: 'X', entries: [e1]);
      final b2 = Lorebook(id: 'b2', name: 'Y', entries: [e2]);
      final merged = mergeBoundLorebooksForExport([b1, b2]);
      expect(merged!.entries.length, 1, reason: 'key-order should not create false duplicates');
    });

    test('merged book name = first book name', () {
      final b1 = Lorebook(id: 'b1', name: 'Alpha Lore',
          entries: [_e('e1', content: 'x')]);
      final b2 = Lorebook(id: 'b2', name: 'Beta Lore',
          entries: [_e('e2', content: 'y')]);
      final merged = mergeBoundLorebooksForExport([b1, b2]);
      expect(merged!.name, 'Alpha Lore');
    });

    test('description joins non-blank descriptions with " · "', () {
      final b1 = Lorebook(id: 'b1', name: 'A', description: 'Desc A',
          entries: [_e('e1', content: 'x')]);
      final b2 = Lorebook(id: 'b2', name: 'B', description: '',
          entries: [_e('e2', content: 'y')]);
      final b3 = Lorebook(id: 'b3', name: 'C', description: 'Desc C',
          entries: [_e('e3', content: 'z')]);
      final merged = mergeBoundLorebooksForExport([b1, b2, b3]);
      expect(merged!.description, 'Desc A · Desc C');
    });

    test('all-empty entries across multiple books → null', () {
      final b1 = Lorebook(id: 'b1', name: 'A');
      final b2 = Lorebook(id: 'b2', name: 'B');
      expect(mergeBoundLorebooksForExport([b1, b2]), isNull);
    });
  });
}
