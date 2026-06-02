// Wave CY.18.256: deletion-propagation tombstone log.
//
// Hard deletes (removeCharacter/removePersona/removeChat/removeLorebook/
// removePreset) leave no per-record trace, so a paired peer that still holds
// the record re-pushes it and the deletion would resurrect on the next pull.
// The SEPARATE synced tombstone log fixes that: each delete records a
// `'<kind>:<id>' -> mtime` entry; the sync apply path consults
// `isTombstonedNewer` to suppress a peer's stale live copy.
//
// These tests lock in the pure helper's true/false decision, that each delete
// method records a tombstone under the right key, and the apply-skip decision
// expressed as a pure check (no HTTP / no mocking).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/state/app_store.dart';

void main() {
  group('isTombstonedNewer', () {
    test('false when no tombstone exists for the key', () {
      final s = AppStore();
      expect(s.isTombstonedNewer('character', 'c1', 1000), isFalse);
    });

    test('true when tombstone mtime > record mtime', () {
      final s = AppStore();
      s.tombstones['character:c1'] = 2000;
      expect(s.isTombstonedNewer('character', 'c1', 1000), isTrue);
    });

    test('true when tombstone mtime == record mtime (>= compare)', () {
      final s = AppStore();
      s.tombstones['character:c1'] = 1000;
      expect(s.isTombstonedNewer('character', 'c1', 1000), isTrue);
    });

    test('false when tombstone mtime < record mtime (record is newer)', () {
      final s = AppStore();
      s.tombstones['character:c1'] = 500;
      expect(s.isTombstonedNewer('character', 'c1', 1000), isFalse);
    });

    test('keyed by kind AND id — a different kind/id never matches', () {
      final s = AppStore();
      s.tombstones['character:c1'] = 2000;
      // Same id, different kind.
      expect(s.isTombstonedNewer('persona', 'c1', 1000), isFalse);
      // Same kind, different id.
      expect(s.isTombstonedNewer('character', 'c2', 1000), isFalse);
    });
  });

  group('recordTombstone via delete methods', () {
    test('removeCharacter records a tombstone under "character:<id>"', () {
      final s = AppStore();
      s.characters.add(Character(id: 'c1', name: 'C'));
      s.removeCharacter('c1');
      expect(s.tombstones.containsKey('character:c1'), isTrue);
      expect(s.tombstones['character:c1']! > 0, isTrue);
      // The live record is hard-removed (no soft-delete ghost).
      expect(s.characters.any((c) => c.id == 'c1'), isFalse);
    });

    test('removePersona records a tombstone under "persona:<id>"', () {
      final s = AppStore();
      s.personas.add(Persona(id: 'p1', name: 'You'));
      s.removePersona('p1');
      expect(s.tombstones.containsKey('persona:p1'), isTrue);
      expect(s.personas.any((p) => p.id == 'p1'), isFalse);
    });

    test('removeChat records a tombstone under "chat:<id>"', () {
      final s = AppStore();
      s.chats.add(Chat(id: 'ch1', characterIds: const ['c1']));
      s.removeChat('ch1');
      expect(s.tombstones.containsKey('chat:ch1'), isTrue);
      expect(s.chats.any((c) => c.id == 'ch1'), isFalse);
    });

    test('removeLorebook records a tombstone under "lorebook:<id>"', () {
      final s = AppStore();
      s.lorebooks.add(Lorebook(id: 'l1', name: 'Lore'));
      s.removeLorebook('l1');
      expect(s.tombstones.containsKey('lorebook:l1'), isTrue);
      expect(s.lorebooks.any((l) => l.id == 'l1'), isFalse);
    });

    test('removePreset records a tombstone under "preset:<id>"', () {
      final s = AppStore();
      s.presets.add(Preset(id: 'pr1', name: 'Preset'));
      s.removePreset('pr1');
      expect(s.tombstones.containsKey('preset:pr1'), isTrue);
      expect(s.presets.any((p) => p.id == 'pr1'), isFalse);
    });

    test('removePreset on a locked preset is a no-op (no tombstone)', () {
      final s = AppStore();
      s.presets.add(Preset(id: 'locked', name: 'Locked', locked: true));
      s.removePreset('locked');
      expect(s.tombstones.containsKey('preset:locked'), isFalse);
      // Locked preset stays.
      expect(s.presets.any((p) => p.id == 'locked'), isTrue);
    });
  });

  group('apply-skip decision (pure)', () {
    test('a tombstone we recorded suppresses a peer\'s still-live copy', () {
      final s = AppStore();
      s.characters.add(Character(id: 'c1', name: 'C', mtime: 1000));
      // We delete locally — records a tombstone at "now" (>> 1000).
      s.removeCharacter('c1');
      // A peer pushes its still-live copy at the SAME (or older) version.
      const incomingMtime = 1000;
      // The sync apply path would skip the record because our tombstone is
      // newer-or-equal — this is exactly the check `applyChars` makes before
      // re-inserting an incoming record.
      expect(s.isTombstonedNewer('character', 'c1', incomingMtime), isTrue);
    });

    test('a record edited AFTER our delete still applies (edit wins)', () {
      final s = AppStore();
      // Tombstone recorded at t=1000.
      s.tombstones['character:c1'] = 1000;
      // A peer's copy was edited at t=2000 (later than our delete) — the edit
      // is genuinely newer, so it must NOT be suppressed (LWW resurrection of
      // an intentionally re-created/edited record is correct).
      expect(s.isTombstonedNewer('character', 'c1', 2000), isFalse);
    });
  });
}
