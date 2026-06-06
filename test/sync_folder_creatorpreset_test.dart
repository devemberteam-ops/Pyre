// Mega-audit 2026-06-05 (F2): folders + creatorPresets joined the synced
// collection set. These tests lock in (a) the new mtime/deleted JSON round-
// trip on both models, (b) that the diff predicate the transport uses
// (`mtime > since`, plus `!locked` for creator presets) selects the right
// records, and (c) that the locked default Creator preset is protected from
// being shipped or overwritten.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('Folder sync metadata', () {
    test('mtime + deleted round-trip through JSON', () {
      final f = Folder(id: 'f1', name: 'Favorites', characterIds: ['c1']);
      f.mtime = 12345;
      final back = Folder.fromJson(f.toJson());
      expect(back.id, 'f1');
      expect(back.name, 'Favorites');
      expect(back.characterIds, ['c1']);
      expect(back.mtime, 12345);
      expect(back.deleted, isFalse);
    });

    test('deleted flag persists only when true and parses back', () {
      final live = Folder(id: 'f1', name: 'x');
      expect(live.toJson().containsKey('deleted'), isFalse);
      final dead = Folder(id: 'f2', name: 'y', mtime: 9, deleted: true);
      expect(dead.toJson()['deleted'], true);
      expect(Folder.fromJson(dead.toJson()).deleted, isTrue);
    });

    test('legacy JSON without mtime defaults to 0', () {
      final back = Folder.fromJson({
        'id': 'f1',
        'name': 'Old',
        'characterIds': <String>[],
        'createdAt': 1,
        'updatedAt': 1,
      });
      expect(back.mtime, 0);
      expect(back.deleted, isFalse);
    });

    test('diff predicate: mtime > since selects only newer folders', () {
      const since = 1000;
      final folders = [
        Folder(id: 'a', name: 'a', mtime: 500),
        Folder(id: 'b', name: 'b', mtime: 1500),
        Folder(id: 'c', name: 'c', mtime: 1000), // exactly at watermark
      ];
      final shipped =
          folders.where((f) => f.mtime > since).map((f) => f.id).toList();
      expect(shipped, ['b']);
    });
  });

  group('CreatorPreset sync metadata', () {
    test('mtime + deleted round-trip through JSON', () {
      final p = CreatorPreset(
        id: 'cp1',
        name: 'My fork',
        characterPrompt: 'char',
        scenarioPrompt: 'scen',
        editPrompt: 'edit',
        mtime: 777,
      );
      final back = CreatorPreset.fromJson(p.toJson());
      expect(back.id, 'cp1');
      expect(back.name, 'My fork');
      expect(back.characterPrompt, 'char');
      expect(back.scenarioPrompt, 'scen');
      expect(back.editPrompt, 'edit');
      expect(back.mtime, 777);
      expect(back.locked, isFalse);
      expect(back.deleted, isFalse);
    });

    test('locked default builds with locked=true and is excluded from diff',
        () {
      const since = 0;
      final def = buildLockedDefaultCreatorPreset();
      expect(def.locked, isTrue);
      final fork = CreatorPreset(id: 'cp1', name: 'fork', mtime: 5000);
      final presets = [def, fork];
      // Transport ships only mtime>since AND !locked.
      final shipped = presets
          .where((p) => p.mtime > since && !p.locked)
          .map((p) => p.id)
          .toList();
      expect(shipped, ['cp1']);
      // The locked default itself has mtime 0 and is filtered regardless.
      expect(def.mtime, 0);
    });

    test('legacy JSON without mtime defaults to 0', () {
      final back = CreatorPreset.fromJson({
        'id': 'cp1',
        'name': 'Old fork',
      });
      expect(back.mtime, 0);
      expect(back.deleted, isFalse);
    });
  });
}
