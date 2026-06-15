// Sub-task C: OOC / Scene message behavior regression tests.
//
// Verifies the founder-decision: OOC and Scene must behave like normal user
// messages (editable, deletable, branchable / variant-swipeable). Only
// MessageKind.system remains truly read-only / aux.
//
// These are PURE / logic tests (no widget build required), so they run fast
// without a real Flutter rendering tree and are not sensitive to widget layout
// details changing in later waves.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_screen.dart';

void main() {
  group('isReadOnlyAuxKind', () {
    test('system is read-only aux', () {
      expect(isReadOnlyAuxKind(MessageKind.system), isTrue);
    });

    test('ooc is NOT read-only aux — it must go through the full bubble', () {
      expect(isReadOnlyAuxKind(MessageKind.ooc), isFalse);
    });

    test('scene is NOT read-only aux — it must go through the full bubble', () {
      expect(isReadOnlyAuxKind(MessageKind.scene), isFalse);
    });

    test('user is NOT read-only aux', () {
      expect(isReadOnlyAuxKind(MessageKind.user), isFalse);
    });

    test('char is NOT read-only aux', () {
      expect(isReadOnlyAuxKind(MessageKind.char), isFalse);
    });

    test('all non-system kinds return false', () {
      final nonSystem = [
        MessageKind.user,
        MessageKind.char,
        MessageKind.ooc,
        MessageKind.scene,
      ];
      for (final k in nonSystem) {
        expect(
          isReadOnlyAuxKind(k),
          isFalse,
          reason: '$k should NOT be read-only aux',
        );
      }
    });

    test('only system returns true', () {
      final all = MessageKind.values;
      final readOnlyKinds = all.where(isReadOnlyAuxKind).toList();
      expect(readOnlyKinds, equals([MessageKind.system]));
    });
  });

  group('OOC/Scene are user-side (isUserSide predicate)', () {
    // Inline definition of the same predicate used in chat_screen.dart build().
    // If the predicate in chat_screen changes, this test should be updated too.
    bool isUserSide(MessageKind k) =>
        k == MessageKind.user ||
        k == MessageKind.ooc ||
        k == MessageKind.scene;

    test('user is user-side', () => expect(isUserSide(MessageKind.user), isTrue));
    test('ooc is user-side', () => expect(isUserSide(MessageKind.ooc), isTrue));
    test('scene is user-side', () => expect(isUserSide(MessageKind.scene), isTrue));
    test('char is NOT user-side', () => expect(isUserSide(MessageKind.char), isFalse));
    test('system is NOT user-side', () => expect(isUserSide(MessageKind.system), isFalse));
  });

  group('Message with OOC/Scene kind supports variants', () {
    // Verifies the data model allows multi-variant OOC/Scene messages —
    // a prerequisite for the branch/swipe affordance to make sense.
    test('OOC message can hold multiple variants', () {
      final m = Message(
        id: 'ooc-1',
        kind: MessageKind.ooc,
        variants: ['First take', 'Second take'],
      );
      m.selectedVariant = 1;
      expect(m.variants.length, equals(2));
      expect(m.text, equals('Second take'));
    });

    test('Scene message can hold multiple variants', () {
      final m = Message(
        id: 'scene-1',
        kind: MessageKind.scene,
        variants: ['The sun rises.', 'A storm begins.'],
      );
      m.selectedVariant = 1;
      expect(m.variants.length, equals(2));
      expect(m.text, equals('A storm begins.'));
    });

    test('OOC message selectedVariant defaults to 0', () {
      final m = Message(
        id: 'ooc-2',
        kind: MessageKind.ooc,
        variants: ['Only take'],
      );
      expect(m.selectedVariant, equals(0));
      expect(m.text, equals('Only take'));
    });
  });
}
