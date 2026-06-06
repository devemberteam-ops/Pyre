import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_api.dart' show scrubProviderBody;

// Audit 2026-06-04 [providers-01]: the Browse-models picker, Test-connection,
// and context-window fetch surfaced raw provider error bodies with no
// redaction (unlike the chat path). A misbehaving proxy that reflects the
// request `Authorization: Bearer <key>` into its 4xx body would put the key
// on-screen and screenshottable. These cases pin the scrub the chat path
// already uses, now shared via the public `scrubProviderBody`.
void main() {
  group('scrubProviderBody (shared with Browse/Test/ctx-fetch)', () {
    test('redacts a reflected Bearer token', () {
      const key = 'sk-abcd1234efgh5678ijkl';
      final body = '{"error":"unauthorized: Bearer $key"}';
      final out = scrubProviderBody(body, apiKey: key);
      expect(out.contains(key), isFalse, reason: 'raw key must not survive');
      expect(out.contains('[redacted]'), isTrue);
    });

    test('redacts an Authorization header echo', () {
      const key = 'verysecretkeyvalue1234';
      final body = 'Authorization: $key\nrejected';
      final out = scrubProviderBody(body, apiKey: key);
      expect(out.contains(key), isFalse);
    });

    test('redacts the literal active key even in an unrecognized shape', () {
      const key = '9f3a8c7b6d5e4f3a2b1c0d9e';
      final body = '{"message":"Invalid API key: $key"}';
      final out = scrubProviderBody(body, apiKey: key);
      expect(out.contains(key), isFalse);
      expect(out.contains('[redacted-key]'), isTrue);
    });

    test('leaves a key-free body untouched', () {
      const body = '{"error":"model not found"}';
      expect(scrubProviderBody(body), body);
    });
  });
}
