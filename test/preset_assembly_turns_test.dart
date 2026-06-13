// Prompt Manager Core, Task 2: assemblePreset now classifies each enabled block:
//   - role 'system', no depth  → joins the system / post-history TEXT (as today)
//   - role 'user'/'assistant', no depth → a separate beforeTurns / afterTurns entry
//   - any block with depth != null → a depthTurns entry (injected into history)
// Backward compat is the invariant: an all-system, depth-null preset (and every
// flat preset) assembles to the SAME text with EMPTY turn lists.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/preset_assembly.dart';

void main() {
  Preset modular(List<PromptBlock> blocks) => Preset(
        id: 'p',
        name: 'p',
        mainPrompt: '',
        postHistoryInstructions: '',
        promptBlocks: blocks,
      );
  PromptBlock blk(String id, String content,
          {String role = 'system',
          PromptBlockPosition pos = PromptBlockPosition.beforeHistory,
          int? depth}) =>
      PromptBlock(id: id, name: id, content: content, role: role, position: pos, depth: depth);

  group('backward compat', () {
    test('flat preset → byte-identical text, empty turn lists', () {
      final a = assemblePreset(Preset(
          id: 'p', name: 'p', mainPrompt: 'SYS', postHistoryInstructions: 'JB'));
      expect(a.systemPrompt, 'SYS');
      expect(a.postHistory, 'JB');
      expect(a.beforeTurns, isEmpty);
      expect(a.afterTurns, isEmpty);
      expect(a.depthTurns, isEmpty);
    });

    test('all-system modular preset → joined text, no turns (unchanged)', () {
      final a = assemblePreset(modular([
        blk('1', 'A', pos: PromptBlockPosition.beforeHistory),
        blk('2', 'B', pos: PromptBlockPosition.afterHistory),
      ]));
      expect(a.systemPrompt, 'A');
      expect(a.postHistory, 'B');
      expect(a.beforeTurns, isEmpty);
      expect(a.afterTurns, isEmpty);
      expect(a.depthTurns, isEmpty);
    });
  });

  group('role-split turns', () {
    test('beforeHistory user block → beforeTurns, not systemPrompt', () {
      final a = assemblePreset(modular([
        blk('1', 'S', role: 'system'),
        blk('2', 'hi', role: 'user'),
      ]));
      expect(a.systemPrompt, 'S');
      expect(a.beforeTurns, [(role: 'user', content: 'hi')]);
    });

    test('afterHistory assistant block → afterTurns', () {
      final a = assemblePreset(modular([
        blk('1', 'P', role: 'assistant', pos: PromptBlockPosition.afterHistory),
      ]));
      expect(a.postHistory, '');
      expect(a.afterTurns, [(role: 'assistant', content: 'P')]);
    });

    test('unknown/odd role falls back to system TEXT (safe)', () {
      final a = assemblePreset(modular([blk('1', 'X', role: 'weird')]));
      expect(a.systemPrompt, 'X');
      expect(a.beforeTurns, isEmpty);
    });

    test('order within a position is preserved', () {
      final a = assemblePreset(modular([
        blk('1', 'u1', role: 'user'),
        blk('2', 'u2', role: 'user'),
      ]));
      expect(a.beforeTurns, [
        (role: 'user', content: 'u1'),
        (role: 'user', content: 'u2'),
      ]);
    });
  });

  group('depth', () {
    test('a depth block → depthTurns (any role), out of the text slots', () {
      final a = assemblePreset(modular([
        blk('1', 'D', role: 'system', depth: 2),
      ]));
      expect(a.systemPrompt, '');
      expect(a.depthTurns, [(depth: 2, role: 'system', content: 'D')]);
    });

    test('depth overrides position for role too', () {
      final a = assemblePreset(modular([
        blk('1', 'D', role: 'user', pos: PromptBlockPosition.afterHistory, depth: 0),
      ]));
      expect(a.afterTurns, isEmpty);
      expect(a.depthTurns, [(depth: 0, role: 'user', content: 'D')]);
    });
  });
}
