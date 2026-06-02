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
  };
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

    // Merge: synced + local. Synced wins on overlap (shouldn't be
    // any, the two sets are disjoint by construction).
    return {...local, ...synced};
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
      final local = <String, dynamic>{};
      for (final k in _BlobSplit.local) {
        if (blob.containsKey(k)) local[k] = blob[k];
      }
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
