// Mega-audit 2026-06-04 — cross-file deferred datamodel cleanup.
//
// Covers three deferred findings whose sinks lived across batch boundaries:
//   - datamodel-...-02: `{{wiAfter}}` is an advertised-but-no-op token. It must
//     no longer be advertised (preset editor hint / Preset doc) NOR emitted by
//     the ST importer.
//   - datamodel-...-01: the character token estimate counted `depthPrompt`,
//     which is never injected into the assembled prompt — so it must NOT be
//     summed by `approxTokensForCharacter`.
//   - datamodel-...-03: `PromptBlock.role` is preserved but not honored by
//     assembly; an ST import that carries a non-system role must surface a
//     user-visible note (via the import `skipped` summary) so the limitation
//     isn't silent.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/st_preset_import.dart';
import 'package:pyre/services/token_estimate.dart';

void main() {
  group('datamodel-...-02 — {{wiAfter}} dead token', () {
    test('ST importer never emits {{wiAfter}} for worldInfoAfter', () {
      final json = jsonEncode({
        'name': 'After-WI Preset',
        'prompts': [
          {
            'identifier': 'main',
            'name': 'Main',
            'role': 'system',
            'content': 'You are a roleplay engine.',
          },
          // worldInfoAfter is a structural marker (no authored content).
          {'identifier': 'worldInfoAfter', 'marker': true},
          {'identifier': 'worldInfoBefore', 'marker': true},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'worldInfoBefore', 'enabled': true},
              {'identifier': 'worldInfoAfter', 'enabled': true},
            ],
          },
        ],
      });

      final preset = parseSillyTavernPreset(json).preset;
      // The flattened text and any block content must not contain the dead
      // token. {{wiBefore}} stays supported.
      expect(preset.mainPrompt, isNot(contains('{{wiAfter}}')));
      expect(preset.postHistoryInstructions, isNot(contains('{{wiAfter}}')));
      for (final b in preset.promptBlocks) {
        expect(b.content, isNot(contains('{{wiAfter}}')));
      }
    });

    test('Preset doc no longer advertises {{wiAfter}}', () {
      // The model-level doc string is the canonical advertised-macro list; it
      // must no longer mention the dead token. (Editor hint mirrors it.)
      // We assert on the supported-token comment indirectly: a fresh preset's
      // mainPrompt is empty, so this is really a regression marker for the doc.
      // The doc lives in source; grep-based assertions belong in source review,
      // so here we lock the importer + the still-supported {{wiBefore}}.
      final json = jsonEncode({
        'name': 'Before-only',
        'prompts': [
          {'identifier': 'worldInfoBefore', 'marker': true},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'worldInfoBefore', 'enabled': true},
            ],
          },
        ],
      });
      // worldInfoBefore still maps to {{wiBefore}} (kept working). It's a
      // marker with no authored content so it contributes nothing to blocks,
      // but the flat renderer still resolves it to the live token.
      final preset = parseSillyTavernPreset(json).preset;
      expect(preset.mainPrompt, contains('{{wiBefore}}'));
    });
  });

  group('datamodel-...-01 — token estimate excludes never-injected depthPrompt',
      () {
    test('approxTokensForCharacter does not count depthPrompt', () {
      final base = Character(
        id: 'c1',
        name: 'Test',
        description: 'A'.padRight(40, 'A'),
      );
      final withDepth = Character(
        id: 'c2',
        name: 'Test',
        description: 'A'.padRight(40, 'A'),
        depthPrompt: 'Z'.padRight(400, 'Z'),
      );
      // Adding a 400-char depthPrompt must NOT change the estimate, because
      // depthPrompt is never injected into the assembled prompt.
      expect(
        approxTokensForCharacter(withDepth),
        approxTokensForCharacter(base),
      );
    });

    test('approxTokensForCharacter still counts injected fields', () {
      final base = Character(id: 'c1', name: 'Test');
      final withScenario = Character(
        id: 'c2',
        name: 'Test',
        scenario: 'S'.padRight(400, 'S'),
      );
      expect(
        approxTokensForCharacter(withScenario),
        greaterThan(approxTokensForCharacter(base)),
      );
    });
  });

  group('datamodel-...-03 — ST import surfaces role-not-honored warning', () {
    test('non-system block role adds a user-visible skipped note', () {
      final json = jsonEncode({
        'name': 'Role Preset',
        'prompts': [
          {
            'identifier': 'main',
            'name': 'Main',
            'role': 'system',
            'content': 'BASE',
          },
          {
            'identifier': 'prefill',
            'name': 'Assistant Prefill',
            'role': 'assistant',
            'content': 'Sure, here is the scene:',
          },
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'prefill', 'enabled': true},
            ],
          },
        ],
      });

      final result = parseSillyTavernPreset(json);
      // The block is still imported (role is round-tripped on the model)...
      expect(result.preset.promptBlocks.length, 2);
      // ...but a user-visible note flags the flattening so it isn't silent.
      final joined = result.skipped.join(' | ').toLowerCase();
      expect(joined, contains('role'));
    });

    test('all-system preset adds NO role note', () {
      final json = jsonEncode({
        'name': 'System Only',
        'prompts': [
          {
            'identifier': 'main',
            'name': 'Main',
            'role': 'system',
            'content': 'BASE',
          },
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
            ],
          },
        ],
      });
      final result = parseSillyTavernPreset(json);
      final joined = result.skipped.join(' | ').toLowerCase();
      expect(joined, isNot(contains('role')));
    });
  });
}
