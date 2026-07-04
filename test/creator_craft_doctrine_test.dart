// 2026-07-04 (Gui): "o creator faz o que faz mas não sabe o PORQUÊ" — each
// architect now carries a per-mode CRAFT DOCTRINE (what makes its artifact
// good), appended at assembly so it also rides user-forked prompts; the
// structured build's system turn carries the condensed version. This locks
// the wiring (each mode gets ITS doctrine, edit stays doctrine-free).
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_prompt_builder.dart';
import 'package:pyre/services/creator_build_prompts.dart';
import 'package:pyre/services/creator_schema.dart' as cs;

void main() {
  group('architect prompts carry the craft doctrine', () {
    test('character mode → character doctrine', () {
      final p = creatorArchitectPrompt(mode: 'character');
      expect(p, contains('WHAT MAKES A CHARACTER CARD GOOD'));
      expect(p, isNot(contains('WHAT MAKES A SCENARIO CARD GOOD')));
    });

    test('scenario mode → scenario doctrine', () {
      final p = creatorArchitectPrompt(mode: 'scenario');
      expect(p, contains('WHAT MAKES A SCENARIO CARD GOOD'));
      expect(p, isNot(contains('WHAT MAKES A CHARACTER CARD GOOD')));
    });

    test('persona mode → persona doctrine', () {
      final p = creatorArchitectPrompt(mode: 'persona');
      expect(p, contains('WHAT MAKES A PERSONA GOOD'));
    });

    test('a user-forked architect prompt STILL gets the doctrine appended',
        () {
      final p = creatorArchitectPrompt(
          mode: 'character', characterPrompt: 'my custom architect');
      expect(p, contains('my custom architect'));
      expect(p, contains('WHAT MAKES A CHARACTER CARD GOOD'));
    });

    test('edit mode stays doctrine-free (narrow edits, own contract)', () {
      final p = creatorArchitectPrompt(mode: 'edit');
      expect(p, isNot(contains('WHAT MAKES A CHARACTER CARD GOOD')));
      expect(p, isNot(contains('WHAT MAKES A SCENARIO CARD GOOD')));
    });
  });

  group('structured build system turn carries the condensed craft', () {
    String systemOf(cs.CreatorMode mode) => buildBatchTurns(
          mode: mode,
          batchKeys: const ['first_mes'],
          transcript: const [],
        ).first.content;

    test('per mode', () {
      expect(systemOf(cs.CreatorMode.character),
          contains('instrument the model PLAYS'));
      expect(systemOf(cs.CreatorMode.persona),
          contains('how the world sees and treats the user'));
      expect(systemOf(cs.CreatorMode.scenario),
          contains('ENGINE for situations'));
    });
  });
}
