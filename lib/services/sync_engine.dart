// Wave CY.18.70: native-mobile sync loop.
//
// Lives on Android (and the eventual iOS build). NOT on the desktop
// server (the desktop IS the source of truth — it has nothing to sync
// FROM, only TO). NOT on web/PWA (which uses RemoteBackend's direct
// HTTP calls instead of a sync loop — Wave 71).
//
// Loop (one "tick"):
//   1. Read prefs['sync.lastServerTime'] (millis-since-epoch). 0 on
//      first ever sync.
//   2. GET /pull?since=<lastSync>&collections=<all> from LanClient.
//   3. For each incoming record: apply via LWW (only if local.mtime
//      < incoming.mtime). Bump AppStore.notifyListeners() when at
//      least one record landed.
//   4. If GenerationKeepAlive.isGenerating → skip push, fall through
//      to step 6.
//   5. POST /push with locally-modified records (mtime > lastSync).
//      Rejected records → schedule a fresh pull immediately so we
//      learn the server's newer value.
//   6. prefs['sync.lastServerTime'] = response.serverTime.
//
// Triggers:
//   - App resume (WidgetsBindingObserver.didChangeAppLifecycleState).
//   - Periodic 30s timer while foreground.
//   - Manual: forceTick() from the "Force sync now" button.
//
// Failure handling:
//   - Any network/HTTP error → log + bump _consecutiveFailures.
//     After 2 in a row, expose status = `offline` so the app shell's
//     SyncStatusPill can show "Offline" until the next success.
//   - 401 from server → disconnect locally (token revoked from
//     desktop). User has to re-pair.
//
// Concurrency:
//   - Serialised. `_tickInFlight` guards against re-entry; a tick
//     that's still running when the next timer fires just gets
//     skipped. This is fine because the next timer will pick up the
//     slack.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import 'attachment_store.dart';
import 'generation_keepalive.dart';
import 'key_crypto.dart';
import 'lan_client.dart';
import 'secure_keys.dart';

enum SyncStatus {
  /// Either never run or last tick was clean and idle is the steady
  /// state until the next trigger.
  idle,

  /// A tick is in flight (pull or push).
  syncing,

  /// Last tick succeeded recently. UI may flash a tiny success blip
  /// then fall back to idle.
  success,

  /// Last tick failed but we haven't crossed the "offline" threshold
  /// yet (1 failure).
  warning,

  /// Two or more consecutive failures — surface "Offline" in the
  /// status pill.
  offline,

  /// Disconnected (LanClient.isPaired is false). Default for native
  /// builds where the user hasn't paired yet.
  disconnected,
}

class SyncEngine extends ChangeNotifier with WidgetsBindingObserver {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  static const String _prefLastServerTime = 'sync.lastServerTime';
  static const Duration _pollInterval = Duration(seconds: 30);
  static const Duration _httpTimeout = Duration(seconds: 12);

  AppStore? _store;
  Timer? _poll;
  bool _tickInFlight = false;
  int _consecutiveFailures = 0;
  int _lastServerTime = 0;
  DateTime? _lastSuccessAt;
  String? _lastError;
  SyncStatus _status = SyncStatus.disconnected;
  bool _serverIsNewer = false;

  /// Wave CY.18.72: true when the most recent /pull response carried
  /// a `serverAppVersion` greater than what this build knows about.
  /// UI bindings (the LAN connect screen, eventually a top-of-app
  /// banner) read this to nudge the user to upgrade. Records with
  /// unknown fields still apply — they just round-trip the extra
  /// fields blindly through fromJson/toJson, which is safe because
  /// every fromJson here is additive-tolerant.
  bool get serverIsNewer => _serverIsNewer;

  /// Wire-shape version the client understands. Bumped in lockstep
  /// with PyreServer's `_serverAppVersion`. If a future server adds
  /// a new collection or changes the /pull response shape, bump
  /// this too so the mismatch banner fires at the right moment.
  static const int _clientAppVersion = 1;

  SyncStatus get status => _status;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  String? get lastError => _lastError;

  /// Install at app boot. Caller (main.dart) passes the AppStore. Safe
  /// to call repeatedly (re-install is a no-op).
  void install(AppStore store) {
    if (_store != null) return;
    _store = store;
    WidgetsBinding.instance.addObserver(this);
    LanClient.instance.addListener(_onLanClientChange);
    _refreshStatusFromPairing();
    _ensurePoll();
    // Fire a first tick a beat after boot so the splash transition
    // doesn't compete with HTTP.
    Future.delayed(const Duration(seconds: 3), () {
      if (LanClient.instance.isPaired) unawaited(_tick());
    });
  }

  /// Manual force-tick from the "Force sync now" button.
  Future<void> forceTick() async {
    if (!LanClient.instance.isPaired) return;
    await _tick();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Resume = the user is back. Pull immediately so they see the
      // freshest state without waiting up to 30s for the next tick.
      if (LanClient.instance.isPaired) unawaited(_tick());
      _ensurePoll();
    } else if (state == AppLifecycleState.paused) {
      // Cancel the polling timer while backgrounded — saves battery
      // + avoids piling up failed ticks when the OS suspends the
      // network stack.
      _poll?.cancel();
      _poll = null;
    }
  }

  void _onLanClientChange() {
    _refreshStatusFromPairing();
    if (LanClient.instance.isPaired) {
      _ensurePoll();
      // Pair-just-happened — kick a tick right away so the new client
      // gets the full server state in one shot.
      unawaited(_tick());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  void _refreshStatusFromPairing() {
    if (!LanClient.instance.isPaired) {
      _setStatus(SyncStatus.disconnected);
    } else if (_status == SyncStatus.disconnected) {
      _setStatus(SyncStatus.idle);
    }
  }

  void _ensurePoll() {
    if (_poll != null) return;
    if (!LanClient.instance.isPaired) return;
    _poll = Timer.periodic(_pollInterval, (_) {
      if (LanClient.instance.isPaired) unawaited(_tick());
    });
  }

  void _setStatus(SyncStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  Future<void> _tick() async {
    final store = _store;
    final client = LanClient.instance;
    if (store == null || !client.isPaired) return;
    if (_tickInFlight) return;
    _tickInFlight = true;
    _setStatus(SyncStatus.syncing);

    try {
      // Load lastServerTime if first call in this process.
      if (_lastServerTime == 0) {
        try {
          final prefs = await SharedPreferences.getInstance();
          _lastServerTime = prefs.getInt(_prefLastServerTime) ?? 0;
        } catch (_) {}
      }

      // ---- 1. PULL ----
      final pullUri = Uri.parse(
          '${client.baseUrl}/pull?since=$_lastServerTime');
      final pullResp = await http
          .get(pullUri, headers: _authHeaders())
          .timeout(_httpTimeout);
      if (pullResp.statusCode == 401) {
        // Server revoked us. Drop local pairing and surface that.
        await client.disconnect();
        throw _SyncError('Server revoked this device. Re-pair to continue.');
      }
      if (pullResp.statusCode != 200) {
        throw _SyncError(
            'Pull HTTP ${pullResp.statusCode}: ${pullResp.body}');
      }
      final pulled =
          jsonDecode(pullResp.body) as Map<String, dynamic>;
      final serverTime =
          (pulled['serverTime'] as num?)?.toInt() ?? _lastServerTime;
      // Wave CY.18.72: schema-mismatch flag. Server bumps
      // serverAppVersion when the wire shape changes; if we're
      // older, surface that to the UI so the user knows to update.
      // We still apply whatever records we got — fromJson is
      // additive-tolerant — so the app keeps working in the
      // meantime.
      final serverAppVersion =
          (pulled['serverAppVersion'] as num?)?.toInt() ?? 0;
      final newServerIsNewer = serverAppVersion > _clientAppVersion;
      if (newServerIsNewer != _serverIsNewer) {
        _serverIsNewer = newServerIsNewer;
        notifyListeners();
      }
      final updates =
          (pulled['updates'] as Map?)?.cast<String, dynamic>() ?? {};

      var appliedAny = false;
      // Wave CY.18.254: every `pyre://attachment/<hash>` ref carried by a
      // record we just applied (character/persona avatar + gallery). After
      // the merge we reconcile these — the refs sync, but the underlying
      // blob bytes do NOT, so a freshly-synced avatar/gallery renders broken
      // until we fetch the bytes from the server's GET /attachments/<hash>.
      final touchedRefs = <String>{};
      void noteRefs(String? avatar, List<String> gallery) {
        if (avatar != null && AttachmentStore.isPyreUrl(avatar)) {
          touchedRefs.add(avatar);
        }
        for (final g in gallery) {
          if (AttachmentStore.isPyreUrl(g)) touchedRefs.add(g);
        }
      }

      void applyChars() {
        final list = (updates['characters'] as List?) ?? const [];
        for (final raw in list) {
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          final id = m['id'] as String?;
          if (id == null) continue;
          // Per-record isolation: a single record whose fromJson throws
          // must not abort the whole tick (which would re-throw every
          // retry and permanently wedge sync). Skip the poison record,
          // log it, and keep applying the rest.
          try {
            final incoming = Character.fromJson(m);
            // Wave CY.18.256: a local tombstone at/after the incoming
            // version means we deleted this card — don't resurrect the
            // peer's stale live copy. Handles pull-before-push ordering:
            // even if the server still holds the live record, our newer
            // delete wins.
            if (store.isTombstonedNewer('character', id, incoming.mtime)) {
              continue;
            }
            final idx = store.characters.indexWhere((c) => c.id == id);
            if (idx >= 0) {
              if (store.characters[idx].mtime >= incoming.mtime) continue;
              store.characters[idx] = incoming;
            } else {
              store.characters.add(incoming);
            }
            noteRefs(incoming.avatar, incoming.gallery);
            appliedAny = true;
          } catch (e) {
            debugPrint('[SyncEngine] skip bad character "$id": $e');
          }
        }
      }

      void applyPersonas() {
        final list = (updates['personas'] as List?) ?? const [];
        for (final raw in list) {
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          final id = m['id'] as String?;
          if (id == null) continue;
          try {
            final incoming = Persona.fromJson(m);
            // Wave CY.18.256: skip if we deleted this persona at/after the
            // incoming version (see applyChars for rationale).
            if (store.isTombstonedNewer('persona', id, incoming.mtime)) {
              continue;
            }
            final idx = store.personas.indexWhere((p) => p.id == id);
            if (idx >= 0) {
              if (store.personas[idx].mtime >= incoming.mtime) continue;
              store.personas[idx] = incoming;
            } else {
              store.personas.add(incoming);
            }
            noteRefs(incoming.avatar, incoming.gallery);
            appliedAny = true;
          } catch (e) {
            debugPrint('[SyncEngine] skip bad persona "$id": $e');
          }
        }
      }

      void applyChats() {
        final list = (updates['chats'] as List?) ?? const [];
        for (final raw in list) {
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          final id = m['id'] as String?;
          if (id == null) continue;
          try {
            final incoming = Chat.fromJson(m);
            // Wave CY.18.256: skip if we deleted this chat at/after the
            // incoming version (see applyChars for rationale).
            if (store.isTombstonedNewer('chat', id, incoming.mtime)) {
              continue;
            }
            final idx = store.chats.indexWhere((c) => c.id == id);
            if (idx >= 0) {
              if (store.chats[idx].mtime >= incoming.mtime) continue;
              store.chats[idx] = incoming;
            } else {
              store.chats.add(incoming);
            }
            appliedAny = true;
          } catch (e) {
            debugPrint('[SyncEngine] skip bad chat "$id": $e');
          }
        }
      }

      void applyPresets() {
        final list = (updates['presets'] as List?) ?? const [];
        for (final raw in list) {
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          final id = m['id'] as String?;
          if (id == null) continue;
          try {
            final incoming = Preset.fromJson(m);
            // Wave CY.18.256: skip if we deleted this preset at/after the
            // incoming version (see applyChars for rationale).
            if (store.isTombstonedNewer('preset', id, incoming.mtime)) {
              continue;
            }
            final idx = store.presets.indexWhere((p) => p.id == id);
            if (idx >= 0) {
              // Never overwrite locked default — refreshed-from-build.
              if (store.presets[idx].locked) continue;
              if (store.presets[idx].mtime >= incoming.mtime) continue;
              store.presets[idx] = incoming;
            } else {
              store.presets.add(incoming);
            }
            appliedAny = true;
          } catch (e) {
            debugPrint('[SyncEngine] skip bad preset "$id": $e');
          }
        }
      }

      void applyLorebooks() {
        final list = (updates['lorebooks'] as List?) ?? const [];
        for (final raw in list) {
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          final id = m['id'] as String?;
          if (id == null) continue;
          try {
            final incoming = Lorebook.fromJson(m);
            // Wave CY.18.256: skip if we deleted this lorebook at/after the
            // incoming version (see applyChars for rationale).
            if (store.isTombstonedNewer('lorebook', id, incoming.mtime)) {
              continue;
            }
            final idx = store.lorebooks.indexWhere((l) => l.id == id);
            if (idx >= 0) {
              if (store.lorebooks[idx].mtime >= incoming.mtime) continue;
              store.lorebooks[idx] = incoming;
            } else {
              store.lorebooks.add(incoming);
            }
            appliedAny = true;
          } catch (e) {
            debugPrint('[SyncEngine] skip bad lorebook "$id": $e');
          }
        }
      }

      // Wave CY.18.261: apply incoming PROVIDER records (config + encrypted
      // API key). Gated on the LOCAL opt-in flag — if the user has key-sync
      // OFF on THIS device, provider records are ignored entirely (even if a
      // peer pushed them). LWW upsert by id; the encrypted key, when it
      // decrypts with our bearer-derived secret, is adopted and persisted to
      // OS-secure storage. A decrypt failure (re-paired, tampered, wrong
      // bearer) keeps the config but NEVER wipes an existing local key.
      // Async (crypto + SecureKeys), so it's awaited explicitly below.
      Future<void> applyProviders() async {
        if (!store.uiPrefs.syncProviderKeys) return;
        final list = (updates['providers'] as List?) ?? const [];
        if (list.isEmpty) return;
        final secret = await _keySyncSecret();
        if (secret == null) return;
        for (final raw in list) {
          if (raw is! Map) continue;
          final m = raw.cast<String, dynamic>();
          final id = m['id'] as String?;
          if (id == null) continue;
          // Per-record isolation: a poison record must not abort the tick.
          try {
            // Wave CY.18.256: a local tombstone at/after the incoming version
            // means we deleted this provider — don't resurrect a peer's stale
            // copy (see applyChars for rationale).
            final incomingMtime = (m['mtime'] as num?)?.toInt() ?? 0;
            if (store.isTombstonedNewer('provider', id, incomingMtime)) {
              continue;
            }
            final idx = store.providers.indexWhere((p) => p.id == id);
            if (idx >= 0 && store.providers[idx].mtime >= incomingMtime) {
              continue;
            }
            // Decode config + (maybe) decrypt the key via the pure helper.
            final (incoming, decryptedKey) =
                await decodeIncomingProvider(m, secret);
            // Preserve the existing local plaintext key as the floor — a
            // decrypt failure or a never-keyed record must NEVER wipe a key
            // the user already has. New providers start with no key.
            incoming.apiKey = idx >= 0 ? store.providers[idx].apiKey : '';
            if (decryptedKey != null) {
              incoming.apiKey = decryptedKey;
              await SecureKeys.write(id, decryptedKey);
            } else if (m['apiKeyEnc'] is String &&
                (m['apiKeyEnc'] as String).isNotEmpty) {
              debugPrint('[SyncEngine] provider $id: key decrypt failed — '
                  'keeping config, existing key untouched');
            }
            if (idx >= 0) {
              store.providers[idx] = incoming;
            } else {
              store.providers.add(incoming);
            }
            appliedAny = true;
          } catch (e) {
            debugPrint('[SyncEngine] skip bad provider "$id": $e');
          }
        }
      }

      // Wave CY.18.256: apply pulled tombstones. For each `kind:id -> mtime`
      // we take `max(existing, incoming)` into our local log AND hard-remove
      // the matching live record if its mtime is older than the tombstone
      // (it was deleted on a peer). Runs AFTER the record applies above so
      // a record that arrived in the SAME pull but is covered by a newer
      // tombstone here gets reaped immediately. (The per-record skip above
      // already blocks resurrection from a tombstone we recorded LOCALLY;
      // this branch is what makes a PEER's delete win on this device.)
      // Wave CY.18.261: async because the `provider` arm also deletes the
      // reaped provider's key from OS-secure storage. Iterate the entries
      // sequentially (await inside) instead of forEach so the SecureKeys
      // delete is properly awaited.
      Future<void> applyTombstones() async {
        final pulledTombstones =
            (pulled['tombstones'] as Map?)?.cast<String, dynamic>() ?? {};
        if (pulledTombstones.isEmpty) return;
        for (final entry in pulledTombstones.entries) {
          final key = entry.key;
          final raw = entry.value;
          final incomingMtime = (raw as num?)?.toInt() ?? 0;
          if (incomingMtime <= 0) continue;
          final existing = store.tombstones[key] ?? 0;
          if (incomingMtime > existing) {
            store.tombstones[key] = incomingMtime;
          }
          // Reap the matching live record if it's older than the tombstone.
          // Key shape is `<kind>:<id>`; split on the FIRST colon only (ids
          // are UUIDs without colons, but be defensive).
          final sep = key.indexOf(':');
          if (sep <= 0) continue;
          final kind = key.substring(0, sep);
          final id = key.substring(sep + 1);
          final effective = store.tombstones[key] ?? incomingMtime;
          switch (kind) {
            case 'character':
              final removed = store.characters
                  .where((c) => c.id == id && c.mtime < effective)
                  .isNotEmpty;
              if (removed) {
                store.characters
                    .removeWhere((c) => c.id == id && c.mtime < effective);
                appliedAny = true;
              }
              break;
            case 'persona':
              final removed = store.personas
                  .where((p) => p.id == id && p.mtime < effective)
                  .isNotEmpty;
              if (removed) {
                store.personas
                    .removeWhere((p) => p.id == id && p.mtime < effective);
                appliedAny = true;
              }
              break;
            case 'chat':
              final removed = store.chats
                  .where((c) => c.id == id && c.mtime < effective)
                  .isNotEmpty;
              if (removed) {
                store.chats
                    .removeWhere((c) => c.id == id && c.mtime < effective);
                appliedAny = true;
              }
              break;
            case 'preset':
              // Never reap the locked default — it is rebuilt-from-build on
              // every load and is intentionally never synced/deleted.
              final removed = store.presets
                  .where((p) => p.id == id && !p.locked && p.mtime < effective)
                  .isNotEmpty;
              if (removed) {
                store.presets.removeWhere(
                    (p) => p.id == id && !p.locked && p.mtime < effective);
                appliedAny = true;
              }
              break;
            case 'lorebook':
              final removed = store.lorebooks
                  .where((l) => l.id == id && l.mtime < effective)
                  .isNotEmpty;
              if (removed) {
                store.lorebooks
                    .removeWhere((l) => l.id == id && l.mtime < effective);
                appliedAny = true;
              }
              break;
            case 'provider':
              // Wave CY.18.261: a deleted provider also drops its key from
              // OS-secure storage so a stale secret never lingers. Mirror the
              // server reap arm: remove the live record then SecureKeys.delete
              // (awaited) when we actually reaped.
              final removed = store.providers
                  .where((p) => p.id == id && p.mtime < effective)
                  .isNotEmpty;
              if (removed) {
                store.providers
                    .removeWhere((p) => p.id == id && p.mtime < effective);
                await SecureKeys.delete(id);
                appliedAny = true;
              }
              break;
          }
        }
      }

      applyChars();
      applyPersonas();
      applyChats();
      applyPresets();
      applyLorebooks();
      // Wave CY.18.261: providers carry an encrypted key + need SecureKeys
      // writes, so this branch is async — await it before the tombstone reap
      // so a provider delete that arrived in the SAME pull reaps immediately.
      await applyProviders();
      await applyTombstones();
      // Fetch any newly-referenced attachment blobs BEFORE the final
      // notify so the UI rebuild already sees the bytes on disk and
      // renders avatars/gallery images instead of broken placeholders.
      // Best-effort: a failed/missing blob never blocks the merge.
      if (touchedRefs.isNotEmpty) {
        await _reconcileAttachments(touchedRefs);
      }
      if (appliedAny) {
        store.notifyAndPersist();
      }

      // ---- 2. PUSH (skip during in-flight generation) ----
      // Wave CY.18.255 (FIX 4): true while the push came back with a
      // rejection we should NOT lose by advancing the watermark past it.
      // A "server-newer" rejection is benign — the next /pull surfaces the
      // server's newer copy and LWW converges. But ANY OTHER rejection
      // (e.g. an unknown collection, a future server-side validation
      // refusal) means our local record never landed AND won't come back
      // on /pull. If we advanced `_lastServerTime` past it, `_collectDirty`
      // (which only re-sends `mtime > _lastServerTime`) would never offer
      // it again → silent local-edit loss. So we keep the prior watermark
      // this tick to force a corrective re-push next tick.
      var pushHadHardReject = false;
      if (!GenerationKeepAlive.isGenerating) {
        final dirty = _collectDirty(store, _lastServerTime);
        // Wave CY.18.261: include the PROVIDERS collection in the push ONLY
        // when the user opted in (syncProviderKeys). Each provider is emitted
        // via toJsonEncrypted — config in cleartext, the API key as an
        // AES-GCM envelope (never plaintext) keyed by our bearer-derived
        // secret. Same `mtime > since` window as every other collection. Flag
        // OFF (default) ⇒ the `providers` key is absent entirely (the server
        // also gates, but we don't even ship it). _collectDirty stays sync +
        // pure; the encryption (async) is layered on here.
        if (store.uiPrefs.syncProviderKeys) {
          final secret = await _keySyncSecret();
          if (secret != null) {
            final out = <Map<String, dynamic>>[];
            for (final p in store.providers) {
              if (p.mtime > _lastServerTime) {
                out.add(await p.toJsonEncrypted(secret));
              }
            }
            dirty['providers'] = out;
          }
        }
        // Wave CY.18.256: deletion-propagation. Send only the tombstones the
        // server hasn't seen (mtime > since) so the server learns about our
        // local deletes and reaps its still-live copies. Additive: an old
        // server ignores the unknown `tombstones` key.
        final dirtyTombstones = _collectDirtyTombstones(store, _lastServerTime);
        final hasDirty = dirty.values.any((l) => l.isNotEmpty);
        // Push when we have dirty records OR dirty tombstones — a tick whose
        // only change is a deletion still needs to reach the server.
        if (hasDirty || dirtyTombstones.isNotEmpty) {
          final pushResp = await http
              .post(
                Uri.parse('${client.baseUrl}/push'),
                headers: {
                  ..._authHeaders(),
                  'content-type': 'application/json',
                },
                body: jsonEncode({
                  'updates': dirty,
                  if (dirtyTombstones.isNotEmpty) 'tombstones': dirtyTombstones,
                }),
              )
              .timeout(_httpTimeout);
          if (pushResp.statusCode == 401) {
            await client.disconnect();
            throw _SyncError('Server revoked this device.');
          }
          if (pushResp.statusCode != 200) {
            throw _SyncError(
                'Push HTTP ${pushResp.statusCode}: ${pushResp.body}');
          }
          // Inspect `rejected`. A pure server-newer rejection is fine to
          // ignore (the next /pull reconciles it). Anything else is a hard
          // reject that must NOT slide under the watermark.
          try {
            final j = jsonDecode(pushResp.body);
            final rejected = (j['rejected'] as List?) ?? const [];
            // The server (pyre_server.dart /push) tags benign LWW losses
            // with this exact reason; treat every OTHER reason as hard.
            const serverNewerReason = 'server has newer mtime';
            pushHadHardReject = rejected.any((r) =>
                r is Map && (r['reason']?.toString() ?? '') != serverNewerReason);
            if (kDebugMode) {
              debugPrint(
                  '[SyncEngine] push response: ${j['accepted']} accepted, '
                  '${rejected.length} rejected'
                  '${pushHadHardReject ? ' (non-server-newer present — '
                      'holding watermark for retry)' : ''}');
            }
          } catch (_) {
            // Malformed/empty body — be conservative and DON'T treat it as
            // a hard reject (a 200 with no parseable rejected list means
            // the server accepted; advancing is safe and avoids a stuck
            // watermark on an old/quiet server).
          }
        }
      }

      // ---- 3. Persist new high-water mark ----
      // Hold the watermark if a hard reject occurred so the rejected
      // record (still `mtime > _lastServerTime`) is re-collected and
      // re-pushed on the next tick. The normal all-accepted (or
      // server-newer-only) path advances as before.
      if (!pushHadHardReject) {
        _lastServerTime = serverTime;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt(_prefLastServerTime, serverTime);
        } catch (_) {}
      }

      _consecutiveFailures = 0;
      _lastSuccessAt = DateTime.now();
      _lastError = null;
      _setStatus(SyncStatus.success);
    } catch (e) {
      _consecutiveFailures++;
      _lastError = e is _SyncError ? e.message : e.toString();
      debugPrint('[SyncEngine] tick failed: $_lastError');
      if (_consecutiveFailures >= 2) {
        _setStatus(SyncStatus.offline);
      } else {
        _setStatus(SyncStatus.warning);
      }
    } finally {
      _tickInFlight = false;
    }
  }

  Map<String, List<Map<String, dynamic>>> _collectDirty(
      AppStore store, int since) {
    return {
      'characters': store.characters
          .where((c) => c.mtime > since)
          .map((c) => c.toJson())
          .toList(),
      'personas': store.personas
          .where((p) => p.mtime > since)
          .map((p) => p.toJson())
          .toList(),
      'chats': store.chats
          .where((c) => c.mtime > since)
          .map((c) => c.toJson())
          .toList(),
      'presets': store.presets
          .where((p) => p.mtime > since && !p.locked)
          .map((p) => p.toJson())
          .toList(),
      'lorebooks': store.lorebooks
          .where((l) => l.mtime > since)
          .map((l) => l.toJson())
          .toList(),
    };
  }

  /// Wave CY.18.256: tombstones recorded since the last watermark. Same
  /// `mtime > since` gate as [_collectDirty] so we only ship deletions the
  /// server hasn't already seen. Returns `{ 'kind:id': mtime }`.
  Map<String, int> _collectDirtyTombstones(AppStore store, int since) {
    final out = <String, int>{};
    store.tombstones.forEach((key, mtime) {
      if (mtime > since) out[key] = mtime;
    });
    return out;
  }

  /// Wave CY.18.254: pull the BLOB BYTES for attachment refs that just
  /// arrived over /pull but aren't in the local content-addressed store
  /// yet. Synced records carry `pyre://attachment/<hash>` refs (avatars +
  /// gallery images); the refs replicate but the bytes do not, so on a
  /// fresh client every such image renders broken until we fetch it from
  /// the desktop server's `GET /attachments/<hash>` endpoint.
  ///
  /// Native only — `AttachmentStore` is a no-op on web (no filesystem),
  /// where the proper fix is to render `pyre://` images straight from the
  /// server URL (separate follow-up). Best-effort + isolated per blob: a
  /// failed or missing attachment is logged and skipped, never thrown out
  /// of the sync tick. Fetched sequentially — galleries are a handful of
  /// images, so there's no need to fan out dozens of parallel requests.
  Future<void> _reconcileAttachments(Set<String> refs) async {
    if (kIsWeb) return;
    final client = LanClient.instance;
    final baseUrl = client.baseUrl;
    if (baseUrl == null) return;
    for (final ref in refs) {
      if (!AttachmentStore.isPyreUrl(ref)) continue;
      final hash = ref.substring(AttachmentStore.urlPrefix.length);
      if (hash.isEmpty) continue;
      try {
        // Already have the bytes locally? `fileFor` returns null when the
        // backing file is missing, so a non-null result means "present".
        final existing = await AttachmentStore.fileFor(ref);
        if (existing != null) continue;

        final resp = await http
            .get(Uri.parse('$baseUrl/attachments/$hash'),
                headers: _authHeaders())
            .timeout(_httpTimeout);
        if (resp.statusCode != 200) {
          debugPrint(
              '[SyncEngine] attachment $hash fetch HTTP ${resp.statusCode}');
          continue;
        }
        final mime = resp.headers['content-type'];
        await AttachmentStore.store(
          resp.bodyBytes,
          mime: (mime != null && mime.isNotEmpty) ? mime : 'image/png',
        );
      } catch (e) {
        debugPrint('[SyncEngine] attachment $hash reconcile failed: $e');
      }
    }
  }

  Map<String, String> _authHeaders() {
    final token = LanClient.instance.bearerToken ?? '';
    return {'authorization': 'Bearer $token'};
  }

  /// Wave CY.18.261: the per-device key-sync secret derived from the raw
  /// pairing bearer (the slot `lan_client` writes). Both peers derive the
  /// SAME secret from the shared bearer, so an encrypted key envelope round-
  /// trips. Returns null if the bearer is missing/empty (e.g. not yet paired)
  /// — the caller then simply skips the encrypted-provider path. Best-effort:
  /// any SecureKeys read failure surfaces as a null secret, never throws.
  Future<SecretKey?> _keySyncSecret() async {
    String rawBearer = '';
    try {
      rawBearer = await SecureKeys.read('__lan__.bearerToken');
    } catch (_) {
      return null;
    }
    if (rawBearer.isEmpty) return null;
    return KeyCrypto.secretForBearer(rawBearer);
  }
}

class _SyncError implements Exception {
  final String message;
  _SyncError(this.message);
  @override
  String toString() => message;
}

/// Wave CY.18.261: decode an incoming synced provider record into a parsed
/// [ApiProvider] plus the decrypted API key (or null if there was none, or
/// it could not be decrypted with [secret]). PURE: never touches SecureKeys,
/// the AppStore, or any I/O beyond the crypto primitives — so the apply
/// logic (config parse + key-decrypt) is unit-testable without a live peer.
///
/// Fail-closed: a missing/empty/garbled `apiKeyEnc` yields a null key, never
/// throws. The returned provider always carries its config; the caller
/// decides whether to adopt the key (and persists it to OS-secure storage).
/// The parsed provider's own `apiKey` field is left as fromJson produced it
/// (empty for synced records — the plaintext key never crosses the wire);
/// the key, if any, comes back as the second tuple element only.
Future<(ApiProvider, String?)> decodeIncomingProvider(
    Map<String, dynamic> j, SecretKey secret) async {
  final provider = ApiProvider.fromJson(j);
  final env = j['apiKeyEnc'];
  if (env is! String || env.isEmpty) {
    return (provider, null);
  }
  // KeyCrypto.decryptApiKey already returns null (never throws) on any
  // failure — bad json, wrong version, wrong key, tampering.
  final decrypted = await KeyCrypto.decryptApiKey(env, secret);
  return (provider, decrypted);
}
