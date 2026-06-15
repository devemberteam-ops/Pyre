// Pyre 1.1.3: native Anthropic (/v1/messages) format adapter — pure helpers.
// buildAnthropicBody translates Pyre's assembled ChatTurn list into Anthropic's
// shape (top-level system, user/assistant alternation starting with user,
// required max_tokens, stop_sequences, image content blocks). anthropicTextDelta
// / anthropicErrorMessage parse the content-block SSE stream.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';

void main() {
  final settings = ModelSettings();

  group('buildAnthropicBody — message shape', () {
    // Pyre 1.1.3 Defect-2 fix: only the LEADING system turn(s) belong in the
    // top-level `system` field. A POST-HISTORY system turn (the char-voice
    // jailbreak / "stay in character" reminder, deliberately last for recency)
    // must stay in position — converted to a user-role turn in `messages`, not
    // hoisted to the top where it would mix with the character card and lose
    // its recency punch.
    test('keeps leading system at top-level, preserves post-history system in '
        'messages', () {
      final body = buildAnthropicBody(
        messages: [
          ChatTurn('system', 'You are X.'),
          ChatTurn('user', 'hi'),
          ChatTurn('assistant', 'hello'),
          ChatTurn('system', 'Stay in character.'),
        ],
        settings: settings,
        model: 'claude-x',
        stream: true,
      );
      // Leading system only — the post-history reminder is NOT folded here.
      expect(body['system'], 'You are X.');
      final msgs = (body['messages'] as List).cast<Map>();
      // Still a valid Anthropic message list (user/assistant only).
      expect(
          msgs.every((m) => m['role'] == 'user' || m['role'] == 'assistant'),
          isTrue);
      // The post-history system turn survives, in order, at the end as a user
      // turn (recency preserved).
      expect(msgs.last['role'], 'user');
      expect(msgs.last['content'], 'Stay in character.');
      expect(body['model'], 'claude-x');
      expect(body['stream'], true);
      expect(body['max_tokens'], isA<int>());
      expect(body['max_tokens'] as int, greaterThan(0)); // required + positive
    });

    test('merges consecutive same-role turns', () {
      final body = buildAnthropicBody(
        messages: [
          ChatTurn('user', 'a'),
          ChatTurn('user', 'b'),
          ChatTurn('assistant', 'c'),
        ],
        settings: settings,
        model: 'm',
        stream: false,
      );
      final msgs = (body['messages'] as List).cast<Map>();
      expect(msgs.length, 2);
      expect(msgs[0]['role'], 'user');
      expect(msgs[0]['content'], 'a\n\nb');
      expect(msgs[1]['content'], 'c');
    });

    test('prepends a user turn when the convo opens with the assistant', () {
      final body = buildAnthropicBody(
        messages: [
          ChatTurn('assistant', 'greeting'),
          ChatTurn('user', 'hi'),
        ],
        settings: settings,
        model: 'm',
        stream: false,
      );
      final msgs = (body['messages'] as List).cast<Map>();
      expect(msgs.first['role'], 'user'); // Anthropic requires user-first
      expect(msgs[1]['role'], 'assistant');
      expect(msgs[1]['content'], 'greeting');
    });

    test('an empty system is omitted entirely', () {
      final body = buildAnthropicBody(
        messages: [ChatTurn('user', 'hi')],
        settings: settings,
        model: 'm',
        stream: false,
      );
      expect(body.containsKey('system'), isFalse);
    });
  });

  group('buildAnthropicBody — sampling', () {
    test('temperature is clamped to Anthropic\'s 0..1 range', () {
      final body = buildAnthropicBody(
        messages: [ChatTurn('user', 'hi')],
        settings: ModelSettings(temperature: 1.8),
        model: 'm',
        stream: false,
      );
      expect(body['temperature'], 1.0);
    });

    test('stop sequences map to Anthropic stop_sequences', () {
      final body = buildAnthropicBody(
        messages: [ChatTurn('user', 'hi')],
        settings: settings,
        model: 'm',
        stream: false,
        stop: ['<<END>>'],
      );
      expect(body['stop_sequences'], ['<<END>>']);
      expect(body.containsKey('stop'), isFalse);
    });
  });

  group('buildAnthropicBody — images', () {
    test('an image turn becomes a content-block array', () {
      final body = buildAnthropicBody(
        messages: [
          ChatTurn('user', 'look',
              imageDataUrls: ['data:image/png;base64,AAAA']),
        ],
        settings: settings,
        model: 'm',
        stream: false,
      );
      final content = (body['messages'] as List).first['content'];
      expect(content, isA<List>());
      final blocks = (content as List).cast<Map>();
      expect(blocks[0]['type'], 'text');
      expect(blocks[0]['text'], 'look');
      expect(blocks[1]['type'], 'image');
      expect(blocks[1]['source']['media_type'], 'image/png');
      expect(blocks[1]['source']['data'], 'AAAA');
    });
  });

  group('anthropicTextDelta', () {
    test('content_block_delta text_delta → the text', () {
      expect(
        anthropicTextDelta({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'Hi'}
        }),
        'Hi',
      );
    });
    test('non-text events → null', () {
      expect(anthropicTextDelta({'type': 'message_start'}), isNull);
      expect(
        anthropicTextDelta({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': 'x'}
        }),
        isNull,
      );
    });
  });

  group('anthropicErrorMessage', () {
    test('error event → the message', () {
      expect(
        anthropicErrorMessage({
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'busy'}
        }),
        'busy',
      );
    });
    test('non-error event → null', () {
      expect(anthropicErrorMessage({'type': 'message_stop'}), isNull);
    });
  });
}
