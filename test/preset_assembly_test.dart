// Pyre 1.1 (Prompt Manager) — pure assembly tests for `assemblePreset`.
//
// The FLAT path is the load-bearing invariant: a preset with no blocks must
// assemble to its raw `mainPrompt` / `postHistoryInstructions` BYTE-IDENTICALLY
// (the prompt-lab golden suite is the end-to-end backstop). The modular path
// joins enabled blocks by position in list order.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/preset_assembly.dart';

void main() {
  group('assemblePreset — flat path (no blocks)', () {
    test('returns mainPrompt / postHistory verbatim', () {
      final p = Preset(
        id: 'p',
        name: 'Flat',
        mainPrompt: 'SYSTEM BODY {{char}}',
        postHistoryInstructions: 'POST BODY {{user}}',
      );
      final asm = assemblePreset(p);
      expect(asm.systemPrompt, 'SYSTEM BODY {{char}}');
      expect(asm.postHistory, 'POST BODY {{user}}');
    });

    test('empty flat fields → empty assembled strings (byte-identical)', () {
      final p = Preset(id: 'p', name: 'Empty');
      final asm = assemblePreset(p);
      expect(asm.systemPrompt, '');
      expect(asm.postHistory, '');
    });

    test('the locked default assembles to its raw flat fields', () {
      final def = buildLockedDefaultPreset();
      final asm = assemblePreset(def);
      expect(asm.systemPrompt, def.mainPrompt);
      expect(asm.postHistory, def.postHistoryInstructions);
    });
  });

  group('assemblePreset — modular path', () {
    test('3 beforeHistory blocks (one disabled) → only the 2 enabled, '
        'joined in list order by \\n\\n', () {
      final p = Preset(
        id: 'p',
        name: 'Modular',
        // mainPrompt is IGNORED once blocks exist.
        mainPrompt: 'IGNORED',
        promptBlocks: [
          PromptBlock(id: 'a', name: 'A', content: 'alpha'),
          PromptBlock(id: 'b', name: 'B', content: 'beta', enabled: false),
          PromptBlock(id: 'c', name: 'C', content: 'gamma'),
        ],
      );
      final asm = assemblePreset(p);
      expect(asm.systemPrompt, 'alpha\n\ngamma');
      expect(asm.postHistory, '');
    });

    test('afterHistory enabled block goes to postHistory, not systemPrompt', () {
      final p = Preset(
        id: 'p',
        name: 'Modular',
        promptBlocks: [
          PromptBlock(id: 'a', name: 'Main', content: 'sys'),
          PromptBlock(
            id: 'b',
            name: 'Jailbreak',
            content: 'jb',
            position: PromptBlockPosition.afterHistory,
          ),
        ],
      );
      final asm = assemblePreset(p);
      expect(asm.systemPrompt, 'sys');
      expect(asm.postHistory, 'jb');
    });

    test('all blocks disabled → empty strings', () {
      final p = Preset(
        id: 'p',
        name: 'Modular',
        promptBlocks: [
          PromptBlock(id: 'a', name: 'A', content: 'x', enabled: false),
          PromptBlock(
            id: 'b',
            name: 'B',
            content: 'y',
            enabled: false,
            position: PromptBlockPosition.afterHistory,
          ),
        ],
      );
      final asm = assemblePreset(p);
      expect(asm.systemPrompt, '');
      expect(asm.postHistory, '');
    });

    test('empty-content blocks are skipped (no stray \\n\\n\\n\\n gap)', () {
      final p = Preset(
        id: 'p',
        name: 'Modular',
        promptBlocks: [
          PromptBlock(id: 'a', name: 'A', content: 'one'),
          PromptBlock(id: 'gap', name: 'Empty', content: ''),
          PromptBlock(id: 'b', name: 'B', content: 'two'),
        ],
      );
      final asm = assemblePreset(p);
      expect(asm.systemPrompt, 'one\n\ntwo');
    });

    test('role does NOT change assembly in the MVP (text join only)', () {
      final p = Preset(
        id: 'p',
        name: 'Modular',
        promptBlocks: [
          PromptBlock(id: 'a', name: 'A', content: 'sys part', role: 'system'),
          PromptBlock(id: 'b', name: 'B', content: 'usr part', role: 'user'),
          PromptBlock(
              id: 'c', name: 'C', content: 'ast part', role: 'assistant'),
        ],
      );
      final asm = assemblePreset(p);
      // All three land in the system slot as text, in order — role is
      // preserved on the model but not honoured by assembly yet.
      expect(asm.systemPrompt, 'sys part\n\nusr part\n\nast part');
      expect(asm.postHistory, '');
    });
  });

  group('H-8: presetSupportsMainPromptQuickEdit predicate', () {
    test('FLAT preset (no blocks) supports the quick-edit', () {
      final flat = Preset(id: 'p', name: 'Flat', mainPrompt: 'body');
      expect(presetSupportsMainPromptQuickEdit(flat), isTrue);
    });

    test('FLAT preset with empty mainPrompt still supports it', () {
      final empty = Preset(id: 'p', name: 'Empty');
      expect(presetSupportsMainPromptQuickEdit(empty), isTrue);
    });

    test('MODULAR preset (has blocks) does NOT support it — quick-edit would '
        'be a no-op', () {
      final modular = Preset(
        id: 'p',
        name: 'Modular',
        // Even a mainPrompt set here is ignored by assembly once blocks exist.
        mainPrompt: 'IGNORED',
        promptBlocks: [PromptBlock(id: 'a', name: 'A', content: 'alpha')],
      );
      expect(presetSupportsMainPromptQuickEdit(modular), isFalse);
    });
  });
}
