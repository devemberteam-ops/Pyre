// Prompt Manager Core, Task 4: buildChatPrompt now emits role-split turns
// (user/assistant blocks become REAL chat turns) and injects depth blocks into
// the replayed history. A pure top-level `insertDepthTurns` helper does the
// depth splice. Backward compat (all-system / flat presets → byte-identical
// turns) is guarded by the prompt-lab goldens; THIS file covers the NEW
// role-split + depth behaviour.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  // ── insertDepthTurns (pure helper) ──────────────────────────────────────
  group('insertDepthTurns', () {
    List<ChatTurn> hist(int n) =>
        [for (var i = 0; i < n; i++) ChatTurn('user', 'm$i')];
    ({int depth, String role, String content}) sysd(int depth, String c) =>
        (depth: depth, role: 'system', content: c);

    test('empty depthTurns → returns the same list instance (identity)', () {
      final h = hist(3);
      expect(identical(insertDepthTurns(h, const []), h), isTrue);
    });

    test('depth 0 → appended AFTER the last message', () {
      final out = insertDepthTurns(hist(2), [sysd(0, 'X')]);
      expect(out.map((t) => t.content).toList(), ['m0', 'm1', 'X']);
    });

    test('depth 1 → inserted BEFORE the last message', () {
      final out = insertDepthTurns(hist(2), [sysd(1, 'X')]);
      expect(out.map((t) => t.content).toList(), ['m0', 'X', 'm1']);
    });

    test('depth >= length → inserted at the FRONT', () {
      final out = insertDepthTurns(hist(2), [sysd(5, 'X')]);
      expect(out.map((t) => t.content).toList(), ['X', 'm0', 'm1']);
    });

    test('multiple turns at the same depth keep list order', () {
      final out = insertDepthTurns(hist(2), [sysd(1, 'A'), sysd(1, 'B')]);
      expect(out.map((t) => t.content).toList(), ['m0', 'A', 'B', 'm1']);
    });

    test('empty history → all at the front in list order', () {
      final out = insertDepthTurns(hist(0), [sysd(0, 'A'), sysd(3, 'B')]);
      expect(out.map((t) => t.content).toList(), ['A', 'B']);
    });

    test('the injected turn carries its own role', () {
      final out = insertDepthTurns(
          hist(1), [(depth: 0, role: 'assistant', content: 'X')]);
      expect(out.last.role, 'assistant');
      expect(out.last.content, 'X');
    });
  });

  // ── buildChatPrompt: role-split + depth integration ─────────────────────
  group('buildChatPrompt role-split + depth', () {
    PromptBlock blk(String id, String content,
            {String role = 'system',
            PromptBlockPosition pos = PromptBlockPosition.beforeHistory,
            int? depth}) =>
        PromptBlock(
            id: id,
            name: id,
            content: content,
            role: role,
            position: pos,
            depth: depth);

    test('user/assistant blocks become turns; depth block injects mid-history',
        () {
      final preset = Preset(
        id: 'p',
        name: 'p',
        mainPrompt: '',
        postHistoryInstructions: '',
        promptBlocks: [
          blk('s', 'SYS', role: 'system'),
          blk('bu', 'before-user', role: 'user'),
          blk('au', 'after-asst',
              role: 'assistant', pos: PromptBlockPosition.afterHistory),
          blk('dp', 'DEPTH', role: 'system', depth: 1),
        ],
      );
      final chat = Chat(
        id: 'c',
        characterIds: const [],
        messages: [
          Message(
              id: 'm1',
              kind: MessageKind.user,
              variants: const ['hello'],
              createdAt: 1),
          Message(
              id: 'm2',
              kind: MessageKind.char,
              variants: const ['hi there'],
              createdAt: 1),
        ],
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: null,
        persona: null,
        preset: preset,
        responderId: null,
        beatsCap: 0,
        lookupCharacter: (_) => null,
        lookupBook: (_) => null,
      );

      final turns = buildChatPrompt(inputs).turns;

      // system → before-user → history (with DEPTH before the last msg) →
      // after-asst.
      expect(turns.map((t) => t.role).toList(),
          ['system', 'user', 'user', 'system', 'assistant', 'assistant']);
      expect(turns[0].content, contains('SYS'));
      expect(turns[1].content, 'before-user');
      expect(turns[2].content, 'hello');
      expect(turns[3].content, 'DEPTH');
      expect(turns[4].content, 'hi there');
      expect(turns[5].content, 'after-asst');
    });

    test('an all-system flat preset is unaffected (no extra turns)', () {
      final preset = Preset(
        id: 'p',
        name: 'p',
        mainPrompt: 'SYSTEXT',
        postHistoryInstructions: 'JB',
      );
      final chat = Chat(
        id: 'c',
        characterIds: const [],
        messages: [
          Message(
              id: 'm1',
              kind: MessageKind.user,
              variants: const ['hello'],
              createdAt: 1),
        ],
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: null,
        persona: null,
        preset: preset,
        responderId: null,
        beatsCap: 0,
        lookupCharacter: (_) => null,
        lookupBook: (_) => null,
      );

      final turns = buildChatPrompt(inputs).turns;
      // system (SYSTEXT) → user (hello) → system (post-history JB). No
      // role-split / depth turns.
      expect(turns.map((t) => t.role).toList(), ['system', 'user', 'system']);
      expect(turns.first.content, contains('SYSTEXT'));
      expect(turns.last.content, contains('JB'));
    });
  });

  group('includePostHistory (Impersonate/Guide fix)', () {
    ChatPromptInputs inputs(bool includePostHistory) {
      final preset = Preset(
        id: 'p',
        name: 'p',
        mainPrompt: 'SYS',
        postHistoryInstructions: 'STAY IN CHARACTER',
      );
      final chat = Chat(
        id: 'c',
        characterIds: const [],
        messages: [
          Message(
              id: 'm1',
              kind: MessageKind.user,
              variants: const ['hi'],
              createdAt: 1),
        ],
      );
      return ChatPromptInputs(
        chat: chat,
        character: null,
        persona: null,
        preset: preset,
        responderId: null,
        beatsCap: 0,
        lookupCharacter: (_) => null,
        lookupBook: (_) => null,
        includePostHistory: includePostHistory,
      );
    }

    test('default (true) keeps the post-history instructions', () {
      final turns = buildChatPrompt(inputs(true)).turns;
      expect(turns.any((t) => t.content.contains('STAY IN CHARACTER')), isTrue);
    });

    test('false drops the post-history (char-voice) system turn', () {
      final turns = buildChatPrompt(inputs(false)).turns;
      expect(turns.any((t) => t.content.contains('STAY IN CHARACTER')), isFalse);
      // the system prompt + history still build normally.
      expect(turns.first.content, contains('SYS'));
      expect(turns.any((t) => t.content == 'hi'), isTrue);
    });
  });
}
