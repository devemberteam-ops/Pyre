// Owner-requested: in-app Duplicate for characters & personas.
//
// duplicateCharacter(id) / duplicatePersona(id) deep-clone the record,
// assign a FRESH id + "<name> (copy)" name, and insert the clone right
// after the original. The avatar / gallery / lorebook refs are COPIED
// (same content-addressed `pyre://attachment/<hash>` strings — no byte
// duplication). The original is left untouched and the count grows by 1.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
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

void main() {
  group('duplicateCharacter', () {
    test('clones with new id, "(copy)" name, copied refs; original intact',
        () async {
      final store = AppStore(storage: _NoopBackend());
      final orig = Character(
        id: 'char-1',
        name: 'Ren',
        description: 'a femboy NEET',
        avatar: 'pyre://attachment/aaaa',
        gallery: const ['pyre://attachment/bbbb', 'pyre://attachment/cccc'],
        lorebookIds: const ['lore-world'],
        tags: const ['isekai'],
        favorite: true,
      );
      store.characters.add(orig);

      final clone = store.duplicateCharacter('char-1');

      expect(clone, isNotNull);
      // New, distinct id.
      expect(clone!.id, isNot('char-1'));
      expect(clone.id.isNotEmpty, isTrue);
      // "(copy)" name.
      expect(clone.name, 'Ren (copy)');
      // Refs are COPIED (same strings — content-addressed, no byte dup).
      expect(clone.avatar, 'pyre://attachment/aaaa');
      expect(clone.gallery, ['pyre://attachment/bbbb', 'pyre://attachment/cccc']);
      expect(clone.lorebookIds, ['lore-world']);
      // Body content carried over.
      expect(clone.description, 'a femboy NEET');
      expect(clone.tags, ['isekai']);

      // List grew by one and clone sits right after the original.
      expect(store.characters.length, 2);
      final idxOrig = store.characters.indexWhere((c) => c.id == 'char-1');
      final idxClone = store.characters.indexWhere((c) => c.id == clone.id);
      expect(idxClone, idxOrig + 1);

      // Original is unchanged.
      expect(orig.id, 'char-1');
      expect(orig.name, 'Ren');
      expect(orig.gallery, ['pyre://attachment/bbbb', 'pyre://attachment/cccc']);

      // Mutating the clone's lists must not bleed back into the original
      // (deep-clone, not a shared list reference).
      clone.gallery.add('pyre://attachment/dddd');
      clone.lorebookIds.add('lore-extra');
      expect(orig.gallery,
          ['pyre://attachment/bbbb', 'pyre://attachment/cccc']);
      expect(orig.lorebookIds, ['lore-world']);

      await store.flushPersist();
    });

    test('returns null for an unknown id, no list change', () async {
      final store = AppStore(storage: _NoopBackend());
      store.characters.add(Character(id: 'x', name: 'X'));
      final before = store.characters.length;
      final clone = store.duplicateCharacter('nope');
      expect(clone, isNull);
      expect(store.characters.length, before);
      await store.flushPersist();
    });
  });

  group('duplicatePersona', () {
    test('clones with new id, "(copy)" name, copied refs; original intact',
        () async {
      final store = AppStore(storage: _NoopBackend());
      final orig = Persona(
        id: 'persona-1',
        name: 'Ren',
        description: 'you are Ren',
        dialogueExamples: '<START>\nRen: hi',
        avatar: 'pyre://attachment/aaaa',
        gallery: const ['pyre://attachment/bbbb'],
        lorebookIds: const ['lore-world'],
        favorite: true,
      );
      store.personas.add(orig);

      final clone = store.duplicatePersona('persona-1');

      expect(clone, isNotNull);
      expect(clone!.id, isNot('persona-1'));
      expect(clone.id.isNotEmpty, isTrue);
      expect(clone.name, 'Ren (copy)');
      expect(clone.avatar, 'pyre://attachment/aaaa');
      expect(clone.gallery, ['pyre://attachment/bbbb']);
      expect(clone.lorebookIds, ['lore-world']);
      expect(clone.description, 'you are Ren');
      expect(clone.dialogueExamples, '<START>\nRen: hi');

      expect(store.personas.length, 2);
      final idxOrig =
          store.personas.indexWhere((p) => p.id == 'persona-1');
      final idxClone = store.personas.indexWhere((p) => p.id == clone.id);
      expect(idxClone, idxOrig + 1);

      // Original untouched + deep-clone (no shared list refs).
      expect(orig.name, 'Ren');
      clone.gallery.add('pyre://attachment/xxxx');
      expect(orig.gallery, ['pyre://attachment/bbbb']);

      await store.flushPersist();
    });

    test('returns null for an unknown id, no list change', () async {
      final store = AppStore(storage: _NoopBackend());
      store.personas.add(Persona(id: 'x', name: 'X'));
      final before = store.personas.length;
      final clone = store.duplicatePersona('nope');
      expect(clone, isNull);
      expect(store.personas.length, before);
      await store.flushPersist();
    });
  });
}
