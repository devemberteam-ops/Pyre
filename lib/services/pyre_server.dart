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
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import 'attachment_refs.dart';
import 'attachment_store.dart';
import 'chat_api.dart';
import 'device_registry.dart';
import 'key_crypto.dart';
import 'rate_limit.dart';
import 'regex_rules.dart';
import 'secure_keys.dart';
import 'sync_manifest.dart';

/// True only on platforms that can actually open a listener socket.
bool get _supportsServer {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

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
        final body = await req.readAsString();
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
        updates['settings'] = [store.syncedSettingsToJson()];
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
        'serverTime': DateTime.now().millisecondsSinceEpoch,
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

        var accepted = 0;
        final rejected = <Map<String, dynamic>>[];

        // Wave CY.18.255 (FIX 5): clamp each incoming record's mtime to the
        // server's own clock so a writer whose clock is AHEAD can't stamp a
        // record with an mtime greater than the `serverTime` /pull hands
        // back. Without this, a future-clock record sits ABOVE the puller's
        // watermark and is then silently skipped on the next /pull (its
        // mtime is not `> since`). We clamp to `min(incoming, serverNow)` —
        // a record already at/below serverNow is left untouched, so normal
        // (correct-clock) records behave exactly as before. The clamp is
        // applied BEFORE the LWW compare AND written into the stored record
        // (we overwrite `m['mtime']`, which `fromJson` reads), so the
        // server's persisted copy carries the clamped value too.
        //
        // This is a low-effort mitigation. The richer fix is full
        // server-authoritative re-stamping (server assigns the mtime on
        // accept, ignoring the writer's clock entirely) — deferred because
        // it changes the LWW contract for every client and needs care.
        final serverNow = DateTime.now().millisecondsSinceEpoch;

        for (final entry in updates.entries) {
          final collection = entry.key.toString();
          final list = entry.value;
          if (list is! List) continue;
          for (final raw in list) {
            // Audit 2026-06-04 (H1): per-record isolation. A single poison
            // record (e.g. a numeric `id` that fails the `as String?` cast, or
            // a malformed nested field that trips Character/Chat.fromJson) must
            // NOT 500 the whole batch — that wedges the pushing device's sync
            // forever (it holds its watermark and re-pushes the same bad batch
            // every tick). The client SyncEngine already isolates per record;
            // mirror that here.
            try {
              if (raw is! Map) continue;
              final m = raw.cast<String, dynamic>();
              // SYNC W3: the settings UNIT is a SINGLETON record with no `id`
              // (it'd be skipped by the id-required path below). Handle it
              // first: clamp its mtime to the server clock (same future-clock
              // guard as records) so it can't outrun the /pull watermark, then
              // apply under LWW. `applySyncedSettings` reads the mtime off the
              // map and no-ops when not strictly newer (counts as a benign
              // server-newer reject so the pusher advances cleanly).
              if (collection == 'settings') {
                var sMtime = (m['mtime'] as num?)?.toInt() ?? 0;
                if (sMtime > serverNow) {
                  sMtime = serverNow;
                  m['mtime'] = serverNow;
                }
                final before = store.settingsMtime;
                store.applySyncedSettings(m);
                if (store.settingsMtime != before) {
                  accepted++;
                } else {
                  rejected.add({
                    'collection': 'settings',
                    'reason': 'server has newer mtime',
                  });
                }
                continue;
              }
              // The BotBooru PROFILE unit is also a SINGLETON record with no
              // `id` — handle it exactly like `settings` (clamp future clock,
              // apply under LWW, count accepted vs server-newer reject).
              if (collection == 'botbooruProfile') {
                var pMtime = (m['mtime'] as num?)?.toInt() ?? 0;
                if (pMtime > serverNow) {
                  pMtime = serverNow;
                  m['mtime'] = serverNow;
                }
                final before = store.botbooruProfileMtime;
                store.applySyncedBotbooruProfile(m);
                if (store.botbooruProfileMtime != before) {
                  accepted++;
                } else {
                  rejected.add({
                    'collection': 'botbooruProfile',
                    'reason': 'server has newer mtime',
                  });
                }
                continue;
              }
              final id = m['id'] as String?;
              if (id == null) continue;
              var incomingMtime = (m['mtime'] as num?)?.toInt() ?? 0;
              if (incomingMtime > serverNow) {
                // Future-clock record — pull it back to the server's now so it
                // can't outrun the /pull watermark. Mutate the map too so the
                // stored copy (built via fromJson) reflects the clamp.
                incomingMtime = serverNow;
                m['mtime'] = serverNow;
              }
              // Wave CY.18.256: if the server has a tombstone for this record
              // at/after the pushed version, the record was deleted here (or by
              // another peer) — don't resurrect it. Reject benignly (NOT a hard
              // reject: the pusher's NEXT /pull carries our tombstone and reaps
              // its own copy, so the loss is intentional and converges).
              final kind = _collectionToKind(collection);
              if (kind != null &&
                  store.isTombstonedNewer(kind, id, incomingMtime)) {
                rejected.add({
                  'id': id,
                  'collection': collection,
                  'reason': 'server has newer mtime',
                });
                continue;
              }
              final applied =
                  await _applyOne(store, collection, m, incomingMtime, device);
              if (applied) {
                accepted++;
              } else {
                rejected.add({
                  'id': id,
                  'collection': collection,
                  'reason': 'server has newer mtime',
                });
              }
            } catch (e) {
              debugPrint(
                  '[PyreServer] /push skipped a malformed $collection record: $e');
              continue;
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
            // Clamp future-clock tombstones to serverNow, same reasoning as
            // the record clamp above — a tombstone whose mtime outran the
            // /pull watermark would never propagate back out.
            if (incoming > serverNow) incoming = serverNow;
            final existing = store.tombstones[key] ?? 0;
            if (incoming > existing) {
              store.tombstones[key] = incoming;
              accepted++;
            }
            final effective = store.tombstones[key] ?? incoming;
            final sep = key.indexOf(':');
            if (sep <= 0) continue;
            final reaped = await _reapTombstoned(
                store, key.substring(0, sep), key.substring(sep + 1), effective);
            if (reaped) accepted++;
          }
        }

        if (accepted > 0) {
          // notifyAndPersist fires notifyListeners + schedules a
          // debounced save, so a burst of /push calls collapses into
          // one disk write at the tail.
          store.notifyAndPersist();
        }

        return Response.ok(
          jsonEncode({'accepted': accepted, 'rejected': rejected}),
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
        final body = jsonDecode(await req.readAsString());
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

      Map<String, dynamic> body;
      try {
        final raw = await req.readAsString();
        body = jsonDecode(raw) as Map<String, dynamic>;
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
          .map((m) => ChatTurn(
                (m['role'] as String?) ?? 'user',
                (m['content'] as String?) ?? '',
              ))
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

    return r;
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
  Future<bool> _applyOne(
    AppStore store,
    String collection,
    Map<String, dynamic> j,
    int incomingMtime,
    PairedDevice? device,
  ) async {
    switch (collection) {
      case 'characters':
        final id = j['id'] as String;
        final idx = store.characters.indexWhere((c) => c.id == id);
        if (idx >= 0) {
          if (store.characters[idx].mtime >= incomingMtime) return false;
          store.characters[idx] = Character.fromJson(j);
        } else {
          store.characters.add(Character.fromJson(j));
        }
        return true;
      case 'personas':
        final id = j['id'] as String;
        final idx = store.personas.indexWhere((p) => p.id == id);
        if (idx >= 0) {
          if (store.personas[idx].mtime >= incomingMtime) return false;
          store.personas[idx] = Persona.fromJson(j);
        } else {
          store.personas.add(Persona.fromJson(j));
        }
        return true;
      case 'chats':
        final id = j['id'] as String;
        final idx = store.chats.indexWhere((c) => c.id == id);
        if (idx >= 0) {
          if (store.chats[idx].mtime >= incomingMtime) return false;
          store.chats[idx] = Chat.fromJson(j);
        } else {
          store.chats.add(Chat.fromJson(j));
        }
        return true;
      case 'presets':
        final id = j['id'] as String;
        final idx = store.presets.indexWhere((p) => p.id == id);
        if (idx >= 0) {
          // Never overwrite the locked default — it's rebuilt from the
          // app binary on every load anyway.
          if (store.presets[idx].locked) return false;
          if (store.presets[idx].mtime >= incomingMtime) return false;
          store.presets[idx] = Preset.fromJson(j);
        } else {
          store.presets.add(Preset.fromJson(j));
        }
        return true;
      case 'lorebooks':
        final id = j['id'] as String;
        final idx = store.lorebooks.indexWhere((l) => l.id == id);
        if (idx >= 0) {
          if (store.lorebooks[idx].mtime >= incomingMtime) return false;
          store.lorebooks[idx] = Lorebook.fromJson(j);
        } else {
          store.lorebooks.add(Lorebook.fromJson(j));
        }
        return true;
      case 'regexRules':
        final id = j['id'] as String;
        final idx = store.regexRules.indexWhere((r) => r.id == id);
        if (idx >= 0) {
          if (store.regexRules[idx].mtime >= incomingMtime) return false;
          store.regexRules[idx] = RegexRule.fromJson(j);
        } else {
          store.regexRules.add(RegexRule.fromJson(j));
        }
        return true;
      case 'folders':
        // Mega-audit 2026-06-05 (F2): LWW by mtime, mirrors lorebooks.
        final id = j['id'] as String;
        final idx = store.folders.indexWhere((f) => f.id == id);
        if (idx >= 0) {
          if (store.folders[idx].mtime >= incomingMtime) return false;
          store.folders[idx] = Folder.fromJson(j);
        } else {
          store.folders.add(Folder.fromJson(j));
        }
        return true;
      case 'creatorPresets':
        // Mega-audit 2026-06-05 (F2): LWW by mtime. The locked default is
        // refreshed-from-build on every load, so a synced copy must never
        // overwrite it (it isn't emitted by /pull either, but be defensive
        // against a hand-crafted push).
        final id = j['id'] as String;
        final idx = store.creatorPresets.indexWhere((p) => p.id == id);
        if (idx >= 0) {
          if (store.creatorPresets[idx].locked) return false;
          if (store.creatorPresets[idx].mtime >= incomingMtime) return false;
          store.creatorPresets[idx] = CreatorPreset.fromJson(j);
        } else {
          final incoming = CreatorPreset.fromJson(j);
          // Never add a second "locked default" via sync.
          if (incoming.locked) return false;
          store.creatorPresets.add(incoming);
        }
        return true;
      case 'providers':
        // Wave CY.18.260: providers carry the API key — gated identically to
        // the pull (opt-in flag AND peer-native). A non-native peer (e.g. web)
        // or an opted-out host has its provider records silently ignored.
        if (!shouldSyncProviders(
            store.uiPrefs.syncProviderKeys, device?.isNative == true)) {
          return false;
        }
        final id = j['id'] as String;
        // LWW on mtime. Build the config-only record first (fromJson never
        // pulls the plaintext key out of the synced blob; it only rehydrates
        // the transient apiKeyEnc envelope).
        final incoming = ApiProvider.fromJson(j);
        final idx = store.providers.indexWhere((p) => p.id == id);
        if (idx >= 0 && store.providers[idx].mtime >= incomingMtime) {
          // Wave CY.18.267: config is at least as fresh so we don't replace
          // it, but backfill a MISSING key from the peer's envelope (never
          // overwrite an existing key, never touch config). Mirrors
          // SyncEngine.applyProviders — covers "this device restored a keyless
          // backup, then a paired peer pushes the key".
          if (store.providers[idx].apiKey.isEmpty) {
            final env = j['apiKeyEnc'];
            if (env is String && env.isNotEmpty && device != null) {
              final secret =
                  await DeviceRegistry.instance.secretForDevice(device);
              final decrypted = await KeyCrypto.decryptApiKey(env, secret);
              if (decrypted != null && decrypted.isNotEmpty) {
                store.providers[idx].apiKey = decrypted;
                await SecureKeys.write(id, decrypted);
                return true;
              }
            }
          }
          return false;
        }
        // Preserve the existing local plaintext key as the floor — a decrypt
        // failure (re-paired, tampered, wrong bearer) must NEVER wipe a key
        // the user already has. New providers start with no key.
        final existingKey = idx >= 0 ? store.providers[idx].apiKey : '';
        incoming.apiKey = existingKey;
        // Decrypt the key envelope, if present, with THIS peer's secret. On
        // success: adopt + persist to OS-secure storage. On failure: keep the
        // config, leave the existing key untouched, log one line.
        final env = j['apiKeyEnc'];
        if (env is String && env.isNotEmpty && device != null) {
          final secret =
              await DeviceRegistry.instance.secretForDevice(device);
          final decrypted = await KeyCrypto.decryptApiKey(env, secret);
          if (decrypted != null) {
            incoming.apiKey = decrypted;
            await SecureKeys.write(id, decrypted);
          } else {
            debugPrint('[PyreServer] provider $id: key decrypt failed — '
                'keeping config, existing key untouched');
          }
        }
        if (idx >= 0) {
          store.providers[idx] = incoming;
        } else {
          store.providers.add(incoming);
        }
        return true;
      default:
        return false;
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
  /// if its mtime is strictly older than [tombstoneMtime] (it was deleted
  /// on a peer). The locked default preset is never reaped (it is rebuilt
  /// from the app binary on every load). Returns true iff something was
  /// removed.
  ///
  /// Wave CY.18.260: async because the `provider` arm also deletes the
  /// reaped provider's key from OS-secure storage.
  static Future<bool> _reapTombstoned(
      AppStore store, String kind, String id, int tombstoneMtime) async {
    switch (kind) {
      case 'character':
        final before = store.characters.length;
        store.characters
            .removeWhere((c) => c.id == id && c.mtime < tombstoneMtime);
        return store.characters.length != before;
      case 'persona':
        final before = store.personas.length;
        store.personas
            .removeWhere((p) => p.id == id && p.mtime < tombstoneMtime);
        return store.personas.length != before;
      case 'chat':
        final before = store.chats.length;
        store.chats.removeWhere((c) => c.id == id && c.mtime < tombstoneMtime);
        return store.chats.length != before;
      case 'preset':
        final before = store.presets.length;
        store.presets.removeWhere(
            (p) => p.id == id && !p.locked && p.mtime < tombstoneMtime);
        return store.presets.length != before;
      case 'lorebook':
        final before = store.lorebooks.length;
        store.lorebooks
            .removeWhere((l) => l.id == id && l.mtime < tombstoneMtime);
        return store.lorebooks.length != before;
      case 'regexRule':
        final before = store.regexRules.length;
        store.regexRules
            .removeWhere((r) => r.id == id && r.mtime < tombstoneMtime);
        return store.regexRules.length != before;
      case 'folder':
        // Mega-audit 2026-06-05 (F2): reap a folder deleted on a peer.
        final before = store.folders.length;
        store.folders
            .removeWhere((f) => f.id == id && f.mtime < tombstoneMtime);
        return store.folders.length != before;
      case 'creatorPreset':
        // Never reap the locked default — it's rebuilt-from-build on load.
        final before = store.creatorPresets.length;
        store.creatorPresets.removeWhere(
            (p) => p.id == id && !p.locked && p.mtime < tombstoneMtime);
        return store.creatorPresets.length != before;
      case 'provider':
        // Wave CY.18.260: a deleted provider also drops its key from OS-secure
        // storage so a stale secret never lingers. We `await` the delete only
        // when we actually reaped (the id matched a now-removed record).
        final before = store.providers.length;
        store.providers
            .removeWhere((p) => p.id == id && p.mtime < tombstoneMtime);
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
    // SYNC W6 (verification): the read-only manifest is auth-gated like /pull —
    // it sits under no other prefix, so it's listed explicitly here. It exposes
    // only per-collection id+mtime fingerprints (no content, no keys), but
    // gating it keeps the whole sync surface uniformly behind the bearer.
    '/manifest',
  };

  static Middleware get _authMiddleware {
    return (Handler inner) {
      return (Request req) async {
        if (req.method == 'OPTIONS') {
          return inner(req);
        }
        final path = '/${req.url.path}';
        final needsAuth = _protectedPrefixes.any(path.startsWith);
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
