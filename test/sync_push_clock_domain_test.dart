// 2026-06-15 — phone→desktop PUSH failure root cause + fix.
//
// SYMPTOM (hands-on test): a character created on the phone never reached the
// desktop, even after repeated "Force sync now" + many ticks, with NO error.
// Desktop→phone always worked. Intermittent / clock-dependent.
//
// ROOT CAUSE: the push side filtered local records with
//   `mtime > _lastServerTime`
// but `_lastServerTime` is the SERVER's wall clock (it's the `serverTime` the
// desktop hands back on /pull), while a locally-created record's `mtime` is the
// CLIENT's wall clock. That is a cross-clock-domain comparison. When the server
// (desktop) clock runs AHEAD of the client (phone) clock, a freshly-created
// local record has `mtime < _lastServerTime` from the moment of creation, so
// `_collectDirty` never picks it up — and because every pull advances
// `_lastServerTime` even higher, it stays below the watermark forever. The PULL
// path is immune (server-domain `since` vs server-domain remote mtimes), which
// is exactly why desktop→phone worked but phone→desktop silently dropped new
// records. The server's existing future-clock clamp (pyre_server FIX 5) only
// rescues writers whose clock is AHEAD — it cannot help a writer that is BEHIND,
// because that record never reaches the server to be clamped.
//
// FIX: track a SEPARATE push cursor in the CLIENT's own clock domain
// (`_lastPushTime`) and filter the push by it, so a local record's mtime is
// only ever compared against a value from the same clock. The pure advance
// logic lives in `nextPushCursor`, tested here; the wiring (capture the client
// clock BEFORE the collection snapshot, advance on a clean push, hold on
// hard-reject / conflict-abort / no-push) lives in SyncEngine._tick.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/sync_engine.dart';

/// The OLD (buggy) push gate: filter local records by the SERVER-domain pull
/// watermark. Reproduced here so the test can show it dropping a behind-clock
/// local record.
bool oldPushIncludes({required int recordMtime, required int serverWatermark}) =>
    recordMtime > serverWatermark;

/// The NEW push gate: filter by the CLIENT-domain push cursor.
bool newPushIncludes({required int recordMtime, required int clientPushCursor}) =>
    recordMtime > clientPushCursor;

void main() {
  // -------------------------------------------------------------------------
  // The bug, made concrete: server clock AHEAD of client clock.
  // -------------------------------------------------------------------------
  group('cross-clock-domain push miss (root cause)', () {
    // Phone (client) clock is BEHIND the desktop (server) clock by 20s — the
    // exact drift measured on the emulator during the hands-on test.
    const skewMs = 20000;
    const clientClockAtLastPush = 1000000; // phone clock at the prior push
    // The desktop's clock at that same moment, 20s ahead. `_lastServerTime`
    // adopts THIS value from the /pull response.
    const serverWatermark = clientClockAtLastPush + skewMs;
    // The user creates a card a few seconds later (still well within the skew),
    // so its mtime (phone clock) is below the server watermark.
    const recordMtime = clientClockAtLastPush + 3000; // 3s after the pull

    test('OLD server-domain gate DROPS the behind-clock local record (the bug)', () {
      expect(
        oldPushIncludes(recordMtime: recordMtime, serverWatermark: serverWatermark),
        isFalse,
        reason: 'record.mtime (phone clock) < _lastServerTime (desktop clock) '
            '→ never collected → never pushed. This is the reported failure.',
      );
    });

    test('NEW client-domain gate COLLECTS the same local record (the fix)', () {
      // The push cursor is in the phone\'s own clock domain: it is the phone
      // clock at the previous push, NOT the desktop\'s serverTime.
      const clientPushCursor = clientClockAtLastPush;
      expect(
        newPushIncludes(recordMtime: recordMtime, clientPushCursor: clientPushCursor),
        isTrue,
        reason: 'record.mtime (phone clock) > push cursor (phone clock) — same '
            'clock domain, so a fresh local write is always seen.',
      );
    });

    test('bug is PERMANENT under the old gate (watermark keeps advancing)', () {
      // Each subsequent pull pushes _lastServerTime even higher (desktop clock
      // marches on), so the fixed-in-the-past record falls further behind.
      const laterServerWatermark = serverWatermark + 60000; // a minute later
      expect(
        oldPushIncludes(recordMtime: recordMtime, serverWatermark: laterServerWatermark),
        isFalse,
        reason: 'advancing the server watermark can only make the miss worse — '
            'explains why repeated force-syncs never recovered the card.',
      );
    });

    test('fix is robust the OTHER way too (client clock AHEAD of server)', () {
      // When the phone clock is AHEAD, the old gate happened to work; the new
      // gate must keep working (no regression for the lucky case).
      const clientPushCursor = clientClockAtLastPush;
      const recordMtimeAhead = clientClockAtLastPush + 5000;
      expect(
        newPushIncludes(recordMtime: recordMtimeAhead, clientPushCursor: clientPushCursor),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // nextPushCursor — the pure advance/hold logic the fix adds to SyncEngine.
  // -------------------------------------------------------------------------
  group('nextPushCursor advance/hold', () {
    test('advances to pushBoundary on a clean push', () {
      final next = nextPushCursor(
        current: 1000,
        pushBoundary: 5000,
        pushRan: true,
        hardReject: false,
        conflictAbort: false,
      );
      expect(next, 5000,
          reason: 'a successful push moves the cursor to the logical boundary '
              '(lastIssuedLocalMtime) captured before the collection snapshot');
    });

    test('HOLDS on a hard reject (so the rejected record re-collects next tick)', () {
      final next = nextPushCursor(
        current: 1000,
        pushBoundary: 5000,
        pushRan: true,
        hardReject: true,
        conflictAbort: false,
      );
      expect(next, 1000,
          reason: 'holding the cursor keeps the rejected local record '
              '`mtime > cursor` so it is re-pushed (no lost update)');
    });

    test('HOLDS on conflict-dialog dismissal (conflictAbort)', () {
      final next = nextPushCursor(
        current: 1000,
        pushBoundary: 5000,
        pushRan: false,
        hardReject: false,
        conflictAbort: true,
      );
      expect(next, 1000);
    });

    test('HOLDS when the push did not run (e.g. generation in-flight)', () {
      final next = nextPushCursor(
        current: 1000,
        pushBoundary: 5000,
        pushRan: false,
        hardReject: false,
        conflictAbort: false,
      );
      expect(next, 1000,
          reason: 'records written while push was skipped must still be '
              'collected on the next pushing tick');
    });

    test('never moves the cursor backwards', () {
      final next = nextPushCursor(
        current: 9000,
        pushBoundary: 5000, // a boundary that briefly went backwards
        pushRan: true,
        hardReject: false,
        conflictAbort: false,
      );
      expect(next, 9000,
          reason: 'monotonic cursor — a backwards value must not re-open '
              'already-pushed records for an echo storm');
    });
  });

  // -------------------------------------------------------------------------
  // Sync-B stage 2 (2026-07-17, Codex): the cursor is the LOGICAL boundary
  // (lastIssuedLocalMtime), not a wall clock. This closes the "dirty forever"
  // gap: under a rolled-back wall clock, a monotonic mtime out-runs `now`, so a
  // wall-clock cursor never covers it and the record re-pushes on every tick.
  // -------------------------------------------------------------------------
  group('nextPushCursor logical boundary (dirty-forever fix)', () {
    test('logical boundary covers a monotonic mtime that out-ran the wall clock',
        () {
      // A backward NTP correction: wall `now` == 5000, but the counter already
      // issued 5001 (nextSyncMtime = max(now, last+1)). The record ships with
      // mtime 5001; the boundary IS the counter, so the cursor advances to 5001
      // and the record is marked clean — not stranded above a 5000 wall cursor.
      const recordMtime = 5001; // minted monotonic, above the rolled-back clock
      const wallNow = 5000; // what the OLD pushClock would have been
      const logicalBoundary = 5001; // store.lastIssuedLocalMtime

      final oldCursor = nextPushCursor(
        current: 4000,
        pushBoundary: wallNow, // the OLD wall-clock value, for contrast
        pushRan: true,
        hardReject: false,
        conflictAbort: false,
      );
      expect(recordMtime > oldCursor, isTrue,
          reason: 'wall-clock cursor (5000) leaves the 5001 record dirty '
              'forever — the bug');

      final newCursor = nextPushCursor(
        current: 4000,
        pushBoundary: logicalBoundary,
        pushRan: true,
        hardReject: false,
        conflictAbort: false,
      );
      expect(recordMtime > newCursor, isFalse,
          reason: 'logical boundary (5001) covers the shipped record — clean');
    });
  });
}
