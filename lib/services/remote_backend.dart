// Wave CY.18.71: web/PWA thin-client persistence.
//
// On native (Android, iOS, desktop), AppStore persists to a local
// JSON file via LocalBackend (which wraps JsonStorage). On web/PWA
// that path technically exists (`shared_preferences` on web maps to
// localStorage), but it's capped at ~5MB and isn't shared across
// devices — defeating the whole point of "open Pyre in a tab and
// see the same chats as your phone".
//
// RemoteBackend solves both by NOT persisting sync collections
// locally at all. Every `load()` is a `/pull?since=0` against the
// paired Pyre server; every `save(blob)` is a `/push` with the
// dirty subset. Local-only fields (the user's provider config,
// uiPrefs, botbooru profile) DO still need persistence — they're
// device-specific and the server doesn't know about them — so
// those get squirreled into a tiny `pyre.localPrefs` blob in
// SharedPreferences (~few KB max, well inside the quota).
//
// Web users in this mode are HARD-DEPENDENT on the server being
// reachable. No server = no app. The pair-first splash in
// main.dart enforces that — the user can't even get into the
// regular UI without a working bearer.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'lan_client.dart';
import 'store_backend.dart';

/// Top-level JSON keys that AppStore expects in the blob shape.
/// We split them into "synced" (round-trip through the LAN server's
/// /pull and /push) and "local" (stays on this device only — provider
/// configs, UI prefs, profile fields).
class _BlobSplit {
  /// Fields that the LAN server owns. /pull returns them; /push
  /// expects them. RemoteBackend.load merges them into the blob it
  /// returns to AppStore.
  static const Set<String> synced = {
    'characters',
    'personas',
    'chats',
    'presets',
    'lorebooks',
    // SYNC W3: the usage SETTINGS unit (model/chat/memory/liveSheet/script/
    // guide + the active/creator/vision role pointers) rides the synced set so
    // the web client round-trips it too. Unlike the other entries this is NOT a
    // top-level blob list — it's a synthesized singleton record — so it gets a
    // dedicated translation in load()/save() below (the generic blob-key path
    // never sees a `settings` key). See [_settingsToLocalBlob] / the merge in
    // load().
    'settings',
  };

  /// Fields that are device-local. Persisted to SharedPreferences
  /// under `pyre.localPrefs.v1`. NOT pushed to the server, NOT
  /// affected by /pull.
  ///
  /// Note: `schemaVersion` rides along in the local blob just so
  /// load() can re-emit it without special-casing the merge.
  ///
  /// Wave CY.18.262: `providers` STAYS local-only (never moved to
  /// `synced`). Encrypted key-sync is NATIVE-only by design — the web
  /// client must never receive synced providers/keys. The RemoteBackend
  /// only /pushes + merges /pull collections from `synced`, so providers
  /// never leave or reach the web view through this path; and on the wire
  /// the web pairs via the same `LanClient.pair()` which sends
  /// `native: !kIsWeb` (= false on web), so the server gates providers OFF
  /// for it regardless.
  static const Set<String> local = {
    'schemaVersion',
    'providers',
    'activeProviderId',
    'creatorProviderId',
    'visionProviderId',
    'activePersonaId',
    'activePresetId',
    'characterDrafts',
    'botbooruUsername',
    'botbooruAvatar',
    'botbooruAboutMe',
    'botbooruTitle',
    'botbooruPronouns',
    'botbooruFeaturedCharacterId',
    'installedAt',
    'folders',
    'creatorSessions',
    'activeCreatorSessionId',
    'modelSettings',
    'chatSettings',
    'memorySettings',
    'uiPrefs',
    // C-5 (web-only): device-local LATCH flags. These are written into the
    // blob (app_store.toJson) and read back with `?? false` (app_store.load),
    // but were in NEITHER `synced` NOR `local` — so web `save()` silently
    // dropped them every time. Effect: onboarding re-shows on every web launch
    // (`seenOnboarding` never persists) and the example-seed gate + one-time
    // migrations re-evaluate each boot. They are device-local (never
    // server-owned), so they belong here. Note: app_store omits each from the
    // blob when false, so an unlatched flag simply isn't in `local` — the
    // `containsKey` guard in save() handles that; the `?? false` on read keeps
    // the semantics identical to native.
    'seenOnboarding',
    'exampleContentSeeded',
    'vesnaExamplePersonaSwept',
    'personaDefaultsAdjustedV2',
    'personaDefaultsAdjustedV3',
  };
}

/// PURE (C-5): filter [blob] down to the device-local fields that web `save()`
/// persists to SharedPreferences. Single source of truth for what survives a
/// web round-trip — `RemoteBackend.save()` calls this, and tests pin it so the
/// seed-latch / onboarding flags (which were silently dropped before C-5) are
/// guaranteed to persist. A key absent from [blob] is simply omitted (it stays
/// unset → reads back `?? false`, matching native semantics).
Map<String, dynamic> filterLocalBlob(Map<String, dynamic> blob) {
  final local = <String, dynamic>{};
  for (final k in _BlobSplit.local) {
    if (blob.containsKey(k)) local[k] = blob[k];
  }
  return local;
}

class RemoteBackend implements StoreBackend {
  /// SharedPreferences slot for the local-only field cache. Versioned
  /// in case the split-set evolves and we need to invalidate.
  static const String _localPrefsKey = 'pyre.localPrefs.v1';

  static const Duration _timeout = Duration(seconds: 15);

  RemoteBackend();

  /// Returns the blob shape AppStore expects. Pulls synced
  /// collections from the LAN server and merges them with the local
  /// prefs cached in SharedPreferences. Returns null only on
  /// completely fresh state (not paired or first-ever load with
  /// nothing to merge) — AppStore boots with defaults in that case.
  @override
  Future<Map<String, dynamic>?> load() async {
    final client = LanClient.instance;
    if (!client.isPaired) {
      // Shouldn't normally hit this — the web pair-first splash
      // blocks app boot when unpaired. Defensive return so a race
      // doesn't crash the loader.
      return null;
    }

    // Local prefs are independent of server reachability — load
    // them first so a server outage at startup still surfaces the
    // user's provider config + UI state.
    Map<String, dynamic> local = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_localPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          local = decoded.cast<String, dynamic>();
        }
      }
    } catch (e) {
      debugPrint('[RemoteBackend] local prefs load failed: $e');
    }

    Map<String, dynamic> synced = {};
    try {
      final resp = await http
          .get(
            Uri.parse('${client.baseUrl}/pull?since=0'),
            headers: {'authorization': 'Bearer ${client.bearerToken}'},
          )
          .timeout(_timeout);
      if (resp.statusCode == 401) {
        // Bearer revoked. Disconnect locally so the next boot lands
        // back at the pair-first splash instead of looping forever.
        await client.disconnect();
        debugPrint('[RemoteBackend] server revoked token — disconnected');
        // Return what we have locally so the user at least sees their
        // own provider list, not a totally blank app.
        return local.isEmpty ? null : local;
      }
      if (resp.statusCode != 200) {
        throw _RemoteError(
            'Pull HTTP ${resp.statusCode}: ${resp.body}');
      }
      final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
      final updates =
          (parsed['updates'] as Map?)?.cast<String, dynamic>() ?? {};
      synced = updates;
    } catch (e) {
      // Server unreachable — boot with whatever we have locally. The
      // sync collections will be empty (no chats / characters / etc)
      // until the user retries. Document in the UI later that web
      // offline means read-empty.
      debugPrint('[RemoteBackend] /pull failed: $e — booting with local-only');
    }

    // SYNC W3: the settings UNIT arrives as `updates['settings'] = [record]`
    // (a synthesized singleton), but AppStore.load() reads the settings as
    // TOP-LEVEL blob keys (modelSettings, chatSettings, settingsMtime, the
    // role pointers …). Expand it into those keys here so the generic merge
    // applies it, then drop the raw `settings` key (AppStore ignores it). The
    // expanded keys land in `synced` so they WIN over the locally-cached copies
    // on the merge below — the server's settings are authoritative. The local
    // chat background is re-attached (it's never on the wire).
    _expandSettingsRecord(synced, local);

    // Merge: synced + local. Synced wins on overlap (shouldn't be
    // any except the settings keys we just expanded into `synced`).
    return {...local, ...synced};
  }

  /// SYNC W3: translate `synced['settings'] = [record]` (if present) into the
  /// top-level settings keys AppStore expects, mutating [synced] in place and
  /// removing the `settings` key. [local] supplies the device-local chat
  /// background (never synced) so it survives the apply. No-op when there's no
  /// settings record (offline pull, or server hasn't shipped one).
  static void _expandSettingsRecord(
      Map<String, dynamic> synced, Map<String, dynamic> local) {
    final raw = synced.remove('settings');
    if (raw is! List || raw.isEmpty) return;
    final first = raw.first;
    if (first is! Map) return;
    final rec = first.cast<String, dynamic>();

    void copyObj(String key) {
      final v = rec[key];
      if (v is Map) synced[key] = v.cast<String, dynamic>();
    }

    copyObj('modelSettings');
    copyObj('memorySettings');
    copyObj('liveSheetSettings');
    copyObj('scriptSettings');
    copyObj('guideSettings');

    // chatSettings: re-attach THIS device's local background (the wire copy has
    // none — see AppStore.syncedSettingsToJson).
    final cs = rec['chatSettings'];
    if (cs is Map) {
      final merged = cs.cast<String, dynamic>();
      final localCs = local['chatSettings'];
      if (localCs is Map) {
        final bg = localCs['customBackgroundDataUrl'];
        if (bg is String && bg.isNotEmpty) {
          merged['customBackgroundDataUrl'] = bg;
        }
      }
      synced['chatSettings'] = merged;
    }

    // Provider role pointers are device-local (1.1.2). The server strips them
    // for this non-native web client, so the record usually OMITS them — only
    // adopt one when the key is actually present, otherwise keep the web's own
    // local selection (don't let an absent key null it via the merge).
    if (rec.containsKey('activeProviderId')) {
      synced['activeProviderId'] = rec['activeProviderId'];
    }
    if (rec.containsKey('creatorProviderId')) {
      synced['creatorProviderId'] = rec['creatorProviderId'];
    }
    if (rec.containsKey('visionProviderId')) {
      synced['visionProviderId'] = rec['visionProviderId'];
    }

    final m = (rec['mtime'] as num?)?.toInt();
    if (m != null) synced['settingsMtime'] = m;
  }

  /// SYNC W3: build the wire settings record from AppStore's full [blob] (the
  /// inverse of [_expandSettingsRecord]). Returns null when settings were never
  /// touched (`settingsMtime` absent/0 — AppStore omits it from the blob when
  /// 0), so a fresh web client never pushes an empty settings record. Strips
  /// the chat background image (device-local; never on the wire).
  static Map<String, dynamic>? _settingsRecordFromBlob(
      Map<String, dynamic> blob) {
    final mtime = (blob['settingsMtime'] as num?)?.toInt() ?? 0;
    if (mtime <= 0) return null;
    Map<String, dynamic>? obj(String key) {
      final v = blob[key];
      return v is Map ? v.cast<String, dynamic>() : null;
    }

    // 1.1.2: the web client NEVER pushes the provider-role pointers — they're
    // device-local and would clobber the desktop host's selection (the server
    // also strips them defensively, but don't even send them).
    final rec = <String, dynamic>{
      'mtime': mtime,
    };
    final ms = obj('modelSettings');
    if (ms != null) rec['modelSettings'] = ms;
    final mem = obj('memorySettings');
    if (mem != null) rec['memorySettings'] = mem;
    final ls = obj('liveSheetSettings');
    if (ls != null) rec['liveSheetSettings'] = ls;
    final ss = obj('scriptSettings');
    if (ss != null) rec['scriptSettings'] = ss;
    final gs = obj('guideSettings');
    if (gs != null) rec['guideSettings'] = gs;
    final cs = obj('chatSettings');
    if (cs != null) {
      rec['chatSettings'] = Map<String, dynamic>.from(cs)
        ..remove('customBackgroundDataUrl');
    }
    return rec;
  }

  /// AppStore hands us the full blob on each save. We split: sync
  /// collections → /push, local-only fields → SharedPreferences.
  /// Both writes are best-effort; a network blip doesn't bomb the
  /// local prefs save.
  @override
  Future<void> save(Map<String, dynamic> blob) async {
    final client = LanClient.instance;

    // ---- LOCAL CACHE ----
    try {
      final local = filterLocalBlob(blob);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_localPrefsKey, jsonEncode(local));
    } catch (e) {
      debugPrint('[RemoteBackend] local prefs save failed: $e');
    }

    // ---- /push ----
    if (!client.isPaired) return;
    final dirty = <String, List<Map<String, dynamic>>>{};
    for (final collection in _BlobSplit.synced) {
      final raw = blob[collection];
      if (raw is! List) continue;
      // Push every record this save sees. The server applies LWW —
      // mtime ties or older-than-server are no-ops. Worst case we
      // ship a few extra KB per save, fine on LAN. Future optim:
      // track lastPushedTime and filter by mtime > that.
      final records = <Map<String, dynamic>>[];
      for (final entry in raw) {
        if (entry is Map) {
          records.add(entry.cast<String, dynamic>());
        }
      }
      if (records.isNotEmpty) {
        dirty[collection] = records;
      }
    }
    // SYNC W3: the settings UNIT isn't a top-level blob list — synthesize the
    // singleton record from the blob's settings keys and push it (the server
    // LWW-no-ops if it isn't newer). Only when the user has touched settings
    // (settingsMtime > 0). The chat background is stripped (never on the wire).
    final settingsRec = _settingsRecordFromBlob(blob);
    if (settingsRec != null) {
      dirty['settings'] = [settingsRec];
    }
    if (dirty.isEmpty) return;
    try {
      final resp = await http
          .post(
            Uri.parse('${client.baseUrl}/push'),
            headers: {
              'authorization': 'Bearer ${client.bearerToken}',
              'content-type': 'application/json',
            },
            body: jsonEncode({'updates': dirty}),
          )
          .timeout(_timeout);
      if (resp.statusCode == 401) {
        await client.disconnect();
        debugPrint('[RemoteBackend] push 401 — disconnected');
      } else if (resp.statusCode != 200) {
        debugPrint(
            '[RemoteBackend] push HTTP ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      debugPrint('[RemoteBackend] /push failed: $e — changes stay local-cached');
    }
  }

  /// Wave CY.18.168: factory reset on web/PWA. There are no local rolling
  /// backup files to wipe (state lives on the paired server + a prefs
  /// cache); AppStore.factoryReset() follows this with a save() of the
  /// cleared blob, which overwrites the local cache and pushes the empty
  /// collections. Just drop the local prefs cache here so nothing stale
  /// lingers before that save lands.
  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localPrefsKey);
    } catch (e) {
      debugPrint('[RemoteBackend] clear local cache failed: $e');
    }
  }
}

class _RemoteError implements Exception {
  final String message;
  _RemoteError(this.message);
  @override
  String toString() => message;
}
