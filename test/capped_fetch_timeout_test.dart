// Mega-audit 2026-06-05 (M-2): the card-fetch helper must fail fast on a
// stalled host instead of hanging the import spinner forever.
//
// Real network is not exercised here; instead an injected http.Client whose
// `send` never completes proves the connect/overall timeout fires and the
// call throws a TimeoutException well within the configured bound.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pyre/services/capped_fetch.dart';

/// A client whose `send` returns a Future that never completes — simulates a
/// host that accepts the socket but never sends response headers.
class _NeverCompletingClient extends http.BaseClient {
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future; // never completes
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  group('fetchCappedNoRedirect — M-2 timeout', () {
    test('throws TimeoutException when the host never responds', () async {
      final client = _NeverCompletingClient();
      // Inject tiny timeouts so the test proves the timeout fires in
      // milliseconds rather than waiting the production 30s/60s.
      await expectLater(
        fetchCappedNoRedirect(
          Uri.parse('https://stalled.example/card.png'),
          client: client,
          connectTimeout: const Duration(milliseconds: 20),
          overallTimeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('timeout constants are wired and sanely ordered', () {
      // The connect timeout must be <= the overall timeout, and both must be
      // positive and bounded (no accidental zero / infinite values).
      expect(kFetchConnectTimeout, greaterThan(Duration.zero));
      expect(kFetchOverallTimeout, greaterThan(Duration.zero));
      expect(kFetchConnectTimeout <= kFetchOverallTimeout, isTrue);
    });
  });
}
