// Mega-audit 2026-06-04 — STATE batch.
//
//   datamodel-appstore-macros-slash-04 — `mtime` was decoded via raw `_jInt`
//   with no clamp, unlike createdAt/updatedAt (which go through `_jTimestamp`
//   and clamp to [0, now]). A restored backup carrying a future-dated mtime
//   (e.g. 99999999999999) would win EVERY local LWW conflict until wall-clock
//   time passed it. The fix routes every entity's `mtime` decode through a
//   clamp. This test locks the pure clamp's contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('datamodel-appstore-macros-slash-04 — clampMtime', () {
    const now = 5000;

    test('null → 0 (preserves the old `?? 0` default for a missing key)', () {
      expect(clampMtime(null, now), 0);
    });

    test('a sane past value passes through unchanged', () {
      expect(clampMtime(1234, now), 1234);
      expect(clampMtime(now, now), now);
    });

    test('a future-dated value is clamped down to now (kills LWW poisoning)', () {
      expect(clampMtime(99999999999999, now), now);
      expect(clampMtime(now + 1, now), now);
    });

    test('a negative value is floored to 0', () {
      expect(clampMtime(-42, now), 0);
    });

    test('non-int junk decodes to 0', () {
      expect(clampMtime('not-a-number', now), 0);
      expect(clampMtime(<String, dynamic>{}, now), 0);
    });

    test('a num (double) is truncated to int then clamped', () {
      expect(clampMtime(1234.9, now), 1234);
      expect(clampMtime(1e18, now), now); // huge double → clamped to now
    });

    test('is idempotent — feeding the result back in is a no-op', () {
      final first = clampMtime(99999999999999, now);
      expect(clampMtime(first, now), first);
    });
  });
}
