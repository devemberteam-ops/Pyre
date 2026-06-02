// Wave CY.18.110 (security audit S1): per-device rate limiting for the
// LAN sync server's cost-bearing LLM proxy (`POST /llm/stream` in
// pyre_server.dart). A paired remote device asks the desktop to run an
// LLM call on the desktop's API key, so an abusive/compromised paired
// device could otherwise spend the user's budget unbounded.
//
// This file holds ONLY the pure, deterministic bucket. All I/O,
// globals, and HTTP wiring live in pyre_server.dart so this stays
// trivially unit-testable: `now` is injected, nothing reads the wall
// clock on its own.
//
// ─── Why the limits are DELIBERATELY GENEROUS ───────────────────────
// Legitimate LLM calls are LATENCY-BOUND: each one streams a response
// over several seconds, so even heavy real usage is only a handful to a
// few tens of requests per minute per device. The worst legit bursts:
//   * Creator completeness cascade (character_assistant_screen.dart):
//     fires turns back-to-back with retries/continuations + a review
//     pass — but each turn AWAITS a full streamed response, so it's
//     sequential (~1 request every several seconds; concurrency 1).
//   * Group chat: a few characters answering at once (concurrency ~a
//     handful, not hundreds).
//   * Rapid regen: a human re-rolling a reply — bounded by reading time.
// A malicious script, by contrast, fires hundreds-to-thousands of
// requests per minute and/or opens many concurrent streams. The caps
// below sit FAR above any legit pattern so only the scripted torrent
// trips them. They must NEVER hinder a real user.

/// A pure token-bucket rate limiter.
///
/// Refills continuously at [refillPerSec] tokens/second up to [capacity]
/// tokens (which also sets the maximum instantaneous burst). Each
/// successful [tryConsume] removes exactly one token.
///
/// The bucket holds no timers and never reads the clock itself — the
/// caller passes `now` on every call and the bucket refills lazily based
/// on the time elapsed since the previous call. This makes behaviour
/// fully deterministic in tests (advance a fake `now`) and avoids any
/// background work in production (refill is computed on demand).
class RateBucket {
  RateBucket({
    required this.capacity,
    required this.refillPerSec,
    DateTime? start,
    double? initialTokens,
  })  : _tokens = initialTokens ?? capacity.toDouble(),
        _last = start;

  /// Maximum tokens the bucket can hold = the largest allowed burst.
  final double capacity;

  /// Tokens regenerated per second of elapsed wall-clock time.
  final double refillPerSec;

  double _tokens;
  DateTime? _last;

  /// Current token count (after lazy refill is NOT applied — this is the
  /// value as of the last [tryConsume]). Exposed for tests/diagnostics.
  double get tokens => _tokens;

  /// Refill based on time elapsed since the last call, then try to spend
  /// one token. Returns true if a token was available (and consumed),
  /// false if the bucket is empty (caller should reject, e.g. HTTP 429).
  ///
  /// [now] is injected so the bucket is deterministic and clock-free.
  /// A non-monotonic `now` (clock moved backwards) never adds tokens —
  /// elapsed is clamped to >= 0.
  bool tryConsume(DateTime now) {
    final last = _last;
    if (last != null) {
      final elapsedMs = now.difference(last).inMicroseconds / 1000.0;
      if (elapsedMs > 0) {
        _tokens += (elapsedMs / 1000.0) * refillPerSec;
        if (_tokens > capacity) _tokens = capacity;
      }
    }
    _last = now;
    if (_tokens >= 1.0) {
      _tokens -= 1.0;
      return true;
    }
    return false;
  }
}
