// SYNC W6 (verification): unit tests for the PURE sync-manifest helper.
//
// The manifest is what lets the user CONFIRM both paired devices hold the same
// library (counts + a stable digest per collection). The two properties that
// MUST hold for the comparison to be trustworthy:
//   1. The digest is ORDER-INDEPENDENT — the phone + PC hold the same records
//      in different in-memory order, so the same logical contents must hash
//      identically. (Tested via collectionDigest + buildManifestFromRefs.)
//   2. diffManifests correctly reports in-sync vs differing, including count
//      mismatches, content drift at equal count, and a collection present on
//      only one side; and allInSync is the AND of every row.
//
// A thin AppStore-adapter test (buildSyncManifest) locks in the exclusions
// (locked presets/creatorPresets dropped) + the settings singleton.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/services/sync_manifest.dart';
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

SyncRecordDigestInput _r(String id, int mtime) =>
    SyncRecordDigestInput(id, mtime);

void main() {
  group('collectionDigest — stability', () {
    test('order-independent: same records, different order → same digest', () {
      final a = collectionDigest([_r('c', 30), _r('a', 10), _r('b', 20)]);
      final b = collectionDigest([_r('a', 10), _r('b', 20), _r('c', 30)]);
      final c = collectionDigest([_r('b', 20), _r('c', 30), _r('a', 10)]);
      expect(a, b);
      expect(b, c);
    });

    test('empty collection has a fixed, non-empty digest', () {
      final d1 = collectionDigest(const []);
      final d2 = collectionDigest(const []);
      expect(d1, d2);
      expect(d1, isNotEmpty);
    });

    test('a changed mtime changes the digest (version-sensitive)', () {
      final before = collectionDigest([_r('a', 10), _r('b', 20)]);
      final after = collectionDigest([_r('a', 10), _r('b', 21)]);
      expect(before, isNot(after));
    });

    test('an added/removed record changes the digest (membership-sensitive)',
        () {
      final two = collectionDigest([_r('a', 10), _r('b', 20)]);
      final three = collectionDigest([_r('a', 10), _r('b', 20), _r('c', 30)]);
      expect(two, isNot(three));
    });

    test('digest is NOT fooled by id/mtime field-swap collisions', () {
      // "1:23" vs "12:3" must not collide — the '\n'-joined, ':'-paired
      // encoding keeps them distinct.
      final x = collectionDigest([_r('1', 23)]);
      final y = collectionDigest([_r('12', 3)]);
      expect(x, isNot(y));
    });
  });

  group('buildManifestFromRefs', () {
    test('counts + digests per collection; same contents different order match',
        () {
      final m1 = buildManifestFromRefs({
        'characters': [_r('a', 1), _r('b', 2)],
        'chats': [_r('x', 9)],
      });
      final m2 = buildManifestFromRefs({
        // characters in REVERSE order — must still match m1.
        'characters': [_r('b', 2), _r('a', 1)],
        'chats': [_r('x', 9)],
      });
      expect(m1['characters']!.count, 2);
      expect(m1['chats']!.count, 1);
      expect(m1['characters']!.digest, m2['characters']!.digest);
      expect(m1['chats']!.digest, m2['chats']!.digest);
    });

    test('settingsMtime emits a settings stat (count 1); null omits it', () {
      final withSettings =
          buildManifestFromRefs({'characters': []}, settingsMtime: 1234);
      expect(withSettings.containsKey('settings'), isTrue);
      expect(withSettings['settings']!.count, 1);

      final without = buildManifestFromRefs({'characters': []});
      expect(without.containsKey('settings'), isFalse);

      // Different settings mtime → different digest.
      final other =
          buildManifestFromRefs({'characters': []}, settingsMtime: 9999);
      expect(withSettings['settings']!.digest,
          isNot(other['settings']!.digest));
    });
  });

  group('diffManifests', () {
    test('identical manifests → allInSync, no differing', () {
      final m = buildManifestFromRefs({
        'characters': [_r('a', 1), _r('b', 2)],
        'presets': [_r('p', 5)],
      }, settingsMtime: 100);
      final diff = diffManifests(m, m);
      expect(diff.allInSync, isTrue);
      expect(diff.differing, isEmpty);
      // Counts carry through on the matched rows.
      final chars = diff.collections.firstWhere((c) => c.name == 'characters');
      expect(chars.localCount, 2);
      expect(chars.remoteCount, 2);
      expect(chars.inSync, isTrue);
    });

    test('count mismatch → that collection differs, allInSync false', () {
      final local = buildManifestFromRefs({
        'characters': [_r('a', 1), _r('b', 2)], // 2 here
      });
      final remote = buildManifestFromRefs({
        'characters': [_r('a', 1)], // 1 on PC
      });
      final diff = diffManifests(local, remote);
      expect(diff.allInSync, isFalse);
      final row = diff.collections.firstWhere((c) => c.name == 'characters');
      expect(row.localCount, 2);
      expect(row.remoteCount, 1);
      expect(row.inSync, isFalse);
    });

    test('SAME count but different contents → differs (digest catches drift)',
        () {
      // Both have 2 records, but one mtime differs → digests differ even though
      // the counts are equal. This is the case a naive count-only check misses.
      final local = buildManifestFromRefs({
        'characters': [_r('a', 1), _r('b', 2)],
      });
      final remote = buildManifestFromRefs({
        'characters': [_r('a', 1), _r('b', 99)], // b edited on the PC
      });
      final diff = diffManifests(local, remote);
      expect(diff.allInSync, isFalse);
      final row = diff.collections.firstWhere((c) => c.name == 'characters');
      expect(row.localCount, 2);
      expect(row.remoteCount, 2);
      expect(row.inSync, isFalse);
    });

    test('collection present on only one side → differs', () {
      final local = buildManifestFromRefs({
        'characters': [_r('a', 1)],
        'lorebooks': [_r('l', 7)], // PC doesn't know this collection
      });
      final remote = buildManifestFromRefs({
        'characters': [_r('a', 1)],
      });
      final diff = diffManifests(local, remote);
      expect(diff.allInSync, isFalse);
      final lore = diff.collections.firstWhere((c) => c.name == 'lorebooks');
      expect(lore.localCount, 1);
      expect(lore.remoteCount, 0);
      expect(lore.inSync, isFalse);
      // characters still matched.
      expect(diff.collections.firstWhere((c) => c.name == 'characters').inSync,
          isTrue);
    });

    test('two EMPTY collections on both sides match (real empty digest)', () {
      final m = buildManifestFromRefs({'characters': []});
      final diff = diffManifests(m, m);
      expect(diff.allInSync, isTrue);
      expect(diff.collections.single.inSync, isTrue);
    });

    test('parseRemoteManifest round-trips a server-shaped body', () {
      final local = buildManifestFromRefs({
        'characters': [_r('a', 1), _r('b', 2)],
      }, settingsMtime: 50);
      // Simulate the server JSON: {collections: {name: {count, digest}}}.
      final body = {
        'collections': {
          for (final e in local.entries) e.key: e.value.toJson(),
        },
      };
      final remote = parseRemoteManifest(body);
      final diff = diffManifests(local, remote);
      expect(diff.allInSync, isTrue);
    });

    test('parseRemoteManifest tolerates a garbled body → everything differs',
        () {
      final local = buildManifestFromRefs({
        'characters': [_r('a', 1)],
      });
      final remote = parseRemoteManifest({'collections': 'not a map'});
      expect(remote, isEmpty);
      final diff = diffManifests(local, remote);
      expect(diff.allInSync, isFalse);
    });
  });

  group('buildSyncManifest(AppStore) — adapter', () {
    test('excludes locked presets/creatorPresets; includes settings + counts',
        () {
      final store = AppStore(storage: _NoopBackend());
      store.characters.add(Character(id: 'c1', name: 'Ren', mtime: 10));
      store.characters.add(Character(id: 'c2', name: 'Vesna', mtime: 20));
      // One locked default + one user preset — only the user one is synced.
      store.presets.add(Preset(id: 'locked', name: 'Default', locked: true));
      store.presets.add(Preset(id: 'mine', name: 'My preset', mtime: 5));
      store.creatorPresets
          .add(CreatorPreset(id: 'cp-locked', name: 'Default', locked: true));
      store.creatorPresets
          .add(CreatorPreset(id: 'cp-mine', name: 'Forked', mtime: 7));
      store.settingsMtime = 999;

      final m = buildSyncManifest(store);
      expect(m['characters']!.count, 2);
      // Locked excluded → only the user preset counts.
      expect(m['presets']!.count, 1);
      expect(m['creatorPresets']!.count, 1);
      // Settings singleton present.
      expect(m['settings']!.count, 1);
      // Empty-but-present collections still appear (count 0).
      expect(m['personas']!.count, 0);
      expect(m['providers']!.count, 0);
    });

    test('two stores with identical synced contents produce an all-in-sync diff',
        () {
      AppStore make() {
        final s = AppStore(storage: _NoopBackend());
        s.characters.add(Character(id: 'c1', name: 'Ren', mtime: 10));
        s.characters.add(Character(id: 'c2', name: 'Vesna', mtime: 20));
        s.settingsMtime = 42;
        return s;
      }

      final a = make();
      final b = make();
      // Reverse one store's in-memory order — digests must still match.
      b.characters.setAll(0, b.characters.reversed.toList());

      final diff = diffManifests(buildSyncManifest(a), buildSyncManifest(b));
      expect(diff.allInSync, isTrue);
    });

    test('an edit on one store surfaces as a characters mismatch', () {
      AppStore make() {
        final s = AppStore(storage: _NoopBackend());
        s.characters.add(Character(id: 'c1', name: 'Ren', mtime: 10));
        return s;
      }

      final a = make();
      final b = make();
      b.characters.first.mtime = 11; // edited on b

      final diff = diffManifests(buildSyncManifest(a), buildSyncManifest(b));
      expect(diff.allInSync, isFalse);
      expect(
          diff.collections.firstWhere((c) => c.name == 'characters').inSync,
          isFalse);
    });
  });
}
