// Wave CY.18.65: PyreServer skeleton — the HTTP listener that mobile
// + web clients connect to over LAN.
//
// This wave ships ONLY the framing + /pair endpoint. Subsequent waves
// add /pull (66), /push (66), /llm/stream (67), /attachments (67).
// Splitting it up this way means each wave can be verified in
// isolation: this one boots a server, accepts a pairing, hands out a
// bearer — but doesn't yet do anything useful with the bearer.
//
// Design notes:
//   - Server is OPT-IN. Default uiPref `lanServerEnabled = false`,
//     gated by a toggle in the Network settings screen (Wave 68).
//     Pyre never opens a port without an explicit user action.
//   - Desktop-only. Mobile builds compile the code but never call
//     `start()` (gated by `_supportsServer` below; throws if a
//     mobile build somehow tries).
//   - Auth + CORS are pipeline middlewares around the router so
//     adding a new endpoint in Wave 66+ doesn't have to re-implement
//     either.

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Directory, File, HttpServer, InternetAddress, Platform, SocketException;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import 'attachment_refs.dart';
import 'attachment_store.dart';
import 'bbx_utils.dart';
import 'chat_api.dart';
import 'device_registry.dart';
import 'key_crypto.dart';
import 'pairing_requests.dart';
import 'rate_limit.dart';
import 'regex_rules.dart';
import 'secure_keys.dart';
import 'sync_manifest.dart';

/// True only on platforms that can actually open a listener socket.
bool get _supportsServer {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Sync-B stage 3 (2026-07-17, Codex): the per-item apply outcome the hub
/// reports back for EVERY pushed record, so the client never mistakes a silent
/// omission (malformed/unknown) for "accepted" and drops the record forever.
/// Wire codes (in the /push `results` array) are the snake_case names below.
///   * [accepted]      — applied; the record now carries `serverMtime`.
///   * [superseded]    — the hub already holds an equal/newer copy (benign LWW
///                       loss; the client's next /pull reconciles).
///   * [tombstoned]    — suppressed by a hub tombstone at/after this version
///                       (the delete wins; benign).
///   * [immutable]     — a locked default (preset/creatorPreset) can't be
///                       overwritten via sync (benign).
///   * [policyRejected]— provider gate closed (opt-out / non-native peer).
///   * [invalidRecord] — malformed (non-Map / missing id / fromJson threw);
///                       re-sending won't help, so the client drops it.
///   * [unsupportedCollection] — the hub doesn't know this collection; the
///                       client DEFERS it (re-scan when the hub upgrades),
///                       rather than hold-looping every tick.
///   * [retryableError] — a TRANSIENT apply failure (keystore/registry I/O),
///                       NOT a malformed record. The client HOLDS and retries;
///                       classifying it as invalid_record would drop it forever.
enum _SyncApplyOutcome {
  accepted,
  superseded,
  tombstoned,
  immutable,
  policyRejected,
  invalidRecord,
  unsupportedCollection,
  retryableError,
}

/// Outcomes that force the client to HOLD its push cursor (retry) — the hub
/// could not durably take the item and a retry may succeed. Everything else is
/// terminal (advance). Kept next to the enum so the server's legacy-reason
/// mapping and the client's classification agree.
bool _outcomeHolds(_SyncApplyOutcome o) =>
    o == _SyncApplyOutcome.unsupportedCollection ||
    o == _SyncApplyOutcome.retryableError;

/// The stable wire string for a [_SyncApplyOutcome] (snake_case `code`).
String _outcomeCode(_SyncApplyOutcome o) {
  switch (o) {
    case _SyncApplyOutcome.accepted:
      return 'accepted';
    case _SyncApplyOutcome.superseded:
      return 'superseded';
    case _SyncApplyOutcome.tombstoned:
      return 'tombstoned';
    case _SyncApplyOutcome.immutable:
      return 'immutable_record';
    case _SyncApplyOutcome.policyRejected:
      return 'policy_rejected';
    case _SyncApplyOutcome.invalidRecord:
      return 'invalid_record';
    case _SyncApplyOutcome.unsupportedCollection:
      return 'unsupported_collection';
    case _SyncApplyOutcome.retryableError:
      return 'retryable_error';
  }
}

/// Blocker 3 (Codex review): pull a FUTURE-clock mtime back to the hub clock
/// before apply. v2 restamping used to preserve a wildly-future incoming mtime
/// verbatim, but load() still clamps future records to wall-clock on restart —
/// demoting the stored copy below the (still-high) counter and hiding it from
/// peers. Clamping on the way in keeps the stored mtime `<= serverNow` so the
/// restart-time clamp is a no-op. A backward-clock mtime (`<= serverNow`) is
/// untouched here; the restamp lifts it up separately.
int clampFutureMtime(int incoming, int serverNow) =>
    incoming > serverNow ? serverNow : incoming;

/// The record collections the hub's /push understands. A collection outside this
/// set (a newer client pushing a record type an older hub lacks) is reported as
/// `unsupported_collection` instead of being silently rejected as "server newer".
const Set<String> _knownPushCollections = {
  'characters',
  'personas',
  'chats',
  'presets',
  'lorebooks',
  'regexRules',
  'folders',
  'creatorPresets',
  'providers',
};

/// Wave CY.18.260: pure gate for whether encrypted provider records may be
/// emitted to (or accepted from) a peer. Providers carry the API key (as an
/// encrypted envelope), so this is deliberately fail-closed on BOTH axes:
///   * [flag] = the host's opt-in (`uiPrefs.syncProviderKeys`, default false);
///   * [isNative] = the peer is a paired native device (web is never native, so
///     it never receives or pushes providers — it keeps proxying via /llm/stream).
/// Either being false ⇒ no providers exchanged. Top-level + pure so it is
/// unit-testable without a running server.
bool shouldSyncProviders(bool flag, bool isNative) => flag && isNative;

/// Bind options for [PyreServer.start].
enum BindMode {
  /// Loopback only — useful when the user wants the server alive but
  /// not visible to other devices (e.g. testing local web build
  /// against own machine).
  localhostOnly,

  /// Accept connections from any interface — every device on the LAN
  /// can reach the server. Required for the phone-on-Wi-Fi case.
  /// Default in the UI.
  entireLan,
}

class PyreServer {
  PyreServer._();
  static final PyreServer instance = PyreServer._();

  HttpServer? _http;
  int? _port;
  BindMode? _bind;
  AppStore? _store;

  // ── v2 secure bbx: dedicated bbx server on a SEPARATE port ───────────────
  // The iframe loads botbooru from this origin → cross-origin with the Pyre
  // web app (mainPort) → botbooru JS cannot read the Pyre app's localStorage.
  // The main server (_http / _port) has NO botbooru proxy route at all.
  HttpServer? _bbxHttp;
  int? _bbxPort;

  // ── Wave CY.18.110 (audit S1): per-device throttling of the LLM
  // proxy. Both maps are keyed by the paired device's stable id
  // (PairedDevice.id), so each remote device gets its own independent
  // budget — one device hammering the proxy can never starve another,
  // and the desktop's own LLM calls (which never traverse /llm/stream)
  // are untouched. These live on the singleton for the listener's
  // lifetime and are cleared in stop(); the request hot path is
  // single-threaded in Dart so plain maps need no locking.
  final Map<String, RateBucket> _llmBuckets = {};
  final Map<String, int> _llmInFlight = {};

  // ── Desktop-confirmation web pairing (release/1.1.3) ──────────────────
  // In-memory store for pending pair requests. The bearer mint function
  // delegates to a Random.secure() + base64url path identical to
  // DeviceRegistry._generateBearerToken. Lives on the singleton so it
  // survives across HTTP requests; the PairingRequests store is not cleared
  // on stop() — pending requests expire via TTL regardless.
  //
  // approvePairRequest / denyPairRequest are called by the desktop dialog
  // (showPairRequestDialog) after the user taps Allow / Deny.
  //
  // onPairRequest is registered by main.dart (mirrors conflictPrompt) and
  // fires fire-and-forget from the /pair/request handler so it never blocks
  // the HTTP response.
  late final PairingRequests _pairingRequests = PairingRequests(
    mintBearer: _mintPairBearer,
  );

  /// Desktop dialog callback. Registered in main.dart, invoked fire-and-
  /// forget when a new /pair/request arrives. The callback receives the
  /// [PendingPairRequest] and should call [approvePairRequest] /
  /// [denyPairRequest] after the user responds.
  Future<void> Function(PendingPairRequest req)? onPairRequest;

  /// Called by the desktop dialog's Allow button. Mints the bearer, registers
  /// the PairedDevice in DeviceRegistry, and sets status→approved so the next
  /// /pair/poll delivers the bearer to the web client. Returns true on success.
  Future<bool> approvePairRequest(String requestId) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Need deviceName + native before approve() drops the pending state.
    final req = _pairingRequests.findById(requestId);
    if (req == null) return false;
    final deviceName = req.deviceName;
    final isNative = req.native;

    final result = _pairingRequests.approve(requestId, nowMs: nowMs);
    if (result == null) return false;

    // Register the PairedDevice so subsequent /pull /push /llm/stream
    // calls can authenticate with the bearer that was just minted.
    await DeviceRegistry.instance.registerApprovedPair(
      deviceId: result.deviceId,
      rawBearer: result.bearer,
      deviceName: deviceName,
      isNative: isNative,
    );
    return true;
  }

  /// Called by the desktop dialog's Deny button.
  bool denyPairRequest(String requestId) =>
      _pairingRequests.deny(requestId);

  /// Bearer generator for confirm-pair requests. Same entropy as
  /// DeviceRegistry._generateBearerToken (32 bytes Random.secure(),
  /// base64url no padding = 43 chars). Instance method so it can be passed
  /// as a tear-off to PairingRequests constructor.
  static String _mintPairBearer() {
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  bool get running => _http != null;
  int? get port => _port;
  BindMode? get bindMode => _bind;

  /// Bind + start. Throws StateError on unsupported platforms — the
  /// UI gates the toggle on `_supportsServer` so this should never
  /// fire in practice. Returns the bound port (useful when the caller
  /// passed 0 and wants the kernel-assigned ephemeral port).
  ///
  /// Wave CY.18.66: `store` is required so /pull and /push can read
  /// from + write to the canonical AppStore. The server holds a
  /// reference for the lifetime of the listener; stop() drops it.
  Future<int> start({
    required int port,
    required BindMode bind,
    required AppStore store,
  }) async {
    if (!_supportsServer) {
      throw StateError('PyreServer is desktop-only');
    }
    if (_http != null) {
      throw StateError('PyreServer already running on port $_port');
    }
    final address = bind == BindMode.localhostOnly
        ? InternetAddress.loopbackIPv4
        : InternetAddress.anyIPv4;

    _store = store;

    // Wave CY.18.76: self-host the Flutter web build. If a `web/`
    // folder sits next to the running pyre.exe (or next to the
    // Dart entrypoint in dev), serve its files as a fallback after
    // the API router. That way a browser hitting
    // `http://<pc>:<port>/` loads index.html → the JS bootstraps
    // the same web client that would otherwise need separate
    // hosting. If the folder doesn't exist (e.g. user didn't copy
    // build/web/ next to the .exe), the static handler returns
    // 404s and the user just sees the JSON health check at
    // /healthz instead.
    Handler? staticHandler;
    final webDir = _findWebBuildDir();
    if (webDir != null) {
      staticHandler = createStaticHandler(
        webDir,
        defaultDocument: 'index.html',
        // SPA-style: unknown paths fall through to index.html so the
        // Flutter web router (if Pyre ever adopts named routes)
        // doesn't 404 on a refresh of a deep link.
        listDirectories: false,
      );
      debugPrint('[PyreServer] serving web build from $webDir');
    } else {
      debugPrint('[PyreServer] no web/ folder found next to exe — '
          'web client must be hosted separately');
    }

    // Pipeline order: CORS → auth → (router OR static fallback).
    // The router responds to API routes (/pair, /pull, /push, etc).
    // Anything it doesn't match returns 404 from shelf_router; the
    // Cascade catches that 404 and tries the static handler next.
    final apiPipeline = const Pipeline()
        .addMiddleware(_corsMiddleware)
        .addMiddleware(_authMiddleware)
        .addHandler(_router.call);
    final handler = staticHandler == null
        ? apiPipeline
        : Cascade().add(apiPipeline).add(staticHandler).handler;

    try {
      _http = await shelf_io.serve(handler, address, port);
    } on SocketException catch (e) {
      // Wave CY.18.73: translate the locale-dependent OS error message
      // into a friendly + actionable one. The raw exception's
      // `osError.errorCode` is platform-independent so we can branch
      // on it cleanly. Keeps the raw text in debugPrint for diags;
      // throws a plain Exception with our localised string so the UI
      // snackbar reads the same in PT-BR, en-US, ja-JP, etc.
      _store = null;
      debugPrint('[PyreServer] raw OS error: ${e.osError} for port $port');
      throw Exception(_friendlySocketError(e, port));
    }
    _port = _http!.port;
    _bind = bind;
    debugPrint('[PyreServer] listening on $address:$_port (bind=$bind)');

    // v2 secure bbx: bind the dedicated bbx server on a SEPARATE port.
    // Try mainPort+1 first; if taken (SocketException), fall back to
    // ephemeral port 0 (kernel assigns). The bbx handler has NO auth
    // middleware — it only proxies botbooru.com with CORS for mainPort.
    final bbxHandler = const Pipeline().addHandler(_bbxRouter.call);
    try {
      _bbxHttp = await shelf_io.serve(bbxHandler, address, _port! + 1);
    } on SocketException {
      // Port+1 is taken → let the kernel pick an ephemeral port.
      try {
        _bbxHttp = await shelf_io.serve(bbxHandler, address, 0);
      } catch (e) {
        // Non-fatal: bbx embed won't work but the rest of Pyre is fine.
        debugPrint('[PyreServer] bbx server failed to bind: $e');
        _bbxHttp = null;
      }
    } catch (e) {
      debugPrint('[PyreServer] bbx server failed to bind: $e');
      _bbxHttp = null;
    }
    _bbxPort = _bbxHttp?.port;
    if (_bbxHttp != null) {
      // CRITICAL for the embed: Dart's HttpServer.defaultResponseHeaders adds
      // `X-Frame-Options: SAMEORIGIN` to EVERY response by default — which makes
      // the browser refuse to render the bbx origin in the Pyre web app's
      // iframe (the proxy already drops botbooru's own XFO; this is Dart's). Clear
      // it so the cross-origin iframe can load. (The main server keeps its XFO —
      // we never want the Pyre app itself framed.)
      _bbxHttp!.defaultResponseHeaders.removeAll('x-frame-options');
      debugPrint('[PyreServer] bbx server on $address:$_bbxPort');
    }

    // Wave CY.18.72: opportunistic orphan-attachment GC. The desktop
    // is the only place where the attachment store lives, so this is
    // also the only place GC needs to run. Fire-and-forget — even on
    // a libraries with hundreds of avatars the scan is sub-second,
    // but we still don't want to block the server's first request.
    unawaited(_runAttachmentGc(store));

    return _port!;
  }

  /// Wave CY.18.72: collect every `pyre://attachment/<hash>` URL
  /// referenced by any synced record on disk, then ask the
  /// AttachmentStore to delete any file NOT in that set. Conservative
  /// — if any record mentions a hash, the file stays.
  ///
  /// Wave CY.18.127: the reference collection now lives in the shared
  /// `collectReferencedAttachmentHashes` (so this GC and the once-per-
  /// launch local sweep in AppStore.load() can never drift), and it
  /// covers character + persona galleries on top of avatars + chat bg.
  Future<void> _runAttachmentGc(AppStore store) async {
    final referenced = collectReferencedAttachmentHashes(store);
    try {
      final removed = await AttachmentStore.gcOrphans(referenced);
      if (removed > 0) {
        debugPrint('[PyreServer] attachment GC removed $removed orphans');
      }
    } catch (e) {
      debugPrint('[PyreServer] attachment GC failed: $e');
    }
  }

  Future<void> stop() async {
    final h = _http;
    if (h == null) return;
    _http = null;
    _port = null;
    _bind = null;
    _store = null;
    // Wave CY.18.110: drop per-device throttle state so a fresh start
    // begins with full buckets and zero in-flight counts.
    _llmBuckets.clear();
    _llmInFlight.clear();
    try {
      await h.close(force: false);
    } catch (e) {
      debugPrint('[PyreServer] stop failed: $e');
    }
    // v2: also close the dedicated bbx server.
    final bbx = _bbxHttp;
    _bbxHttp = null;
    _bbxPort = null;
    if (bbx != null) {
      try {
        await bbx.close(force: false);
      } catch (e) {
        debugPrint('[PyreServer] bbx stop failed: $e');
      }
    }
  }

  // ---------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------

  Router get _router {
    final r = Router();

    // POST /pair — redeem a pairing token, return a bearer. The auth
    // middleware below explicitly skips this path.
    r.post('/pair', (Request req) async {
      try {
        // N2 audit 2026-06-15: /pair is UNAUTHENTICATED — the cheapest pre-auth
        // DoS surface. A pairing request body carries only a token + device name;
        // 64 KB is a generous ceiling. Same declared-Content-Length + mid-stream
        // abort pattern as /push and /attachments.
        const maxPairBodyBytes = 64 * 1024; // 64 KB
        final declaredPairLen =
            int.tryParse(req.headers['content-length'] ?? '');
        if (declaredPairLen != null && declaredPairLen > maxPairBodyBytes) {
          return Response(413, body: '{"error":"request body too large"}');
        }
        final pairBuf = <int>[];
        await for (final chunk in req.read()) {
          pairBuf.addAll(chunk);
          if (pairBuf.length > maxPairBodyBytes) {
            return Response(413, body: '{"error":"request body too large"}');
          }
        }
        final body = utf8.decode(pairBuf, allowMalformed: true);
        final json = body.isEmpty ? const {} : jsonDecode(body);
        if (json is! Map) {
          return Response(400, body: '{"error":"invalid body"}');
        }
        final token = (json['pairingToken'] as String?)?.trim() ?? '';
        final name = (json['deviceName'] as String?)?.trim() ?? '';
        // Wave CY.18.259: the client declares whether it's a NATIVE peer
        // (mobile/desktop) here. Absent ⇒ false (fail-closed) so a web
        // client never gets the native flag and is excluded from key-sync.
        final native = (json['native'] as bool?) ?? false;
        if (token.isEmpty) {
          return Response(400, body: '{"error":"missing pairingToken"}');
        }
        final device = await DeviceRegistry.instance.redeemPairing(
            pairingToken: token, deviceName: name, isNative: native);
        if (device == null) {
          return Response(401,
              body: '{"error":"pairing token invalid or expired"}');
        }
        // Wave CY.18.255 (audit FIX 2): the server persists only a hash of
        // the bearer; the RAW token lives on `device.rawBearer` solely at
        // this freshly-minted moment, so this is the one place it's handed
        // to the client (which keeps it). It's null for any reloaded
        // record, but redeemPairing always returns a just-minted device.
        return Response.ok(
          jsonEncode({
            'deviceId': device.id,
            'bearerToken': device.rawBearer,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        debugPrint('[PyreServer] /pair failed: $e');
        return Response.internalServerError(
            body: '{"error":"server error"}');
      }
    });

    // ── Desktop-confirmation web pairing (release/1.1.3) ─────────────────
    //
    // POST /pair/request — web client registers a pending pair request.
    // Auth-skipped (same as /pair): a web client can't auth before pairing.
    // Body: {deviceName?, native?}
    // Returns: {requestId, ttlMs}  or 429 if at capacity.
    // Fires onPairRequest fire-and-forget (never blocks the response).
    //
    // Security: requestId is 256-bit random — the ONLY secret that lets the
    // client claim its bearer. Origin/remote addr are display-only.
    r.post('/pair/request', (Request req) async {
      try {
        const maxBodyBytes = 64 * 1024; // 64 KB (same as /pair)
        final declaredLen =
            int.tryParse(req.headers['content-length'] ?? '');
        if (declaredLen != null && declaredLen > maxBodyBytes) {
          return Response(413, body: '{"error":"request body too large"}');
        }
        final buf = <int>[];
        await for (final chunk in req.read()) {
          buf.addAll(chunk);
          if (buf.length > maxBodyBytes) {
            return Response(413, body: '{"error":"request body too large"}');
          }
        }
        Map<String, dynamic> body;
        try {
          final raw = utf8.decode(buf, allowMalformed: true);
          body = raw.isEmpty
              ? const {}
              : (jsonDecode(raw) as Map<String, dynamic>? ?? const {});
        } catch (_) {
          body = const {};
        }

        final nowMs = DateTime.now().millisecondsSinceEpoch;

        // Prune expired entries and enforce cap BEFORE creating new entry.
        if (_pairingRequests.atCapacity(nowMs: nowMs)) {
          return Response(
            429,
            body: '{"error":"too_many_pending","detail":'
                '"Too many pending pair requests — try again shortly."}',
            headers: {
              'content-type': 'application/json',
              'retry-after': '5',
            },
          );
        }

        // requesterLabel = Origin header if present, else peer address.
        // DISPLAY-ONLY — never used for auth decisions (DNS-rebinding-safe).
        final origin = req.headers['origin'] ?? '';
        final remote = req.context['shelf.io.connection_info'] != null
            ? (req.context['shelf.io.connection_info']
                    as dynamic) // HttpConnectionInfo
                .remoteAddress
                .toString()
            : '';
        final requesterLabel =
            origin.isNotEmpty ? origin : (remote.isNotEmpty ? remote : 'unknown');

        final deviceName =
            (body['deviceName'] as String?)?.trim() ?? 'Web tab';
        final native = (body['native'] as bool?) ?? false;

        final pendingReq = _pairingRequests.create(
          deviceName: deviceName,
          native: native,
          requesterLabel: requesterLabel,
          nowMs: nowMs,
        );

        // Fire UI callback fire-and-forget — do NOT await in the handler so
        // the 200 response returns immediately.
        final cb = onPairRequest;
        if (cb != null) {
          unawaited(cb(pendingReq).catchError(
            (e) => debugPrint('[PyreServer] onPairRequest callback error: $e'),
          ));
        }

        return Response.ok(
          jsonEncode({
            'requestId': pendingReq.requestId,
            'ttlMs': _pairingRequests.ttlMs,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        debugPrint('[PyreServer] POST /pair/request failed: $e');
        return Response.internalServerError(body: '{"error":"server error"}');
      }
    });

    // GET /pair/poll?requestId=<id>
    // Web client polls for the result of its pending request.
    //
    // Auth-skipped: the requestId IS the secret; only the holder can claim
    // their bearer. Unknown id → expired (no oracle so attacker learns nothing).
    // Approved: delivers bearer ONCE then drops the entry (bearer never re-served).
    // Denied: delivers status once then drops.
    r.get('/pair/poll', (Request req) async {
      try {
        final requestId =
            (req.url.queryParameters['requestId'] ?? '').trim();
        if (requestId.isEmpty) {
          return Response(400,
              body: '{"error":"missing requestId query parameter"}',
              headers: {'content-type': 'application/json'});
        }

        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final result = _pairingRequests.poll(requestId, nowMs: nowMs);

        switch (result.status) {
          case PairStatus.pending:
            return Response.ok(
              jsonEncode({'status': 'pending'}),
              headers: {'content-type': 'application/json'},
            );
          case PairStatus.approved:
            // Deliver bearer exactly once — entry is now dropped.
            return Response.ok(
              jsonEncode({
                'status': 'approved',
                'deviceId': result.deviceId,
                'bearerToken': result.bearer,
              }),
              headers: {'content-type': 'application/json'},
            );
          case PairStatus.denied:
            return Response.ok(
              jsonEncode({'status': 'denied'}),
              headers: {'content-type': 'application/json'},
            );
          case PairStatus.expired:
            return Response.ok(
              jsonEncode({'status': 'expired'}),
              headers: {'content-type': 'application/json'},
            );
        }
      } catch (e) {
        debugPrint('[PyreServer] GET /pair/poll failed: $e');
        return Response.internalServerError(body: '{"error":"server error"}');
      }
    });

    // GET /healthz — tiny health check so the desktop UI / mobile
    // client can sniff "server alive" without crafting a full sync
    // request. Wave CY.18.76: moved from `/` to `/healthz` so the
    // root path is free for the self-hosted web build's index.html.
    r.get('/healthz', (Request req) {
      return Response.ok(
        jsonEncode({'service': 'pyre', 'version': 1}),
        headers: {'content-type': 'application/json'},
      );
    });

    // SYNC W6 (verification): GET /manifest
    // Read-only. Returns a per-collection fingerprint of THIS server's library
    // — `{collections: {name: {count, digest}}}` — computed via the shared
    // buildSyncManifest. The phone fetches it, builds its OWN manifest the same
    // way, and diffs the two so the user can CONFIRM both sides converged after
    // a sync (the "there should be a hash to compare the two versions" ask).
    // Never mutates anything; the digest is over id+mtime only (no API keys,
    // no content), so it leaks nothing beyond what /pull already exposes.
    r.get('/manifest', (Request req) {
      final store = _store;
      if (store == null) {
        return Response.internalServerError(body: '{"error":"no store"}');
      }
      final manifest = buildSyncManifest(store);
      final collections = <String, dynamic>{
        for (final e in manifest.entries) e.key: e.value.toJson(),
      };
      return Response.ok(
        jsonEncode({'collections': collections}),
        headers: {'content-type': 'application/json'},
      );
    });

    // Wave CY.18.66: GET /pull?since=<ms>&collections=<csv>
    // Returns every synced record with mtime > since, grouped by
    // collection. Clients persist response.serverTime as their next
    // `since` to avoid clock skew.
    r.get('/pull', (Request req) async {
      final store = _store;
      if (store == null) {
        return Response.internalServerError(body: '{"error":"no store"}');
      }
      // Wave CY.18.260: read the authenticated peer null-safely (mirrors the
      // /llm/stream read). The auth middleware stashes the resolved device, but
      // we stay defensive: a missing device fails the provider gate closed.
      final device = req.context['pyreDevice'] as PairedDevice?;
      final sinceStr = req.url.queryParameters['since'] ?? '0';
      final since = int.tryParse(sinceStr) ?? 0;
      final collectionsParam = req.url.queryParameters['collections'];
      final wanted = collectionsParam == null || collectionsParam.isEmpty
          ? _allCollections
          : collectionsParam
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toSet();

      // Sync-B stage 4 (2026-07-17, Codex): serverTime is the hub's LOGICAL
      // high-water — `store.lastIssuedLocalMtime`, NOT a wall clock. Every
      // record the hub holds has `mtime <= lastIssuedLocalMtime` (the stage-1
      // load rebase + every accept's observeSyncMtime keep it a true
      // high-water), so a client that adopts this as its next `since` sees
      // exactly this snapshot and nothing re-appears next pull (no churn). The
      // old wall-clock stamp could sit BELOW a hub-restamped record's mtime,
      // which would then re-ship on every pull. We do NOT mint a new mtime here
      // (an empty pull must not advance the clock — that would be pure churn);
      // we only READ the counter. The S-BUG2 stamp-before-select discipline
      // still holds: any record written after this read gets a strictly higher
      // mtime and is caught on the next pull (since == this serverTime).
      final serverTime = store.lastIssuedLocalMtime;

      final updates = <String, List<Map<String, dynamic>>>{};

      if (wanted.contains('characters')) {
        updates['characters'] = store.characters
            .where((c) => c.mtime > since)
            .map((c) => c.toJson())
            .toList();
      }
      if (wanted.contains('personas')) {
        updates['personas'] = store.personas
            .where((p) => p.mtime > since)
            .map((p) => p.toJson())
            .toList();
      }
      if (wanted.contains('chats')) {
        // Chats sync whole — including their inline messages + memory
        // checkpoints. Per-message granularity within a chat is a Wave
        // 70+ optimisation if we hit payload-size issues in practice.
        updates['chats'] = store.chats
            .where((ch) => ch.mtime > since)
            .map((ch) => ch.toJson())
            .toList();
      }
      if (wanted.contains('presets')) {
        updates['presets'] = store.presets
            .where((p) => p.mtime > since && !p.locked)
            .map((p) => p.toJson())
            .toList();
        // Note: locked default preset is refreshed-from-build on each
        // load, so syncing it would just create churn. Skipped.
      }
      if (wanted.contains('lorebooks')) {
        updates['lorebooks'] = store.lorebooks
            .where((l) => l.mtime > since)
            .map((l) => l.toJson())
            .toList();
      }
      // Pyre 1.1 (F4): regex find/replace rules.
      if (wanted.contains('regexRules')) {
        updates['regexRules'] = store.regexRules
            .where((r) => r.mtime > since)
            .map((r) => r.toJson())
            .toList();
      }
      // Mega-audit 2026-06-05 (F2): library folders.
      if (wanted.contains('folders')) {
        updates['folders'] = store.folders
            .where((f) => f.mtime > since)
            .map((f) => f.toJson())
            .toList();
      }
      // Mega-audit 2026-06-05 (F2): forkable Creator presets — locked default
      // excluded (rebuilt-from-build on every load), same as locked Preset.
      if (wanted.contains('creatorPresets')) {
        updates['creatorPresets'] = store.creatorPresets
            .where((p) => p.mtime > since && !p.locked)
            .map((p) => p.toJson())
            .toList();
      }

      // Wave CY.18.260: providers carry the API key (as an encrypted
      // envelope), so they only ride the pull when the host opted in AND the
      // peer is native (web is never native → never receives keys; it proxies
      // via /llm/stream). The key is encrypted per-recipient using THIS
      // device's bearer-hash-derived secret — both peers can derive the same
      // secret from the shared pairing bearer, but a captured payload can't be
      // decrypted without it. An empty-keyed provider emits config + no
      // apiKeyEnc (see ApiProvider.toJsonEncrypted).
      if (wanted.contains('providers') &&
          shouldSyncProviders(
              store.uiPrefs.syncProviderKeys, device?.isNative == true) &&
          device != null) {
        final secret = await DeviceRegistry.instance.secretForDevice(device);
        final out = <Map<String, dynamic>>[];
        for (final p in store.providers) {
          if (p.mtime > since) {
            out.add(await p.toJsonEncrypted(secret));
          }
        }
        updates['providers'] = out;
      }

      // SYNC W3: the settings UNIT — a single record under `settingsMtime`.
      // Ship it only when ours is newer than the puller's watermark (same
      // `mtime > since` gate as every collection). The record carries no `id`
      // (it's a singleton) and excludes the chat background image.
      if (wanted.contains('settings') && store.settingsMtime > since) {
        // 1.1.2: the provider-role pointers (active/creator/vision) are
        // device-local. A web (non-native) peer has a DIFFERENT provider list,
        // so shipping the pointer would clobber its selection — strip them for
        // non-native peers. Native peers (which also receive the provider
        // objects) keep them.
        final rec = store.syncedSettingsToJson();
        updates['settings'] = [
          device?.isNative == true ? rec : withoutProviderRolePointers(rec),
        ];
      }

      // The BotBooru PROFILE unit — a single record under `botbooruProfileMtime`
      // (same `mtime > since` gate + no-`id` singleton shape as `settings`).
      if (wanted.contains('botbooruProfile') &&
          store.botbooruProfileMtime > since) {
        updates['botbooruProfile'] = [store.syncedBotbooruProfileToJson()];
      }

      // Wave CY.18.256: ship deletion tombstones recorded after `since` so
      // the client learns about deletes that happened on this server (or
      // were pushed here by another peer) and reaps its own live copies.
      // Always included (additive): an old client ignores the key.
      final tombstones = <String, int>{};
      store.tombstones.forEach((key, mtime) {
        if (mtime > since) tombstones[key] = mtime;
      });

      final body = {
        'serverTime': serverTime, // captured BEFORE selection — see S-BUG2 comment above
        'serverAppVersion': _serverAppVersion,
        'updates': updates,
        'tombstones': tombstones,
      };
      return Response.ok(
        jsonEncode(body),
        headers: {'content-type': 'application/json'},
      );
    });

    // Wave CY.18.66: POST /push { updates: {collection: [records...]} }
    // Applies each record only if its mtime is strictly greater than
    // the local copy's. Rejected records (server has newer) come back
    // so the client knows to fetch fresh on the next /pull.
    r.post('/push', (Request req) async {
      final store = _store;
      if (store == null) {
        return Response.internalServerError(body: '{"error":"no store"}');
      }
      // Wave CY.18.260: the authenticated peer — needed by _applyOne to gate
      // (and decrypt) pushed provider records. Read null-safely; a missing
      // device fails the provider gate closed. All other collections ignore it.
      final device = req.context['pyreDevice'] as PairedDevice?;
      try {
        // Mega-audit 2026-06-05 (M-12): cap the /push body. Previously this
        // was an unbounded `readAsString()`, so a paired device could send a
        // multi-GB body and OOM the host (the whole body is buffered in
        // memory before jsonDecode). A push carries a delta of the library
        // (chats + characters + lorebooks etc.), which can be large for a
        // big library, so the cap is generous — 128 MB, double the
        // /attachments image ceiling — comfortably above any legitimate
        // sync delta while still bounding the DoS. Reject early on a
        // declared Content-Length and abort mid-stream if it lies.
        const maxPushBytes = 128 * 1024 * 1024; // 128 MB
        final declaredLen = int.tryParse(req.headers['content-length'] ?? '');
        if (declaredLen != null && declaredLen > maxPushBytes) {
          return Response(413, body: '{"error":"push body too large"}');
        }
        final buf = <int>[];
        await for (final chunk in req.read()) {
          buf.addAll(chunk);
          if (buf.length > maxPushBytes) {
            return Response(413, body: '{"error":"push body too large"}');
          }
        }
        final body = utf8.decode(buf, allowMalformed: true);
        final json = body.isEmpty ? const {} : jsonDecode(body);
        if (json is! Map) {
          return Response(400, body: '{"error":"invalid body"}');
        }
        final updates = json['updates'];
        if (updates is! Map) {
          return Response(400, body: '{"error":"missing updates"}');
        }

        // Sync-B stage 3 (2026-07-17, Codex): the client advertises the
        // protocol it speaks in the push body. v2 clients get an exhaustive
        // per-item `results` array (one honest outcome per pushed record) so a
        // silent omission can never masquerade as "accepted". v1 (legacy)
        // clients only read `accepted`/`rejected`, so we KEEP emitting a benign
        // `reason:"server has newer mtime"` for every non-accepted item — that
        // string is exactly what the old client treats as a soft loss it can
        // advance past.
        final protocol = (json['syncProtocol'] as num?)?.toInt() ?? 1;
        final v2 = protocol >= 2;

        var accepted = 0;
        final rejected = <Map<String, dynamic>>[];
        final results = <Map<String, dynamic>>[];
        // Stage 5: only a state change requires a synchronous persist before the
        // 200. Set on any accept, on a tombstone change/reap, AND on an
        // equal-version superseded (a retry after a failed persist — the record
        // is in memory but maybe not on disk, so persist again rather than 200
        // it away).
        var needsPersist = false;

        // Records one honest outcome for a pushed item. Appends the v2 result
        // AND (for non-accepted) the legacy benign-reject entry old clients need.
        void record({
          String? id,
          int? index,
          required String collection,
          required _SyncApplyOutcome outcome,
          int? clientMtime,
          int? serverMtime,
        }) {
          results.add({
            'collection': collection,
            'id': ?id,
            if (id == null && index != null) 'index': index,
            'code': _outcomeCode(outcome),
            'clientMtime': ?clientMtime,
            'serverMtime': ?serverMtime,
          });
          if (outcome != _SyncApplyOutcome.accepted) {
            rejected.add({
              'id': ?id,
              'collection': collection,
              // Legacy contract: a v1 client advances only on this exact
              // string. Emit it for BENIGN terminal losses (superseded /
              // tombstoned / immutable / policy / invalid) so old clients
              // advance; for HOLD outcomes (unsupported / retryable) emit a
              // DIFFERENT reason so a v1 client also holds and retries.
              'reason': _outcomeHolds(outcome)
                  ? 'retry: ${_outcomeCode(outcome)}'
                  : 'server has newer mtime',
              if (v2) 'code': _outcomeCode(outcome),
            });
          }
        }

        // Wave CY.18.255 (FIX 5): the v1 future-clock clamp — pull a record
        // whose (ahead) clock outran serverNow back down so it can't sit above
        // the /pull watermark and be skipped. v2 replaces this with hub
        // re-stamping (see _acceptedRevision), so the clamp is v1-only now.
        final serverNow = DateTime.now().millisecondsSinceEpoch;

        // Stage 4 helper: restamp a WINNING singleton (settings/profile) to a
        // hub-monotonic revision so peers see it even under a rolled-back
        // pusher clock. Only called on v2 + a win; mutates m['mtime'] in place.
        void restampSingletonIfWin(Map<String, dynamic> m, int incoming, int localMtime) {
          if (!v2 || incoming <= localMtime) return;
          final floor = store.lastIssuedLocalMtime;
          m['mtime'] = incoming > floor ? incoming : store.nextSyncMtimeAfter(floor);
        }

        for (final entry in updates.entries) {
          final collection = entry.key.toString();
          final list = entry.value;
          if (list is! List) {
            // Malformed collection payload (not a list). One invalid result for
            // the whole entry — never a silent skip.
            record(collection: collection, index: 0,
                outcome: _SyncApplyOutcome.invalidRecord);
            continue;
          }
          final isSingleton =
              collection == 'settings' || collection == 'botbooruProfile';
          final known = _knownPushCollections.contains(collection);
          for (var index = 0; index < list.length; index++) {
            final raw = list[index];
            // Audit 2026-06-04 (H1): per-record isolation. A single poison
            // record must NOT 500 the whole batch (that wedges the pusher's
            // sync forever). The client SyncEngine already isolates per record;
            // mirror that here — but REPORT the failure instead of dropping it.
            try {
              if (raw is! Map) {
                record(index: index, collection: collection,
                    outcome: _SyncApplyOutcome.invalidRecord);
                continue;
              }
              final m = raw.cast<String, dynamic>();

              // Unknown collection (a newer client pushing a record type this
              // hub lacks). Report `unsupported_collection` — the client defers
              // it (re-scan on hub upgrade) instead of us lying "server newer".
              if (!isSingleton && !known) {
                final uid = m['id'] as String?;
                record(id: uid, index: index, collection: collection,
                    outcome: _SyncApplyOutcome.unsupportedCollection,
                    clientMtime: (m['mtime'] as num?)?.toInt());
                continue;
              }

              // SYNC W3: the settings UNIT is a SINGLETON with no `id`. Apply
              // under LWW; v2 restamps a win to a hub revision, v1 clamps a
              // future clock.
              if (collection == 'settings') {
                var cM = (m['mtime'] as num?)?.toInt() ?? 0;
                final before = store.settingsMtime;
                // Blocker 3 (r2): future-clamp is v1-only; v2 compares the
                // ORIGINAL mtime under LWW and restamps a backward win up.
                if (v2) {
                  restampSingletonIfWin(m, cM, before);
                } else if (cM > serverNow) {
                  cM = clampFutureMtime(cM, serverNow);
                  m['mtime'] = cM;
                }
                // 1.1.2: strip a non-native (web) peer's provider-role pointers
                // — they index its own provider list and would clobber ours.
                store.applySyncedSettings(
                  device?.isNative == true ? m : withoutProviderRolePointers(m),
                );
                if (store.settingsMtime != before) {
                  accepted++;
                  needsPersist = true;
                  record(index: index, collection: 'settings',
                      outcome: _SyncApplyOutcome.accepted,
                      clientMtime: cM, serverMtime: store.settingsMtime);
                } else {
                  // Superseded: no state change → no notify. The blocker-1
                  // unconditional flush (any non-empty push) covers the
                  // restamp-retry durability case.
                  record(index: index, collection: 'settings',
                      outcome: _SyncApplyOutcome.superseded,
                      clientMtime: cM, serverMtime: store.settingsMtime);
                }
                continue;
              }
              // The BotBooru PROFILE unit — same singleton shape as settings.
              if (collection == 'botbooruProfile') {
                var cM = (m['mtime'] as num?)?.toInt() ?? 0;
                final before = store.botbooruProfileMtime;
                if (v2) {
                  restampSingletonIfWin(m, cM, before);
                } else if (cM > serverNow) {
                  cM = clampFutureMtime(cM, serverNow);
                  m['mtime'] = cM;
                }
                store.applySyncedBotbooruProfile(m);
                if (store.botbooruProfileMtime != before) {
                  accepted++;
                  needsPersist = true;
                  record(index: index, collection: 'botbooruProfile',
                      outcome: _SyncApplyOutcome.accepted,
                      clientMtime: cM, serverMtime: store.botbooruProfileMtime);
                } else {
                  record(index: index, collection: 'botbooruProfile',
                      outcome: _SyncApplyOutcome.superseded,
                      clientMtime: cM, serverMtime: store.botbooruProfileMtime);
                }
                continue;
              }

              final id = m['id'] as String?;
              if (id == null) {
                record(index: index, collection: collection,
                    outcome: _SyncApplyOutcome.invalidRecord);
                continue;
              }
              var incomingMtime = (m['mtime'] as num?)?.toInt() ?? 0;
              // Blocker 3 (Codex review r2): the future-clamp is v1-ONLY. For v2
              // the LWW compare in _applyOne must see the ORIGINAL incoming mtime
              // — clamping it down first could make a genuinely newer edit
              // (2001 clamped to serverNow 1000) lose to a stale server copy
              // (1500) and be dropped. v2 stays server-authoritative: the hub
              // restamp handles a backward clock, and load()'s counter-aware
              // ceiling handles the future case on restart.
              if (!v2 && incomingMtime > serverNow) {
                incomingMtime = clampFutureMtime(incomingMtime, serverNow);
                m['mtime'] = incomingMtime;
              }
              // Wave CY.18.256: a server tombstone at/after this version means
              // the record was deleted here — don't resurrect it. Benign: the
              // pusher's NEXT /pull carries our tombstone and reaps its copy.
              final kind = _collectionToKind(collection);
              if (kind != null &&
                  store.isTombstonedNewer(kind, id, incomingMtime)) {
                record(id: id, collection: collection,
                    outcome: _SyncApplyOutcome.tombstoned,
                    clientMtime: incomingMtime);
                continue;
              }
              final (outcome, serverMtime) = await _applyOne(
                  store, collection, m, incomingMtime, device,
                  restamp: v2);
              if (outcome == _SyncApplyOutcome.accepted) {
                accepted++;
                needsPersist = true;
              }
              // A superseded/equal retry needs no needsPersist flag: blocker 1
              // flushes on ANY non-empty push, so the restamp-retry durability
              // case is covered without a false notify here.
              record(id: id, collection: collection, outcome: outcome,
                  clientMtime: incomingMtime, serverMtime: serverMtime);
            } catch (e) {
              // Blocker 4 (Codex review r2): anything reaching THIS catch is a
              // DETERMINISTIC parse/cast failure (fromJson / `as String`) —
              // re-sending can't help → invalid_record (advance). TRANSIENT
              // apply failures (provider key I/O) are caught inside _applyOne and
              // returned as retryable_error, so they never reach here. A
              // malformed provider therefore no longer wedges the cursor forever.
              debugPrint(
                  '[PyreServer] /push malformed $collection record: $e');
              record(index: index, collection: collection,
                  outcome: _SyncApplyOutcome.invalidRecord);
            }
          }
        }

        // Wave CY.18.256: apply pushed tombstones (additive — absent on
        // older clients → const {}). For each `kind:id -> mtime` we take
        // `max(existing, incoming)` into the server's log AND hard-remove
        // the matching live record if it's older than the tombstone (it was
        // deleted on the pushing device). A reap counts as a change so the
        // notifyAndPersist below fires.
        final pushedTombstones = json['tombstones'];
        if (pushedTombstones is Map) {
          // Wave CY.18.260: a `for` loop (was forEach) so we can `await` the
          // reap — the provider arm deletes from OS-secure storage, which is
          // async. `continue` replaces the early-return inside the old closure.
          for (final tEntry in pushedTombstones.entries) {
            final key = tEntry.key.toString();
            var incoming = (tEntry.value as num?)?.toInt() ?? 0;
            if (incoming <= 0) continue;
            // Blocker 3 (r2): future-clamp is v1-only (v2 restamps instead).
            if (!v2 && incoming > serverNow) {
              incoming = clampFutureMtime(incoming, serverNow);
            }
            final existing = store.tombstones[key] ?? 0;
            if (incoming > existing) {
              // Stage 4: v2 restamps a winning tombstone to a hub-monotonic
              // revision so peers pull it even when the pusher's clock rolled
              // back below the hub high-water.
              if (v2 && incoming <= store.lastIssuedLocalMtime) {
                incoming = store.nextSyncMtimeAfter(store.lastIssuedLocalMtime);
              }
              store.tombstones[key] = incoming;
              // D-#3 (Codex review): observe on BOTH v1 and v2 so the tombstone
              // never sits above the counter — else /pull.serverTime (= counter)
              // would be below it and a v1 tombstone-only push wouldn't ship.
              store.observeSyncMtime(incoming);
              accepted++;
              needsPersist = true;
            }
            final effective = store.tombstones[key] ?? incoming;
            final sep = key.indexOf(':');
            if (sep <= 0) continue;
            final reaped = await _reapTombstoned(
                store, key.substring(0, sep), key.substring(sep + 1), effective);
            if (reaped) {
              accepted++;
              needsPersist = true;
            }
          }
        }

        // Stage 5 (2026-07-17, Codex): persist SYNCHRONOUSLY before the 200.
        // The old code only scheduled a debounced save, so the hub could 200 a
        // push, the client advance its cursor, and the hub crash before the
        // save — losing the record with the client believing it delivered.
        //
        // Blocker 1 (Codex review): flush before EVERY non-empty push, not just
        // when THIS batch changed state. The restamp-retry loses data otherwise:
        // attempt 1 accepts+restamps a record (5000 → 10001) but the persist
        // fails (503); the retry sees the in-memory 10001 as `superseded` with
        // serverMtime(10001) != incomingMtime(5000), so the equal-version guard
        // doesn't fire, needsPersist stays false, and a benign 200 lets the
        // client advance while the record was never written to disk. Persisting
        // on any non-empty push closes that: `stateChanged` still gates the
        // notify (no needless repaint), but a non-empty push always flushes.
        final stateChanged = needsPersist;
        final pushCarriedItems = results.isNotEmpty ||
            (pushedTombstones is Map && pushedTombstones.isNotEmpty);
        if (pushCarriedItems) {
          if (stateChanged) store.notifyAndPersist();
          await store.flushPersist();
          if (store.lastPersistFailed) {
            return Response(503,
                body: '{"error":"persist failed"}',
                headers: {'content-type': 'application/json'});
          }
        }

        return Response.ok(
          jsonEncode({
            'accepted': accepted,
            'rejected': rejected,
            // Sync-B stage 3: exhaustive per-item outcomes (additive — v1
            // clients ignore it) + the hub's protocol so the client can trust
            // `results` rather than the lossy `rejected`-only heuristic.
            'results': results,
            'syncProtocol': 2,
          }),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        debugPrint('[PyreServer] /push failed: $e');
        return Response.internalServerError(
            body: '{"error":"server error"}');
      }
    });

    // Wave CY.18.67: GET /attachments/<sha256>
    // Serves raw bytes from the AttachmentStore. Used by web/PWA
    // clients (RemoteBackend) to fetch avatars referenced by
    // `pyre://attachment/...` URLs synced over /pull.
    r.get('/attachments/<hash>', (Request req, String hash) async {
      final clean = hash.trim();
      if (clean.isEmpty || clean.contains('/') || clean.contains('..')) {
        return Response(400, body: '{"error":"invalid hash"}');
      }
      final url = '${AttachmentStore.urlPrefix}$clean';
      final bytes = await AttachmentStore.readBytes(url);
      if (bytes == null) {
        return Response.notFound('{"error":"attachment not found"}');
      }
      final mime = await AttachmentStore.mimeFor(url) ?? 'application/octet-stream';
      return Response.ok(
        bytes,
        headers: {
          'content-type': mime,
          // Hash-keyed = safe to cache forever; bytes can't change for
          // a given URL because the URL IS the hash of the bytes.
          'cache-control': 'public, max-age=31536000, immutable',
        },
      );
    });

    // Wave CY.18.67: POST /attachments
    // Accepts raw bytes, stores them, returns the sha256. Idempotent
    // by content. Web/PWA RemoteBackend uses this to push an avatar
    // up before referencing it in a Character record.
    r.post('/attachments', (Request req) async {
      try {
        // Audit 2026-06-04 (M2): cap the upload. The body is buffered fully in
        // memory before hitting disk, so an unbounded POST from a paired
        // device could OOM the host or fill the disk. Attachments are
        // avatars/gallery images — a 64 MB ceiling is generous. Reject early
        // on a declared Content-Length, and abort mid-stream if it lies.
        const maxAttachmentBytes = 64 * 1024 * 1024;
        final declaredLen = int.tryParse(req.headers['content-length'] ?? '');
        if (declaredLen != null && declaredLen > maxAttachmentBytes) {
          return Response(413, body: '{"error":"attachment too large"}');
        }
        final bytes = <int>[];
        await for (final chunk in req.read()) {
          bytes.addAll(chunk);
          if (bytes.length > maxAttachmentBytes) {
            return Response(413, body: '{"error":"attachment too large"}');
          }
        }
        if (bytes.isEmpty) {
          return Response(400, body: '{"error":"empty body"}');
        }
        final mime = req.headers['content-type'];
        final url = await AttachmentStore.store(
          Uint8List.fromList(bytes),
          mime: mime,
        );
        if (url == null) {
          return Response.internalServerError(
              body: '{"error":"store failed"}');
        }
        final hash = url.substring(AttachmentStore.urlPrefix.length);
        return Response(
          201,
          body: jsonEncode({'sha256': hash, 'url': url}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        debugPrint('[PyreServer] POST /attachments failed: $e');
        return Response.internalServerError(
            body: '{"error":"server error"}');
      }
    });

    // SYNC W7 (attachment volume): POST /attachments/missing
    // Negotiation so a pushing client uploads ONLY the blobs this server
    // lacks. Body: {"hashes":[...]}. Returns {"missing":[...]} — the subset
    // not already on disk. Content-hash dedup means each image transfers at
    // most once, ever, instead of re-sending gigabytes of images the server
    // already holds. (Auth-protected: '/attachments' prefix covers this.)
    r.post('/attachments/missing', (Request req) async {
      try {
        // N2 audit 2026-06-15: cap the /attachments/missing body. The request
        // carries a list of sha256 hex strings (64 chars each); even a library
        // with thousands of attachments would be well under 1 MB. 1 MB ceiling
        // is generous while bounding the DoS. Same pattern as /push / /pair.
        const maxMissingBodyBytes = 1024 * 1024; // 1 MB
        final declaredMissingLen =
            int.tryParse(req.headers['content-length'] ?? '');
        if (declaredMissingLen != null &&
            declaredMissingLen > maxMissingBodyBytes) {
          return Response(413, body: '{"error":"request body too large"}');
        }
        final missingBuf = <int>[];
        await for (final chunk in req.read()) {
          missingBuf.addAll(chunk);
          if (missingBuf.length > maxMissingBodyBytes) {
            return Response(413, body: '{"error":"request body too large"}');
          }
        }
        final body =
            jsonDecode(utf8.decode(missingBuf, allowMalformed: true));
        final hashes = (body is Map ? body['hashes'] : null) as List?;
        final requested =
            hashes?.whereType<String>().toList() ?? const <String>[];
        final present = <String>{};
        for (final h in requested) {
          final clean = h.trim();
          if (clean.isEmpty || clean.contains('/') || clean.contains('..')) {
            continue;
          }
          final f = await AttachmentStore.fileFor(
              '${AttachmentStore.urlPrefix}$clean');
          if (f != null) present.add(clean);
        }
        final missing = attachmentHashesMissing(requested, present);
        return Response.ok(
          jsonEncode({'missing': missing.toList()}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        debugPrint('[PyreServer] POST /attachments/missing failed: $e');
        return Response.internalServerError(
            body: '{"error":"server error"}');
      }
    });

    // Wave CY.18.67: POST /llm/stream
    // Web/PWA clients can't safely hold LLM API keys (no SecureKeys
    // equivalent in the browser, and exposing them via JS = leak
    // through every browser extension). The server proxies on their
    // behalf using ITS keys. Native mobile clients call the upstream
    // LLM directly and skip this endpoint entirely.
    //
    // Request body: {
    //   "providerId": <optional — when present it MUST equal the host's
    //                  active provider id, else 403; null = use active>,
    //   "messages": [{role, content, ...}],
    //   "sampling": {temperature, topP, ...},  // optional overrides
    //   "stop": [...],                          // optional
    // }
    // Response: text/event-stream with lines `data: <chunk>\n\n`.
    // Terminal sentinel: `data: [DONE]\n\n` (matches the OpenAI
    // wire format the client is already used to from native calls).
    r.post('/llm/stream', (Request req) async {
      final store = _store;
      if (store == null) {
        return Response.internalServerError(body: '{"error":"no store"}');
      }

      // ── Wave CY.18.110 (audit S1): per-device throttle. The auth
      // middleware only reaches this handler with a valid bearer, so
      // `pyreDevice` is always present here; we key the budget on the
      // device's stable id. We gate BEFORE parsing the body so the
      // cheapest possible work rejects a torrent.
      final device = req.context['pyreDevice'] as PairedDevice?;
      final deviceKey = device?.id ?? 'unknown';

      // (1) Token bucket — caps sustained + burst request rate. See
      // _kProxy* constants below for why these are far above legit use.
      final bucket = _llmBuckets.putIfAbsent(
        deviceKey,
        () => RateBucket(
          capacity: _kProxyRpmBurst.toDouble(),
          refillPerSec: _kProxyRefillPerSec.toDouble(),
        ),
      );
      if (!bucket.tryConsume(DateTime.now())) {
        return _rateLimited();
      }

      // (2) Concurrency cap — bounds simultaneous in-flight proxied
      // calls per device. A sequential cascade uses 1; group chat a
      // few; a script opening 100 streams is capped at _kProxyMaxConcurrent.
      // We only CHECK the count here; the actual increment happens at the
      // streaming-commit point below (so the 400/503 pre-flight rejections
      // that follow never touch the counter) and is released in the
      // generator's finally (covers success, error, and client disconnect).
      if ((_llmInFlight[deviceKey] ?? 0) >= _kProxyMaxConcurrent) {
        return _rateLimited();
      }

      // N1 audit 2026-06-15: cap the /llm/stream body. Previously this was an
      // unbounded readAsString() — a paired device could send a multi-GB body
      // and OOM the host before the rate-limit or validation fired. An LLM
      // request body carries messages + sampling params; 4 MB is generous for
      // any realistic context window while still bounding the DoS surface.
      // Same declared-Content-Length 413 + mid-stream abort pattern as /push.
      const maxLlmBodyBytes = 4 * 1024 * 1024; // 4 MB
      Map<String, dynamic> body;
      try {
        final declaredLlmLen =
            int.tryParse(req.headers['content-length'] ?? '');
        if (declaredLlmLen != null && declaredLlmLen > maxLlmBodyBytes) {
          return Response(413, body: '{"error":"request body too large"}');
        }
        final llmBuf = <int>[];
        await for (final chunk in req.read()) {
          llmBuf.addAll(chunk);
          if (llmBuf.length > maxLlmBodyBytes) {
            return Response(413, body: '{"error":"request body too large"}');
          }
        }
        body = jsonDecode(utf8.decode(llmBuf, allowMalformed: true))
            as Map<String, dynamic>;
      } catch (e) {
        return Response(400, body: '{"error":"invalid JSON body"}');
      }

      // Wave CY.18.255 (audit FIX 1): the proxy is bound to the host's
      // CURRENTLY ACTIVE provider only. A paired device used to be able
      // to send any `providerId` from the server's provider list and the
      // proxy would honour it (falling back to active) — letting a device
      // pick the host's most expensive provider and drain its budget.
      // Now a client-supplied `providerId` is only allowed when it equals
      // the active provider's id; any other id is rejected with 403. This
      // bounds a paired device to whatever the host has active. A richer
      // per-device provider allowlist is a future option if a host wants
      // to scope individual devices to specific (e.g. cheaper) providers.
      final provider = store.activeProvider;
      if (provider == null) {
        return Response(503,
            body: '{"error":"no provider configured on server"}');
      }
      final requestedId = body['providerId'] as String?;
      if (requestedId != null &&
          requestedId.isNotEmpty &&
          requestedId != provider.id) {
        return Response(403,
            body: '{"error":"provider not permitted — '
                'the host only proxies its active provider"}');
      }

      final rawMessages = body['messages'];
      if (rawMessages is! List) {
        return Response(400, body: '{"error":"messages must be a list"}');
      }
      final messages = rawMessages
          .whereType<Map>()
          .map(chatTurnFromLanProxyJson)
          .toList();

      // Sampling overrides: take client's hint when provided, else
      // fall through to server's persisted ModelSettings.
      final samplingRaw = body['sampling'];
      final settings = store.modelSettings;
      final stopList = (body['stop'] as List?)?.whereType<String>().toList();

      // Wave CY.18.110: we are now committed to the proxied call, so
      // take an in-flight slot. The matching release lives in the
      // generator's finally below, which fires on ALL terminal paths:
      // normal [DONE], upstream error, and client disconnect (shelf
      // cancels the body subscription when the socket closes, running
      // the finally). A guard makes release idempotent.
      _llmInFlight[deviceKey] = (_llmInFlight[deviceKey] ?? 0) + 1;
      var releasedInFlight = false;
      void releaseInFlight() {
        if (releasedInFlight) return;
        releasedInFlight = true;
        final n = (_llmInFlight[deviceKey] ?? 1) - 1;
        if (n <= 0) {
          _llmInFlight.remove(deviceKey);
        } else {
          _llmInFlight[deviceKey] = n;
        }
      }

      // Build the SSE response as an async generator. Each chunk
      // becomes one SSE `data:` line. We don't have to worry about
      // client disconnects because the upstream Stream cancels
      // naturally when the controller's sink is closed.
      Stream<List<int>> sseBody() async* {
        try {
          await for (final chunk in streamChatCompletion(
            provider: provider,
            settings: settings,
            messages: messages,
            stop: stopList,
          )) {
            if (chunk.isEmpty) continue;
            yield utf8.encode('data: ${_escapeForSse(chunk)}\n\n');
          }
          yield utf8.encode('data: [DONE]\n\n');
        } catch (e) {
          // Surface the upstream error to the client so the web UI
          // can show a snackbar. Wrapped in `event: error` so the
          // client can dispatch independently of regular data.
          final msg = e is ChatApiError ? e.toString() : 'proxy error: $e';
          yield utf8.encode(
              'event: error\ndata: ${_escapeForSse(msg)}\n\n');
        } finally {
          // Wave CY.18.110: always free the in-flight slot — runs on
          // normal completion, upstream error, AND client disconnect.
          releaseInFlight();
        }
        // Note: we deliberately ignore the cleanup-on-disconnect side;
        // upstream client's HTTP client cancels when its socket closes.
        // The samplingRaw param is unused for now — Wave 70 chat client
        // will pipe through full settings if needed.
        if (samplingRaw != null) {
          // Suppress unused-variable lint without losing the comment.
        }
      }

      return Response.ok(
        sseBody(),
        headers: {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          'connection': 'keep-alive',
          'x-accel-buffering': 'no', // tell reverse proxies not to buffer
        },
      );
    });

    // v2 SECURE bbx: the botbooru proxy has moved to a SEPARATE-ORIGIN server
    // (_bbxRouter / _bbxHttp / _bbxPort). The main origin (this server) no
    // longer proxies botbooru at all — there is intentionally NO /bbx/ route
    // here. This is the key security fix: botbooru JS loaded in an iframe
    // cannot touch the Pyre app's localStorage/bearer because the iframe is
    // now cross-origin (bbxPort ≠ mainPort).
    //
    // PUBLIC: /bbx-info tells the web client which port the bbx server is on
    // so it can compute bbxOrigin = scheme://host:bbxPort and point the iframe
    // there. Returns {"port": <int>} or {"port": null} (if bbx failed to bind).
    r.get('/bbx-info', (Request req) {
      return Response.ok(
        jsonEncode({'port': _bbxPort}),
        headers: {'content-type': 'application/json'},
      );
    });

    return r;
  }

  /// Browser-ish UA so botbooru's Cloudflare serves the real page (a Dart
  /// default UA risks a bot challenge).
  static const String _kBbBrowserUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  // ---------------------------------------------------------------------------
  // v2 SECURE bbx — dedicated-origin router + proxy
  // ---------------------------------------------------------------------------

  /// The router for the bbx dedicated server. Has NO auth middleware — it only
  /// proxies botbooru.com with CORS restricted to the Pyre main origin.
  /// The handler is `r.all('/<rest|.*>', _proxyBotbooruDedicated)`.
  Router get _bbxRouter {
    final r = Router();
    r.all('/<rest|.*>', _proxyBotbooruDedicated);
    return r;
  }

  /// v2 SECURE: proxy a botbooru.com request through the DEDICATED bbx origin.
  ///
  /// Changes from the removed v1 `_proxyBotbooru`:
  ///   - B2 fix: `followRedirects = false`; redirects are followed manually,
  ///     re-checking bbxHostLocked on every hop (bounded to 5 hops) so a
  ///     redirect chain can never escape botbooru.com.
  ///   - CORS: `Access-Control-Allow-Origin` = Pyre main origin ONLY (port ==
  ///     _port), via bbxCorsOriginFor(). Never `*`. No credentials.
  ///     OPTIONS preflight → 200 + CORS headers (no upstream call needed).
  ///   - HTML rewrite: uses rewriteBotbooruHtmlDedicated (absolute → relative,
  ///     postMessage shim) instead of the v1 /bbx/-prefix rewrite.
  ///   - Security invariants maintained: host-lock, 25MB cap, cookie pass-through
  ///     (user session), error scrub. This server holds no AppStore reference.
  Future<Response> _proxyBotbooruDedicated(Request req, String rest) async {
    final q = req.requestedUri.query;
    final initialTarget =
        Uri.parse('https://botbooru.com/$rest${q.isNotEmpty ? '?$q' : ''}');

    // Host-lock on the initial target.
    if (!bbxHostLocked(initialTarget)) {
      debugPrint('[bbxServer] host-lock rejected: ${initialTarget.host}');
      return Response.forbidden('proxy target not allowed');
    }

    // CORS: compute the allowed origin from the request's Origin header.
    // mainPort can be null while the server is stopping — treat as no match.
    final reqOrigin = req.headers['origin'] ?? '';
    final corsOrigin = bbxCorsOriginFor(reqOrigin, _port ?? -1);
    final corsHeaders = <String, String>{
      'access-control-allow-methods': 'GET, POST, OPTIONS',
      'access-control-allow-headers': 'content-type',
      'access-control-max-age': '3600',
      // No credentials: botbooru JS in the iframe uses its OWN cookies for
      // its session; Pyre does NOT send credentials across origins.
      // (We do forward Cookie below so the user's logged-in session is
      // maintained — that's the browser's own cookie jar on the bbx origin.)
    };
    if (corsOrigin != null) {
      corsHeaders['access-control-allow-origin'] = corsOrigin;
      corsHeaders['vary'] = 'Origin';
    }

    // OPTIONS preflight: respond immediately without hitting upstream.
    if (req.method == 'OPTIONS') {
      return Response.ok('', headers: corsHeaders);
    }

    // Manual redirect loop (B2 fix). Maximum 5 hops; stop on non-3xx.
    var target = initialTarget;
    const maxHops = 5;
    final client = http.Client();
    try {
      for (var hop = 0; hop <= maxHops; hop++) {
        // Build the forwarded request (manual redirect = no automatic follow).
        final fwd = http.Request(req.method, target)
          ..followRedirects = false
          ..headers['user-agent'] = _kBbBrowserUA
          ..headers['accept'] = req.headers['accept'] ?? '*/*';
        final lang = req.headers['accept-language'];
        if (lang != null) fwd.headers['accept-language'] = lang;
        // Pass the user's session cookie so the botbooru front-end renders the
        // logged-in view (same as the native webview). Never logged.
        final cookie = req.headers['cookie'];
        if (cookie != null) fwd.headers['cookie'] = cookie;
        // Forward body only on first hop (redirects are GET per HTTP spec).
        if (hop == 0 &&
            (req.method == 'POST' ||
                req.method == 'PUT' ||
                req.method == 'PATCH')) {
          fwd.bodyBytes = await req
              .read()
              .fold<List<int>>(<int>[], (b, d) => b..addAll(d));
          final ct = req.headers['content-type'];
          if (ct != null) fwd.headers['content-type'] = ct;
        }

        final upstream =
            await client.send(fwd).timeout(const Duration(seconds: 30));

        // Handle redirects manually so we can re-check host-lock per hop.
        if (upstream.statusCode >= 300 && upstream.statusCode < 400) {
          // Drain the redirect response body (usually empty) to free the socket.
          await upstream.stream.drain<void>();
          final location = upstream.headers['location'];
          if (location == null || location.isEmpty) {
            return Response.internalServerError(
                body: 'redirect with no Location');
          }
          // Resolve relative Location against the current target.
          final nextTarget = target.resolve(location);
          // Re-check host-lock: the redirect destination MUST still be botbooru.com.
          if (!bbxHostLocked(nextTarget)) {
            debugPrint('[bbxServer] redirect host-lock rejected: '
                '${nextTarget.host} (hop $hop)');
            return Response(502, body: 'redirect target not allowed');
          }
          target = nextTarget;
          if (hop == maxHops) {
            return Response(502, body: 'too many redirects');
          }
          continue; // follow the redirect
        }

        // Non-redirect: stream the response with a 25MB cap.
        final chunks = <List<int>>[];
        int total = 0;
        await for (final chunk in upstream.stream) {
          total += chunk.length;
          if (total > kBbxMaxResponseBytes) {
            debugPrint('[bbxServer] response too large (>$kBbxMaxResponseBytes)');
            return Response.internalServerError(body: 'proxy response too large');
          }
          chunks.add(chunk);
        }
        final bytes = Uint8List.fromList(chunks.expand((c) => c).toList());

        final contentType =
            upstream.headers['content-type'] ?? 'application/octet-stream';
        // Fresh headers ONLY — drops upstream X-Frame-Options + CSP so the
        // iframe (on bbxPort) can render botbooru. Forward set-cookie so the
        // user's botbooru session is maintained (cookies go to bbxPort, not
        // mainPort — cross-origin session isolation is maintained).
        final outHeaders = <String, String>{
          'content-type': contentType,
          ...corsHeaders,
        };
        final setCookie = upstream.headers['set-cookie'];
        if (setCookie != null) outHeaders['set-cookie'] = setCookie;

        if (contentType.contains('text/html')) {
          return Response.ok(
            rewriteBotbooruHtmlDedicated(
                utf8.decode(bytes, allowMalformed: true)),
            headers: outHeaders,
          );
        }
        return Response.ok(bytes, headers: outHeaders);
      }
      // Should not reach here (loop exits via continue or return above).
      return Response(502, body: 'redirect loop');
    } catch (e) {
      // Scrub raw exceptions — never send stack traces in the HTTP body.
      debugPrint('[bbxServer] proxy error: $e');
      return Response.internalServerError(body: 'proxy error');
    } finally {
      client.close();
    }
  }

  /// Wave CY.18.76: locate the Flutter web build to self-host. Looks
  /// in two places, in order of priority:
  ///   1. `<exe-dir>/web/` — production layout. Ship the .exe with a
  ///      `web/` folder next to it (build script's job).
  ///   2. `<cwd>/build/web/` — dev layout. When the user runs
  ///      `flutter run -d windows` and turns the server on, this
  ///      lets them test against the latest `flutter build web`
  ///      without copying anything.
  /// Returns null if neither contains an index.html (treat that as
  /// "no web client bundled — clients must host separately").
  String? _findWebBuildDir() {
    try {
      // Candidate 1: next to the running executable. Platform.resolvedExecutable
      // is the .exe's full path; its parent dir is where Release/ files live.
      final exe = File(Platform.resolvedExecutable);
      final exeDir = exe.parent;
      final beside = Directory('${exeDir.path}${Platform.pathSeparator}web');
      if (File('${beside.path}${Platform.pathSeparator}index.html')
          .existsSync()) {
        return beside.path;
      }
    } catch (e) {
      debugPrint('[PyreServer] exe-dir web lookup failed: $e');
    }
    try {
      // Candidate 2: dev layout. Use the project's `build/web/` if
      // present. This makes `flutter run` + toggle-on usable without
      // a packaged build.
      final dev = Directory(
          '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}web');
      if (File('${dev.path}${Platform.pathSeparator}index.html')
          .existsSync()) {
        return dev.path;
      }
    } catch (e) {
      debugPrint('[PyreServer] dev-dir web lookup failed: $e');
    }
    return null;
  }

  /// SSE field values can't contain raw newlines — they delimit events.
  /// Replace `\n` with `\\n` so the client can reverse on the other side.
  /// We also escape `\r` for safety (some streams use CRLF).
  static String _escapeForSse(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('\n', '\\n').replaceAll('\r', '\\r');

  /// Wave CY.18.73: turn the cryptic + locale-dependent OS error
  /// from a `dart:io` SocketException into a friendly English message
  /// the UI can show consistently regardless of the user's Windows /
  /// Linux / macOS system language. Switches on `osError.errorCode`,
  /// not the message text (errno is stable across locales).
  ///
  /// Errno reference (Windows WSA codes; Linux/macOS errno follows
  /// POSIX but the bind() semantics are the same so the case-by-case
  /// translation maps cleanly):
  ///   10048 WSAEADDRINUSE   — port already bound by another app
  ///      98 EADDRINUSE       — same, POSIX
  ///   10013 WSAEACCES       — permission denied (port < 1024 on
  ///                            most OSes requires admin)
  ///      13 EACCES           — same, POSIX
  ///   10049 WSAEADDRNOTAVAIL — bind address isn't on this machine
  static String _friendlySocketError(SocketException e, int port) {
    final code = e.osError?.errorCode;
    if (code == 10048 || code == 98) {
      return 'Port $port is already in use. Another program (maybe a '
          'second Pyre instance, or a previous one still in the system '
          'tray) is holding it. Pick a different port, or close the '
          'other program.';
    }
    if (code == 10013 || code == 13) {
      return 'Permission denied for port $port. Ports below 1024 '
          'usually need administrator rights — pick a port above 1024.';
    }
    if (code == 10049) {
      return 'Bind address not available. Try switching Bind to '
          '"Entire LAN" or "Localhost only".';
    }
    // Unknown / less common errors: include both a short prefix and
    // the raw message. The raw text may be locale-specific, but
    // there's no clean fallback for the long tail of platform errors.
    return 'Could not bind to port $port. ${e.osError?.message ?? e.message}';
  }

  /// Collections the server knows how to sync. Used as the default
  /// when /pull doesn't specify.
  static const Set<String> _allCollections = {
    'characters',
    'personas',
    'chats',
    'presets',
    'lorebooks',
    // Pyre 1.1 (F4): regex find/replace rules.
    'regexRules',
    // Mega-audit 2026-06-05 (F2): user-authored library folders + forkable
    // Creator presets now ride the synced set. Both diff by mtime + delete
    // via the tombstone log; the locked default Creator preset is excluded
    // (rebuilt-from-build on every load) exactly like the locked Preset.
    'folders',
    'creatorPresets',
    // Wave CY.18.260: providers ride the synced set ONLY when the user has
    // opted in (uiPrefs.syncProviderKeys) AND the peer is native — the /pull
    // block below gates them out otherwise, so an old/web peer that asks for
    // 'providers' explicitly still receives nothing.
    'providers',
    // SYNC W3: the usage SETTINGS unit (model/chat/memory/liveSheet/script/
    // guide + the active/creator/vision provider role pointers). Synced as a
    // SINGLE record under one `settingsMtime` (LWW). The chat background image
    // is excluded from the wire (see AppStore.syncedSettingsToJson).
    'settings',
    // The BotBooru PROFILE unit (username / avatar (+ original) / about-me /
    // title / pronouns / featured character). Synced as its OWN SINGLE record
    // under one `botbooruProfileMtime` (LWW), exactly like `settings`.
    'botbooruProfile',
  };

  /// Bumped when the wire shape changes incompatibly. Wave 66 = v1.
  /// Clients compare against their own and surface "PC is on a newer
  /// Pyre" banner when this is higher than theirs.
  static const int _serverAppVersion = 1;

  // ── Wave CY.18.110 (audit S1): LLM-proxy throttle limits. These are
  // DELIBERATELY GENEROUS and exist ONLY to cap a scripted/compromised
  // paired device from draining the desktop's API budget — they must
  // NEVER trip during real use. Rationale: legit LLM calls are
  // latency-bound (each streams a reply over seconds), so even heavy
  // human/cascade usage is only a few-to-tens of requests/min per
  // device and runs sequentially. A malicious script fires
  // hundreds-to-thousands/min and/or many concurrent streams; only
  // that torrent crosses these thresholds. Applied to /llm/stream ONLY
  // (the sole cost-bearing endpoint); /pull, /push, /attachments are
  // free sync and untouched.

  /// Token-bucket capacity = max instantaneous burst (also the
  /// per-minute sustained ceiling given the refill below). 120 dwarfs
  /// the worst legit burst (e.g. the Creator cascade's back-to-back
  /// turns, each gated on a full streamed response → ~1 req / several s).
  static const int _kProxyRpmBurst = 120;

  /// Tokens refilled per second → 120 requests/minute sustained. A
  /// sequential cascade never approaches this; a torrent saturates it.
  static const int _kProxyRefillPerSec = 2;

  /// Max simultaneous in-flight proxied calls per device. A sequential
  /// cascade uses 1, group chat a handful; a script opening 100 streams
  /// is capped here.
  static const int _kProxyMaxConcurrent = 10;

  /// Wave CY.18.110: shared 429 response for both proxy throttles. Same
  /// JSON shape + `Retry-After: 1` (bucket refills 2 tokens/sec, so a
  /// one-second wait restores headroom). We do NOT ban or disconnect —
  /// the limit self-heals as the bucket refills / calls drain.
  static Response _rateLimited() => Response(
        429,
        body:
            '{"error":"rate_limited","detail":"Too many requests — slow down."}',
        headers: {
          'content-type': 'application/json',
          'retry-after': '1',
        },
      );

  /// Apply ONE incoming record. Returns true if applied, false if
  /// rejected because local mtime is greater-or-equal.
  ///
  /// Wave CY.18.260: async because the `providers` case decrypts the key
  /// envelope (AES-GCM is async) and writes it to OS-secure storage. [device]
  /// is the authenticated peer (nullable) — only the `providers` case reads it
  /// (for the gate + per-peer decrypt secret); every other case ignores it.
  /// Sync-B stage 4 (2026-07-17, Codex): the hub is server-authoritative on the
  /// revision it assigns an accepted write. [restamp] (v2 pushers only) stamps
  /// the record with a value guaranteed to sit at or above the hub's monotonic
  /// high-water, so EVERY peer's `mtime > since` pull sees it — even when the
  /// pusher's [incomingMtime] came from a rolled-back clock and landed at/below
  /// the hub's high-water (the "invisible to peers" loss). A well-behaved
  /// incoming mtime already above the floor is kept as-is (no churn). v1
  /// (legacy) pushers are NOT restamped — their mtime was future-clamped in the
  /// push loop, and restamping them would echo/re-push under skew.
  static int _acceptedRevision(AppStore store, int incomingMtime, bool restamp) {
    if (!restamp) return incomingMtime;
    final floor = store.lastIssuedLocalMtime;
    return incomingMtime > floor
        ? incomingMtime
        : store.nextSyncMtimeAfter(floor);
  }

  /// Test seam for the /push apply core (LWW + hub restamp + outcome). Returns
  /// the wire `code` + the record's resulting server revision. `device` is null
  /// (provider decryption is out of scope for the unit tests that use this).
  @visibleForTesting
  static Future<(String, int)> applyPushRecordForTest(
    AppStore store,
    String collection,
    Map<String, dynamic> j,
    int incomingMtime, {
    required bool restamp,
  }) async {
    final (outcome, serverMtime) =
        await _applyOne(store, collection, j, incomingMtime, null, restamp: restamp);
    return (_outcomeCode(outcome), serverMtime);
  }

  /// Applies one pushed record under LWW and reports the OUTCOME + the record's
  /// resulting server revision. Returns [_SyncApplyOutcome.superseded] with the
  /// EXISTING mtime when the local copy is at least as fresh (the caller uses
  /// `serverMtime == incomingMtime` to detect an equal-version retry that still
  /// needs a persist). Unknown collections are handled by the caller BEFORE this
  /// runs, so the `default` arm is defensive only.
  static Future<(_SyncApplyOutcome, int)> _applyOne(
    AppStore store,
    String collection,
    Map<String, dynamic> j,
    int incomingMtime,
    PairedDevice? device, {
    required bool restamp,
  }) async {
    switch (collection) {
      case 'characters':
        final id = j['id'] as String;
        final idx = store.characters.indexWhere((c) => c.id == id);
        if (idx >= 0 && store.characters[idx].mtime >= incomingMtime) {
          return (_SyncApplyOutcome.superseded, store.characters[idx].mtime);
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.characters[idx] = Character.fromJson(j);
        } else {
          store.characters.add(Character.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'personas':
        final id = j['id'] as String;
        final idx = store.personas.indexWhere((p) => p.id == id);
        if (idx >= 0 && store.personas[idx].mtime >= incomingMtime) {
          return (_SyncApplyOutcome.superseded, store.personas[idx].mtime);
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.personas[idx] = Persona.fromJson(j);
        } else {
          store.personas.add(Persona.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'chats':
        final id = j['id'] as String;
        final idx = store.chats.indexWhere((c) => c.id == id);
        if (idx >= 0 && store.chats[idx].mtime >= incomingMtime) {
          return (_SyncApplyOutcome.superseded, store.chats[idx].mtime);
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.chats[idx] = Chat.fromJson(j);
        } else {
          store.chats.add(Chat.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'presets':
        final id = j['id'] as String;
        final idx = store.presets.indexWhere((p) => p.id == id);
        if (idx >= 0) {
          // Never overwrite the locked default — it's rebuilt from the
          // app binary on every load anyway.
          if (store.presets[idx].locked) {
            return (_SyncApplyOutcome.immutable, store.presets[idx].mtime);
          }
          if (store.presets[idx].mtime >= incomingMtime) {
            return (_SyncApplyOutcome.superseded, store.presets[idx].mtime);
          }
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.presets[idx] = Preset.fromJson(j);
        } else {
          store.presets.add(Preset.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'lorebooks':
        final id = j['id'] as String;
        final idx = store.lorebooks.indexWhere((l) => l.id == id);
        if (idx >= 0 && store.lorebooks[idx].mtime >= incomingMtime) {
          return (_SyncApplyOutcome.superseded, store.lorebooks[idx].mtime);
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.lorebooks[idx] = Lorebook.fromJson(j);
        } else {
          store.lorebooks.add(Lorebook.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'regexRules':
        final id = j['id'] as String;
        final idx = store.regexRules.indexWhere((r) => r.id == id);
        if (idx >= 0 && store.regexRules[idx].mtime >= incomingMtime) {
          return (_SyncApplyOutcome.superseded, store.regexRules[idx].mtime);
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.regexRules[idx] = RegexRule.fromJson(j);
        } else {
          store.regexRules.add(RegexRule.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'folders':
        // Mega-audit 2026-06-05 (F2): LWW by mtime, mirrors lorebooks.
        final id = j['id'] as String;
        final idx = store.folders.indexWhere((f) => f.id == id);
        if (idx >= 0 && store.folders[idx].mtime >= incomingMtime) {
          return (_SyncApplyOutcome.superseded, store.folders[idx].mtime);
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.folders[idx] = Folder.fromJson(j);
        } else {
          store.folders.add(Folder.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'creatorPresets':
        // Mega-audit 2026-06-05 (F2): LWW by mtime. The locked default is
        // refreshed-from-build on every load, so a synced copy must never
        // overwrite it (it isn't emitted by /pull either, but be defensive
        // against a hand-crafted push).
        final id = j['id'] as String;
        final idx = store.creatorPresets.indexWhere((p) => p.id == id);
        if (idx >= 0) {
          if (store.creatorPresets[idx].locked) {
            return (_SyncApplyOutcome.immutable, store.creatorPresets[idx].mtime);
          }
          if (store.creatorPresets[idx].mtime >= incomingMtime) {
            return (_SyncApplyOutcome.superseded, store.creatorPresets[idx].mtime);
          }
        }
        // Never add a second "locked default" via sync.
        if (idx < 0 && CreatorPreset.fromJson(j).locked) {
          return (_SyncApplyOutcome.immutable, incomingMtime);
        }
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        j['mtime'] = rev;
        store.observeSyncMtime(rev);
        if (idx >= 0) {
          store.creatorPresets[idx] = CreatorPreset.fromJson(j);
        } else {
          store.creatorPresets.add(CreatorPreset.fromJson(j));
        }
        return (_SyncApplyOutcome.accepted, rev);
      case 'providers':
        // Wave CY.18.260: providers carry the API key — gated identically to
        // the pull (opt-in flag AND peer-native). A non-native peer (e.g. web)
        // or an opted-out host has its provider records ignored (policy reject).
        if (!shouldSyncProviders(
            store.uiPrefs.syncProviderKeys, device?.isNative == true)) {
          return (_SyncApplyOutcome.policyRejected, 0);
        }
        final id = j['id'] as String;
        // Parse OUTSIDE the I/O try: a malformed provider (fromJson throws) is
        // a DETERMINISTIC failure → it propagates to the caller's per-item catch
        // as invalid_record (advance), NOT retryable. fromJson never pulls the
        // plaintext key; it only rehydrates the apiKeyEnc envelope.
        final incoming = ApiProvider.fromJson(j);

        // Blocker 4 (Codex review r3): decrypt UP FRONT (the only async I/O that
        // isn't the durable write) into a local, touching NO store state. A
        // transient secret/decrypt failure → retryable, store untouched.
        String? decrypted;
        final env = j['apiKeyEnc'];
        final envelopePresent = env is String && env.isNotEmpty && device != null;
        if (envelopePresent) {
          try {
            final secret =
                await DeviceRegistry.instance.secretForDevice(device);
            decrypted = await KeyCrypto.decryptApiKey(env, secret);
          } catch (e) {
            debugPrint('[PyreServer] provider $id secret/decrypt I/O: $e');
            return (_SyncApplyOutcome.retryableError, incomingMtime);
          }
          // Blocker (Codex review r4): KeyCrypto.decryptApiKey returns NULL (it
          // never throws) on a bad envelope / wrong secret / tampering. The
          // envelope PROMISED a key — committing now would accept the config and
          // silently DROP the key while the client advances its cursor, so the
          // key never arrives. HOLD + retry instead (a re-pair fixes a secret
          // mismatch); never swallow a promised key.
          if (decrypted == null) {
            debugPrint('[PyreServer] provider $id: key decrypt returned null — '
                'holding for retry (envelope present)');
            return (_SyncApplyOutcome.retryableError, incomingMtime);
          }
        }

        // RE-RESOLVE + re-do the LWW compare AFTER the decrypt awaits — a
        // concurrent local edit (updateProvider) may have changed providers
        // while we were decrypting. Never act on a stale index/decision.
        var idx = store.providers.indexWhere((p) => p.id == id);
        if (idx >= 0 && store.providers[idx].mtime >= incomingMtime) {
          // Wave CY.18.267: config is fresh — don't replace it — but backfill a
          // MISSING key. Uses the CHECKED write and only mutates RAM AFTER the
          // key is durably on disk (blocker 4: a swallowed write failure used to
          // put the key in RAM, answer accepted, then lose it on restart).
          if (store.providers[idx].apiKey.isEmpty &&
              decrypted != null &&
              decrypted.isNotEmpty) {
            // retryable returns use incomingMtime (never a pre-await index) so a
            // concurrent DELETE can't turn a benign retry into a RangeError.
            if (!await SecureKeys.tryWrite(id, decrypted)) {
              return (_SyncApplyOutcome.retryableError, incomingMtime);
            }
            // Re-resolve after the write await; only adopt if still empty (a
            // concurrent edit may have set a key meanwhile — don't clobber RAM).
            idx = store.providers.indexWhere((p) => p.id == id);
            if (idx >= 0 && store.providers[idx].apiKey.isEmpty) {
              store.providers[idx].apiKey = decrypted;
              return (_SyncApplyOutcome.accepted, store.providers[idx].mtime);
            }
            return (
              _SyncApplyOutcome.superseded,
              idx >= 0 ? store.providers[idx].mtime : incomingMtime
            );
          }
          return (_SyncApplyOutcome.superseded, store.providers[idx].mtime);
        }

        // Accept path (config wins or new provider). Write the key (if any) to
        // secure storage FIRST; only commit config to RAM once it's durable.
        if (decrypted != null) {
          if (!await SecureKeys.tryWrite(id, decrypted)) {
            return (_SyncApplyOutcome.retryableError, incomingMtime);
          }
        }
        // Re-resolve + re-check LWW after the write await — respect a concurrent
        // edit that won during it (its own key is already in secure storage via
        // its path; we don't overwrite its config here).
        idx = store.providers.indexWhere((p) => p.id == id);
        if (idx >= 0 && store.providers[idx].mtime >= incomingMtime) {
          return (_SyncApplyOutcome.superseded, store.providers[idx].mtime);
        }
        // Codex review r4: re-validate the tombstone after the awaits too — a
        // concurrent DELETE during the decrypt/write would otherwise let the
        // accept path RESURRECT the just-deleted provider.
        if (store.isTombstonedNewer('provider', id, incomingMtime)) {
          return (_SyncApplyOutcome.tombstoned, incomingMtime);
        }
        // Preserve the existing local key as the floor — a decrypt miss must
        // NEVER wipe a key the user already has. New providers start keyless.
        incoming.apiKey = decrypted ?? (idx >= 0 ? store.providers[idx].apiKey : '');
        final rev = _acceptedRevision(store, incomingMtime, restamp);
        incoming.mtime = rev;
        store.observeSyncMtime(rev);
        // No await between here and the return → the commit is atomic.
        if (idx >= 0) {
          store.providers[idx] = incoming;
        } else {
          store.providers.add(incoming);
        }
        return (_SyncApplyOutcome.accepted, rev);
      default:
        return (_SyncApplyOutcome.superseded, incomingMtime);
    }
  }

  /// Wave CY.18.256: map a /push collection key (plural) to the tombstone
  /// KIND string (singular) used by [AppStore.tombstones]. Returns null for
  /// unknown collections (no tombstone semantics → never suppress).
  static String? _collectionToKind(String collection) {
    switch (collection) {
      case 'characters':
        return 'character';
      case 'personas':
        return 'persona';
      case 'chats':
        return 'chat';
      case 'presets':
        return 'preset';
      case 'lorebooks':
        return 'lorebook';
      // Pyre 1.1 (F4): regex-rule deletes propagate via the tombstone log.
      case 'regexRules':
        return 'regexRule';
      // Wave CY.18.260: provider deletes propagate via the tombstone log too.
      case 'providers':
        return 'provider';
      // Mega-audit 2026-06-05 (F2): folder + Creator-preset deletes.
      case 'folders':
        return 'folder';
      case 'creatorPresets':
        return 'creatorPreset';
      default:
        return null;
    }
  }

  /// Wave CY.18.256: hard-remove the live record identified by [kind]/[id]
  /// if its mtime is older-or-equal to [tombstoneMtime] (it was deleted on a
  /// peer). Using `<=` matches [AppStore.isTombstonedNewer]'s `>=` boundary —
  /// S-BUG3 fix: the old `<` (strict) left a record live AND tombstoned at
  /// equality, causing divergence when the server clamps a record-push and
  /// its tombstone to the same serverNow. The locked default preset is never
  /// reaped (rebuilt from the app binary on every load). Returns true iff
  /// something was removed.
  ///
  /// Wave CY.18.260: async because the `provider` arm also deletes the
  /// reaped provider's key from OS-secure storage.
  static Future<bool> _reapTombstoned(
      AppStore store, String kind, String id, int tombstoneMtime) async {
    switch (kind) {
      case 'character':
        final before = store.characters.length;
        store.characters
            .removeWhere((c) => c.id == id && c.mtime <= tombstoneMtime);
        return store.characters.length != before;
      case 'persona':
        final before = store.personas.length;
        store.personas
            .removeWhere((p) => p.id == id && p.mtime <= tombstoneMtime);
        return store.personas.length != before;
      case 'chat':
        final before = store.chats.length;
        store.chats.removeWhere((c) => c.id == id && c.mtime <= tombstoneMtime);
        return store.chats.length != before;
      case 'preset':
        final before = store.presets.length;
        store.presets.removeWhere(
            (p) => p.id == id && !p.locked && p.mtime <= tombstoneMtime);
        return store.presets.length != before;
      case 'lorebook':
        final before = store.lorebooks.length;
        store.lorebooks
            .removeWhere((l) => l.id == id && l.mtime <= tombstoneMtime);
        return store.lorebooks.length != before;
      case 'regexRule':
        final before = store.regexRules.length;
        store.regexRules
            .removeWhere((r) => r.id == id && r.mtime <= tombstoneMtime);
        return store.regexRules.length != before;
      case 'folder':
        // Mega-audit 2026-06-05 (F2): reap a folder deleted on a peer.
        final before = store.folders.length;
        store.folders
            .removeWhere((f) => f.id == id && f.mtime <= tombstoneMtime);
        return store.folders.length != before;
      case 'creatorPreset':
        // Never reap the locked default — it's rebuilt-from-build on load.
        final before = store.creatorPresets.length;
        store.creatorPresets.removeWhere(
            (p) => p.id == id && !p.locked && p.mtime <= tombstoneMtime);
        return store.creatorPresets.length != before;
      case 'provider':
        // Wave CY.18.260: a deleted provider also drops its key from OS-secure
        // storage so a stale secret never lingers. We `await` the delete only
        // when we actually reaped (the id matched a now-removed record).
        final before = store.providers.length;
        store.providers
            .removeWhere((p) => p.id == id && p.mtime <= tombstoneMtime);
        final removed = store.providers.length != before;
        if (removed) {
          await SecureKeys.delete(id);
        }
        return removed;
      default:
        return false;
    }
  }

  // ---------------------------------------------------------------------
  // Middleware
  // ---------------------------------------------------------------------

  /// CORS — the self-hosted web build is served by THIS server, so it
  /// calls us same-origin and needs no CORS grant at all. Previously we
  /// echoed `Access-Control-Allow-Origin: *`, which let any page on the
  /// internet read our responses and freely probe cross-origin. We now
  /// REFLECT the request `Origin` only when it is same-origin (host:port
  /// matches the request's own Host); cross-origin requests get NO ACAO
  /// header, so the browser blocks the response. Native mobile/desktop
  /// clients don't use browser CORS and are unaffected (they never send
  /// an `Origin` and ignore these headers).
  static Middleware get _corsMiddleware {
    return (Handler inner) {
      return (Request req) async {
        final cors = _corsHeadersFor(req);
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: cors);
        }
        final resp = await inner(req);
        return resp.change(headers: {
          ...resp.headers,
          ...cors,
        });
      };
    };
  }

  /// Base CORS headers (no `Access-Control-Allow-Origin`). ACAO is added
  /// per-request by [_corsHeadersFor] only when the caller is same-origin.
  static const Map<String, String> _corsBaseHeaders = {
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type',
    'access-control-max-age': '3600',
  };

  /// Build the CORS response headers for [req]. Reflects the `Origin`
  /// back as `Access-Control-Allow-Origin` ONLY when that origin is the
  /// server's own origin (same host:port as the request's Host). Any
  /// cross-origin / unparseable / missing-Host case omits ACAO entirely.
  static Map<String, String> _corsHeadersFor(Request req) {
    final origin = req.headers['origin'];
    if (origin == null || origin.isEmpty) return _corsBaseHeaders;
    Uri originUri;
    try {
      originUri = Uri.parse(origin);
    } catch (_) {
      return _corsBaseHeaders;
    }
    // The request's own authority (host[:port]) comes from the Host
    // header via requestedUri. Same-origin == same host AND same port.
    final self = req.requestedUri;
    final samePort = originUri.hasPort
        ? originUri.port == self.port
        : self.port == _defaultPortForScheme(originUri.scheme);
    final sameOrigin =
        originUri.host.isNotEmpty && originUri.host == self.host && samePort;
    if (!sameOrigin) return _corsBaseHeaders;
    return {
      ..._corsBaseHeaders,
      'access-control-allow-origin': origin,
      // Vary on Origin so caches don't serve one origin's ACAO to another.
      'vary': 'Origin',
    };
  }

  static int _defaultPortForScheme(String scheme) =>
      scheme == 'https' ? 443 : 80;

  /// Bearer-token auth. Wave CY.18.78: switched from allow-list to
  /// deny-list because the self-hosted web build (Wave 76) introduced
  /// many static-asset paths (`flutter_bootstrap.js`, `manifest.json`,
  /// `favicon.png`, `assets/...`, `canvaskit/...`, etc) that an
  /// allow-list of "public paths" can't enumerate. The old allow-list
  /// returned 401 for them, which (a) the browser refused to execute
  /// as JS because of MIME mismatch and (b) prevented Cascade from
  /// falling through to the static handler. So the user saw a blank
  /// tab and 401s in the console.
  ///
  /// New rule: only the SENSITIVE routes need bearer. Everything else
  /// is public — that includes static files (intentionally) and any
  /// unknown path (returns 404 from the static handler).
  ///
  /// Protected routes (must come with a valid bearer):
  ///   /pull  /push  /llm/stream  /attachments/...
  ///
  /// Public routes (no auth):
  ///   /pair (issues bearers — auth-bootstrap by definition)
  ///   /healthz (alive check)
  ///   /  (web app index)
  ///   anything that doesn't match the protected list (static files,
  ///   future public endpoints).
  ///
  /// Authenticated handlers can read the device via
  /// `req.context['pyreDevice']`.
  static const Set<String> _protectedPrefixes = {
    '/pull',
    '/push',
    '/llm/',
    '/attachments',
    // NOTE: the sync `/manifest` endpoint (SYNC W6 — per-collection id+mtime
    // fingerprints, no content/keys) is ALSO auth-gated, but as an EXACT path
    // match in `needsAuth` below — NOT a prefix here, because a `/manifest`
    // prefix wrongly 401'd the Flutter PWA's static `/manifest.json`.
  };

  static Middleware get _authMiddleware {
    return (Handler inner) {
      return (Request req) async {
        if (req.method == 'OPTIONS') {
          return inner(req);
        }
        final path = '/${req.url.path}';
        // `/manifest` (sync fingerprint endpoint) is gated as an EXACT match so
        // the PWA's static `/manifest.json` stays public (a prefix match 401'd
        // it). Everything else is prefix-matched.
        final needsAuth =
            path == '/manifest' || _protectedPrefixes.any(path.startsWith);
        if (!needsAuth) {
          return inner(req);
        }
        final auth = req.headers['authorization'] ?? '';
        if (!auth.toLowerCase().startsWith('bearer ')) {
          return Response(401, body: '{"error":"missing bearer"}');
        }
        final token = auth.substring(7).trim();
        if (token.isEmpty) {
          return Response(401, body: '{"error":"empty bearer"}');
        }
        final device = await DeviceRegistry.instance.deviceFor(token);
        if (device == null) {
          return Response(401, body: '{"error":"unknown bearer"}');
        }
        // Mega-audit 2026-06-05 (Item 3 / Finding 2): self-heal legacy native
        // devices. A native client advertises `x-pyre-native: 1` on every
        // authenticated request (web never sends it). If a stored record is
        // marked non-native (legacy / pre-flag pairing) but the caller proves
        // it is native, upgrade the record so key-sync stops excluding it —
        // no re-pair required. Fire-and-forget persist (off the hot path); the
        // in-memory flag is already true for THIS request's gate checks.
        final declaresNative =
            (req.headers['x-pyre-native'] ?? '').trim() == '1';
        if (declaresNative && !device.isNative) {
          unawaited(DeviceRegistry.instance.markNative(device));
        }
        // Stash the device on the request so downstream handlers can
        // log who did what (and so Wave 66's /push knows which device
        // originated an upload).
        final withDevice = req.change(context: {'pyreDevice': device});
        return inner(withDevice);
      };
    };
  }
}
