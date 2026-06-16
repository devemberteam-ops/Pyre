// Desktop-confirmation web pairing — pure lifecycle.
//
// This file holds ONLY the pure, clock/HTTP-free PairingRequests state
// machine so the entire lifecycle is unit-testable without any I/O.
// All time injection: callers pass `nowMs`. Bearer minting is injected
// via the `mintBearer` function parameter so tests can verify the mint
// is called exactly once on approve and never elsewhere.
//
// Security invariants enforced here:
//   • No bearer is ever minted before approve().
//   • requestId is cryptographically random + unguessable (256-bit).
//   • poll() does NOT distinguish unknown vs expired (no oracle).
//   • poll(approved) delivers bearer exactly ONCE then drops the entry.
//   • poll(denied) delivers status exactly ONCE then drops the entry.
//   • Capacity cap prevents dialog-spam DoS.

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

/// Status of a pending pair request (from the perspective of the poller).
enum PairStatus { pending, approved, denied, expired }

/// A single in-flight pairing request (value type — immutable apart from
/// the mutable _status/_rawBearer fields managed by [PairingRequests]).
class PendingPairRequest {
  final String requestId;
  final String deviceName;
  final bool native;

  /// Display-only: the Origin header or remote address. NEVER used for
  /// auth decisions (DNS-rebinding-safe).
  final String requesterLabel;

  final int createdAtMs;
  PairStatus status;

  /// Transient raw bearer minted at approve time. Null until approved;
  /// cleared (entry dropped) after the first consuming poll.
  String? _rawBearer;

  /// Stable device id assigned at approve time (UUID v4). Null until
  /// approved; cleared with the entry after the consuming poll.
  String? _deviceId;

  PendingPairRequest({
    required this.requestId,
    required this.deviceName,
    required this.native,
    required this.requesterLabel,
    required this.createdAtMs,
  }) : status = PairStatus.pending;

  bool isExpired(int nowMs, int ttlMs) => nowMs - createdAtMs >= ttlMs;
}

/// The poll result returned by [PairingRequests.poll].
class PairPollResult {
  final PairStatus status;

  /// Non-null only when status == [PairStatus.approved] (the one delivery).
  final String? bearer;

  /// Non-null only when status == [PairStatus.approved].
  final String? deviceId;

  const PairPollResult._(this.status, {this.bearer, this.deviceId});

  factory PairPollResult.pending() =>
      const PairPollResult._(PairStatus.pending);
  factory PairPollResult.approved(String bearer, String deviceId) =>
      PairPollResult._(PairStatus.approved, bearer: bearer, deviceId: deviceId);
  factory PairPollResult.denied() =>
      const PairPollResult._(PairStatus.denied);
  factory PairPollResult.expired() =>
      const PairPollResult._(PairStatus.expired);
}

/// Return value from [PairingRequests.approve] — carries the freshly-minted
/// bearer and assigned deviceId so the caller (PyreServer) can register the
/// PairedDevice in DeviceRegistry without needing to read internal fields.
class ApproveResult {
  final String bearer;
  final String deviceId;
  const ApproveResult({required this.bearer, required this.deviceId});
}

/// Pure in-memory store for pending pair requests.
///
/// Inject [mintBearer] (e.g. DeviceRegistry._generateBearerToken-equivalent)
/// and [ttlMs] / [maxPending] for full testability. No timers, no I/O.
class PairingRequests {
  PairingRequests({
    this.ttlMs = 120 * 1000,
    this.maxPending = 5,
    required String Function() mintBearer,
    // private field + public param name is intentional (callers pass
    // `mintBearer:`); an initializing formal would force a `_`-named param.
    // ignore: prefer_initializing_formals
  }) : _mintBearer = mintBearer;

  final int ttlMs;
  final int maxPending;
  final String Function() _mintBearer;

  // keyed by requestId (full string — matched constant-time in poll)
  final Map<String, PendingPairRequest> _requests = {};

  // ── creation ────────────────────────────────────────────────────────────

  /// Register a new pending request. Callers MUST check [atCapacity] first
  /// (which also prunes expired entries) and reject with 429 if true.
  PendingPairRequest create({
    String deviceName = '',
    bool native = false,
    String requesterLabel = '',
    required int nowMs,
  }) {
    final id = _generateRequestId();
    final req = PendingPairRequest(
      requestId: id,
      deviceName: deviceName,
      native: native,
      requesterLabel: requesterLabel,
      createdAtMs: nowMs,
    );
    _requests[id] = req;
    return req;
  }

  // ── poll ────────────────────────────────────────────────────────────────

  /// Query the status of a request by id.
  ///
  /// Security: unknown id returns [PairStatus.expired] — same as an expired
  /// entry — so a brute-force attacker learns nothing about whether a given
  /// id ever existed (no oracle).
  ///
  /// Consuming semantics: approved and denied entries are dropped on first
  /// read so the bearer is delivered at most once.
  PairPollResult poll(String requestId, {required int nowMs}) {
    // constant-time lookup — linear scan over the (tiny) map so we compare
    // every entry with _constantTimeEquals and don't short-circuit on a hit.
    PendingPairRequest? found;
    for (final entry in _requests.entries) {
      if (_constantTimeEquals(entry.key, requestId)) {
        found = entry.value;
      }
    }
    if (found == null) return PairPollResult.expired();

    // TTL check (pending only — approved/denied entries have finite lifetime
    // regardless, consumed on first poll).
    if (found.status == PairStatus.pending &&
        found.isExpired(nowMs, ttlMs)) {
      _requests.remove(found.requestId);
      return PairPollResult.expired();
    }

    switch (found.status) {
      case PairStatus.pending:
        return PairPollResult.pending();

      case PairStatus.approved:
        final bearer = found._rawBearer!;
        final deviceId = found._deviceId!;
        // Drop the entry — bearer delivered exactly once.
        _requests.remove(found.requestId);
        return PairPollResult.approved(bearer, deviceId);

      case PairStatus.denied:
        // Drop the entry after delivering denied once.
        _requests.remove(found.requestId);
        return PairPollResult.denied();

      case PairStatus.expired:
        _requests.remove(found.requestId);
        return PairPollResult.expired();
    }
  }

  // ── approve / deny ──────────────────────────────────────────────────────

  /// Approve the request identified by [requestId]. Mints the bearer (exactly
  /// once) and stores it transiently on the request for the next poll to
  /// consume. Returns an [ApproveResult] with the minted bearer + deviceId on
  /// success, or null if the request is unknown, already decided, or expired.
  ///
  /// [nowMs] is used for the TTL check.
  ApproveResult? approve(String requestId, {required int nowMs}) {
    final req = _findConstantTime(requestId);
    if (req == null || req.status != PairStatus.pending) return null;
    if (req.isExpired(nowMs, ttlMs)) {
      _requests.remove(req.requestId);
      return null;
    }
    req._rawBearer = _mintBearer(); // one and only mint
    req._deviceId = const Uuid().v4();
    req.status = PairStatus.approved;
    return ApproveResult(bearer: req._rawBearer!, deviceId: req._deviceId!);
  }

  /// Deny the request. Returns true if found and flipped.
  bool deny(String requestId) {
    final req = _findConstantTime(requestId);
    if (req == null || req.status != PairStatus.pending) return false;
    req.status = PairStatus.denied;
    return true;
  }

  // ── lookup (for server-side use) ────────────────────────────────────────

  /// Return the request for [requestId] using constant-time comparison.
  /// Exposed for PyreServer so it can read display fields (deviceName, native)
  /// before approving. Returns null if not found.
  PendingPairRequest? findById(String requestId) =>
      _findConstantTime(requestId);

  // ── capacity / pruning ───────────────────────────────────────────────────

  /// Prune all pending entries that have passed TTL.
  void pruneExpired({required int nowMs}) {
    _requests.removeWhere(
      (_, r) =>
          r.status == PairStatus.pending && r.isExpired(nowMs, ttlMs),
    );
  }

  /// Returns true if the number of PENDING (not expired) requests is at or
  /// above [maxPending]. Prunes expired entries first so they don't count
  /// against the cap (frees capacity for legitimate new requests after old
  /// ones time out).
  bool atCapacity({required int nowMs}) {
    pruneExpired(nowMs: nowMs);
    final pendingCount =
        _requests.values.where((r) => r.status == PairStatus.pending).length;
    return pendingCount >= maxPending;
  }

  // ── private helpers ─────────────────────────────────────────────────────

  /// Look up a request by id using constant-time comparison. Linear scan
  /// over the tiny map — safe because the set is always small.
  PendingPairRequest? _findConstantTime(String requestId) {
    PendingPairRequest? found;
    for (final entry in _requests.entries) {
      if (_constantTimeEquals(entry.key, requestId)) {
        found = entry.value;
      }
    }
    return found;
  }

  /// 256-bit cryptographically random id, base64url-encoded (no padding).
  /// Same generator style as DeviceRegistry._generateBearerToken.
  static String _generateRequestId() {
    final rng = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = rng.nextInt(256);
    }
    // base64url without padding: 32 bytes → 43 chars
    const b64Chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final buf = StringBuffer();
    for (var i = 0; i < 32; i += 3) {
      final b0 = bytes[i];
      final b1 = i + 1 < 32 ? bytes[i + 1] : 0;
      final b2 = i + 2 < 32 ? bytes[i + 2] : 0;
      buf.write(b64Chars[(b0 >> 2) & 0x3F]);
      buf.write(b64Chars[((b0 << 4) | (b1 >> 4)) & 0x3F]);
      if (i + 1 < 32) buf.write(b64Chars[((b1 << 2) | (b2 >> 6)) & 0x3F]);
      if (i + 2 < 32) buf.write(b64Chars[b2 & 0x3F]);
    }
    return buf.toString();
  }

  /// Constant-time string comparison. Returns false immediately on length
  /// mismatch (length is not secret — both ids are fixed-width 43-char strings).
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
