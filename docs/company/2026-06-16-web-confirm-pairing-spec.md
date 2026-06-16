# Spec: desktop-confirmation web pairing ("Allow this browser? [Allow]")

> Kuru asked for one-click web pairing. Loopback-auto was REJECTED (DNS-rebinding:
> a malicious site could rebind to 127.0.0.1 and auto-pair). The safe design is
> request → desktop-confirm → deliver. Branch release/1.1.3. SECURITY-SENSITIVE.

## Goal
A web client served by a Pyre desktop pairs WITHOUT the user typing host/port/token.
The web sends a pairing REQUEST; the desktop shows "Allow this browser to pair?
[Allow] [Deny]"; on Allow the web receives a bearer and syncs. Works for any
device (PC, phone). A malicious site can only make a dialog appear that the user
denies — it can never pair without an explicit Allow click.

## Protocol (3 new unauth endpoints on PyreServer; existing /pair stays unchanged)
All bodies capped (mirror the existing /pair 64KB cap). All return JSON.

1. `POST /pair/request`  body `{deviceName?, native?}`
   - Mint a random unguessable `requestId` (e.g. 256-bit, same generator as the
     bearer — NOT a v4 uuid; it doubles as the claim secret for /pair/poll).
   - Register a PENDING request: {requestId, deviceName, native, requesterLabel,
     createdAtMs, status:'pending'}. `requesterLabel` = the request's `Origin`
     header if present else the socket remote address (display only; NEVER trusted
     for auth).
   - Fire the `onPairRequest` UI callback (fire-and-forget; do NOT await it in the
     handler).
   - Return `{requestId, ttlMs}` immediately. NO bearer.
   - Rate-limit / cap: at most N (e.g. 5) concurrent pending requests; prune
     expired (TTL ~120s) on every call; if over the cap, return 429. This bounds
     the malicious-site dialog-spam DoS.

2. `GET /pair/poll?requestId=<id>`
   - Look up by requestId (constant-time compare, like redeemPairing). Unknown /
     expired → `{status:'expired'}` (do NOT distinguish unknown vs expired —
     avoids an oracle).
   - `pending` → `{status:'pending'}`.
   - `denied` → `{status:'denied'}` then drop it.
   - `approved` → `{status:'approved', deviceId, bearerToken}` exactly ONCE, then
     drop the pending entry (bearer delivered; never re-served). The bearer is the
     real 256-bit token; the server already stores only its hash (reuse the
     redeemPairing minting path).

3. (internal, not HTTP) `PyreServer.approvePairRequest(requestId)` /
   `denyPairRequest(requestId)` — called by the desktop dialog. approve mints the
   bearer + registers the PairedDevice (reuse DeviceRegistry minting; isNative from
   the request's `native` flag) and flips status→approved with the rawBearer held
   transiently for the next poll. deny flips status→denied.

## Security invariants (verifier will check ALL)
- NO bearer is ever minted before an explicit `approvePairRequest` (Allow click).
  /pair/request and /pair/poll(pending) never mint.
- `requestId` is cryptographically random + unguessable (256-bit), constant-time
  compared; it is the only thing that lets a client claim its bearer.
- DNS-rebinding-safe: a cross-origin / rebound site can trigger a request (→ a
  dialog the user denies) but cannot approve it. The Origin/remote addr is
  DISPLAY-ONLY, never an auth decision.
- The existing token flow (`/pair` + `issuePairingToken` + `redeemPairing`) is
  UNCHANGED — LAN/token pairing keeps working exactly as before.
- Pending requests + bearers held in memory only; TTL-expire; pending cap → 429.
- Bearer delivered at most once via poll, then the entry is dropped.

## Data structures
- A `PendingPairRequest` value type + an in-memory store. Put the pure lifecycle
  logic in a testable place (e.g. a `PairingRequests` class in device_registry.dart
  or a new pairing_requests.dart): create→pending, approve(id)→approved(+bearer),
  deny(id)→denied, poll(id)→status (consuming on approved/denied), pruneExpired,
  atCapacity. Keep it pure/injectable (pass `nowMs` + a bearer-mint fn) so it is
  unit-testable without HTTP/clock.

## Desktop UI (host only)
- Mirror `SyncEngine.instance.conflictPrompt` (main.dart:564): register
  `PyreServer.instance.onPairRequest = (req) async { ctx=_rootNavKey.currentContext;
  if (ctx==null) return; await showPairRequestDialog(ctx, req); }`.
- `showPairRequestDialog`: AlertDialog "Allow this device to pair?" + the
  requesterLabel + [Allow]/[Deny]. Allow → PyreServer.instance.approvePairRequest(id);
  Deny → denyPairRequest(id). Non-dismissible by tap-outside (explicit choice).
- Only fires on the host (the desktop running the server). Web/phone never see it.

## Web flow (lan_client + connect screen / web boot)
- `LanClient.requestPairingFromOrigin()` (web): derive origin host+port from
  `Uri.base`; POST /pair/request {deviceName:'Web tab', native:false}; then poll
  GET /pair/poll?requestId= every ~1.5s up to the TTL. On `approved` → store
  host/port/bearer (reuse the existing post-pair persistence) → notify → the
  SyncEngine pulls. On `denied`/`expired` → return a clear status for the UI.
- Connect screen (web): show a prominent "Pair with this PC (<origin>)" button
  that calls requestPairingFromOrigin() and shows "Waiting for approval on the
  PC…". Also prefill host/port from Uri.base for the manual path. Optional: the
  empty-library state on web shows the same CTA.
- Native (phone/desktop) path: unchanged (token). The request→confirm flow is
  also usable by the phone later but out of scope now (web-first).

## TDD targets (pure where possible)
- PairingRequests: create returns pending + unique id; poll(pending)=pending;
  approve→poll returns approved+bearer ONCE then expired; deny→poll denied once;
  expired after TTL; atCapacity→reject; unknown id = expired (no oracle);
  requestId distinct/long. Bearer mint fn called only on approve.
- Keep existing pairing/redeem tests green.

## Out of scope / follow-ups
- Phone using the confirm flow (still token) — fine.
- Persisting pending across restart — no (in-memory; a restart just needs re-request).
- S2 (bind 0.0.0.0 / plaintext HTTP) unchanged.
