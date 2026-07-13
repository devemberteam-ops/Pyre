// 2026-07-13 (community request) — folders organise Personas and Lorebooks
// too, mirroring the character pattern exactly.
//
// Covered here:
//   - the pure visibility helpers `topLevelVisiblePersonas` /
//     `topLevelVisibleLorebooks` (folder-scoped / search-all / hide-filed /
//     vanished-folder rules, mirroring character_folder_visibility_test.dart)
//   - the AppStore membership ops (add / remove / dedupe / unknown-folder
//     no-op) and that removePersona / removeLorebook clean folder membership
//   - `Folder` JSON round-trip with the new `personaIds` / `lorebookIds`
//     fields, incl. old-JSON back-compat (missing fields → empty lists) and
//     the empty-omitted toJson shape that keeps pre-existing folders
//     byte-identical.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/characters_screen.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

Persona _p(String id, {bool deleted = false}) =>
    Persona(id: id, name: 'Persona $id', deleted: deleted);

Lorebook _b(String id, {bool hidden = false, bool deleted = false}) =>
    Lorebook(id: id, name: 'Book $id', hidden: hidden, deleted: deleted);

Folder _fPersonas(String id, List<String> memberIds,
        {bool deleted = false}) =>
    Folder(
      id: id,
      name: 'Folder $id',
      personaIds: memberIds,
      mtime: 0,
      deleted: deleted,
    );

Folder _fBooks(String id, List<String> memberIds, {bool deleted = false}) =>
    Folder(
      id: id,
      name: 'Folder $id',
      lorebookIds: memberIds,
      mtime: 0,
      deleted: deleted,
    );

void main() {
  group('topLevelVisiblePersonas', () {
    test('home: shows only unfiled personas when some are filed', () {
      final personas = [_p('a'), _p('b'), _p('c')];
      final folders = [_fPersonas('f1', ['b'])];
      final result = topLevelVisiblePersonas(personas, folders);
      expect(result.map((p) => p.id).toList(), equals(['a', 'c']));
    });

    test('home: deleted (tombstoned) folders do not hide personas', () {
      final personas = [_p('a'), _p('b')];
      final folders = [_fPersonas('f1', ['a'], deleted: true)];
      final result = topLevelVisiblePersonas(personas, folders);
      expect(result.map((p) => p.id).toSet(), equals({'a', 'b'}));
    });

    test('home: tombstoned personas are excluded even if unfiled', () {
      final personas = [_p('a'), _p('b', deleted: true)];
      final result = topLevelVisiblePersonas(personas, []);
      expect(result.map((p) => p.id).toList(), equals(['a']));
    });

    test('folder open: shows only the folder members', () {
      final personas = [_p('a'), _p('b'), _p('c')];
      final folders = [_fPersonas('f1', ['a', 'c'])];
      final result =
          topLevelVisiblePersonas(personas, folders, activeFolderId: 'f1');
      expect(result.map((p) => p.id).toSet(), equals({'a', 'c'}));
    });

    test('folder open: tombstoned member is still excluded', () {
      final personas = [_p('a'), _p('b', deleted: true)];
      final folders = [_fPersonas('f1', ['a', 'b'])];
      final result =
          topLevelVisiblePersonas(personas, folders, activeFolderId: 'f1');
      expect(result.map((p) => p.id).toList(), equals(['a']));
    });

    test('folder open: vanished folder id returns empty', () {
      final personas = [_p('a')];
      final folders = [_fPersonas('f1', ['a'])];
      final result = topLevelVisiblePersonas(personas, folders,
          activeFolderId: 'ghost');
      expect(result, isEmpty,
          reason: 'vanished folder → empty (same as characters)');
    });

    test('search: scans ALL personas including filed ones', () {
      final personas = [_p('a'), _p('b')];
      final folders = [_fPersonas('f1', ['b'])];
      final result =
          topLevelVisiblePersonas(personas, folders, query: 'b');
      expect(result.any((p) => p.id == 'b'), isTrue,
          reason: 'search must override the hide-filed rule');
    });

    test('search: empty query still hides filed personas', () {
      final personas = [_p('a'), _p('b')];
      final folders = [_fPersonas('f1', ['b'])];
      final result = topLevelVisiblePersonas(personas, folders, query: '');
      expect(result.map((p) => p.id).toList(), equals(['a']));
    });
  });

  group('topLevelVisibleLorebooks', () {
    test('home: shows only unfiled books when some are filed', () {
      final books = [_b('a'), _b('b'), _b('c')];
      final folders = [_fBooks('f1', ['b'])];
      final result = topLevelVisibleLorebooks(books, folders);
      expect(result.map((b) => b.id).toList(), equals(['a', 'c']));
    });

    test('home: hidden (embedded-only) books never surface', () {
      final books = [_b('a'), _b('h', hidden: true)];
      final result = topLevelVisibleLorebooks(books, []);
      expect(result.map((b) => b.id).toList(), equals(['a']));
    });

    test('folder open: hidden member is still excluded', () {
      // A hidden book filed into a folder must NOT leak into the folder
      // view — the management-list pre-filter applies everywhere.
      final books = [_b('a'), _b('h', hidden: true)];
      final folders = [_fBooks('f1', ['a', 'h'])];
      final result =
          topLevelVisibleLorebooks(books, folders, activeFolderId: 'f1');
      expect(result.map((b) => b.id).toList(), equals(['a']));
    });

    test('folder open: shows only the folder members', () {
      final books = [_b('a'), _b('b'), _b('c')];
      final folders = [_fBooks('f1', ['b', 'c'])];
      final result =
          topLevelVisibleLorebooks(books, folders, activeFolderId: 'f1');
      expect(result.map((b) => b.id).toSet(), equals({'b', 'c'}));
    });

    test('folder open: vanished folder id returns empty', () {
      final books = [_b('a')];
      final folders = [_fBooks('f1', ['a'])];
      final result = topLevelVisibleLorebooks(books, folders,
          activeFolderId: 'ghost');
      expect(result, isEmpty);
    });

    test('search: scans ALL books including filed ones', () {
      final books = [_b('a'), _b('b')];
      final folders = [_fBooks('f1', ['b'])];
      final result = topLevelVisibleLorebooks(books, folders, query: 'b');
      expect(result.any((b) => b.id == 'b'), isTrue);
    });

    test('search: hidden books stay excluded even under search-all', () {
      final books = [_b('a'), _b('h', hidden: true)];
      final result = topLevelVisibleLorebooks(books, [], query: 'book');
      expect(result.any((b) => b.id == 'h'), isFalse);
    });

    test('home: deleted folders do not hide books', () {
      final books = [_b('a')];
      final folders = [_fBooks('f1', ['a'], deleted: true)];
      final result = topLevelVisibleLorebooks(books, folders);
      expect(result.map((b) => b.id).toList(), equals(['a']));
    });
  });

  group('AppStore persona folder membership ops', () {
    test('addPersonaToFolder adds and bumps folder metadata', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('RP crew');
      store.personas.add(_p('p1'));
      final mtimeBefore = f.mtime;

      store.addPersonaToFolder(f.id, 'p1');
      expect(store.folders.first.personaIds, equals(['p1']));
      expect(store.folders.first.mtime, greaterThanOrEqualTo(mtimeBefore),
          reason: 'membership change must stamp sync metadata');
    });

    test('addPersonaToFolder is idempotent (no duplicate ids)', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('RP crew');
      store.addPersonaToFolder(f.id, 'p1');
      store.addPersonaToFolder(f.id, 'p1');
      expect(store.folders.first.personaIds, equals(['p1']));
    });

    test('add/remove with an unknown folder id is a silent no-op', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('RP crew');
      store.addPersonaToFolder('ghost', 'p1');
      store.removePersonaFromFolder('ghost', 'p1');
      expect(store.folders.first.personaIds, isEmpty);
      expect(f.personaIds, isEmpty);
    });

    test('removePersonaFromFolder removes; absent member is a no-op', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('RP crew');
      store.addPersonaToFolder(f.id, 'p1');
      store.removePersonaFromFolder(f.id, 'p2'); // not a member
      expect(store.folders.first.personaIds, equals(['p1']));
      store.removePersonaFromFolder(f.id, 'p1');
      expect(store.folders.first.personaIds, isEmpty);
    });

    test('removePersona cleans folder membership', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('RP crew');
      store.personas.addAll([_p('p1'), _p('p2')]);
      store.addPersonaToFolder(f.id, 'p1');
      store.addPersonaToFolder(f.id, 'p2');

      store.removePersona('p1');
      expect(store.folders.first.personaIds, equals(['p2']),
          reason: 'deleted persona must not linger in folder lists');
    });
  });

  group('AppStore lorebook folder membership ops', () {
    test('addLorebookToFolder adds; re-add dedupes', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('World');
      store.addLorebookToFolder(f.id, 'b1');
      store.addLorebookToFolder(f.id, 'b1');
      expect(store.folders.first.lorebookIds, equals(['b1']));
    });

    test('add/remove with an unknown folder id is a silent no-op', () {
      final store = AppStore(storage: _NoopBackend());
      store.createFolder('World');
      store.addLorebookToFolder('ghost', 'b1');
      store.removeLorebookFromFolder('ghost', 'b1');
      expect(store.folders.first.lorebookIds, isEmpty);
    });

    test('removeLorebookFromFolder removes the membership', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('World');
      store.addLorebookToFolder(f.id, 'b1');
      store.addLorebookToFolder(f.id, 'b2');
      store.removeLorebookFromFolder(f.id, 'b1');
      expect(store.folders.first.lorebookIds, equals(['b2']));
    });

    test('removeLorebook cleans folder membership', () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('World');
      store.lorebooks.addAll([_b('b1'), _b('b2')]);
      store.addLorebookToFolder(f.id, 'b1');
      store.addLorebookToFolder(f.id, 'b2');

      store.removeLorebook('b1');
      expect(store.folders.first.lorebookIds, equals(['b2']),
          reason: 'deleted book must not linger in folder lists');
    });
  });

  group('AppStore segment folder filters', () {
    test('setPersonaFolderId / setLoreFolderId round-trip through null', () {
      final store = AppStore(storage: _NoopBackend());
      expect(store.personaFolderId, isNull);
      expect(store.loreFolderId, isNull);
      store.setPersonaFolderId('f1');
      store.setLoreFolderId('f2');
      expect(store.personaFolderId, 'f1');
      expect(store.loreFolderId, 'f2');
      store.setPersonaFolderId(null);
      store.setLoreFolderId(null);
      expect(store.personaFolderId, isNull);
      expect(store.loreFolderId, isNull);
    });

    test('deleteFolder clears the persona/lorebook filters it was backing',
        () {
      final store = AppStore(storage: _NoopBackend());
      final f = store.createFolder('Campaign');
      final other = store.createFolder('Other');
      store.setPersonaFolderId(f.id);
      store.setLoreFolderId(other.id);

      store.deleteFolder(f.id);
      expect(store.personaFolderId, isNull,
          reason: 'deleted folder must not linger as the active view');
      expect(store.loreFolderId, other.id,
          reason: 'unrelated filter untouched');
    });
  });

  group('Folder JSON — personaIds / lorebookIds', () {
    test('round-trips both new fields', () {
      final f = Folder(
        id: 'f1',
        name: 'Campaign',
        characterIds: ['c1'],
        personaIds: ['p1', 'p2'],
        lorebookIds: ['b1'],
        mtime: 7,
      );
      final restored = Folder.fromJson(f.toJson());
      expect(restored.characterIds, equals(['c1']));
      expect(restored.personaIds, equals(['p1', 'p2']));
      expect(restored.lorebookIds, equals(['b1']));
    });

    test('old JSON without the new fields loads as empty lists', () {
      final restored = Folder.fromJson({
        'id': 'f1',
        'name': 'Legacy',
        'characterIds': ['c1'],
        'createdAt': 1,
        'updatedAt': 1,
        'mtime': 0,
      });
      expect(restored.personaIds, isEmpty);
      expect(restored.lorebookIds, isEmpty);
    });

    test('empty membership lists are omitted from toJson (byte-compat)', () {
      final f = Folder(id: 'f1', name: 'Chars only', characterIds: ['c1']);
      final json = f.toJson();
      expect(json.containsKey('personaIds'), isFalse,
          reason: 'pre-existing folders must stay byte-identical');
      expect(json.containsKey('lorebookIds'), isFalse);
    });
  });
}
