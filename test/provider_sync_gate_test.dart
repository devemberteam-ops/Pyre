// Wave CY.18.260: unit test for the pure server-side provider-sync gate.
//
// The full server pull/push paths need a running shelf server, but the
// gating decision is a pure boolean function: providers (which carry the
// API key) are exchanged ONLY when the host has opted in AND the peer is a
// native device. This locks in the fail-closed truth table so a regression
// that leaks keys to web (non-native) or to an opted-out host is caught.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/pyre_server.dart';

void main() {
  group('shouldSyncProviders', () {
    test('only flag ON AND native peer permits providers', () {
      expect(shouldSyncProviders(true, true), isTrue);
    });
    test('flag OFF blocks even a native peer', () {
      expect(shouldSyncProviders(false, true), isFalse);
    });
    test('non-native peer blocked even with flag ON (web never gets keys)', () {
      expect(shouldSyncProviders(true, false), isFalse);
    });
    test('both off blocks', () {
      expect(shouldSyncProviders(false, false), isFalse);
    });
  });
}
