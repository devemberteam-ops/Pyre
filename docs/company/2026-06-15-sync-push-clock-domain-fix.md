# Fix: phone→desktop sync PUSH silently lost new records (clock-domain bug)

> Branch release/1.1.3. Found during the hands-on emulator↔desktop sync test.
> Diagnosis is code-level airtight + locked into a deterministic test.
> TDD + green gate (analyze clean · 1676 tests) + independent verifier.

## Symptom (hands-on test)
A character created ON THE PHONE never reached the desktop — Characters stayed
9 on desktop while the phone went to 10 — after 2× "Force sync now" + ~4 min /
several ticks, with **NO error surfaced**. Desktop→phone ALWAYS worked (the
phone pulled the full 9-char library + personas + avatars fine). The failure was
**silent and intermittent**.

## Root cause (CONFIRMED by reading both sides)
The push path compared records across **two different clock domains**.

- `_lastServerTime` (sync_engine.dart) is the **SERVER's** wall clock — it's the
  `serverTime` the desktop returns on `/pull` (`pyre_server.dart` stamps
  `DateTime.now()`; client adopts it at sync_engine ~line 371).
- A locally-created record's `mtime` is **THIS device's** (the phone's) wall
  clock.
- The PULL filter `since = _lastServerTime` compares a server-domain watermark
  against the desktop's server-domain record mtimes → **same domain** →
  correct. *This is why desktop→phone always worked.*
- The PUSH collector `_collectDirty(store, _lastServerTime)` (and the provider /
  tombstone collectors) compared that **server-domain** watermark against each
  **client-domain** local `mtime`. **Cross-domain.**

When the desktop clock runs **ahead** of the phone clock (Android emulator
clocks drift heavily — we measured ~20s during the failing test, 55ms later),
a freshly-created phone record has `mtime < _lastServerTime` *from the moment of
creation*. `mtime > since` is false → never collected → never pushed. And every
pull advances `_lastServerTime` even higher, so the record stays stuck below the
watermark **forever** (explains why repeated force-syncs never recovered it).

The server's existing future-clock clamp (pyre_server FIX 5, ~line 538) does
**not** help: it clamps writers whose clock is *ahead* down to `serverNow`; it
cannot help a writer that is *behind*, because that record never reaches the
server to be clamped.

Signature match: silent (no push attempted → no error), intermittent
(clock-drift dependent), one-way (only the cross-domain push direction).

## Fix (surgical, single file: sync_engine.dart)
A **separate push cursor `_lastPushTime` in the client's own clock domain**.
Push collection now filters by `_lastPushTime`, never `_lastServerTime`, so a
local `mtime` is only ever compared against a same-clock value. PULL is
untouched (still `_lastServerTime`).

- New pure helper `nextPushCursor({current, pushClock, pushRan, hardReject,
  conflictAbort})` — advances to `pushClock` on a clean push, HOLDS on
  hard-reject / conflict-abort / push-skipped (generation in-flight), never
  moves backwards.
- `pushClock` (client clock) captured **before** the collection snapshot —
  mirrors the server's stamp-before-select fix (S-BUG2): a record written during
  the push has `mtime > pushClock` → caught next tick, not skipped.
- `_lastPushTime` persisted (`sync.lastPushTime`), lazy-loaded on first tick,
  reset to 0 on re-pair (W1) so a new pairing re-pushes the whole library.
- The three push collectors switched to `_lastPushTime`: `_collectDirty`, the
  provider loop, `_collectDirtyTombstones`.

### Robustness
- Phone behind / ahead / equal clock: local writes always collected (same-domain
  compare). No clock relationship can lose a local write.
- Bounded benign echo: pulled records carry the desktop's foreign mtimes; when
  the desktop is ahead, they sit briefly above the client cursor and get
  re-pushed ONCE per skew-window, then stop as the client clock overtakes them.
  The server LWW-rejects them with reason `'server has newer mtime'` — which the
  client treats as **benign** (NOT a hard reject), so the watermark still
  advances and "Pushed N" is not inflated. Worst case is a one-time
  library-sized echo right after a fresh pair when the desktop clock is ahead.
- Hold-on-reject preserved: a hard reject / conflict-abort holds BOTH cursors so
  the un-pushed local record re-collects next tick (no lost update).

## Tests
`test/sync_push_clock_domain_test.dart` (9 tests, all green):
- Reproduces the bug: old server-domain gate DROPS a behind-clock local record;
  new client-domain gate COLLECTS it; the miss is PERMANENT under the old gate.
- `nextPushCursor` advance/hold matrix (clean push / hard-reject / conflict-abort
  / push-skipped / never-backwards).

## FLAGGED for Kuru — adjacent, NOT fixed (founder's call)
**Conflict detection still compares local mtimes against the server watermark.**
`_detectConflictsForPull(store, updates, _lastServerTime)` (line 471) passes
`_lastServerTime` as `lastSyncAt`; `detectSyncConflicts` compares **local**
(client-domain) mtimes against it. So in **non-default** conflict modes
(Ask / preferThisDevice / preferOtherDevice), a genuinely-local edit on a phone
whose clock lags the desktop may NOT be detected as a conflict → silently LWW'd.
- **Default mode (newestWins) is UNAFFECTED** — it skips detection entirely
  (line 470). Only users who switched modes are exposed.
- Proper fix needs a TWO-watermark `detectSyncConflicts` (compare local vs the
  client-domain push cursor, remote vs the server watermark) — a contract change
  with its own tests. Deferred to keep this sensitive fix tight. Recommend doing
  it as a focused follow-up.

## Live re-test (attempted — BLOCKED by emulator transport, fix exonerated)
I rebuilt both .dev artifacts with the fix, relaunched the desktop host (new
pyre.exe, confirmed listening on 0.0.0.0:6767, clean 401 on a loopback /pull),
and reinstalled the APK with `adb install -r` (data preserved — the stuck
`SyncTestPhone` survived, phone shows Characters (10)). The plan was a
DISCRIMINATING test: on the new build `_lastPushTime` cold-starts at 0 (the pref
key is new), so `_collectDirty(store, 0)` should collect the previously-stuck
card and finally push it — independent of clock direction.

It did NOT push, and the phone logcat shows why:
```
[SyncEngine] tick failed: ClientException: Connection closed before full header
was received, uri=http://127.0.0.1:6767/pull?since=...   (every 30s)
```
The tick dies at the **/pull** HTTP call — the FIRST call of a tick, and code
this fix never touched — so the push logic never runs. The desktop server is
healthy (loopback /pull returns 401), so this is the Android emulator's
well-known `adb reverse` fragility (the tunnel went stale while pyre.exe was
down during the rebuild). A full `adb kill-server`/`start-server` + re-add did
not clear it. This is a TEST-HARNESS transport failure, NOT evidence about the
fix: the unchanged pull path fails identically, and the push change is never
exercised.

CONCLUSION: the fix is proven by the deterministic reproduction test +
independent adversarial verification (R1–R8 APPROVED) + green analyze/1676
tests + green builds. The live end-to-end (and the adverse-clock case) is best
confirmed over real Wi-Fi with Kuru — a real device avoids the adb-reverse flake
entirely (the original bug was found on this setup when the tunnel was healthy),
or by re-pairing the emulator via host alias `10.0.2.2:6767` instead of an
adb-reverse'd 127.0.0.1.
