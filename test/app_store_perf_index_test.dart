// BATCH P1-state — perf root-cause fixes (D, B, E, H).
//
// Covers:
//   (D) characterById / personaById / lorebookById are backed by O(1) Map
//       indexes rebuilt on collection mutation (add/update/delete/load).
//   (B) lastUsedAtByCharacter / chatCountByCharacter memoized maps computed
//       in one O(chats) pass and invalidated on chat add/update/delete.
//   (E) approxTokensForCharacterCached memoizes by character id + contentHash.
//   (H) runBatch coalesces N mutations into ONE persist, and the multi-select
//       tag setter persists once.
//
// Pure in-memory store mutations only (no HTTP / no disk) — the debounced
// `_persist` Timer never fires synchronously in a test, so we count saves
// through a fake StoreBackend that records each `save()` call.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/services/token_estimate.dart';
import 'package:pyre/state/app_store.dart';

/// Counts how many times the blob is written to disk. Each `save()` is one
/// full re-serialise — exactly the cost (H) is trying to coalesce.
class _CountingBackend implements StoreBackend {
  int saveCount = 0;
  Map<String, dynamic>? lastBlob;

  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> blob) async {
    saveCount++;
    lastBlob = blob;
  }

  @override
  Future<void> clear() async {}
}

Character _char(String id, {String name = 'C', String description = ''}) =>
    Character(id: id, name: name, description: description);

Chat _chat(String id, List<String> charIds, {int updatedAt = 0}) {
  final c = Chat(id: id, characterIds: charIds);
  if (updatedAt != 0) c.updatedAt = updatedAt;
  return c;
}

void main() {
  group('(D) lookup indexes — characterById / personaById / lorebookById', () {
    test('characterById resolves after add and stays consistent', () {
      final s = AppStore();
      expect(s.characterById('a'), isNull);
      s.addCharacter(_char('a', name: 'Alpha'));
      s.addCharacter(_char('b', name: 'Beta'));
      expect(s.characterById('a')!.name, 'Alpha');
      expect(s.characterById('b')!.name, 'Beta');
      expect(s.characterById('missing'), isNull);
    });

    test('characterById reflects update in place', () {
      final s = AppStore();
      s.addCharacter(_char('a', name: 'Alpha'));
      s.updateCharacter(_char('a', name: 'Renamed'));
      expect(s.characterById('a')!.name, 'Renamed');
    });

    test('characterById returns null after remove', () {
      final s = AppStore();
      s.addCharacter(_char('a'));
      s.removeCharacter('a');
      expect(s.characterById('a'), isNull);
    });

    test('index rebuilds after the collection is reassigned wholesale '
        '(the load() / restore pattern)', () {
      final s = AppStore();
      s.addCharacter(_char('a', name: 'Alpha'));
      // Force the index to build + cache.
      expect(s.characterById('a')!.name, 'Alpha');
      // load()/factoryReset reassign the list wholesale rather than going
      // through add/remove. Simulate that exact pattern, then invalidate as
      // those paths do, and confirm the stale index is gone.
      s.characters = [_char('b', name: 'Beta'), _char('c', name: 'Gamma')];
      s.debugInvalidatePerfCachesForTest();
      expect(s.characterById('a'), isNull);
      expect(s.characterById('b')!.name, 'Beta');
      expect(s.characterById('c')!.name, 'Gamma');
    });

    test('personaById resolves O(1) and tracks add/remove', () {
      final s = AppStore();
      expect(s.personaById('p'), isNull);
      s.addPersona(Persona(id: 'p', name: 'Ren'));
      expect(s.personaById('p')!.name, 'Ren');
      s.removePersona('p');
      expect(s.personaById('p'), isNull);
    });

    test('lorebookById resolves O(1) and tracks add/update/remove', () {
      final s = AppStore();
      expect(s.lorebookById('l'), isNull);
      s.addLorebook(Lorebook(id: 'l', name: 'World'));
      expect(s.lorebookById('l')!.name, 'World');
      s.updateLorebook(Lorebook(id: 'l', name: 'World v2'));
      expect(s.lorebookById('l')!.name, 'World v2');
      s.removeLorebook('l');
      expect(s.lorebookById('l'), isNull);
    });
  });

  group('(B) memoized sort maps — lastUsedAtByCharacter / chatCountByCharacter',
      () {
    test('single O(chats) pass yields correct per-character values', () {
      final s = AppStore();
      s.addCharacter(_char('a'));
      s.addCharacter(_char('b'));
      s.addImportedChat(_chat('c1', ['a'], updatedAt: 100));
      s.addImportedChat(_chat('c2', ['a', 'b'], updatedAt: 200));
      s.addImportedChat(_chat('c3', ['b'], updatedAt: 150));

      expect(s.chatCountByCharacter['a'], 2);
      expect(s.chatCountByCharacter['b'], 2);
      expect(s.lastUsedAtByCharacter['a'], 200);
      expect(s.lastUsedAtByCharacter['b'], 200);
    });

    test('characters with no chats are absent (treated as 0 by callers)', () {
      final s = AppStore();
      s.addCharacter(_char('a'));
      expect(s.chatCountByCharacter['a'], isNull);
      expect(s.lastUsedAtByCharacter['a'], isNull);
    });

    test('maps invalidate on chat add', () {
      final s = AppStore();
      s.addCharacter(_char('a'));
      expect(s.chatCountByCharacter['a'], isNull);
      s.addImportedChat(_chat('c1', ['a'], updatedAt: 100));
      expect(s.chatCountByCharacter['a'], 1);
      expect(s.lastUsedAtByCharacter['a'], 100);
    });

    test('maps invalidate on message add (chat updatedAt bumped)', () {
      final s = AppStore();
      s.addCharacter(_char('a'));
      final chat = s.addImportedChat(_chat('c1', ['a'], updatedAt: 100));
      final before = s.lastUsedAtByCharacter['a'];
      s.addMessage(chat.id, Message(id: 'm1', kind: MessageKind.user));
      final after = s.lastUsedAtByCharacter['a'];
      expect(after, greaterThan(before!));
    });

    test('maps invalidate on chat remove', () {
      final s = AppStore();
      s.addCharacter(_char('a'));
      s.addImportedChat(_chat('c1', ['a'], updatedAt: 100));
      expect(s.chatCountByCharacter['a'], 1);
      s.removeChat('c1');
      expect(s.chatCountByCharacter['a'], isNull);
    });

    test('repeated reads return the same cached map instance', () {
      final s = AppStore();
      s.addCharacter(_char('a'));
      s.addImportedChat(_chat('c1', ['a'], updatedAt: 100));
      final first = s.chatCountByCharacter;
      final second = s.chatCountByCharacter;
      expect(identical(first, second), isTrue);
    });
  });

  group('(E) memoized per-character token estimate', () {
    test('cached value equals the direct computation', () {
      final s = AppStore();
      final c = _char('a', description: 'hello world this is a description');
      s.addCharacter(c);
      expect(s.approxTokensForCharacterCached(c),
          approxTokensForCharacter(c));
    });

    test('cache returns the same value on repeated calls', () {
      final s = AppStore();
      final c = _char('a', description: 'abcd' * 100);
      s.addCharacter(c);
      final first = s.approxTokensForCharacterCached(c);
      final second = s.approxTokensForCharacterCached(c);
      expect(first, second);
    });

    test('cache re-computes when the content hash changes', () {
      final s = AppStore();
      final c1 = _char('a', description: 'short');
      s.addCharacter(c1);
      final small = s.approxTokensForCharacterCached(c1);
      // Same id, much larger content → new contentHash → recompute.
      final c2 = _char('a', description: 'x' * 4000);
      final big = s.approxTokensForCharacterCached(c2);
      expect(big, greaterThan(small));
      expect(big, approxTokensForCharacter(c2));
    });
  });

  group('(H) batched / coalesced persistence', () {
    test('runBatch persists exactly once for N mutations', () async {
      final backend = _CountingBackend();
      final s = AppStore(storage: backend);
      s.runBatch(() {
        s.addCharacter(_char('a'));
        s.addCharacter(_char('b'));
        s.addCharacter(_char('c'));
      });
      // The batch coalesces to a single notify; flush forces the one save.
      await s.flushPersist();
      expect(s.characters.length, 3);
      expect(backend.saveCount, 1);
    });

    test('setCharSelectedTags applies a multi-select set in ONE persist',
        () async {
      final backend = _CountingBackend();
      final s = AppStore(storage: backend);
      s.setCharSelectedTags({'fantasy', 'adult', 'isekai'});
      await s.flushPersist();
      expect(s.charSelectedTags.toSet(), {'fantasy', 'adult', 'isekai'});
      expect(backend.saveCount, 1);
    });

    test('runBatch still fires a single notifyListeners', () {
      final s = AppStore();
      var notifies = 0;
      s.addListener(() => notifies++);
      s.runBatch(() {
        s.addCharacter(_char('a'));
        s.addCharacter(_char('b'));
      });
      expect(notifies, 1);
    });
  });
}
