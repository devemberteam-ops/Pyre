// TDD: pure PairingRequests lifecycle.
//
// All targets from the spec's "TDD targets":
//   create returns pending + unique id
//   poll(pending) = pending
//   approve → poll returns approved+bearer ONCE then expired
//   deny → poll denied once
//   expired after TTL
//   atCapacity → reject
//   unknown id = expired (no oracle)
//   requestId distinct/long
//   Bearer mint fn called only on approve

import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/services/pairing_requests.dart';

void main() {
  // ── helpers ────────────────────────────────────────────────────────────

  int mintCount = 0;
  String mockMint() {
    mintCount++;
    return 'bearer-$mintCount';
  }

  setUp(() => mintCount = 0);

  const ttl = 120 * 1000; // 120 s, same as default

  PairingRequests make({int cap = 5}) => PairingRequests(
        ttlMs: ttl,
        maxPending: cap,
        mintBearer: mockMint,
      );

  const t0 = 1_000_000; // arbitrary epoch ms

  // ── create ─────────────────────────────────────────────────────────────

  test('create returns a PendingPairRequest with status pending', () {
    final pr = make();
    final req = pr.create(
      deviceName: 'My browser',
      native: false,
      requesterLabel: 'http://192.168.0.45:6767',
      nowMs: t0,
    );
    expect(req.status, PairStatus.pending);
    expect(req.requestId, isNotEmpty);
    expect(req.deviceName, 'My browser');
    expect(req.native, isFalse);
    expect(req.requesterLabel, 'http://192.168.0.45:6767');
    expect(req.createdAtMs, t0);
  });

  test('create generates unique requestIds', () {
    final pr = make();
    final ids = {
      for (var i = 0; i < 20; i++)
        pr.create(nowMs: t0).requestId,
    };
    expect(ids.length, 20); // all distinct
  });

  test('requestId is long (at least 32 chars = 192 bits base64)', () {
    final pr = make();
    final id = pr.create(nowMs: t0).requestId;
    expect(id.length, greaterThanOrEqualTo(32));
  });

  // ── poll(pending) ──────────────────────────────────────────────────────

  test('poll on a pending request returns pending', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    final result = pr.poll(req.requestId, nowMs: t0 + 1000);
    expect(result.status, PairStatus.pending);
    expect(result.bearer, isNull);
    expect(result.deviceId, isNull);
  });

  // ── approve ────────────────────────────────────────────────────────────

  test('approve flips status to approved and returns ApproveResult', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    final result = pr.approve(req.requestId, nowMs: t0 + 100);
    expect(result, isNotNull);
    expect(result!.bearer, isNotEmpty);
    expect(result.deviceId, isNotEmpty);
  });

  test('poll after approve returns approved with bearer ONCE then expired', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    pr.approve(req.requestId, nowMs: t0 + 100);

    // First poll: approved + bearer
    final first = pr.poll(req.requestId, nowMs: t0 + 200);
    expect(first.status, PairStatus.approved);
    expect(first.bearer, 'bearer-1'); // our mock mint
    expect(first.deviceId, isNotNull);
    expect(first.deviceId, isNotEmpty);

    // Second poll: entry dropped → expired (no oracle)
    final second = pr.poll(req.requestId, nowMs: t0 + 300);
    expect(second.status, PairStatus.expired);
    expect(second.bearer, isNull);
  });

  test('bearer mint fn called exactly once on approve, not before', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    expect(mintCount, 0, reason: 'create must not mint');

    // Poll before approve also must not mint
    pr.poll(req.requestId, nowMs: t0 + 100);
    expect(mintCount, 0, reason: 'poll(pending) must not mint');

    final ar = pr.approve(req.requestId, nowMs: t0 + 200);
    expect(ar, isNotNull);
    expect(mintCount, 1, reason: 'approve must mint exactly once');

    // Consuming poll doesn't mint again
    pr.poll(req.requestId, nowMs: t0 + 300);
    expect(mintCount, 1);
  });

  // ── deny ───────────────────────────────────────────────────────────────

  test('deny flips status to denied and returns true', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    final ok = pr.deny(req.requestId);
    expect(ok, isTrue);
  });

  test('poll after deny returns denied ONCE then entry is dropped', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    pr.deny(req.requestId);

    final first = pr.poll(req.requestId, nowMs: t0 + 100);
    expect(first.status, PairStatus.denied);
    expect(first.bearer, isNull);

    // Second poll: dropped → expired
    final second = pr.poll(req.requestId, nowMs: t0 + 200);
    expect(second.status, PairStatus.expired);
  });

  test('deny does not mint bearer', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    pr.deny(req.requestId);
    pr.poll(req.requestId, nowMs: t0 + 100);
    expect(mintCount, 0, reason: 'deny must never mint');
  });

  // ── TTL expiry ─────────────────────────────────────────────────────────

  test('pending request expires after TTL', () {
    final pr = make();
    final req = pr.create(nowMs: t0);

    // Just under TTL: still pending
    final before = pr.poll(req.requestId, nowMs: t0 + ttl - 1);
    expect(before.status, PairStatus.pending);

    // At or past TTL: expired
    final after = pr.poll(req.requestId, nowMs: t0 + ttl);
    expect(after.status, PairStatus.expired);
  });

  test('pruneExpired removes pending requests past TTL', () {
    final pr = make();
    final req = pr.create(nowMs: t0);

    pr.pruneExpired(nowMs: t0 + ttl + 1);
    // Entry gone — poll sees expired
    final result = pr.poll(req.requestId, nowMs: t0 + ttl + 2);
    expect(result.status, PairStatus.expired);
  });

  // ── atCapacity ─────────────────────────────────────────────────────────

  test('atCapacity returns false when under the cap', () {
    final pr = make(cap: 3);
    expect(pr.atCapacity(nowMs: t0), isFalse);
    pr.create(nowMs: t0);
    expect(pr.atCapacity(nowMs: t0), isFalse);
    pr.create(nowMs: t0);
    expect(pr.atCapacity(nowMs: t0), isFalse);
  });

  test('atCapacity returns true when pending count reaches maxPending', () {
    final pr = make(cap: 2);
    pr.create(nowMs: t0);
    pr.create(nowMs: t0);
    expect(pr.atCapacity(nowMs: t0), isTrue);
  });

  test('atCapacity considers pruning: expired slots free up capacity', () {
    final pr = make(cap: 1);
    pr.create(nowMs: t0);
    expect(pr.atCapacity(nowMs: t0), isTrue);

    // After TTL + prune the slot is free
    expect(pr.atCapacity(nowMs: t0 + ttl + 1), isFalse);
  });

  // ── unknown / expired id → no oracle ──────────────────────────────────

  test('poll on completely unknown id returns expired (no oracle)', () {
    final pr = make();
    final result = pr.poll('totally-unknown-id', nowMs: t0);
    expect(result.status, PairStatus.expired,
        reason: 'unknown id must return same as expired to avoid oracle');
  });

  test('approve unknown id returns null', () {
    final pr = make();
    expect(pr.approve('no-such-id', nowMs: t0), isNull);
  });

  test('deny unknown id returns false', () {
    final pr = make();
    expect(pr.deny('no-such-id'), isFalse);
  });

  // ── constant-time compare safety ─────────────────────────────────────

  test('requestId comparison is correct (same vs different)', () {
    final pr = make();
    final req = pr.create(nowMs: t0);
    // Approve should work with the exact id
    expect(pr.approve(req.requestId, nowMs: t0 + 1), isNotNull);

    final pr2 = make();
    final req2 = pr2.create(nowMs: t0);
    // Slightly different id (one char off) must NOT approve
    final badId =
        '${req2.requestId.substring(0, req2.requestId.length - 1)}X';
    // Only if it's actually different (last char was not already 'X')
    if (badId != req2.requestId) {
      expect(pr2.approve(badId, nowMs: t0 + 1), isNull);
    }
  });
}
