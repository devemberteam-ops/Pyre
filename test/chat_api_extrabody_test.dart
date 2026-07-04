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

    // 2026-07-04 (Gui approved): DRY + banned-words passthrough. Unset =
    // absent (the request stays byte-identical for every existing preset);
    // set = present under the names the RP backends accept.
    test('DRY + banned words absent when the preset does not set them', () {
      final body = buildRequestBody(
        provider: makeProvider(),
        settings: settings,
        messages: messages,
        stream: true,
        preset: Preset(id: 'x', name: 'plain'),
      );
      expect(body.containsKey('dry_multiplier'), isFalse);
      expect(body.containsKey('dry_base'), isFalse);
      expect(body.containsKey('dry_allowed_length'), isFalse);
      expect(body.containsKey('banned_strings'), isFalse);
      expect(body.containsKey('bad_words'), isFalse);
      expect(body.containsKey('banned_tokens'), isFalse);
    });

    test('DRY + banned words ride the body when set', () {
      final body = buildRequestBody(
        provider: makeProvider(),
        settings: settings,
        messages: messages,
        stream: true,
        preset: Preset(
          id: 'x',
          name: 'dry',
          dryMultiplier: 0.8,
          dryBase: 1.75,
          dryAllowedLength: 2,
          bannedWords: ['ministrations', 'shivers down her spine'],
        ),
      );
      expect(body['dry_multiplier'], 0.8);
      expect(body['dry_base'], 1.75);
      expect(body['dry_allowed_length'], 2);
      const words = ['ministrations', 'shivers down her spine'];
      expect(body['banned_strings'], words);
      expect(body['bad_words'], words);
      expect(body['banned_tokens'], words);
    });
  });
}
