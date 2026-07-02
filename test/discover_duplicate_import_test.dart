// Audit fix #3: importing the same BotBooru card twice used to silently
// create two Character records with no warning. `findLikelyDuplicateCharacter`
// is a pure pre-save check — same normalized name AND a similar description
// — so the Discover import flow can ask "You already imported '<name>' —
// import again anyway?" before adding a second copy. Non-blocking: the
// caller still lets the user proceed.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/discover_screen.dart';

Character _char({
  required String id,
  required String name,
  String description = '',
}) =>
    Character(id: id, name: name, description: description);

void main() {
  group('findLikelyDuplicateCharacter', () {
    test('exact same name + description → flagged as duplicate', () {
      final existing = [
        _char(id: '1', name: 'Vael', description: 'A stoic knight.'),
      ];
      final candidate =
          _char(id: '2', name: 'Vael', description: 'A stoic knight.');
      final dup = findLikelyDuplicateCharacter(candidate, existing);
      expect(dup, isNotNull);
      expect(dup!.id, '1');
    });

    test('same name, case/whitespace-insensitive → flagged', () {
      final existing = [
        _char(id: '1', name: 'Vael', description: 'A stoic knight.'),
      ];
      final candidate =
          _char(id: '2', name: '  vael  ', description: 'A stoic knight.');
      final dup = findLikelyDuplicateCharacter(candidate, existing);
      expect(dup, isNotNull);
    });

    test('same name, similar (not identical) description → flagged', () {
      final existing = [
        _char(
          id: '1',
          name: 'Vael',
          description:
              'A stoic knight who serves the crown and protects the realm.',
        ),
      ];
      // Minor edit (one word changed) — should still count as "similar".
      final candidate = _char(
        id: '2',
        name: 'Vael',
        description:
            'A stoic knight who serves the queen and protects the realm.',
      );
      final dup = findLikelyDuplicateCharacter(candidate, existing);
      expect(dup, isNotNull);
    });

    test('same name, wildly different description → NOT flagged', () {
      final existing = [
        _char(id: '1', name: 'Vael', description: 'A stoic knight.'),
      ];
      final candidate = _char(
        id: '2',
        name: 'Vael',
        description:
            'A completely different character from another universe with '
            'an unrelated backstory about space pirates and dragons.',
      );
      final dup = findLikelyDuplicateCharacter(candidate, existing);
      expect(dup, isNull);
    });

    test('different name → NOT flagged even with identical description', () {
      final existing = [
        _char(id: '1', name: 'Vael', description: 'A stoic knight.'),
      ];
      final candidate =
          _char(id: '2', name: 'Rowan', description: 'A stoic knight.');
      final dup = findLikelyDuplicateCharacter(candidate, existing);
      expect(dup, isNull);
    });

    test('empty library → NOT flagged', () {
      final candidate = _char(id: '1', name: 'Vael', description: 'x');
      expect(findLikelyDuplicateCharacter(candidate, const []), isNull);
    });

    test('both descriptions empty, same name → flagged (name-only match)',
        () {
      final existing = [_char(id: '1', name: 'Vael')];
      final candidate = _char(id: '2', name: 'Vael');
      final dup = findLikelyDuplicateCharacter(candidate, existing);
      expect(dup, isNotNull);
    });

    test('returns the FIRST matching existing character', () {
      final existing = [
        _char(id: '1', name: 'Other', description: 'nope'),
        _char(id: '2', name: 'Vael', description: 'A stoic knight.'),
        _char(id: '3', name: 'Vael', description: 'A stoic knight.'),
      ];
      final candidate =
          _char(id: '4', name: 'Vael', description: 'A stoic knight.');
      final dup = findLikelyDuplicateCharacter(candidate, existing);
      expect(dup!.id, '2');
    });
  });
}
