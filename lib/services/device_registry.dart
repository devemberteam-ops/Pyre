// Wave CY.18.65: registry of paired devices + active pairing tokens.
//
// The desktop's PyreServer owns one of these. Two kinds of tokens:
//
//   * Pairing token — UUID v4, 5-minute TTL, single-use. Generated
//     by the "Pair new device" flow on desktop, embedded in the QR
//     code. The mobile client redeems it once via POST /pair and
//     receives a long-lived bearer token in return. After redemption
//     the pairing token is invalidated; another scan of the same QR
//     fails (defends against shoulder-surfing screenshots).
//
//   * Bearer token — 256-bit random, base64url-encoded. Issued by
//     /pair, persisted in the registry alongside the device's
//     friendly name, sent on every subsequent /pull, /push,
//     /llm/stream, /attachments call. Revocable from the desktop UI.
//
// The registry is in-memory + JSON-persisted under
// `<app-docs>/EmberChat/lan_devices.json`. NOT in the main state
// blob because (a) it's desktop-only and (b) bearer tokens shouldn't
// surface in a regular backup export.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Directory;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'key_crypto.dart';

/// SHA-256 hex digest of [token]. Used to persist a one-way hash of each
/// device's bearer rather than the raw secret (Wave CY.18.255, audit
/// FIX 2): the raw bearer is handed to the client once at pair time and
/// the client keeps it; the server only ever needs to VERIFY an incoming
/// bearer, so storing the hash is sufficient and means a leaked
/// lan_devices.json no longer yields usable tokens.
String _hashBearer(String token) =>
    sha256.convert(utf8.encode(token)).toString();

/// Constant-time string comparison — avoids leaking how many leading
/// characters of a candidate matched via early-exit timing. Compares the
/// full length of both inputs regardless of where they first differ.
/// Returns false immediately on a length mismatch (length isn't secret
/// here — both are fixed-width hex/UUID strings).
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// One device the user has paired to this PyreServer.
///
/// Wave CY.18.255 (audit FIX 2): we persist only [bearerHash] (a SHA-256
/// of the bearer), never the raw secret. [rawBearer] is a TRANSIENT field
/// populated only at issue time (in [DeviceRegistry.redeemPairing]) so the
/// /pair handler can hand the freshly-minted token to the client once; it
/// is never serialized to disk and is always null for devices reloaded
/// from `lan_devices.json`.
class PairedDevice {
  final String id;
  String name;

  /// SHA-256 hex digest of the device's bearer. This is what gets
  /// persisted + matched on every authenticated request.
  final String bearerHash;

  /// The raw bearer — only set when this record was just minted by
  /// [DeviceRegistry.redeemPairing]. Null for any record loaded from disk.
  /// Never serialized.
  final String? rawBearer;

  final int pairedAt;
  int lastSeen;

  /// Whether this device is a NATIVE peer (mobile/desktop) rather than the
  /// web view. Set at pair time from the client's `native` flag and gates
  /// encrypted API-key sync (Wave CY.18.259): the web view never receives
  /// provider keys. Fail-closed — absent in stored JSON ⇒ false.
  bool isNative;

  PairedDevice({
    required this.id,
    required this.name,
    required this.bearerHash,
    this.rawBearer,
    required this.pairedAt,
    required this.lastSeen,
    this.isNative = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        // Persist ONLY the hash — never the raw bearer.
        'bearerHash': bearerHash,
        'pairedAt': pairedAt,
        'lastSeen': lastSeen,
        if (isNative) 'isNative': true,
      };

  /// Parse a stored record. Migrates the OLD format (a raw `bearerToken`
  /// field) to the new hashed format on read: if there's no `bearerHash`
  /// but there is a legacy `bearerToken`, hash it now. The migrated record
  /// is re-persisted by [DeviceRegistry.load] (which always saves after a
  /// migration), so the raw token leaves disk on the first launch with
  /// this build.
  factory PairedDevice.fromJson(Map<String, dynamic> j) {
    var hash = (j['bearerHash'] as String?) ?? '';
    if (hash.isEmpty) {
      final legacyRaw = (j['bearerToken'] as String?) ?? '';
      if (legacyRaw.isNotEmpty) hash = _hashBearer(legacyRaw);
    }
    return PairedDevice(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? 'Unknown device',
      bearerHash: hash,
      pairedAt: (j['pairedAt'] as num?)?.toInt() ?? 0,
      lastSeen: (j['lastSeen'] as num?)?.toInt() ?? 0,
      // Fail-closed: a record without `isNative` (old format, or a web
      // peer) is treated as non-native, so key-sync stays off for it.
      isNative: (j['isNative'] as bool?) ?? false,
    );
  }
}

/// Active (unconsumed) pairing token. Kept in memory only — if the
/// desktop restarts before the user scans the QR, they generate a new
/// token. That's the safer default than re-loading old tokens (which
/// could grant a stale QR new validity after restart).
class _PairingToken {
  final String token;
  final int issuedAt;
  static const _ttlMs = 5 * 60 * 1000;

  _PairingToken(this.token) : issuedAt = DateTime.now().millisecondsSinceEpoch;

  bool get expired =>
      DateTime.now().millisecondsSinceEpoch - issuedAt > _ttlMs;
}

class DeviceRegistry {
  DeviceRegistry._();
  static final DeviceRegistry instance = DeviceRegistry._();

  static const String _fileName = 'lan_devices.json';

  /// Paired devices keyed by the SHA-256 hash of their bearer (NOT the
  /// raw token — Wave CY.18.255, audit FIX 2).
  final Map<String, PairedDevice> _byHash = {};
  final List<_PairingToken> _pendingPairings = [];
  bool _loaded = false;

  final _changes = StreamController<void>.broadcast();

  /// Broadcasts whenever the paired-device list changes (pair, revoke,
  /// rename). UI bindings the desktop Network screen will subscribe to
  /// this in Wave 68.
  Stream<void> get changes => _changes.stream;

  /// Snapshot of currently paired devices, newest first.
  List<PairedDevice> get paired {
    final list = _byHash.values.toList();
    list.sort((a, b) => b.pairedAt.compareTo(a.pairedAt));
    return list;
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/EmberChat');
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$_fileName');
  }

  /// Lazy load; safe to call repeatedly.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final devices = decoded['devices'];
      // Wave CY.18.255 (audit FIX 2): one-time migration of the OLD
      // plaintext-bearer format. A pre-FIX-2 record stored the raw token
      // under `bearerToken`; PairedDevice.fromJson hashes it on read. If
      // ANY entry needed migrating, we re-save once so the raw token
      // leaves disk on this launch.
      var migrated = false;
      if (devices is List) {
        for (final entry in devices) {
          if (entry is Map) {
            final m = entry.cast<String, dynamic>();
            if ((m['bearerHash'] as String?)?.isNotEmpty != true &&
                (m['bearerToken'] as String?)?.isNotEmpty == true) {
              migrated = true;
            }
            final d = PairedDevice.fromJson(m);
            if (d.bearerHash.isNotEmpty) {
              _byHash[d.bearerHash] = d;
            }
          }
        }
      }
      if (migrated) {
        // Re-persist in the new hashed-only format (no raw tokens).
        await _save();
      }
    } catch (e) {
      debugPrint('[DeviceRegistry] load failed: $e');
    }
  }

  Future<void> _save() async {
    try {
      final f = await _file();
      final blob = {
        'version': 2,
        'devices': _byHash.values.map((d) => d.toJson()).toList(),
      };
      // Atomic write: tmp + rename, same pattern as JsonStorage.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(blob), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('[DeviceRegistry] save failed: $e');
    }
  }

  /// Generate a new one-shot pairing token (5-min TTL). Returns the
  /// raw token string the caller embeds in a QR. Prunes expired
  /// tokens as a side effect.
  String issuePairingToken() {
    _pendingPairings.removeWhere((p) => p.expired);
    final token = const Uuid().v4();
    _pendingPairings.add(_PairingToken(token));
    return token;
  }

  /// Redeem a pairing token, issue a bearer token, register the new
  /// device. Returns null if the pairing token is unknown / expired /
  /// already used.
  Future<PairedDevice?> redeemPairing({
    required String pairingToken,
    required String deviceName,
    bool isNative = false,
  }) async {
    await load();
    _pendingPairings.removeWhere((p) => p.expired);
    // Constant-time match against each pending token (Wave CY.18.255,
    // audit FIX 2). The list is short-lived + small, so the linear scan
    // is fine; we just avoid the early-exit timing of `==`.
    final idx = _pendingPairings
        .indexWhere((p) => _constantTimeEquals(p.token, pairingToken));
    if (idx < 0) return null;
    _pendingPairings.removeAt(idx); // one-shot

    final now = DateTime.now().millisecondsSinceEpoch;
    // Mint the raw bearer once: hand it to the client (via [rawBearer],
    // read by the /pair handler) but persist ONLY its hash.
    final rawBearer = _generateBearerToken();
    final device = PairedDevice(
      id: const Uuid().v4(),
      name: deviceName.trim().isEmpty ? 'Unnamed device' : deviceName.trim(),
      bearerHash: _hashBearer(rawBearer),
      rawBearer: rawBearer,
      pairedAt: now,
      lastSeen: now,
      isNative: isNative,
    );
    _byHash[device.bearerHash] = device;
    await _save();
    _changes.add(null);
    return device;
  }

  /// Look up a device by the RAW bearer token presented on a request.
  /// We hash the incoming bearer and verify it constant-time against the
  /// stored hashes (Wave CY.18.255, audit FIX 2) — the server never holds
  /// the raw token. Bumps lastSeen as a side effect. Returns null when the
  /// token isn't recognised — the auth middleware turns that into a 401.
  Future<PairedDevice?> deviceFor(String bearerToken) async {
    await load();
    final candidateHash = _hashBearer(bearerToken);
    // Constant-time scan: compare the candidate hash against every stored
    // hash without an early-exit map lookup. The device set is tiny (a
    // user's own phones/tablets), so the linear pass is negligible.
    PairedDevice? match;
    for (final entry in _byHash.entries) {
      if (_constantTimeEquals(entry.key, candidateHash)) {
        match = entry.value;
      }
    }
    if (match == null) return null;
    match.lastSeen = DateTime.now().millisecondsSinceEpoch;
    // Lazily persist lastSeen — don't block the request hot path.
    unawaited(_save());
    return match;
  }

  /// Derive a paired device's key-sync secret (AES-256-GCM key) from its
  /// stored bearer-hash (Wave CY.18.259). The server never holds the raw
  /// bearer, so it derives the shared secret from the hash it persisted;
  /// the client derives the same secret from the raw bearer it kept.
  Future<SecretKey> secretForDevice(PairedDevice d) =>
      KeyCrypto.secretForBearerHashHex(d.bearerHash);

  /// Remove a device by its bearer HASH — next call from that device gets
  /// 401. Callers pass [PairedDevice.bearerHash] (the raw token is never
  /// available server-side after pairing).
  Future<void> revoke(String bearerHash) async {
    await load();
    if (_byHash.remove(bearerHash) != null) {
      await _save();
      _changes.add(null);
    }
  }

  String _generateBearerToken() {
    // 32 bytes of entropy, base64url-encoded (no padding) → 43 chars,
    // URL-safe + Authorization-header safe.
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
