import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';

/// Wave: verifies the extracted `buildRequestBody` body builder behind the
/// optional `extraBody` parameter that the structured-output pipeline will
/// use to inject `response_format: {type: 'json_object'}`. The hot path
/// (chat/LTM) MUST stay byte-identical when `extraBody` is null.
void main() {
  ApiProvider makeProvider({Map<String, dynamic>? extraParams}) => ApiProvider(
        id: 'p1',
        name: 'Test Provider',
        baseUrl: 'https://example.test/v1',
        apiKey: 'sk-secret',
        model: 'test-model',
        extraParams: extraParams,
      );

  final settings = ModelSettings();
  final messages = <ChatTurn>[
    ChatTurn('system', 'You are a test.'),
    ChatTurn('user', 'Hello.'),
  ];

  group('buildRequestBody', () {
    test('extraBody is spread in and present', () {
      final body = buildRequestBody(
        provider: makeProvider(),
        settings: settings,
        messages: messages,
        stream: true,
        extraBody: {
          'response_format': {'type': 'json_object'},
        },
      );
      expect(body['response_format'], {'type': 'json_object'});
    });

    test('extraBody overrides a stale response_format from extraParams', () {
      final body = buildRequestBody(
        provider: makeProvider(extraParams: {
          'response_format': {'type': 'text'},
        }),
        settings: settings,
        messages: messages,
        stream: true,
        extraBody: {
          'response_format': {'type': 'json_object'},
        },
      );
      // extraBody is spread LAST, so it wins.
      expect(body['response_format'], {'type': 'json_object'});
    });

    test('null extraBody = no response_format + unchanged shape', () {
      final body = buildRequestBody(
        provider: makeProvider(),
        settings: settings,
        messages: messages,
        stream: true,
        extraBody: null,
      );
      expect(body.containsKey('response_format'), isFalse);
      // Core Pyre-managed fields still present.
      expect(body['model'], 'test-model');
      expect(body['messages'], isA<List<dynamic>>());
      expect(body['stream'], isTrue);
      // Sampling keys (from _samplingPayload) still present.
      expect(body['temperature'], settings.temperature);
      expect(body['top_p'], settings.topP);
      expect(body['max_tokens'], settings.maxTokens);
    });

    test('stream flag passes through', () {
      final body = buildRequestBody(
        provider: makeProvider(),
        settings: settings,
        messages: messages,
        stream: false,
      );
      expect(body['stream'], isFalse);
    });
  });
}
