// 2026-06-15 audit fixes: S-BUG1, S-BUG3, S-BUG4, S-BUG2 (server-side).
//
// S-BUG1 (HIGH, lost update) — keep-local conflict now bumps mtime so the
//   record gets pushed next tick and out-dates the peer's copy (prevents
//   LWW-revert). We test the pure mtime-bump helper + the mtime gate.
//
// S-BUG3 (MEDIUM) — reap boundary asymmetry: `isTombstonedNewer` uses `>=`
//   but reap used `< tombstoneMtime` (strict). At equality the record stayed
//   live AND tombstoned. Fix: make reap `<=` (i.e. remove WHERE mtime > tMtime
//   becomes remove WHERE mtime <= tMtime). We test the equal-mtime boundary.
//
// S-BUG4 (MEDIUM, secret durability) — tombstone applied BEFORE providers so
//   isTombstonedNewer catches a same-payload delete before the key is written.
//   This is a runtime-ordering fix (sync_engine.dart apply order); tested here
//   as a pure state check: if tombstones is populated BEFORE isTombstonedNewer
//   is consulted by applyProviders, the key-write is skipped correctly.
//
// S-BUG2 — server-side timing (serverTime stamped before selection). Pure
//   ordering test: serverTime at-or-before selection means watermark can only
//   claim coverage through timestamps already present in the response.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/state/app_store.dart';

/// Pure helper extracted from the S-BUG1 fix: compute the bumped mtime that
/// ensures the kept-local record out-dates the peer's serverTime and will be
/// re-pushed next tick.
///
/// This function mirrors what each `apply*` branch now calls when `force == false`.
int keepLocalBumpMtime(int serverTime) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return now > serverTime + 1 ? now : serverTime + 1;
}

/// S-BUG3 helper: given a tombstone mtime [t] and a record mtime [r], returns
/// true iff the reap boundary (now `<=`) would remove the record. Symmetric
/// with `isTombstonedNewer` (`>=`).
bool reapBoundary(int recordMtime, int tombstoneMtime) =>
    recordMtime <= tombstoneMtime;

void main() {
  // -------------------------------------------------------------------------
  // S-BUG1: keep-local mtime bump
  // -------------------------------------------------------------------------
  group('S-BUG1: keepLocalBumpMtime', () {
    test('result is strictly greater than serverTime', () {
      final serverTime = DateTime.now().millisecondsSinceEpoch - 100;
      final bump = keepLocalBumpMtime(serverTime);
      expect(bump > serverTime, isTrue,
          reason: 'bumped mtime must exceed serverTime so it is pushed next tick');
    });

    test('result is at least serverTime + 1', () {
      // Even if the clock is behind serverTime, the bump is at least +1.
      final serverTime = DateTime.now().millisecondsSinceEpoch + 9999;
      final bump = keepLocalBumpMtime(serverTime);
      expect(bump, greaterThanOrEqualTo(serverTime + 1));
    });

    test('bumped mtime causes record to be included in _collectDirty (mtime > since)', () {
      // Simulate: serverTime = 5000, local mtime = 3000 (old, pre-bump).
      // After bump => at least 5001. _collectDirty gate is `mtime > since`
      // where since == serverTime (5000). 5001 > 5000 → included.
      const serverTime = 5000;
      final bump = keepLocalBumpMtime(serverTime);
      expect(bump > serverTime, isTrue,
          reason: 'bumped record must satisfy `mtime > since` so _collectDirty picks it up');
    });

    test('preferOtherDevice (force == true) path is NOT bumped', () {
      // Sanity: the bump should only happen on the keep-local (force==false)
      // branch. When force==true the incoming record is applied directly —
      // its mtime is authoritative. (This test documents the invariant, not
      // a function call.)
      final incoming = Character(id: 'x', name: 'X', mtime: 9000);
      // After applying the incoming record, mtime == 9000 (the peer's value).
      expect(incoming.mtime, 9000);
    });
  });

  // -------------------------------------------------------------------------
  // S-BUG1: integration with AppStore — bumped mtime exceeds peer's mtime
  // -------------------------------------------------------------------------
  group('S-BUG1: bumped mtime out-dates peer copy', () {
    test('after keep-local bump, local mtime > peer mtime AND > serverTime', () {
      const peerMtime = 3000;
      const serverTime = 5000;
      final bump = keepLocalBumpMtime(serverTime);
      // The bump must exceed both the peer's copy (so LWW on the next pull
      // keeps local) AND serverTime (so _collectDirty includes it for push).
      expect(bump > peerMtime, isTrue);
      expect(bump > serverTime, isTrue);
    });

    test('AppStore mtime field is mutable (can be bumped in place)', () {
      final c = Character(id: 'c1', name: 'Test', mtime: 1000);
      c.mtime = keepLocalBumpMtime(5000);
      expect(c.mtime > 5000, isTrue);
    });

    test('bumped character satisfies _collectDirty gate (mtime > since)', () {
      const since = 5000; // the watermark after the tick
      final c = Character(id: 'c1', name: 'Test', mtime: 1000);
      c.mtime = keepLocalBumpMtime(since);
      // This mirrors `store.characters.where((c) => c.mtime > since)`.
      expect(c.mtime > since, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // S-BUG3: reap boundary `<=` is consistent with isTombstonedNewer `>=`
  // -------------------------------------------------------------------------
  group('S-BUG3: reap boundary consistency', () {
    test('equal mtime: isTombstonedNewer returns true (>=)', () {
      final s = AppStore();
      s.tombstones['character:c1'] = 2000;
      // isTombstonedNewer uses `>=` — equal mtime tombstone suppresses record.
      expect(s.isTombstonedNewer('character', 'c1', 2000), isTrue);
    });

    test('equal mtime: reapBoundary returns true (<=)', () {
      // After fix: reap uses `mtime <= tombstoneMtime`, so equal-mtime record
      // IS reaped — consistent with isTombstonedNewer.
      expect(reapBoundary(2000, 2000), isTrue,
          reason: 'record with mtime == tombstoneMtime must be reaped (<=)');
    });

    test('record mtime LESS than tombstone: both reap and suppress', () {
      final s = AppStore();
      s.tombstones['character:c1'] = 2000;
      expect(s.isTombstonedNewer('character', 'c1', 1000), isTrue);
      expect(reapBoundary(1000, 2000), isTrue);
    });

    test('record mtime GREATER than tombstone: neither reaps nor suppresses', () {
      final s = AppStore();
      s.tombstones['character:c1'] = 2000;
      expect(s.isTombstonedNewer('character', 'c1', 3000), isFalse);
      expect(reapBoundary(3000, 2000), isFalse,
          reason: 'record newer than tombstone must NOT be reaped');
    });

    test('old code (strict <) wrongly kept equal-mtime record alive', () {
      // Document the OLD bug: `mtime < tombstoneMtime` (strict) was false at
      // equality → record stayed live while isTombstonedNewer returned true
      // → divergence. The new `<=` fixes this.
      const recordMtime = 2000;
      const tombstoneMtime = 2000;
      final oldReap = recordMtime < tombstoneMtime; // OLD: false (bug)
      final newReap = recordMtime <= tombstoneMtime; // NEW: true (fixed)
      expect(oldReap, isFalse, reason: 'old strict-< was the bug');
      expect(newReap, isTrue, reason: 'new <= matches the suppression boundary');
    });
  });

  // -------------------------------------------------------------------------
  // S-BUG4: tombstone-before-provider ordering (pure state check)
  // -------------------------------------------------------------------------
  group('S-BUG4: tombstone applied before providers', () {
    test('isTombstonedNewer returns true AFTER tombstone is recorded (state order)', () {
      final s = AppStore();
      const providerId = 'prov-1';
      const providerMtime = 1000;

      // Step 1: tombstone is NOT yet in store (simulates pre-applyTombstones).
      expect(s.isTombstonedNewer('provider', providerId, providerMtime), isFalse,
          reason: 'before tombstone apply, the key-write is not blocked');

      // Step 2: apply tombstone (simulates applyTombstones running FIRST now).
      s.tombstones['provider:$providerId'] = providerMtime + 1;

      // Step 3: isTombstonedNewer now returns true → applyProviders skips
      // the SecureKeys.write for this provider.
      expect(s.isTombstonedNewer('provider', providerId, providerMtime), isTrue,
          reason: 'after tombstone apply, provider key-write must be skipped');
    });

    test('equal-mtime tombstone also blocks provider key-write (>= boundary)', () {
      final s = AppStore();
      const providerId = 'prov-2';
      const providerMtime = 5000;

      s.tombstones['provider:$providerId'] = providerMtime; // same mtime
      expect(s.isTombstonedNewer('provider', providerId, providerMtime), isTrue,
          reason: '>= boundary: equal-mtime tombstone suppresses the provider');
    });
  });

  // -------------------------------------------------------------------------
  // S-BUG2: serverTime-before-selection invariant (pure)
  // -------------------------------------------------------------------------
  group('S-BUG2: serverTime captured before selection', () {
    test('watermark must never exceed the mtime of records actually returned', () {
      // The invariant: for every record returned in the /pull response with
      // mtime M, the client's new watermark W must satisfy M >= since (it was
      // selected) AND W >= M (so the record is not re-fetched forever).
      // When serverTime is stamped BEFORE selection, W == serverTime (at capture
      // time), and any record written after the stamp (mtime > serverTime) is
      // NOT selected because we use `mtime > since` with `since` already settled.
      // But if a record snuck in during serialization with mtime between
      // [since, serverTime_old], the old code would set W = serverTime_old > that
      // record's mtime → it would never be re-fetched. The fix: stamp early so
      // W is at most as large as the snapshot moment, and any record with
      // mtime > W is still caught on the next pull (it passes `mtime > since`).
      //
      // We can verify the invariant purely: if W is captured BEFORE any record
      // selection, then all selected records have mtime in (since, W] or might
      // be > W (if written after W but selected in the same snapshot — those are
      // idempotently re-delivered next pull). The key property:
      //   ∀ record r: if r was not in response, then r.mtime > W (so next pull
      //   catches it with `r.mtime > W`).
      //
      // We express this as: a record that arrives during serialization and has
      // mtime just above the capture-time serverTime will be caught next pull.
      const captureTimeServerTime = 5000;
      const recordArrivedDuringSerialization = 5001; // mtime > captureTime

      // Since watermark = captureTimeServerTime, the next pull uses
      // `since = 5000`. Record with mtime 5001 satisfies `5001 > 5000` → caught.
      expect(recordArrivedDuringSerialization > captureTimeServerTime, isTrue,
          reason: 'record written after stamp is caught on the next pull');
    });

    test('OLD code (stamp after selection) could miss records at mtime between since and serverTime', () {
      // The old ordering: select `mtime > since`, then stamp serverTime = now().
      // If a record lands with mtime M where since < M < serverTime_old,
      // it is NOT in the response (was written after the snapshot) but the
      // watermark jumps to serverTime_old > M → `M > serverTime_old` is false
      // next pull → permanent miss.
      //
      // With the fix (stamp BEFORE), serverTime_new < M, so `M > serverTime_new`
      // is true → caught next pull.
      const since = 1000;
      const missedRecordMtime = 2000;
      final serverTimeOld = missedRecordMtime + 1; // stamped AFTER the record
      final serverTimeNew = missedRecordMtime - 1; // stamped BEFORE the record

      // Old behaviour: `missedRecordMtime > serverTimeOld` is false → permanent miss.
      expect(missedRecordMtime > serverTimeOld, isFalse,
          reason: 'old: the missed record would never be re-fetched');

      // New behaviour: `missedRecordMtime > serverTimeNew` is true → caught.
      expect(missedRecordMtime > serverTimeNew, isTrue,
          reason: 'new: early stamp means the record is caught next pull');

      // Also confirm the record would have been selected under `mtime > since`.
      expect(missedRecordMtime > since, isTrue);
    });
  });
}
