// Tests for the "hide filed characters from home" feature.
// The pure function `topLevelVisibleCharacters` encodes all visibility rules;
// these tests run without Flutter widgets or a store.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/characters_screen.dart';

Character _c(String id, {bool deleted = false, bool favorite = false}) =>
    Character(id: id, name: 'Char $id', deleted: deleted, favorite: favorite);

Folder _f(String id, List<String> memberIds, {bool deleted = false}) => Folder(
      id: id,
      name: 'Folder $id',
      characterIds: memberIds,
      mtime: 0,
      deleted: deleted,
    );

void main() {
  group('topLevelVisibleCharacters — home (no folder, no query)', () {
    test('shows only unfiled characters when some are filed', () {
      final chars = [_c('a'), _c('b'), _c('c')];
      final folders = [_f('f1', ['b'])];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result.map((c) => c.id).toList(), containsAll(['a', 'c']));
      expect(result.any((c) => c.id == 'b'), isFalse,
          reason: 'filed character b must be hidden from home');
    });

    test('shows all characters when none are filed', () {
      final chars = [_c('a'), _c('b'), _c('c')];
      final folders = <Folder>[];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result.map((c) => c.id).toSet(), equals({'a', 'b', 'c'}));
    });

    test('returns empty list when all characters are filed', () {
      final chars = [_c('a'), _c('b')];
      final folders = [_f('f1', ['a', 'b'])];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result, isEmpty,
          reason: 'all filed → home shows no character rows (folders section still shown in UI)');
    });

    test('ignores deleted (tombstoned) folders when computing filed set', () {
      final chars = [_c('a'), _c('b')];
      // f1 is deleted — its membership must be ignored
      final folders = [_f('f1', ['a'], deleted: true)];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result.map((c) => c.id).toSet(), equals({'a', 'b'}),
          reason: 'deleted folder must not hide characters from home');
    });

    test('multi-folder: character in any live folder is hidden', () {
      final chars = [_c('a'), _c('b'), _c('c')];
      // a is in f1, c is in f2, b is in neither
      final folders = [
        _f('f1', ['a']),
        _f('f2', ['c']),
      ];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result.map((c) => c.id).toList(), equals(['b']));
    });

    test('character in multiple folders is hidden exactly once', () {
      final chars = [_c('x')];
      final folders = [
        _f('f1', ['x']),
        _f('f2', ['x']),
      ];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result, isEmpty,
          reason: 'multi-folder membership should not cause duplicates or errors');
    });

    test('deleted characters are still excluded even if unfiled', () {
      final chars = [_c('a'), _c('b', deleted: true)];
      final folders = <Folder>[];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result.map((c) => c.id).toList(), equals(['a']),
          reason: 'deleted characters are never visible regardless of filing');
    });
  });

  group('topLevelVisibleCharacters — folder open (activeFolderId set)', () {
    test('shows only the folder members when a folder is active', () {
      final chars = [_c('a'), _c('b'), _c('c')];
      final folders = [_f('f1', ['a', 'c'])];
      final result = topLevelVisibleCharacters(chars, folders,
          activeFolderId: 'f1');
      expect(result.map((c) => c.id).toSet(), equals({'a', 'c'}));
      expect(result.any((c) => c.id == 'b'), isFalse);
    });

    test('returns empty when folder exists but is empty', () {
      final chars = [_c('a'), _c('b')];
      final folders = [_f('f1', [])];
      final result = topLevelVisibleCharacters(chars, folders,
          activeFolderId: 'f1');
      expect(result, isEmpty);
    });

    test('returns empty when folder id not found (vanished)', () {
      final chars = [_c('a'), _c('b')];
      final folders = [_f('f1', ['a'])];
      final result = topLevelVisibleCharacters(chars, folders,
          activeFolderId: 'ghost');
      expect(result, isEmpty,
          reason: 'vanished folder → empty (same as existing behavior)');
    });
  });

  group('topLevelVisibleCharacters — search active (query non-empty)', () {
    test('search scans ALL characters including filed ones', () {
      final chars = [_c('a'), _c('b'), _c('c')];
      // b is filed
      final folders = [_f('f1', ['b'])];
      final result = topLevelVisibleCharacters(chars, folders, query: 'b');
      expect(result.any((c) => c.id == 'b'), isTrue,
          reason: 'search must surface filed characters (b is Char b)');
    });

    test('active folder with a query: returns full folder pool (text match is callers job)', () {
      // topLevelVisibleCharacters only determines the POOL; actual text
      // filtering happens in _applyFiltersAndSort (step 3, _matches).
      // When a folder is active, the pool = folder members regardless of query.
      final chars = [_c('a'), _c('b'), _c('c')];
      final folders = [_f('f1', ['a', 'b'])];
      final result = topLevelVisibleCharacters(chars, folders,
          activeFolderId: 'f1', query: 'b');
      // Returns all folder members — text match is NOT applied here.
      expect(result.map((c) => c.id).toSet(), equals({'a', 'b'}));
      expect(result.any((c) => c.id == 'c'), isFalse,
          reason: 'c is not in the active folder');
    });

    test('search with no folder active searches all unfiled AND filed', () {
      final chars = [
        Character(id: 'filed', name: 'Alice'),
        Character(id: 'unfiled', name: 'Bob'),
      ];
      final folders = [_f('f1', ['filed'])];
      final result =
          topLevelVisibleCharacters(chars, folders, query: 'alice');
      expect(result.any((c) => c.id == 'filed'), isTrue,
          reason: 'search must override the hide-filed rule');
    });

    test('empty query still hides filed characters', () {
      final chars = [_c('a'), _c('b')];
      final folders = [_f('f1', ['b'])];
      final result = topLevelVisibleCharacters(chars, folders, query: '');
      expect(result.map((c) => c.id).toList(), equals(['a']));
    });
  });

  group('topLevelVisibleCharacters — favorites rule', () {
    test('favorited but filed character is still hidden from home', () {
      final chars = [_c('a', favorite: true), _c('b')];
      final folders = [_f('f1', ['a'])];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result.any((c) => c.id == 'a'), isFalse,
          reason: 'favorite + filed → hides from home; lives in its folder');
    });

    test('favorited unfiled character stays visible on home', () {
      final chars = [_c('a', favorite: true), _c('b')];
      final folders = [_f('f1', ['b'])];
      final result = topLevelVisibleCharacters(chars, folders);
      expect(result.any((c) => c.id == 'a'), isTrue);
    });
  });
}
