import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/prompt_post_processing.dart';

/// Wave CY.18.267: SillyTavern-style prompt post-processing pure engine.
/// Each mode is exercised against a representative messy array and the
/// string codec is round-tripped. The `none` identity, idempotency, and
/// edge cases (only-system, single-user collapse) are pinned down so the
/// chat_api chokepoint can rely on these guarantees.
void main() {
  // Convenience constructors.
  PpMessage sys(String c) => PpMessage('system', c);
  PpMessage usr(String c) => PpMessage('user', c);
  PpMessage ast(String c) => PpMessage('assistant', c);

  List<(String, String)> shape(List<PpMessage> ms) =>
      [for (final m in ms) (m.role, m.content)];

  // A representative messy array: two systems, two users, one assistant.
  List<PpMessage> messy() => [
        sys('S1'),
        sys('S2'),
        usr('U1'),
        usr('U2'),
        ast('A1'),
      ];

  group('enum string codec', () {
    test('round-trips every value', () {
      for (final v in PromptPostProcessing.values) {
        final s = promptPostProcessingToString(v);
        expect(promptPostProcessingFromString(s), v);
      }
    });

    test('unknown / null / empty string → none', () {
      expect(promptPostProcessingFromString('nope'), PromptPostProcessing.none);
      expect(promptPostProcessingFromString(null), PromptPostProcessing.none);
      expect(promptPostProcessingFromString(''), PromptPostProcessing.none);
    });

    test('exact stable names', () {
      expect(promptPostProcessingToString(PromptPostProcessing.none), 'none');
      expect(promptPostProcessingToString(PromptPostProcessing.mergeConsecutive),
          'mergeConsecutive');
      expect(promptPostProcessingToString(PromptPostProcessing.semiStrict),
          'semiStrict');
      expect(promptPostProcessingToString(PromptPostProcessing.strict),
          'strict');
      expect(promptPostProcessingToString(PromptPostProcessing.singleUser),
          'singleUser');
    });
  });

  group('none', () {
    test('returns the input unchanged (same reference)', () {
      final input = messy();
      final out = applyPromptPostProcessingRoles(input, PromptPostProcessing.none);
      expect(identical(out, input), isTrue);
    });

    test('empty list → empty', () {
      final out = applyPromptPostProcessingRoles(
          const <PpMessage>[], PromptPostProcessing.none);
      expect(out, isEmpty);
    });
  });

  group('mergeConsecutive', () {
    test('folds adjacent same-role into one (3 messages)', () {
      final out = applyPromptPostProcessingRoles(
          messy(), PromptPostProcessing.mergeConsecutive);
      expect(shape(out), [
        ('system', 'S1\n\nS2'),
        ('user', 'U1\n\nU2'),
        ('assistant', 'A1'),
      ]);
    });

    test('already-clean alternating list is unchanged in shape', () {
      final clean = [sys('S'), usr('U'), ast('A'), usr('U2')];
      final out = applyPromptPostProcessingRoles(
          clean, PromptPostProcessing.mergeConsecutive);
      expect(shape(out), shape(clean));
    });

    test('empty list → empty', () {
      final out = applyPromptPostProcessingRoles(
          const <PpMessage>[], PromptPostProcessing.mergeConsecutive);
      expect(out, isEmpty);
    });
  });

  group('semiStrict', () {
    test('one system first, then merged user, then assistant', () {
      final out = applyPromptPostProcessingRoles(
          messy(), PromptPostProcessing.semiStrict);
      expect(shape(out), [
        ('system', 'S1\n\nS2'),
        ('user', 'U1\n\nU2'),
        ('assistant', 'A1'),
      ]);
    });

    test('collapses systems scattered through the array into one, first', () {
      final scattered = [
        usr('U1'),
        sys('S1'),
        ast('A1'),
        sys('S2'),
        usr('U2'),
      ];
      final out = applyPromptPostProcessingRoles(
          scattered, PromptPostProcessing.semiStrict);
      expect(out.first.role, 'system');
      expect(out.first.content, 'S1\n\nS2');
      // Only one system message survives.
      expect(out.where((m) => m.role == 'system').length, 1);
      // Non-system order preserved.
      expect(shape(out.where((m) => m.role != 'system').toList()), [
        ('user', 'U1'),
        ('assistant', 'A1'),
        ('user', 'U2'),
      ]);
    });

    test('only-system messages → a single system message', () {
      final out = applyPromptPostProcessingRoles(
          [sys('S1'), sys('S2')], PromptPostProcessing.semiStrict);
      expect(shape(out), [
        ('system', 'S1\n\nS2'),
      ]);
    });

    test('no system message → unchanged after merge', () {
      final out = applyPromptPostProcessingRoles(
          [usr('U1'), ast('A1')], PromptPostProcessing.semiStrict);
      expect(shape(out), [
        ('user', 'U1'),
        ('assistant', 'A1'),
      ]);
    });
  });

  group('strict', () {
    test('inserts a placeholder user before a leading assistant greeting', () {
      // [system, assistant(greeting), user] — assistant is first non-system.
      final greetingFirst = [sys('S'), ast('Hi there!'), usr('Hello')];
      final out = applyPromptPostProcessingRoles(
          greetingFirst, PromptPostProcessing.strict);
      expect(shape(out), [
        ('system', 'S'),
        ('user', ' '),
        ('assistant', 'Hi there!'),
        ('user', 'Hello'),
      ]);
    });

    test('already-user-first array is left correctly alternating', () {
      final userFirst = [sys('S'), usr('U1'), ast('A1'), usr('U2')];
      final out = applyPromptPostProcessingRoles(
          userFirst, PromptPostProcessing.strict);
      expect(shape(out), [
        ('system', 'S'),
        ('user', 'U1'),
        ('assistant', 'A1'),
        ('user', 'U2'),
      ]);
    });

    test('no system, assistant-first → placeholder user inserted first', () {
      final out = applyPromptPostProcessingRoles(
          [ast('A1'), usr('U1')], PromptPostProcessing.strict);
      expect(shape(out), [
        ('user', ' '),
        ('assistant', 'A1'),
        ('user', 'U1'),
      ]);
    });

    test('only-system → single system, no placeholder', () {
      final out = applyPromptPostProcessingRoles(
          [sys('S1'), sys('S2')], PromptPostProcessing.strict);
      expect(shape(out), [
        ('system', 'S1\n\nS2'),
      ]);
    });
  });

  group('singleUser', () {
    test('collapses everything into exactly one user message, in order', () {
      final out = applyPromptPostProcessingRoles(
          messy(), PromptPostProcessing.singleUser);
      expect(out.length, 1);
      expect(out.first.role, 'user');
      expect(out.first.content, 'S1\n\nS2\n\nU1\n\nU2\n\nA1');
    });

    test('empty list → empty', () {
      final out = applyPromptPostProcessingRoles(
          const <PpMessage>[], PromptPostProcessing.singleUser);
      expect(out, isEmpty);
    });
  });

  group('idempotency (apply twice == once)', () {
    test('strict', () {
      final once = applyPromptPostProcessingRoles(
          messy(), PromptPostProcessing.strict);
      final twice = applyPromptPostProcessingRoles(
          once, PromptPostProcessing.strict);
      expect(shape(twice), shape(once));
    });

    test('strict with a leading-assistant array', () {
      final greetingFirst = [sys('S'), ast('Hi!'), usr('Hello')];
      final once = applyPromptPostProcessingRoles(
          greetingFirst, PromptPostProcessing.strict);
      final twice = applyPromptPostProcessingRoles(
          once, PromptPostProcessing.strict);
      expect(shape(twice), shape(once));
    });

    test('singleUser', () {
      final once = applyPromptPostProcessingRoles(
          messy(), PromptPostProcessing.singleUser);
      final twice = applyPromptPostProcessingRoles(
          once, PromptPostProcessing.singleUser);
      expect(shape(twice), shape(once));
    });

    test('semiStrict', () {
      final once = applyPromptPostProcessingRoles(
          messy(), PromptPostProcessing.semiStrict);
      final twice = applyPromptPostProcessingRoles(
          once, PromptPostProcessing.semiStrict);
      expect(shape(twice), shape(once));
    });

    test('mergeConsecutive', () {
      final once = applyPromptPostProcessingRoles(
          messy(), PromptPostProcessing.mergeConsecutive);
      final twice = applyPromptPostProcessingRoles(
          once, PromptPostProcessing.mergeConsecutive);
      expect(shape(twice), shape(once));
    });
  });

  group('ApiProvider model round-trip', () {
    test('default none is NOT written to JSON (byte-identical to pre-Wave)', () {
      final p = ApiProvider(id: 'p1', name: 'P');
      expect(p.promptPostProcessing, PromptPostProcessing.none);
      expect(p.toJson().containsKey('promptPostProcessing'), isFalse);
    });

    test('missing key loads as none', () {
      final p = ApiProvider.fromJson({'id': 'p1', 'name': 'P'});
      expect(p.promptPostProcessing, PromptPostProcessing.none);
    });

    test('custom value round-trips through toJson/fromJson', () {
      final p = ApiProvider(
        id: 'p1',
        name: 'P',
        promptPostProcessing: PromptPostProcessing.strict,
      );
      final json = p.toJson();
      expect(json['promptPostProcessing'], 'strict');
      final back = ApiProvider.fromJson(json);
      expect(back.promptPostProcessing, PromptPostProcessing.strict);
    });

    test('unknown stored value loads as none (tolerant)', () {
      final p = ApiProvider.fromJson({
        'id': 'p1',
        'name': 'P',
        'promptPostProcessing': 'bogusMode',
      });
      expect(p.promptPostProcessing, PromptPostProcessing.none);
    });
  });

  group('chat_api adapter (ChatTurn <-> engine)', () {
    test('none returns the same ChatTurn list reference (byte-identical)', () {
      final input = [
        ChatTurn('system', 'S'),
        ChatTurn('user', 'U'),
      ];
      final out = applyPromptPostProcessing(input, PromptPostProcessing.none);
      expect(identical(out, input), isTrue);
    });

    test('image-bearing arrays are left untouched on a reshaping mode', () {
      final input = [
        ChatTurn('system', 'S'),
        ChatTurn('user', 'Look at this',
            imageDataUrls: const ['data:image/png;base64,AAAA']),
      ];
      final out = applyPromptPostProcessing(input, PromptPostProcessing.strict);
      expect(identical(out, input), isTrue);
    });

    test('text array is reshaped by strict (placeholder user inserted)', () {
      final input = [
        ChatTurn('system', 'S'),
        ChatTurn('assistant', 'Greeting'),
        ChatTurn('user', 'Hi'),
      ];
      final out = applyPromptPostProcessing(input, PromptPostProcessing.strict);
      expect(out.map((m) => (m.role, m.content)).toList(), [
        ('system', 'S'),
        ('user', ' '),
        ('assistant', 'Greeting'),
        ('user', 'Hi'),
      ]);
    });
  });
}
