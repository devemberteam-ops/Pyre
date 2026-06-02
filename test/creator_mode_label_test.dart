// Wave CY.18.200: unit tests for creatorModeLabel — truth table covering
// all documented mode values + null / unknown inputs.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_cascade.dart';

void main() {
  group('creatorModeLabel', () {
    test('character mode → "Build a character"', () {
      expect(
        creatorModeLabel(mode: 'character', editingPersonaId: null),
        'Build a character',
      );
    });

    test('scenario mode → "Build a Scenario"', () {
      expect(
        creatorModeLabel(mode: 'scenario', editingPersonaId: null),
        'Build a Scenario',
      );
    });

    test('persona mode + no editingPersonaId → "Build a persona"', () {
      expect(
        creatorModeLabel(mode: 'persona', editingPersonaId: null),
        'Build a persona',
      );
    });

    test('persona mode + editingPersonaId set → "Edit persona"', () {
      expect(
        creatorModeLabel(mode: 'persona', editingPersonaId: 'persona-abc'),
        'Edit persona',
      );
    });

    test('edit mode + no editingPersonaId → "Edit card"', () {
      expect(
        creatorModeLabel(mode: 'edit', editingPersonaId: null),
        'Edit card',
      );
    });

    test('edit mode + editingPersonaId set → "Edit persona"', () {
      expect(
        creatorModeLabel(mode: 'edit', editingPersonaId: 'persona-xyz'),
        'Edit persona',
      );
    });

    test('null mode → null (no badge)', () {
      expect(
        creatorModeLabel(mode: null, editingPersonaId: null),
        isNull,
      );
    });

    test('unknown mode string → null (no badge)', () {
      expect(
        creatorModeLabel(mode: 'future_mode', editingPersonaId: null),
        isNull,
      );
    });
  });
}
