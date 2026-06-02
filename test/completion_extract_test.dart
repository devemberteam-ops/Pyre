// Wave CY.18.160: the one-shot completeChat path used to read ONLY
// `message.content`, so a reasoning model that emits its answer via the
// reasoning channel (Venice's uncensored Qwen, DeepSeek-R1, …) returned ''
// → the LTM auto-summariser silently produced no checkpoint ("nothing
// fires at #25"). extractCompletionMessageText() is the reasoning-aware
// replacement: prefer think-stripped content, else fall back to the
// reasoning channel (also think-stripped).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_api.dart';

void main() {
  group('extractCompletionMessageText', () {
    test('plain content passes through', () {
      expect(
        extractCompletionMessageText({'content': 'A clean recap.'}),
        'A clean recap.',
      );
    });

    test('inline <think> block is stripped from content', () {
      final out = extractCompletionMessageText({
        'content': '<think>let me consider the arc</think>\n\nThe recap.',
      });
      expect(out, 'The recap.');
    });

    test('empty content falls back to reasoning (DeepSeek field)', () {
      final out = extractCompletionMessageText({
        'content': '',
        'reasoning_content': 'They escaped the Gate and reached the village.',
      });
      expect(out, 'They escaped the Gate and reached the village.');
    });

    test('null content falls back to reasoning (OpenRouter field)', () {
      final out = extractCompletionMessageText({
        'content': null,
        'reasoning': 'Ren bonded with Vesna over the campfire.',
      });
      expect(out, 'Ren bonded with Vesna over the campfire.');
    });

    test('reasoning_content wins over reasoning when both present', () {
      final out = extractCompletionMessageText({
        'content': '',
        'reasoning_content': 'preferred',
        'reasoning': 'ignored',
      });
      expect(out, 'preferred');
    });

    test('content wins when BOTH content and reasoning are present', () {
      final out = extractCompletionMessageText({
        'content': 'The actual summary.',
        'reasoning': 'chain of thought that must not be used',
      });
      expect(out, 'The actual summary.');
    });

    test('<think> stripped from the reasoning fallback too', () {
      final out = extractCompletionMessageText({
        'content': '',
        'reasoning': '<think>noise</think>The real recap survives.',
      });
      expect(out, 'The real recap survives.');
    });

    test('truly empty everywhere → empty string', () {
      expect(extractCompletionMessageText({'content': ''}), '');
      expect(extractCompletionMessageText({}), '');
      expect(
        extractCompletionMessageText({'content': '   ', 'reasoning': '  '}),
        '',
      );
    });

    test('content that is only an unclosed <think> tail → empty', () {
      // Truncated mid-reasoning: dangling open tag runs to end, nothing real.
      final out = extractCompletionMessageText({
        'content': '<think>still thinking and then cut off',
      });
      expect(out, '');
    });
  });

  // Wave CY.18.160: the summariser now assembles the STREAMING transport
  // (same as the live chat) instead of the one-shot completeChat, then
  // strips Pyre's internal stream sentinels + reasoning via this helper.
  group('stripStreamArtifacts', () {
    test('plain streamed prose passes through', () {
      expect(stripStreamArtifacts('They reached the village.'),
          'They reached the village.');
    });

    test('finish-reason sentinel is stripped', () {
      expect(
        stripStreamArtifacts('A clean recap.<<__PYRE_FINISH__:stop__>>'),
        'A clean recap.',
      );
    });

    test('dropped-frames sentinel is stripped', () {
      expect(
        stripStreamArtifacts(
            'Recap text.<<__PYRE_DROPPED__:3:FormatException__>>'),
        'Recap text.',
      );
    });

    test('both sentinels + a <think> block all stripped', () {
      final out = stripStreamArtifacts(
        '<think>planning the recap</think>The story so far.'
        '<<__PYRE_FINISH__:length__>>',
      );
      expect(out, 'The story so far.');
    });

    test('reasoning-model stream: think wraps everything, real text after',
        () {
      final out = stripStreamArtifacts(
        '<think>let me summarise</think>\n\nRen and Vesna pressed on.'
        '<<__PYRE_FINISH__:stop__>>',
      );
      expect(out, 'Ren and Vesna pressed on.');
    });
  });
}
