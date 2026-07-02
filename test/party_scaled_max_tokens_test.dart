import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';

/// Party mode (owner request): one generation voices the WHOLE party in a
/// scene, so the single-character `max_tokens` ceiling is too tight. This
/// pure helper scales the resolved ceiling up with the member count while
/// staying byte-identical for every non-party chat (memberCount <= 1).
void main() {
  group('partyScaledMaxTokens — truth table', () {
    test('memberCount <= 1 returns base unchanged', () {
      expect(partyScaledMaxTokens(1024, 1), 1024);
      expect(partyScaledMaxTokens(1024, 0), 1024);
      expect(partyScaledMaxTokens(1024, -3), 1024);
    });

    test('2 members ~= 1.6x', () {
      // 1024 * 1.6 = 1638.4 -> round = 1638
      expect(partyScaledMaxTokens(1024, 2), 1638);
    });

    test('3 members ~= 2.2x', () {
      // 1024 * 2.2 = 2252.8 -> round = 2253
      expect(partyScaledMaxTokens(1024, 3), 2253);
    });

    test('4 members ~= 2.8x', () {
      // 1024 * 2.8 = 2867.2 -> round = 2867
      expect(partyScaledMaxTokens(1024, 4), 2867);
    });

    test('5 members capped at 3.0x (the formula would exceed the cap)', () {
      // formula: 1 + 0.6*4 = 3.4x -> clamped to 3x
      expect(partyScaledMaxTokens(1024, 5), 1024 * 3);
    });

    test('6+ members stay capped at 3.0x', () {
      expect(partyScaledMaxTokens(1024, 6), 1024 * 3);
      expect(partyScaledMaxTokens(1024, 20), 1024 * 3);
    });

    test('never goes below base even for a tiny base', () {
      expect(partyScaledMaxTokens(1, 5), greaterThanOrEqualTo(1));
    });

    test('base <= 0 passes through unchanged regardless of memberCount', () {
      expect(partyScaledMaxTokens(0, 5), 0);
      expect(partyScaledMaxTokens(-1, 5), -1);
    });
  });

  group('_samplingPayload / buildRequestBody — party scaling wired in', () {
    ApiProvider makeProvider() => ApiProvider(
          id: 'p1',
          name: 'Test Provider',
          baseUrl: 'https://example.test/v1',
          apiKey: 'sk-secret',
          model: 'test-model',
        );

    final messages = <ChatTurn>[
      ChatTurn('system', 'You are a test.'),
      ChatTurn('user', 'Hello.'),
    ];

    test('non-party (default) body carries the base max_tokens unchanged',
        () {
      final settings = ModelSettings(maxTokens: 1024);
      final body = buildRequestBody(
        provider: makeProvider(),
        settings: settings,
        messages: messages,
        stream: true,
      );
      expect(body['max_tokens'], 1024);
    });

    test('a 3-member party scales the OpenAI body max_tokens', () {
      final settings = ModelSettings(maxTokens: 1024);
      final body = buildRequestBody(
        provider: makeProvider(),
        settings: settings,
        messages: messages,
        stream: true,
        partyMemberCount: 3,
      );
      expect(body['max_tokens'], 2253);
    });

    test('a 3-member party scales the Anthropic body max_tokens', () {
      final settings = ModelSettings(maxTokens: 1024);
      final body = buildAnthropicBody(
        messages: messages,
        settings: settings,
        model: 'm',
        stream: false,
        partyMemberCount: 3,
      );
      expect(body['max_tokens'], 2253);
    });

    test('default partyMemberCount (1) leaves the Anthropic body unchanged',
        () {
      final settings = ModelSettings(maxTokens: 1024);
      final body = buildAnthropicBody(
        messages: messages,
        settings: settings,
        model: 'm',
        stream: false,
      );
      expect(body['max_tokens'], 1024);
    });
  });
}
