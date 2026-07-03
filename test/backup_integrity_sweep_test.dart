// Restore reference-integrity sweep (Waves CY.18.42/43, extracted to the
// top-level [pruneDanglingBackupRefs] so it is unit-testable).
//
// 2026-07-03 additions under test:
//  - I-3: `chat.personaIds` (persona-party roster) was invisible to the
//    sweep — a restored backup could carry a roster pointing at personas
//    that didn't survive the restore. Prune mirrors setChatPersonaParty's
//    collapse rule: >1 live → party stays (personaId = first live), exactly
//    1 → collapse to single-persona, 0 → defer to the singular rule.
//  - Sentinel guard: `chat.personaId == kExplicitNoPersonaId` ("explicitly
//    no persona") never resolves to a real persona, so the old rule nulled
//    it on EVERY restore — silently flipping "no persona" into "inherit the
//    global active persona".

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/backup_restore_screen.dart'
    show pruneDanglingBackupRefs;
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

AppStore _store({List<String> personaIds = const []}) {
  final store = AppStore(storage: _NoopBackend());
  for (final id in personaIds) {
    store.personas.add(Persona(
        id: id, name: id, description: 'x', createdAt: 0, updatedAt: 0));
  }
  return store;
}

// NOTE: growable lists on purpose — the sweep prunes in place, and real
// restored chats come from JSON with growable lists.
Chat _chat({String? personaId, List<String> personaIds = const []}) =>
    Chat(id: 'c1', characterIds: ['ch'], personaId: personaId,
        personaIds: [...personaIds]);

void main() {
  group('personaIds roster prune (I-3)', () {
    test('one dangling member drops out, party of 2+ survives', () {
      final s = _store(personaIds: ['a', 'b']);
      final chat = _chat(personaId: 'a', personaIds: ['a', 'gone', 'b']);
      s.chats.add(chat);
      pruneDanglingBackupRefs(s);
      expect(chat.personaIds, ['a', 'b']);
      expect(chat.personaId, 'a');
      expect(chat.isPersonaParty, isTrue);
    });

    test('primary was the dangling one → re-anchors to first survivor', () {
      final s = _store(personaIds: ['a', 'b']);
      final chat = _chat(personaId: 'gone', personaIds: ['gone', 'a', 'b']);
      s.chats.add(chat);
      pruneDanglingBackupRefs(s);
      expect(chat.personaIds, ['a', 'b']);
      expect(chat.personaId, 'a');
    });

    test('exactly one survivor → collapses to single-persona chat', () {
      final s = _store(personaIds: ['a']);
      final chat = _chat(personaId: 'a', personaIds: ['a', 'gone']);
      s.chats.add(chat);
      pruneDanglingBackupRefs(s);
      expect(chat.personaIds, isEmpty);
      expect(chat.personaId, 'a');
      expect(chat.isPersonaParty, isFalse);
    });

    test('whole roster dangling → no roster, singular rule nulls personaId',
        () {
      final s = _store();
      final chat = _chat(personaId: 'gone', personaIds: ['gone', 'gone2']);
      s.chats.add(chat);
      pruneDanglingBackupRefs(s);
      expect(chat.personaIds, isEmpty);
      expect(chat.personaId, isNull,
          reason: 'falls back to "inherit global persona" like the classic '
              'dangling-personaId rule');
    });
  });

  group('explicit-no-persona sentinel guard', () {
    test('the sentinel survives the sweep (it never resolves by design)', () {
      final s = _store(personaIds: ['a']);
      final chat = _chat(personaId: kExplicitNoPersonaId);
      s.chats.add(chat);
      pruneDanglingBackupRefs(s);
      expect(chat.personaId, kExplicitNoPersonaId,
          reason: 'nulling it silently flips "no persona" into "inherit the '
              'global active persona" on every restore');
    });
  });

  group('classic singular rules still hold (extraction regression)', () {
    test('dangling personaId → null, valid personaId → kept', () {
      final s = _store(personaIds: ['a']);
      final dangling = _chat(personaId: 'gone');
      final valid = Chat(id: 'c2', characterIds: ['ch'], personaId: 'a');
      s.chats.addAll([dangling, valid]);
      pruneDanglingBackupRefs(s);
      expect(dangling.personaId, isNull);
      expect(valid.personaId, 'a');
    });

    test('dangling presetId → null', () {
      final s = _store();
      final chat = _chat();
      chat.presetId = 'no-such-preset';
      s.chats.add(chat);
      pruneDanglingBackupRefs(s);
      expect(chat.presetId, isNull);
    });
  });
}
