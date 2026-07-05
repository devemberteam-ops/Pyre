// 2026-07-05 (Gui): "O que tá faltando agora são botões de navegação para
// os OOCs, mas também eles não devem valer os scenarios que acabamos de
// mexer." — aux notes (OOC / Scene) get always-visible variant controls:
// the `< n/N >` arrows plus a `+` chip that branches a new version of the
// note. Fill-In scenario notes BOUND to a greeting variant
// (Message.greetingVariant != null) are excluded — those are navigated by
// swiping the greeting itself, so controls on the note would add a second,
// conflicting navigation axis.
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

Message _note(String text,
        {int variants = 1, int selected = 0, int? greetingVariant}) =>
    Message(
      id: 'n',
      kind: MessageKind.ooc,
      variants: List<String>.generate(variants, (i) => i == 0 ? text : '$text $i'),
      selectedVariant: selected,
      createdAt: 0,
    )..greetingVariant = greetingVariant;

void main() {
  group('auxNoteShowsVariantArrows', () {
    test('multi-variant manual note shows arrows', () {
      expect(auxNoteShowsVariantArrows(_note('ooc', variants: 2)), isTrue);
    });

    test('single-variant note has nothing to navigate', () {
      expect(auxNoteShowsVariantArrows(_note('ooc')), isFalse);
    });

    test('bound Fill-In scenario note NEVER shows arrows', () {
      expect(
        auxNoteShowsVariantArrows(
            _note('Scenario: x', variants: 2, greetingVariant: 1)),
        isFalse,
      );
    });
  });

  group('auxNoteShowsBranchChip', () {
    test('manual note with text can branch', () {
      expect(auxNoteShowsBranchChip(_note('ooc')), isTrue);
    });

    test('bound Fill-In scenario note NEVER branches', () {
      expect(
        auxNoteShowsBranchChip(_note('Scenario: x', greetingVariant: 0)),
        isFalse,
      );
    });

    test('empty / blank current variant suppresses the + (no branching a '
        'slot the user has not committed)', () {
      expect(auxNoteShowsBranchChip(_note('')), isFalse);
      expect(auxNoteShowsBranchChip(_note('   ')), isFalse);
    });

    test('branch stays available from a NON-last variant (addVariant '
        'appends + selects the new slot regardless of position)', () {
      expect(
        auxNoteShowsBranchChip(_note('ooc', variants: 3, selected: 0)),
        isTrue,
      );
    });
  });
}
