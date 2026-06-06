// SYNC W5 (transparency UI): unit tests for the PURE relativeSyncTime helper
// that drives the SyncStatusPill's "Synced <relative> ago" label. The widget
// itself is mostly presentation; the only logic worth pinning down is the
// bucketing of a duration into a casual label, which we exercise here across
// every bucket boundary.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/widgets/sync_status_pill.dart';

void main() {
  // A fixed "now" so the tests are deterministic — relativeSyncTime takes both
  // instants, so there's no real clock involved.
  final now = DateTime(2026, 6, 5, 12, 0, 0);

  DateTime ago({int days = 0, int hours = 0, int minutes = 0, int seconds = 0}) {
    return now.subtract(Duration(
      days: days,
      hours: hours,
      minutes: minutes,
      seconds: seconds,
    ));
  }

  group('relativeSyncTime', () {
    test('< 10s → "just now"', () {
      expect(relativeSyncTime(now, ago(seconds: 0)), 'just now');
      expect(relativeSyncTime(now, ago(seconds: 9)), 'just now');
    });

    test('a future timestamp (clock skew) clamps to "just now"', () {
      expect(
        relativeSyncTime(now, now.add(const Duration(seconds: 5))),
        'just now',
      );
    });

    test('10–59s → "Ns ago"', () {
      expect(relativeSyncTime(now, ago(seconds: 10)), '10s ago');
      expect(relativeSyncTime(now, ago(seconds: 42)), '42s ago');
      expect(relativeSyncTime(now, ago(seconds: 59)), '59s ago');
    });

    test('1–59m → "Nm ago"', () {
      expect(relativeSyncTime(now, ago(minutes: 1)), '1m ago');
      expect(relativeSyncTime(now, ago(minutes: 2)), '2m ago');
      expect(relativeSyncTime(now, ago(minutes: 59)), '59m ago');
    });

    test('60s boundary rolls into minutes', () {
      expect(relativeSyncTime(now, ago(seconds: 60)), '1m ago');
    });

    test('1–23h → "Nh ago"', () {
      expect(relativeSyncTime(now, ago(hours: 1)), '1h ago');
      expect(relativeSyncTime(now, ago(hours: 5)), '5h ago');
      expect(relativeSyncTime(now, ago(hours: 23)), '23h ago');
    });

    test('60m boundary rolls into hours', () {
      expect(relativeSyncTime(now, ago(minutes: 60)), '1h ago');
    });

    test('>= 24h → "Nd ago"', () {
      expect(relativeSyncTime(now, ago(hours: 24)), '1d ago');
      expect(relativeSyncTime(now, ago(days: 2)), '2d ago');
      expect(relativeSyncTime(now, ago(days: 10)), '10d ago');
    });
  });
}
