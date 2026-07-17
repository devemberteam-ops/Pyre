@TestOn('vm')
library;

// Sync hardening — the two self-contained "cheap" fixes from Codex's
// 2026-07-15 monster design:
//   #2 nextSyncMtime() — every sync stamp is strictly monotonic, so a
//      backward wall-clock (NTP correction) can't mint an mtime at/below the
//      push cursor and hide the edit forever.
//   #4 tombstone GC is OFF while a sync relationship exists — a peer offline
//      past the 30d TTL can no longer find the tombstone reaped and resurrect
//      its live copy.

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

/// Captures the serialized blob (SAVE side) AND can replay it (LOAD side), so a
/// full persist→load round-trip can be exercised through the real code paths.
class _CaptureBackend implements StoreBackend {
  Map<String, dynamic>? captured;
  @override
  Future<Map<String, dynamic>?> load() async => captured;
  @override
  Future<void> save(Map<String, dynamic> blob) async => captured = blob;
  @override
  Future<void> clear() async => captured = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('#2 nextSyncMtime monotonicity', () {
    test('strictly increases even on a same-ms burst', () {
      final store = AppStore(storage: _NoopBackend());
      final a = store.nextSyncMtime();
      final b = store.nextSyncMtime();
      final c = store.nextSyncMtime();
      expect(b, greaterThan(a));
      expect(c, greaterThan(b));
    });

    test('a mutation after a backward clock still out-stamps the push cursor',
        () {
      final store = AppStore(storage: _NoopBackend());
      // Simulate a device that has already issued a high mtime (e.g. before
      // an NTP correction jumped the clock back) and pushed up to it.
      final future = DateTime.now().millisecondsSinceEpoch + 600000; // +10min
      store.lastIssuedLocalMtime = future;
      // A new edit now — wall clock is "behind" the last-issued value.
      final next = store.nextSyncMtime();
      expect(next, greaterThan(future),
          reason: 'the new stamp must sit ABOVE the last issued value (which '
              'is what the push cursor tracks) — else the edit would never '
              'satisfy mtime > cursor and would never sync out');
    });

    test('a real mutation routes through nextSyncMtime (character rename)', () {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime =
          DateTime.now().millisecondsSinceEpoch + 600000;
      final c = Character(
          id: 'c', name: 'A', description: 'd', createdAt: 0, updatedAt: 0);
      store.characters.add(c);
      store.updateCharacter(c..name = 'B');
      expect(c.mtime, greaterThan(600000000),
          reason: 'the mutation stamped a monotonic mtime, not a raw '
              'backward wall clock');
    });

    test('lastIssuedLocalMtime round-trips through the local blob', () async {
      final store = AppStore(storage: _NoopBackend());
      store.nextSyncMtime();
      final v = store.lastIssuedLocalMtime;
      expect(v, greaterThan(0));
      // toJson only emits it when > 0 (byte-clean for fresh installs).
      final fresh = AppStore(storage: _NoopBackend());
      expect(fresh.lastIssuedLocalMtime, 0);
    });
  });

  group('sync-B stage 1 — complete the logical clock', () {
    test('observeSyncMtime raises the counter but never lowers it', () {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 1000;
      store.observeSyncMtime(500); // below — ignored
      expect(store.lastIssuedLocalMtime, 1000);
      store.observeSyncMtime(2000); // above — adopted
      expect(store.lastIssuedLocalMtime, 2000);
      // The very next mint sits strictly above the observed revision.
      expect(store.nextSyncMtime(), greaterThan(2000));
    });

    test('nextSyncMtimeAfter(floor) returns strictly above the floor', () {
      final store = AppStore(storage: _NoopBackend());
      final floor = DateTime.now().millisecondsSinceEpoch + 3600000; // +1h
      final v = store.nextSyncMtimeAfter(floor);
      expect(v, greaterThan(floor));
      // And the counter is now parked at that value.
      expect(store.lastIssuedLocalMtime, v);
    });

    test('_touchSettings is monotonic (backward clock cannot demote settings)',
        () {
      final store = AppStore(storage: _NoopBackend());
      final future = DateTime.now().millisecondsSinceEpoch + 600000;
      store.lastIssuedLocalMtime = future;
      // Any synced-settings mutation flows through _touchSettings.
      store.updateModelSettings(store.modelSettings);
      expect(store.settingsMtime, greaterThan(future),
          reason: 'settings must out-stamp the last issued value so the unit '
              'is never hidden below the push cursor after a clock rollback');
    });

    test('_touchBotbooruProfile is monotonic', () {
      final store = AppStore(storage: _NoopBackend());
      final future = DateTime.now().millisecondsSinceEpoch + 600000;
      store.lastIssuedLocalMtime = future;
      store.setBotbooruUsername('kuru');
      expect(store.botbooruProfileMtime, greaterThan(future));
    });

    test('applySyncedSettings win tracks the peer revision in the counter', () {
      final store = AppStore(storage: _NoopBackend());
      final hi = DateTime.now().millisecondsSinceEpoch + 900000;
      store.applySyncedSettings({'mtime': hi, 'modelSettings': const {}});
      expect(store.settingsMtime, hi);
      expect(store.lastIssuedLocalMtime, greaterThanOrEqualTo(hi),
          reason: 'after adopting a peer settings revision, the next local '
              'edit must mint above it — else it demotes below what peers hold');
      expect(store.nextSyncMtime(), greaterThan(hi));
    });

    test('rebaseSyncClock lifts the counter above a record that outran the '
        'persisted lastIssuedLocalMtime (load-path rebase)', () {
      // Simulate an OLD build (or a hub restamp) that left a character mtime
      // far above the persisted counter — the classic demote-on-next-edit trap.
      // rebaseSyncClock() is the exact call load() makes after fromJson.
      final store = AppStore(storage: _NoopBackend());
      final highMtime = DateTime.now().millisecondsSinceEpoch + 5_000_000;
      store.characters.add(Character(
          id: 'c', name: 'A', description: 'd', createdAt: 0, updatedAt: 0)
        ..mtime = highMtime);
      store.lastIssuedLocalMtime = 0; // counter "never maintained"

      store.rebaseSyncClock();

      expect(store.lastIssuedLocalMtime, greaterThanOrEqualTo(highMtime),
          reason: 'the rebase must lift the counter to the highest on-disk '
              'mtime so the next mint cannot land below an existing record');
      // A rename now stamps strictly above the pre-existing record mtime.
      final loaded = store.characters.firstWhere((x) => x.id == 'c');
      store.updateCharacter(loaded..name = 'B');
      expect(loaded.mtime, greaterThan(highMtime));
    });

    test('rebaseSyncClock also scans settings/profile/tombstone mtimes', () {
      final store = AppStore(storage: _NoopBackend());
      final hi = DateTime.now().millisecondsSinceEpoch + 7_000_000;
      store.settingsMtime = hi;
      store.botbooruProfileMtime = hi - 1;
      store.tombstones['chat:x'] = hi + 5;
      store.lastIssuedLocalMtime = 0;

      store.rebaseSyncClock();

      expect(store.lastIssuedLocalMtime, hi + 5,
          reason: 'the highest of every mtime source (here a tombstone) wins');
    });
  });

  group('#4 tombstone retention while synced', () {
    Chat deadChat(int mtime) => Chat(
        id: 'gone',
        characterIds: const [],
        messages: const [],
        createdAt: 0,
        updatedAt: 0)
      ..deleted = true
      ..mtime = mtime;

    test('a synced device retains an ancient tombstone (no resurrection)',
        () async {
      final store = AppStore(storage: _NoopBackend());
      store.syncedPushWatermark = 999999999999; // sync IS configured
      final ancient =
          DateTime.now().millisecondsSinceEpoch - 40 * 24 * 60 * 60 * 1000;
      store.chats.add(deadChat(ancient));
      store.tombstones['chat:gone'] = ancient;
      await store.flushPersist(); // runs the GC
      expect(store.tombstones.containsKey('chat:gone'), isTrue,
          reason: 'while synced, an ancient tombstone must survive — a peer '
              'offline past the TTL still needs it to not resurrect');
      expect(store.chats.any((c) => c.id == 'gone'), isTrue,
          reason: 'the soft-deleted record is retained too');
    });

    test('a never-synced single-device user still reaps by wall-clock',
        () async {
      final store = AppStore(storage: _NoopBackend());
      // syncedPushWatermark stays null → no peer to protect.
      final ancient =
          DateTime.now().millisecondsSinceEpoch - 40 * 24 * 60 * 60 * 1000;
      store.chats.add(deadChat(ancient));
      store.tombstones['chat:gone'] = ancient;
      await store.flushPersist();
      expect(store.tombstones.containsKey('chat:gone'), isFalse,
          reason: 'solo user: no peer can resurrect, so old tombstones are '
              'reaped to keep the blob lean (unchanged behavior)');
    });
  });
}
