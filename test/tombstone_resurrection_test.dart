@TestOn('vm')
library;

// Pyre 1.2 (Tier-1 H-1) — tombstone-GC "data resurrection" fix.
//
// THE HEADLINE SYNC BUG (whole-app-map 2026-07-01): `_gcTombstones` physically
// reaps soft-deleted records (and the synced tombstone LOG) older than 30 days
// on EVERY save, keyed ONLY on wall-clock age. A device that deletes something
// then stays offline 30+ days reaps its OWN tombstone BEFORE it ever pushed the
// deletion — so on reconnect the peer's still-live copy LWW-applies BACK: "my
// character came back from the dead".
//
// THE FIX (push-before-reap): a tombstone is reapable only once we've confirmed
// it was pushed. `syncedPushWatermark` (client-clock domain, fed by SyncEngine's
// _lastPushTime) is the anchor — after a successful push every record with
// `mtime <= watermark` is on the hub, so peers will pull the deletion. Reaping
// is gated on `(watermark == null || mtime <= watermark)`:
//   * watermark == null  => NO sync relationship => wall-clock reap (unchanged
//     for the single-device majority — zero regression);
//   * watermark == N     => sync active, pushed up to N => reap only what's
//     been pushed (mtime <= N). Un-pushed deletes are kept until they go up.
// Erring toward a LOWER watermark is always safe (reap less, never resurrect).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _MemoryBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

/// Captures the last saved blob so the SERIALIZE side can be inspected through
/// the REAL persist path (`flushPersist` → toJson → save) — the deterministic,
/// plugin-free persistence pattern the sibling sync tests use.
class _CaptureBackend implements StoreBackend {
  Map<String, dynamic>? captured;
  @override
  Future<Map<String, dynamic>?> load() async => captured;
  @override
  Future<void> save(Map<String, dynamic> blob) async => captured = blob;
  @override
  Future<void> clear() async => captured = null;
}

/// A soft-deleted record whose deletion happened LONG ago (mtime tiny => far
/// older than the 30-day wall-clock cutoff, no clock mocking needed).
Character _oldGhost(String id, {required int mtime}) => Character(
      id: id,
      name: 'Ghost $id',
      description: 'A deleted character.',
      createdAt: 0,
      updatedAt: 0,
      mtime: mtime,
      deleted: true,
    );

void main() {
  group('H-1 tombstone resurrection — push-before-reap', () {
    test('un-pushed old soft-delete is KEPT while sync active (mtime > watermark)',
        () {
      final store = AppStore(storage: _MemoryBackend());
      // Deleted at mtime 1000 (>30 days ago). Sync is active but we've only
      // pushed up to 500 — this deletion was NEVER pushed.
      store.characters.add(_oldGhost('g1', mtime: 1000));
      store.setSyncedPushWatermark(500);

      store.debugRunTombstoneGc();

      expect(
        store.characters.any((c) => c.id == 'g1'),
        isTrue,
        reason: 'reaping an un-pushed tombstone lets a peer resurrect the record',
      );
    });

    test('old soft-delete IS reaped once it has been pushed (mtime <= watermark)',
        () {
      final store = AppStore(storage: _MemoryBackend());
      store.characters.add(_oldGhost('g1', mtime: 1000));
      store.setSyncedPushWatermark(2000); // 1000 <= 2000 => pushed

      store.debugRunTombstoneGc();

      expect(store.characters.any((c) => c.id == 'g1'), isFalse,
          reason: 'a pushed, 30-day-old tombstone is safe to free');
    });

    test('no sync relationship (watermark null) reaps by wall-clock — unchanged',
        () {
      final store = AppStore(storage: _MemoryBackend());
      store.characters.add(_oldGhost('g1', mtime: 1000));
      store.setSyncedPushWatermark(null); // never synced

      store.debugRunTombstoneGc();

      expect(store.characters.any((c) => c.id == 'g1'), isFalse,
          reason: 'single-device users keep the old wall-clock GC behavior');
    });

    test('the synced tombstone LOG entry follows the same push-gate', () {
      final store = AppStore(storage: _MemoryBackend());
      store.tombstones['character:g1'] = 1000;

      store.setSyncedPushWatermark(500); // un-pushed
      store.debugRunTombstoneGc();
      expect(store.tombstones.containsKey('character:g1'), isTrue,
          reason: 'the deletion LOG must survive until it is pushed');

      store.setSyncedPushWatermark(2000); // pushed
      store.debugRunTombstoneGc();
      expect(store.tombstones.containsKey('character:g1'), isFalse);
    });

    test('a RECENT delete is never reaped regardless of watermark', () {
      final store = AppStore(storage: _MemoryBackend());
      final recent = DateTime.now().millisecondsSinceEpoch; // < 30 days old
      store.characters.add(_oldGhost('g1', mtime: recent));
      store.setSyncedPushWatermark(recent + 10_000); // "pushed", but too fresh

      store.debugRunTombstoneGc();

      expect(store.characters.any((c) => c.id == 'g1'), isTrue,
          reason: 'the 30-day storage floor is independent of the push gate');
    });

    test('watermark is written to the persisted blob (serialize side)',
        () async {
      final backend = _CaptureBackend();
      final store = AppStore(storage: backend);
      store.setSyncedPushWatermark(12345);

      await store.flushPersist();

      expect(backend.captured, isNotNull);
      expect(backend.captured!['syncedPushWatermark'], 12345);
    });
  });
}
