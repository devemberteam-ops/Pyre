// Pyre 1.1 feature F1 — `{{summary}}` macro.
//
// The long-term-memory recap can now be placed ANYWHERE in a preset via a
// `{{summary}}` macro, instead of only being auto-injected at the fixed spot
// after the system prompt. When the macro is present in the resolved preset
// text the hardcoded recap block must NOT also inject (no double recap); when
// the macro is absent, behaviour is EXACTLY as before (recap auto-injected).
//
// Setup mirrors chat_prompt_builder_test.dart: a `Chat` with a valid
// `memoryCheckpoint` (empty pathHash = always valid) + a `Preset`, run through
// `buildChatPrompt`.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  const recapText = 'They met at the Sunken Gate and struck a wary truce.';
  const recapHeader = '--- Story so far (recap) ---';

  Message userMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.user, variants: [text], createdAt: 1);

  Chat chatWithCheckpoint({required List<Message> messages}) => Chat(
        id: 'c-summary',
        characterIds: ['char1'],
        memoryEnabled: true,
        memoryCheckpoints: [
          MemoryCheckpoint(
            id: 'mc1',
            summary: recapText,
            anchorMessageIdx: 0,
            pathHash: '', // empty = always valid
            createdAt: 1,
          ),
        ],
        messages: messages,
      );

  final character = Character(id: 'char1', name: 'Vesna', description: 'A delver.');

  ChatPromptInputs inputsFor(Chat chat, Preset? preset) => ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: preset,
        responderId: 'char1',
        beatsCap: 0,
        lookupCharacter: (id) => id == 'char1' ? character : null,
        lookupBook: (_) => null,
      );

  String wholePrompt(ChatPromptResult result) =>
      result.turns.map((t) => t.content).join('\n\n');

  group('{{summary}} macro', () {
    test('preset WITH {{summary}} → recap at macro position, NOT double-injected',
        () {
      final preset = Preset(
        id: 'pr-summary',
        name: 'Has summary macro',
        mainPrompt: 'You are a narrator.\n\nMEMORY:\n{{summary}}\n\nGo.',
      );
      final chat = chatWithCheckpoint(
        messages: [
          userMsg('m0', 'covered by recap'),
          userMsg('m1', 'continue please'),
        ],
      );

      final result = buildChatPrompt(inputsFor(chat, preset));
      final sys = result.turns.first.content;

      // The recap text resolved at the macro position inside the main prompt.
      expect(sys, contains('MEMORY:'));
      expect(sys, contains(recapText));
      // The macro itself was consumed.
      expect(sys, isNot(contains('{{summary}}')));
      // CRITICAL: the hardcoded recap header must NOT also be present — no
      // double injection. The user's macro is the single source.
      expect(sys, isNot(contains(recapHeader)));
      // And across the whole prompt the recap text appears exactly once.
      final whole = wholePrompt(result);
      final occurrences = recapHeader.allMatches(whole).length;
      expect(occurrences, 0, reason: 'no hardcoded recap header when macro used');
    });

    test('preset WITHOUT {{summary}} → recap auto-injected as before', () {
      final preset = Preset(
        id: 'pr-plain',
        name: 'No summary macro',
        mainPrompt: 'You are a narrator. Go.',
      );
      final chat = chatWithCheckpoint(
        messages: [
          userMsg('m0', 'covered by recap'),
          userMsg('m1', 'continue please'),
        ],
      );

      final result = buildChatPrompt(inputsFor(chat, preset));
      final sys = result.turns.first.content;

      // The hardcoded recap block is present exactly once.
      expect(sys, contains(recapHeader));
      expect(sys, contains(recapText));
      final whole = wholePrompt(result);
      expect(recapHeader.allMatches(whole).length, 1);
    });

    test('{{summary}} only in postHistory still suppresses the hardcoded block',
        () {
      // postHistoryInstructions is filled AFTER the hardcoded-recap decision,
      // so the suppression must rely on the pre-scan of both preset fields —
      // this guards the fill-order robustness.
      final preset = Preset(
        id: 'pr-post',
        name: 'Summary in post-history',
        mainPrompt: 'You are a narrator. Go.',
        postHistoryInstructions: 'Reminder of events:\n{{summary}}',
      );
      final chat = chatWithCheckpoint(
        messages: [
          userMsg('m0', 'covered by recap'),
          userMsg('m1', 'continue please'),
        ],
      );

      final result = buildChatPrompt(inputsFor(chat, preset));
      final whole = wholePrompt(result);
      // Recap text present (resolved at the post-history macro).
      expect(whole, contains(recapText));
      // The hardcoded recap header must NOT appear (no double injection).
      expect(whole, isNot(contains(recapHeader)));
      // The macro itself was consumed in the post-history turn.
      expect(whole, isNot(contains('{{summary}}')));
    });

    test('{{summary}} is case-insensitive like the other macros', () {
      final preset = Preset(
        id: 'pr-case',
        name: 'Mixed-case summary macro',
        mainPrompt: 'Recap:\n{{Summary}}',
      );
      final chat = chatWithCheckpoint(
        messages: [
          userMsg('m0', 'covered by recap'),
          userMsg('m1', 'continue please'),
        ],
      );

      final result = buildChatPrompt(inputsFor(chat, preset));
      final sys = result.turns.first.content;
      expect(sys, contains(recapText));
      expect(sys, isNot(contains(recapHeader)));
      expect(sys.toLowerCase(), isNot(contains('{{summary}}')));
    });
  });
}
