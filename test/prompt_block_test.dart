// Pyre 1.1 (Prompt Manager) — model tests for [PromptBlock] +
// `Preset.promptBlocks`. The load-bearing invariant: a Preset with NO blocks
// (every preset today) serialises WITHOUT a `promptBlocks` key, so existing
// preset blobs / backups / sync payloads stay byte-identical.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('PromptBlockPosition codec', () {
    test('round-trips both values', () {
      for (final p in PromptBlockPosition.values) {
        expect(
          promptBlockPositionFromString(promptBlockPositionToString(p)),
          p,
        );
      }
    });

    test('tolerant default is beforeHistory for unknown / null', () {
      expect(promptBlockPositionFromString(null),
          PromptBlockPosition.beforeHistory);
      expect(promptBlockPositionFromString('garbage'),
          PromptBlockPosition.beforeHistory);
      expect(promptBlockPositionFromString(''),
          PromptBlockPosition.beforeHistory);
    });
  });

  group('PromptBlock (de)serialisation', () {
    test('constructor defaults', () {
      final b = PromptBlock(id: 'b1', name: 'README');
      expect(b.content, '');
      expect(b.enabled, isTrue);
      expect(b.role, 'system');
      expect(b.position, PromptBlockPosition.beforeHistory);
    });

    test('round-trips through toJson/fromJson', () {
      final b = PromptBlock(
        id: 'b1',
        name: 'OMNI PROTOCOL',
        content: 'do the thing',
        enabled: false,
        role: 'user',
        position: PromptBlockPosition.afterHistory,
      );
      final restored = PromptBlock.fromJson(b.toJson());
      expect(restored.id, b.id);
      expect(restored.name, b.name);
      expect(restored.content, b.content);
      expect(restored.enabled, b.enabled);
      expect(restored.role, b.role);
      expect(restored.position, b.position);
    });

    test('fromJson tolerates missing fields (enabled→true, role→system, '
        'position→beforeHistory)', () {
      final restored = PromptBlock.fromJson({'id': 'x', 'name': 'n'});
      expect(restored.id, 'x');
      expect(restored.name, 'n');
      expect(restored.content, '');
      expect(restored.enabled, isTrue);
      expect(restored.role, 'system');
      expect(restored.position, PromptBlockPosition.beforeHistory);
    });
  });

  group('Preset.promptBlocks', () {
    test('empty promptBlocks → toJson OMITS the key entirely', () {
      final p = Preset(id: 'p1', name: 'Flat');
      final json = p.toJson();
      expect(json.containsKey('promptBlocks'), isFalse);
    });

    test('locked default preset stays FLAT (no promptBlocks key)', () {
      final def = buildLockedDefaultPreset();
      expect(def.promptBlocks, isEmpty);
      expect(def.toJson().containsKey('promptBlocks'), isFalse);
    });

    test('non-empty promptBlocks → toJson INCLUDES the key + round-trips', () {
      final p = Preset(
        id: 'p2',
        name: 'Modular',
        mainPrompt: 'kept as fallback',
        promptBlocks: [
          PromptBlock(id: 'b1', name: 'Main', content: 'main text'),
          PromptBlock(
            id: 'b2',
            name: 'Jailbreak',
            content: 'jb text',
            enabled: false,
            role: 'system',
            position: PromptBlockPosition.afterHistory,
          ),
        ],
      );
      final json = p.toJson();
      expect(json.containsKey('promptBlocks'), isTrue);

      final restored = Preset.fromJson(json);
      expect(restored.promptBlocks.length, 2);
      expect(restored.promptBlocks[0].id, 'b1');
      expect(restored.promptBlocks[0].content, 'main text');
      expect(restored.promptBlocks[0].enabled, isTrue);
      expect(restored.promptBlocks[1].id, 'b2');
      expect(restored.promptBlocks[1].enabled, isFalse);
      expect(
          restored.promptBlocks[1].position, PromptBlockPosition.afterHistory);
      // The flat fallback fields survive alongside blocks.
      expect(restored.mainPrompt, 'kept as fallback');
    });

    test('legacy preset JSON (no promptBlocks key) loads with empty list', () {
      // A minimal pre-1.1 preset blob.
      final legacy = {
        'id': 'legacy',
        'name': 'Legacy',
        'mainPrompt': 'sys',
        'postHistoryInstructions': 'post',
      };
      final restored = Preset.fromJson(legacy);
      expect(restored.promptBlocks, isEmpty);
      // And re-serialising it does NOT introduce the key.
      expect(restored.toJson().containsKey('promptBlocks'), isFalse);
    });
  });
}
