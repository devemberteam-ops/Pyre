@TestOn('vm')
library;

// Sync-B stages 3 & 4 (2026-07-17, Codex) — the hub side of the sync-hardening
// release.
//
//   Stage 4 (hub monotonic restamp): the hub is server-authoritative on the
//   revision an accepted write gets. A backward-clock pusher whose mtime landed
//   at/below the hub's high-water used to be accepted RAW → it sat below every
//   peer's pull cursor → "my edit was invisible to the other device". The hub
//   now restamps such a write ABOVE its high-water so `mtime > since` pulls ship
//   it. A well-behaved (already-ahead) mtime is kept verbatim (no churn).
//
//   Stage 3 (honest per-item outcomes): the client classifies each pushed
//   item's real outcome instead of the old lossy "rejected-string-only"
//   heuristic — so an unknown/garbled result HOLDS the cursor (retry) while
//   every terminal outcome ADVANCES.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/pyre_server.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/services/sync_engine.dart';
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

Character _char(String id, {required int mtime, String name = 'A'}) => Character(
      id: id,
      name: name,
      description: 'd',
      createdAt: 0,
      updatedAt: 0,
      mtime: mtime,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stage 4 — hub monotonic restamp (applyPushRecordForTest)', () {
    test('a backward-clock record is restamped ABOVE the hub high-water', () async {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 10000; // hub high-water
      // Pusher clock rolled back: its mtime (5000) is BELOW the high-water.
      final j = _char('c1', mtime: 5000).toJson();

      final (code, serverMtime) =
          await PyreServer.applyPushRecordForTest(store, 'characters', j, 5000,
              restamp: true);

      expect(code, 'accepted');
      expect(serverMtime, greaterThan(10000),
          reason: 'restamp must lift the record above the hub high-water so '
              'every peer whose pull cursor is near 10000 still sees it');
      expect(store.characters.single.mtime, serverMtime,
          reason: 'the STORED record carries the restamped revision');
      expect(store.lastIssuedLocalMtime, greaterThanOrEqualTo(serverMtime),
          reason: 'the hub counter tracks the revision it just issued');
    });

    test('an already-ahead record keeps its mtime (no restamp churn)', () async {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 10000;
      final j = _char('c1', mtime: 20000).toJson();

      final (code, serverMtime) =
          await PyreServer.applyPushRecordForTest(store, 'characters', j, 20000,
              restamp: true);

      expect(code, 'accepted');
      expect(serverMtime, 20000,
          reason: 'a healthy mtime above the floor is authoritative as-is');
      expect(store.characters.single.mtime, 20000);
    });

    test('v1 pusher (restamp:false) is NOT restamped — mtime kept verbatim',
        () async {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 10000;
      final j = _char('c1', mtime: 5000).toJson();

      final (code, serverMtime) =
          await PyreServer.applyPushRecordForTest(store, 'characters', j, 5000,
              restamp: false);

      expect(code, 'accepted');
      expect(serverMtime, 5000,
          reason: 'legacy clients keep the old clamp-only contract; restamping '
              'them would echo/re-push under skew');
    });

    test('LWW still holds: an older incoming record is superseded, not applied',
        () async {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 30000;
      store.characters.add(_char('c1', mtime: 20000, name: 'server'));
      final j = _char('c1', mtime: 15000, name: 'stale').toJson();

      final (code, serverMtime) =
          await PyreServer.applyPushRecordForTest(store, 'characters', j, 15000,
              restamp: true);

      expect(code, 'superseded');
      expect(serverMtime, 20000, reason: 'returns the EXISTING server mtime');
      expect(store.characters.single.name, 'server',
          reason: 'a stale push must never overwrite newer data — the '
              'inevitable limit: restamp does not blind-accept');
    });

    test('an equal-version push is superseded and reports the equal mtime '
        '(the retry-after-failed-persist signal)', () async {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 30000;
      store.characters.add(_char('c1', mtime: 20000));
      final j = _char('c1', mtime: 20000).toJson();

      final (code, serverMtime) =
          await PyreServer.applyPushRecordForTest(store, 'characters', j, 20000,
              restamp: true);

      expect(code, 'superseded');
      expect(serverMtime, 20000,
          reason: 'serverMtime == incomingMtime is how /push detects a retry '
              'whose first accept may not have persisted, and re-persists');
    });

    test('a locked default preset reports immutable_record (never overwritten)',
        () async {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 100;
      final locked = Preset(
          id: 'p1', name: 'Default', mainPrompt: 'x', mtime: 50, locked: true);
      store.presets.add(locked);
      final j =
          Preset(id: 'p1', name: 'Hijack', mainPrompt: 'y', mtime: 9999).toJson();

      final (code, _) =
          await PyreServer.applyPushRecordForTest(store, 'presets', j, 9999,
              restamp: true);

      expect(code, 'immutable_record');
      expect(store.presets.single.name, 'Default',
          reason: 'the locked default is rebuilt from the binary — sync must '
              'never clobber it');
    });

    test('providers with the key-sync gate CLOSED report policy_rejected',
        () async {
      final store = AppStore(storage: _NoopBackend());
      // syncProviderKeys defaults false → the provider gate is closed.
      final j = ApiProvider(
        id: 'prov1',
        name: 'X',
        baseUrl: 'http://localhost:1234/v1',
        mtime: 100,
      ).toJson();

      final (code, _) =
          await PyreServer.applyPushRecordForTest(store, 'providers', j, 100,
              restamp: true);

      expect(code, 'policy_rejected',
          reason: 'a closed provider gate is an honest policy reject, not a '
              'silent drop or a fake "server newer"');
      expect(store.providers, isEmpty);
    });
  });

  group('stage 3 — client push-result classification (syncPushHoldForResults)',
      () {
    Map<String, dynamic> res(String code) => {'collection': 'characters', 'code': code};

    test('all-accepted advances (no hold)', () {
      expect(syncPushHoldForResults([res('accepted'), res('accepted')]), isFalse);
    });

    test('every benign terminal outcome advances', () {
      for (final code in const [
        'accepted',
        'superseded',
        'tombstoned',
        'invalid_record',
        'immutable_record',
        'policy_rejected',
      ]) {
        expect(syncPushHoldForResults([res(code)]), isFalse,
            reason: '$code is terminal — re-sending cannot change it');
      }
    });

    test('unsupported_collection HOLDS (retry until the hub upgrades)', () {
      expect(
          syncPushHoldForResults([res('accepted'), res('unsupported_collection')]),
          isTrue);
    });

    test('retryable_error HOLDS (transient hub apply failure)', () {
      expect(syncPushHoldForResults([res('accepted'), res('retryable_error')]),
          isTrue);
    });

    test('a garbled (non-Map) result entry HOLDS', () {
      expect(syncPushHoldForResults([res('accepted'), 42]), isTrue);
    });

    test('a result with a missing/blank code HOLDS', () {
      expect(syncPushHoldForResults([{'collection': 'characters'}]), isTrue);
      expect(syncPushHoldForResults([{'collection': 'characters', 'code': ''}]),
          isTrue);
    });

    test('an UNKNOWN code HOLDS — blocker 4: advancing over an unknown fate is '
        'not loss-safe', () {
      expect(syncPushHoldForResults([res('some_future_outcome')]), isTrue);
    });

    test('an empty results array advances (nothing to retry)', () {
      expect(syncPushHoldForResults(const []), isFalse);
    });
  });

  group('blocker 3 — clampFutureMtime', () {
    test('a future-clock mtime is pulled back to serverNow', () {
      expect(clampFutureMtime(5000, 3000), 3000);
    });
    test('a mtime at/below serverNow is untouched (backward-clock survives '
        'for the restamp to lift)', () {
      expect(clampFutureMtime(2000, 3000), 2000);
      expect(clampFutureMtime(3000, 3000), 3000);
    });
  });

  group('blocker 2 — reconcilePushedRevision (client)', () {
    test('always observes the hub revision so the client can never re-mint it '
        '(the tie that diverges)', () {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 100;
      // No such record — pure observe path.
      store.reconcilePushedRevision('characters', 50, 10001, id: 'ghost');
      expect(store.lastIssuedLocalMtime, greaterThanOrEqualTo(10001));
      expect(store.nextSyncMtime(), greaterThan(10001),
          reason: 'after observing the hub restamp, the next local mint is '
              'strictly above it — no floor+1 collision with the hub');
    });

    test('re-bumps a record EDITED during the push so it re-pushes and wins '
        '(and reports it changed state)', () {
      final store = AppStore(storage: _NoopBackend());
      // We sent c@5000; the hub restamped to 10001; but the user edited c
      // locally during the round-trip → its mtime is now 9999 (new data).
      store.characters.add(_char('c', mtime: 9999));
      final changed =
          store.reconcilePushedRevision('characters', 5000, 10001, id: 'c');
      final c = store.characters.single;
      expect(c.mtime, greaterThan(10001),
          reason: 'the concurrent edit must out-stamp the hub copy (10001) so '
              'it re-pushes and wins — else both sides tie at 10001 forever '
              'with DIFFERENT data (permanent divergence)');
      expect(changed, isTrue,
          reason: 'r2: a re-bump must report dirty so the caller persists it '
              'before advancing the cursor');
    });

    test('leaves an UNTOUCHED record alone (mtime still == clientMtime)', () {
      final store = AppStore(storage: _NoopBackend());
      store.lastIssuedLocalMtime = 10001; // already at the hub revision
      store.characters.add(_char('c', mtime: 5000)); // unchanged since we sent
      final changed =
          store.reconcilePushedRevision('characters', 5000, 10001, id: 'c');
      expect(store.characters.single.mtime, 5000,
          reason: 'untouched → the hub copy is identical; the one benign '
              'pull-echo reconciles it, no local re-bump needed');
      expect(changed, isFalse,
          reason: 'no counter raise, no re-bump → nothing to persist');
    });

    test('reconciles on a SUPERSEDED result too (not just accepted) — the tie '
        'can arise from a superseded snapshot', () {
      // The client calls reconcile for both accepted AND superseded results;
      // the METHOD is outcome-agnostic, so this just pins the divergence-break
      // works regardless of which outcome carried the (clientMtime, serverMtime).
      final store = AppStore(storage: _NoopBackend());
      store.characters.add(_char('c', mtime: 10001)); // edited to the tie value
      final changed =
          store.reconcilePushedRevision('characters', 5000, 10001, id: 'c');
      expect(store.characters.single.mtime, greaterThan(10001),
          reason: 'mtime==serverMtime but != clientMtime → edited-during-push '
              '→ re-bump above the tie');
      expect(changed, isTrue);
    });
  });

  group('blocker 3 — load future-clamp respects the counter ceiling', () {
    test('a future record COVERED by the counter survives (not demoted)', () {
      // load() clamps with ceiling = max(now, persistedCounter). A v2-accepted
      // record whose mtime the counter already covers must NOT be pulled down.
      const counter = 5000000000000; // ~2128, above wall-clock now
      expect(clampMtime(counter, counter), counter,
          reason: 'a mtime at the trusted counter ceiling is kept — else '
              "/pull.serverTime (= counter) would sit above it and hide it");
    });
    test('a record ABOVE the counter (uncovered/hostile) is still clamped', () {
      const ceiling = 4000000000000;
      expect(clampMtime(ceiling + 999, ceiling), ceiling,
          reason: 'a value the counter never issued is still pulled to the '
              'ceiling — the corrupt-backup defense survives');
    });
  });
}
