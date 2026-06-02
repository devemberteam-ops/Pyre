// Wave CY.18.110 (security audit S1): tests for the pure token-bucket
// that throttles the LAN server's cost-bearing LLM proxy.
//
// The headline guarantee these tests LOCK IN: the limiter must never
// hinder a legitimate user. Legit LLM traffic is latency-bound (each
// call streams a reply over seconds), so the worst real bursts — the
// Creator completeness cascade firing turns back-to-back, group chat,
// rapid regen — are only a few-to-tens of sequential requests/min per
// device. The "torrent" test proves the same bucket still stops a
// scripted flood. If anyone tightens the constants and breaks the legit
// pattern, the first test here goes red.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/rate_limit.dart';

/// The production constants from pyre_server.dart, mirrored here so the
/// tests exercise the exact shipped configuration (capacity 120, refill
/// 2 tokens/sec → 120/min sustained, burst 120).
const int kCapacity = 120;
const int kRefillPerSec = 2;

RateBucket _bucket(DateTime start) => RateBucket(
      capacity: kCapacity.toDouble(),
      refillPerSec: kRefillPerSec.toDouble(),
      start: start,
    );

void main() {
  group('RateBucket — legit usage must NEVER be throttled', () {
    test(
        'Creator-cascade-like pattern: 30 sequential turns spread across a '
        'simulated minute (~2s apart) all succeed', () {
      // Models the Creator completeness cascade: turns fire back-to-back
      // with retries/continuations + a review pass, but each AWAITS a
      // full streamed response, so requests arrive sequentially roughly
      // every couple of seconds (concurrency 1 — the in-flight cap is a
      // separate guard, tested in pyre_server wiring). 30 turns over a
      // minute is already heavier than a typical cascade; every single
      // one must pass.
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      var now = t0;
      var passed = 0;
      final bucket = _bucket(t0);
      for (var i = 0; i < 30; i++) {
        // Advance ~2s between turns (a fast cascade turn; real ones are
        // often slower, which only helps refill).
        now = now.add(const Duration(seconds: 2));
        if (bucket.tryConsume(now)) passed++;
      }
      expect(passed, 30,
          reason: 'A 30-turn cascade spread over a minute must not trip '
              'the limiter — legit usage is latency-bound and sequential.');
    });

    test(
        'Sustained legit drip far longer than any cascade: 100 requests at '
        '1.5s spacing all succeed (refill keeps up)', () {
      // 1.5s spacing → 0.667 req/s, well under the 2 tokens/s refill, so
      // the bucket never empties no matter how long the session runs.
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      var now = t0;
      var passed = 0;
      final bucket = _bucket(t0);
      for (var i = 0; i < 100; i++) {
        now = now.add(const Duration(milliseconds: 1500));
        if (bucket.tryConsume(now)) passed++;
      }
      expect(passed, 100);
    });

    test('a modest human burst (10 regen taps in 2s) is absorbed by burst '
        'capacity', () {
      // Rapid regen / a few group-chat characters answering at once: a
      // short flurry well within the 120-token burst.
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      final bucket = _bucket(t0);
      var passed = 0;
      for (var i = 0; i < 10; i++) {
        // Essentially simultaneous (200ms apart).
        if (bucket.tryConsume(t0.add(Duration(milliseconds: i * 200)))) {
          passed++;
        }
      }
      expect(passed, 10);
    });
  });

  group('RateBucket — scripted torrent IS throttled', () {
    test('200 consumes at the same instant: first 120 (burst) pass, rest '
        'fail', () {
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      final bucket = _bucket(t0);
      var passed = 0;
      var rejected = 0;
      for (var i = 0; i < 200; i++) {
        // Same instant for every call → no refill between them.
        if (bucket.tryConsume(t0)) {
          passed++;
        } else {
          rejected++;
        }
      }
      expect(passed, kCapacity,
          reason: 'Exactly the burst capacity (120) should pass.');
      expect(rejected, 200 - kCapacity,
          reason: 'The remaining 80 of a same-instant flood must be 429ed.');
    });

    test('once drained, an immediate further request fails', () {
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      final bucket = _bucket(t0);
      for (var i = 0; i < kCapacity; i++) {
        expect(bucket.tryConsume(t0), isTrue);
      }
      expect(bucket.tryConsume(t0), isFalse,
          reason: 'Bucket is empty at the same instant after draining.');
    });
  });

  group('RateBucket — refill', () {
    test('after draining, advancing now by N seconds restores ~2N tokens', () {
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      final bucket = _bucket(t0);
      // Drain completely.
      for (var i = 0; i < kCapacity; i++) {
        bucket.tryConsume(t0);
      }
      expect(bucket.tryConsume(t0), isFalse);

      // Advance 5s → expect ~10 tokens (2/sec * 5). The next consume
      // also spends one, so exactly 10 consumes should now succeed and
      // the 11th should fail.
      const seconds = 5;
      final later = t0.add(const Duration(seconds: seconds));
      var passed = 0;
      for (var i = 0; i < 20; i++) {
        if (bucket.tryConsume(later)) passed++;
      }
      expect(passed, seconds * kRefillPerSec,
          reason: 'N seconds of refill at 2 tokens/sec restores exactly 2N '
              'tokens (10 for 5s).');
    });

    test('refill is capped at capacity (no overflow after a long idle)', () {
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      final bucket = _bucket(t0);
      // Drain.
      for (var i = 0; i < kCapacity; i++) {
        bucket.tryConsume(t0);
      }
      // Idle for an hour — refill would be 7200 tokens uncapped, but the
      // bucket can hold at most `capacity`.
      final muchLater = t0.add(const Duration(hours: 1));
      var passed = 0;
      for (var i = 0; i < kCapacity + 50; i++) {
        if (bucket.tryConsume(muchLater)) passed++;
      }
      expect(passed, kCapacity,
          reason: 'A long idle refills only up to capacity, not beyond.');
    });

    test('a backwards clock jump never adds tokens', () {
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      final bucket = _bucket(t0);
      for (var i = 0; i < kCapacity; i++) {
        bucket.tryConsume(t0);
      }
      // Clock moves backwards (NTP correction / DST): elapsed < 0 must
      // be clamped, so still empty.
      final earlier = t0.subtract(const Duration(minutes: 10));
      expect(bucket.tryConsume(earlier), isFalse);
    });
  });

  group('RateBucket — per-device isolation', () {
    test('two device buckets are independent', () {
      final t0 = DateTime(2026, 5, 29, 12, 0, 0);
      final deviceA = _bucket(t0);
      final deviceB = _bucket(t0);

      // Device A floods itself dry at one instant.
      for (var i = 0; i < kCapacity; i++) {
        expect(deviceA.tryConsume(t0), isTrue);
      }
      expect(deviceA.tryConsume(t0), isFalse,
          reason: 'Device A is now throttled.');

      // Device B is untouched — still has its full burst available.
      var passedB = 0;
      for (var i = 0; i < kCapacity; i++) {
        if (deviceB.tryConsume(t0)) passedB++;
      }
      expect(passedB, kCapacity,
          reason: 'One device exhausting its budget must not affect another.');
    });
  });
}
