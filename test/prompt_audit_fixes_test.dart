// Mega-audit 2026-06-04 — regression tests for the PROMPT batch fixes.
//
//   chat-core-1-01  — strip <think>…</think> from assistant bodies when
//                     building OUTGOING history turns (not at persist time).
//   creator-03      — buildCreatorCanvasStateMessage must NOT inject the
//                     removed "block"/"PARTIAL SHEET update"/"card-done"
//                     jargon into the live architect prompt.
//   chat-core-1-08  — {{random:…}} seed is stable per-chat and per-occurrence
//                     (no message-count drift, no equal-length collision).
//   memory-…-01     — Memory OFF must replay full history (firstUncoveredIndex
//                     clamps to 0 when memory is disabled).
//
// Covered here at the pure-builder level; the memory-OFF window test also
// lives in memory_test.dart against firstUncoveredIndex directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  Message userMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.user, variants: [text], createdAt: 1);
  Message charMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.char, variants: [text], createdAt: 1);

  ChatPromptInputs inputsFor(Chat chat, {Character? character}) =>
      ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character?.id,
        beatsCap: 0,
        lookupCharacter: (id) => character != null && id == character.id
            ? character
            : null,
        lookupBook: (_) => null,
      );

  group('chat-core-1-01 — <think> stripped from outgoing assistant history', () {
    test('assistant turn drops a complete <think> block but keeps prose', () {
      final char = Character(id: 'c', name: 'Vesna', description: 'A delver.');
      final chat = Chat(
        id: 'c1',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [
          userMsg('m1', 'hi'),
          charMsg('m2',
              '<think>The user said hi. I should greet warmly.</think>Vesna nods, ears flat.'),
        ],
      );
      final result = buildChatPrompt(inputsFor(chat, character: char));
      final assistantTurns =
          result.turns.where((t) => t.role == 'assistant').toList();
      expect(assistantTurns.length, 1);
      expect(assistantTurns.first.content, 'Vesna nods, ears flat.');
      expect(assistantTurns.first.content, isNot(contains('<think>')));
      expect(assistantTurns.first.content, isNot(contains('I should greet')));
    });

    test('stored message text is NOT mutated (strip only at assembly)', () {
      final char = Character(id: 'c', name: 'Vesna', description: 'A delver.');
      final reasoning = '<think>private cot</think>Hello.';
      final chat = Chat(
        id: 'c1',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [userMsg('m1', 'hi'), charMsg('m2', reasoning)],
      );
      buildChatPrompt(inputsFor(chat, character: char));
      // The persisted variant must still carry the reasoning for the
      // per-message toggle.
      expect(chat.messages[1].text, reasoning);
    });

    test('dangling (unterminated) <think> tail is also stripped', () {
      final char = Character(id: 'c', name: 'Vesna', description: 'A delver.');
      final chat = Chat(
        id: 'c1',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [
          userMsg('m1', 'hi'),
          charMsg('m2', 'Visible line.\n<think>leaked tail with no close'),
        ],
      );
      final result = buildChatPrompt(inputsFor(chat, character: char));
      final assistant =
          result.turns.firstWhere((t) => t.role == 'assistant');
      expect(assistant.content, 'Visible line.');
      expect(assistant.content, isNot(contains('<think>')));
    });

    test('user turns are untouched by reasoning strip', () {
      final char = Character(id: 'c', name: 'Vesna', description: 'A delver.');
      final chat = Chat(
        id: 'c1',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        // A user literally typing <think> is left alone (only assistant
        // bodies carry reasoning).
        messages: [userMsg('m1', '<think>my note</think> what now?')],
      );
      final result = buildChatPrompt(inputsFor(chat, character: char));
      final user = result.turns.firstWhere((t) => t.role == 'user');
      expect(user.content, contains('<think>my note</think>'));
    });
  });

  group('creator-03 — canvas-state dump is de-jargoned', () {
    test('no "block", "PARTIAL SHEET", or "card-done" jargon leaks', () {
      final msg = buildCreatorCanvasStateMessage(
        {
          'name': 'Aria',
          'description': 'A wandering bard.',
          // first_mes intentionally lacks bold+italic so the old code would
          // have appended the "re-emit as PARTIAL SHEET update" warning.
          'first_mes': 'A plain greeting with no markdown at all.',
        },
        mode: 'character',
      );
      expect(msg, isNotEmpty);
      final lower = msg.toLowerCase();
      // The removed block/sheet-update PROTOCOL jargon must not leak.
      expect(lower, isNot(contains('block')));
      expect(lower, isNot(contains('partial sheet')));
      expect(lower, isNot(contains('card-done')));
      // The obsolete "PRE-EMISSION CHECK … re-emit cleanly without bold"
      // trailer (which assumed a parse/block protocol) is gone.
      expect(lower, isNot(contains('pre-emission')));
      expect(lower, isNot(contains('parse failure')));
      // The "re-emit as PARTIAL SHEET update" first_mes directive is gone.
      expect(lower, isNot(contains('re-emit as')));
    });

    test('still reports filled + not-yet-filled fields neutrally', () {
      final msg = buildCreatorCanvasStateMessage(
        {'name': 'Aria'},
        mode: 'character',
      );
      // Filled field is acknowledged.
      expect(msg, contains('name'));
      // Empty fields are still surfaced (neutral wording, no "card-done").
      expect(msg.toLowerCase(), contains('not yet filled'));
    });

    test('brand-new (no filled fields) session still returns empty', () {
      final msg = buildCreatorCanvasStateMessage(const {}, mode: 'character');
      expect(msg, isEmpty);
    });
  });

  group('chat-core-1-08 — {{random:}} seed stability', () {
    Preset randomPreset(String main) =>
        Preset(id: 'p', name: 'r', mainPrompt: main);

    String renderWith(Preset preset, Chat chat) {
      final inputs = ChatPromptInputs(
        chat: chat,
        character: Character(id: 'c', name: 'X'),
        persona: null,
        preset: preset,
        responderId: 'c',
        beatsCap: 0,
        lookupCharacter: (_) => null,
        lookupBook: (_) => null,
      );
      return buildChatPrompt(inputs).turns.first.content;
    }

    test('same chat: pick is stable as the message count grows', () {
      final preset = randomPreset('Time of day: {{random:dawn,noon,dusk}}.');
      final chatA = Chat(
        id: 'stable-chat',
        characterIds: ['c'],
        characterSnapshots: {'c': Character(id: 'c', name: 'X')},
        messages: [userMsg('m1', 'a')],
      );
      final chatB = Chat(
        id: 'stable-chat', // SAME id → same salt
        characterIds: ['c'],
        characterSnapshots: {'c': Character(id: 'c', name: 'X')},
        messages: [
          userMsg('m1', 'a'),
          charMsg('m2', 'b'),
          userMsg('m3', 'c'),
        ],
      );
      final a = renderWith(preset, chatA);
      final b = renderWith(preset, chatB);
      expect(a, equals(b),
          reason: 'pick must not drift as the conversation grows');
    });

    test('two equal-length macros in one field can diverge', () {
      // 'aa,bb' and 'xx,yy' have identical source length; the old seed
      // (length-based) collapsed them to the same index. They must be allowed
      // to differ. We assert over a spread of chat ids that they are NOT
      // always identical.
      final preset = randomPreset('A:{{random:aa,bb}} B:{{random:xx,yy}}');
      var sawDivergence = false;
      for (var i = 0; i < 16; i++) {
        final chat = Chat(
          id: 'chat-$i',
          characterIds: ['c'],
          characterSnapshots: {'c': Character(id: 'c', name: 'X')},
          messages: [userMsg('m1', 'a')],
        );
        final out = renderWith(preset, chat);
        final aIsFirst = out.contains('A:aa');
        final bIsFirst = out.contains('B:xx');
        if (aIsFirst != bIsFirst) {
          sawDivergence = true;
          break;
        }
      }
      expect(sawDivergence, isTrue,
          reason:
              'equal-length {{random}} macros must be able to pick independently');
    });
  });
}
