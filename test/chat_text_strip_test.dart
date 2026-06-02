// Wave CY.18.153: ChatText.stripReasoning is the shared reasoning stripper
// now used by Impersonate-Me (so a reasoning model's <think> never lands in
// the user's input box). These lock the behaviour the impersonate path relies
// on.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/widgets/chat_text.dart';

void main() {
  group('ChatText.stripReasoning', () {
    test('strips a complete <think> block, keeps the answer', () {
      expect(ChatText.stripReasoning('<think>plan the reply</think>Hey there.'),
          'Hey there.');
    });
    test('strips a dangling open <think> (mid-stream, no close yet)', () {
      expect(
          ChatText.stripReasoning('Hello.<think>still thinking'), 'Hello.');
    });
    test('a plain answer is untouched', () {
      expect(ChatText.stripReasoning('Just a normal line.'),
          'Just a normal line.');
    });
    test('wrapped-everything (both tags, no outside text) → keeps inner', () {
      expect(ChatText.stripReasoning('<think>the whole reply here.</think>'),
          'the whole reply here.');
    });
    test('only an unterminated reasoning preamble → empty string', () {
      expect(
          ChatText.stripReasoning('<think>thinking with no answer yet'), '');
    });
    test('tags are case-insensitive', () {
      expect(ChatText.stripReasoning('<THINK>x</THINK>Yo.'), 'Yo.');
    });
  });
}
