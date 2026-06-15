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
    test('advances to pushClock on a clean push', () {
      final next = nextPushCursor(
        current: 1000,
        pushClock: 5000,
        pushRan: true,
        hardReject: false,
        conflictAbort: false,
      );
      expect(next, 5000,
          reason: 'a successful push moves the cursor to the client clock '
              'captured before the collection snapshot');
    });

    test('HOLDS on a hard reject (so the rejected record re-collects next tick)', () {
      final next = nextPushCursor(
        current: 1000,
        pushClock: 5000,
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
        pushClock: 5000,
        pushRan: false,
        hardReject: false,
        conflictAbort: true,
      );
      expect(next, 1000);
    });

    test('HOLDS when the push did not run (e.g. generation in-flight)', () {
      final next = nextPushCursor(
        current: 1000,
        pushClock: 5000,
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
        pushClock: 5000, // a clock that briefly went backwards
        pushRan: true,
        hardReject: false,
        conflictAbort: false,
      );
      expect(next, 9000,
          reason: 'monotonic cursor — a backwards clock must not re-open '
              'already-pushed records for an echo storm');
    });
  });
}
