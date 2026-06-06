// Regression for audit creator-01: the persona "Edit with AI" input was
// permanently locked because the persona-edit bootstrap left `flow == null`
// while `mode == 'persona'`, and `creatorInputLocked` locks any non-'edit'
// mode whose flow hasn't been picked. The fix seeds `flow = 'freeform'` in
// the persona-edit bootstrap (mirroring the character Edit-with-AI session),
// so this exercises the lock predicate directly to lock the contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/screens/character_assistant_screen.dart';

void main() {
  group('creatorInputLocked', () {
    test('no mode yet → locked (still on the greeting / mode picker)', () {
      expect(creatorInputLocked(mode: null, flow: null), isTrue);
    });

    test('character mode without a picked flow → locked', () {
      expect(creatorInputLocked(mode: 'character', flow: null), isTrue);
    });

    test('scenario mode without a picked flow → locked', () {
      expect(creatorInputLocked(mode: 'scenario', flow: null), isTrue);
    });

    test('persona mode without a flow → locked (the creator-01 dead end)', () {
      // This is the exact state the broken persona-edit bootstrap produced.
      expect(creatorInputLocked(mode: 'persona', flow: null), isTrue);
    });

    test('persona-edit session with flow=freeform → UNLOCKED (the fix)', () {
      expect(creatorInputLocked(mode: 'persona', flow: 'freeform'), isFalse);
    });

    test('character mode with a picked flow → unlocked', () {
      expect(creatorInputLocked(mode: 'character', flow: 'freeform'), isFalse);
    });

    test('edit mode is never locked, flow or not', () {
      expect(creatorInputLocked(mode: 'edit', flow: null), isFalse);
      expect(creatorInputLocked(mode: 'edit', flow: 'freeform'), isFalse);
    });
  });
}
