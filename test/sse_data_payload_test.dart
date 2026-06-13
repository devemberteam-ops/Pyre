// 1.1.3 fix: the web LAN-proxy reads streamed tokens from SSE `data:` lines.
// The old parse did `line.substring(5).trimLeft()`, but trimLeft() strips ALL
// leading whitespace — including a TOKEN'S OWN leading space (e.g. " world").
// That ran words together on web-initiated responses ("Hello"+"world" =
// "Helloworld"). Per the SSE spec, only the SINGLE optional space right after
// "data:" is a separator and must be removed; everything else is payload.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_api.dart';

void main() {
  group('sseDataPayload', () {
    test('preserves a token\'s OWN leading space (the concatenation bug)', () {
      // "data:" + " " (SSE separator) + " world" (the token) → " world".
      expect(sseDataPayload('data:  world'), ' world');
    });
    test('strips the single SSE separator space', () {
      expect(sseDataPayload('data: hello'), 'hello');
    });
    test('handles no space after the colon', () {
      expect(sseDataPayload('data:hello'), 'hello');
    });
    test('keeps the [DONE] sentinel intact', () {
      expect(sseDataPayload('data: [DONE]'), '[DONE]');
    });
    test('preserves internal and trailing spaces', () {
      expect(sseDataPayload('data: a b '), 'a b ');
    });
  });
}
