import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/card_assist_prompts.dart';

void main() {
  group('CreatorPreset (de)serialisation', () {
    test('round-trips through toJson/fromJson', () {
      final p = CreatorPreset(
        id: 'creatorpreset_custom',
        name: 'My Architect',
        locked: false,
        characterPrompt: 'char base',
        scenarioPrompt: 'scenario base',
        editPrompt: 'edit base',
      );
      final restored = CreatorPreset.fromJson(p.toJson());
      expect(restored.id, p.id);
      expect(restored.name, p.name);
      expect(restored.locked, p.locked);
      expect(restored.characterPrompt, p.characterPrompt);
      expect(restored.scenarioPrompt, p.scenarioPrompt);
      expect(restored.editPrompt, p.editPrompt);
    });

    test('fromJson tolerates missing optional fields', () {
      final restored = CreatorPreset.fromJson({'id': 'x'});
      expect(restored.id, 'x');
      expect(restored.name, 'Creator preset');
      expect(restored.locked, isFalse);
      expect(restored.characterPrompt, '');
      expect(restored.scenarioPrompt, '');
      expect(restored.editPrompt, '');
    });

    test('locked default round-trips identically', () {
      final def = buildLockedDefaultCreatorPreset();
      final restored = CreatorPreset.fromJson(def.toJson());
      expect(restored.id, def.id);
      expect(restored.name, def.name);
      expect(restored.locked, def.locked);
      expect(restored.characterPrompt, def.characterPrompt);
      expect(restored.scenarioPrompt, def.scenarioPrompt);
      expect(restored.editPrompt, def.editPrompt);
    });
  });

  group('buildLockedDefaultCreatorPreset', () {
    test('is locked with a stable id and the Pyre Default name', () {
      final def = buildLockedDefaultCreatorPreset();
      expect(def.locked, isTrue);
      expect(def.id, lockedDefaultCreatorPresetId);
      expect(def.id, 'creatorpreset_default');
      expect(def.name, 'Pyre Default');
    });

    test('prompts equal the v2 architect consts', () {
      final def = buildLockedDefaultCreatorPreset();
      expect(def.characterPrompt, kCardAssistantPrompt);
      expect(def.scenarioPrompt, kScenarioArchitectPrompt);
      expect(def.editPrompt, kCardEditorFreeFormPrompt);
    });
  });
}
