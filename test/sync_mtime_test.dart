// LAN-sync correctness: tests for the zero-mtime repair helper.
//
// Seeded example records (and any pre-sync record) can be persisted at
// `mtime == 0`. The server's `/pull` only ships records where
// `mtime > since`, and a fresh client pulls with `since == 0` — so a
// `mtime == 0` record (`0 > 0` is false) would NEVER sync. The load-time
// migration in `AppStore.load()` repairs this by stamping a real
// timestamp via `stampMtimeIfZero`. These tests lock in its three
// branches and its idempotency.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/state/app_store.dart';

void main() {
  group('stampMtimeIfZero', () {
    const now = 5000;

    test('mtime == 0 & updatedAt > 0 → adopts updatedAt', () {
      expect(stampMtimeIfZero(0, 1234, now), 1234);
    });

    test('mtime == 0 & updatedAt == 0 → falls back to now', () {
      expect(stampMtimeIfZero(0, 0, now), now);
    });

    test('mtime > 0 → unchanged (never clobbers an existing timestamp)', () {
      expect(stampMtimeIfZero(42, 1234, now), 42);
      // Even when the existing mtime is older than updatedAt, the record's
      // own mtime wins — the migration only ever fills a true zero.
      expect(stampMtimeIfZero(7, 9999, now), 7);
    });

    test('is idempotent — feeding the result back in is a no-op', () {
      final first = stampMtimeIfZero(0, 1234, now);
      expect(stampMtimeIfZero(first, 1234, now), first);

      final firstNowFallback = stampMtimeIfZero(0, 0, now);
      expect(stampMtimeIfZero(firstNowFallback, 0, now), firstNowFallback);
    });
  });
}
