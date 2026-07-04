// Checkpoints v3 — final design per Gui (2026-07-04): CHAPTERS.
// "A ideia é que os checkpoints possam contar a história resumida por si só,
// mas de 0 até 20 conta o setting e começo, e o de 20 até 40 resume o que
// aconteceu SEM recontar o que já foi contado no checkpoint anterior."
//
// So: each checkpoint = ONE new chapter covering ONLY its span; the chain
// read in order = the complete story. The first chapter grounds
// setting/people/inciting events; later ones never retell. (An intermediate
// draft retold the whole story each time — rejected by the owner; the
// retell-mode helpers were removed.) Also locks the TRIGGER fix: the counter
// counts CHARACTER replies only, and the stock default of 20 meant ~40+
// total messages before the first checkpoint — "não dispara quando devia" —
// so the default dropped to 10 with a one-time migration.
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/memory.dart';

Message _m(String id, MessageKind kind, String text) => Message(
      id: id,
      kind: kind,
      variants: [text],
      createdAt: 0,
    );

void main() {
  group('buildRecapBlock — chapters concatenate in order', () {
    test('the chain is the story: chapters joined chronologically', () {
      final chat = Chat(
        id: 'c',
        characterIds: const ['x'],
        messages: [
          _m('m1', MessageKind.user, 'a'),
          _m('m2', MessageKind.char, 'b'),
          _m('m3', MessageKind.user, 'c'),
          _m('m4', MessageKind.char, 'd'),
        ],
        memoryCheckpoints: [
          MemoryCheckpoint(
              id: 'a',
              summary: 'Opening chapter.',
              anchorMessageIdx: 1,
              pathHash: ''),
          MemoryCheckpoint(
              id: 'b',
              summary: 'Second chapter.',
              anchorMessageIdx: 3,
              pathHash: ''),
        ],
        memoryEnabled: true,
        createdAt: 0,
        updatedAt: 0,
      );
      expect(buildRecapBlock(chat), 'Opening chapter.\n\nSecond chapter.');
    });
  });

  group('trigger default + migration (autoEvery 20 → 10)', () {
    test('fresh install defaults to 10', () {
      expect(MemorySettings().autoEvery, 10);
      expect(MemorySettings.fromJson(const {}).autoEvery, 10);
    });

    test('an install still on the OLD STOCK 20 from an old version is '
        'migrated to 10 once', () {
      final m = MemorySettings.fromJson({
        'autoEvery': 20,
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion - 1,
      });
      expect(m.autoEvery, 10);
    });

    test('a DELIBERATE non-stock value is preserved across the migration', () {
      final m = MemorySettings.fromJson({
        'autoEvery': 35,
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion - 1,
      });
      expect(m.autoEvery, 35);
    });

    test('20 chosen ON the current version is respected', () {
      final m = MemorySettings.fromJson({
        'autoEvery': 20,
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion,
      });
      expect(m.autoEvery, 20);
    });
  });

  group('summariser body (chapter framing)', () {
    final chat = Chat(
      id: 'c',
      characterIds: const ['x'],
      messages: [
        _m('m1', MessageKind.user, 'hello'),
        _m('m2', MessageKind.char, 'reply one'),
        _m('m3', MessageKind.user, 'more'),
        _m('m4', MessageKind.char, 'reply two'),
      ],
      createdAt: 0,
      updatedAt: 0,
    );

    test('with earlier chapters: context-only priors + NEXT chapter covering '
        'ONLY the new events — never a retell', () {
      final body = buildSummariserBodyForTest(
        chat: chat,
        startExclusive: 1,
        endInclusive: 3,
        priorContext: [
          MemoryCheckpoint(
              id: 'a',
              summary: 'Opening chapter.',
              anchorMessageIdx: 1,
              pathHash: ''),
        ],
      );
      expect(body, contains('Earlier chapters'));
      expect(body, contains('do NOT retell'));
      expect(body, contains('Opening chapter.'));
      expect(body, contains('NEXT chapter'));
      // The rejected retell-mode contract must be gone.
      expect(body, isNot(contains('REPLACES')));
    });

    test('without earlier chapters: asks for the OPENING chapter', () {
      final body = buildSummariserBodyForTest(
        chat: chat,
        startExclusive: -1,
        endInclusive: 3,
        priorContext: const [],
      );
      expect(body, contains('OPENING chapter'));
    });

    test('the default prompt sets the chapter contract (first = setting + '
        'start; later = only what happened, no retell)', () {
      final p = MemorySettings.defaultSummaryPrompt;
      expect(p, contains('ONE new chapter'));
      expect(p, contains('NEVER retell'));
      expect(p.toLowerCase(), contains('self-contained story'));
      expect(p, contains('FIRST chapter'));
    });
  });
}
