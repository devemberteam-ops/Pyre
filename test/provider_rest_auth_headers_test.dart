// 2026-07-03: the "Test connection" probe and the model browser always sent
// `Authorization: Bearer`, so a native-Anthropic provider with a VALID Claude
// key got a 401 and the user concluded their key was bad — on the app's
// make-or-break first screen. providerRestAuthHeaders picks the dialect the
// chat path already uses.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart' show ApiFormat;
import 'package:pyre/services/chat_api.dart' show providerRestAuthHeaders;

void main() {
  group('providerRestAuthHeaders', () {
    test('OpenAI-compatible → Bearer', () {
      final h = providerRestAuthHeaders(
          format: ApiFormat.openai, apiKey: 'sk-abc');
      expect(h['Authorization'], 'Bearer sk-abc');
      expect(h.containsKey('x-api-key'), isFalse);
    });

    test('native Anthropic → x-api-key + anthropic-version, no Bearer', () {
      final h = providerRestAuthHeaders(
          format: ApiFormat.anthropic, apiKey: 'sk-ant-xyz');
      expect(h['x-api-key'], 'sk-ant-xyz');
      expect(h['anthropic-version'], '2023-06-01');
      expect(h.containsKey('Authorization'), isFalse);
    });

    test('empty / whitespace key → no auth header (keyless local server)', () {
      expect(providerRestAuthHeaders(format: ApiFormat.openai, apiKey: ''),
          isEmpty);
      expect(
          providerRestAuthHeaders(format: ApiFormat.anthropic, apiKey: '   '),
          isEmpty);
    });

    test('key is trimmed', () {
      final h = providerRestAuthHeaders(
          format: ApiFormat.openai, apiKey: '  sk-abc  ');
      expect(h['Authorization'], 'Bearer sk-abc');
    });
  });
}
