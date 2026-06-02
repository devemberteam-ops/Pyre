import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/image_describe.dart';

void main() {
  group('stripVisionReasoningPreamble', () {
    test('drops reasoning + "Shape Picker:" preamble above an Ensemble profile',
        () {
      // The exact shape of leak a user reported: the model narrated its
      // decision process and emitted a "Shape Picker:" label before the
      // real GROUP COMPOSITION output.
      const raw = '''
The user wants a character card analysis of the provided image.
The image features three male characters standing together in a wooden setting, likely a sauna or bathhouse given the steam, wood paneling, and their nakedness (mostly).
The user's note is in Portuguese: "Oi, vamos trabalhar com esses personagens aqui" (Hi, let's work with these characters here).
I need to follow the "Ensemble" structure because there are three characters of roughly equal visual weight.

Shape Picker: Ensemble.

GROUP COMPOSITION
Three men share the frame, side by side in the steam.

CHARACTER A
Tall, broad-shouldered, dark hair.

NEXT
Want to name the cast?''';
      final out = stripVisionReasoningPreamble(raw);
      expect(out, startsWith('GROUP COMPOSITION'));
      expect(out, isNot(contains('Shape Picker')));
      expect(out, isNot(contains('The user wants')));
      expect(out, isNot(contains('I need to follow')));
      // Real content downstream of the first header is preserved.
      expect(out, contains('CHARACTER A'));
      expect(out, contains('NEXT'));
    });

    test('leaves a clean single-character profile unchanged', () {
      const raw = '''GENERAL PHYSICAL FEATURES
Human woman, athletic build.

FACE
Heart-shaped, green eyes.

NEXT
Tell me about her voice?''';
      expect(stripVisionReasoningPreamble(raw), raw.trim());
    });

    test('removes <think> blocks and keeps the profile', () {
      const raw = "<think>Okay, single subject, I'll use the single "
          "template.</think>\nGENERAL PHYSICAL FEATURES\nHuman, tall.";
      final out = stripVisionReasoningPreamble(raw);
      expect(out, startsWith('GENERAL PHYSICAL FEATURES'));
      expect(out, isNot(contains('think')));
      expect(out, isNot(contains('single template')));
    });

    test('matches a markdown-wrapped opening header after preamble', () {
      const raw = 'Let me analyse this.\n\n**GROUP COMPOSITION**\nTwo characters.';
      final out = stripVisionReasoningPreamble(raw);
      expect(out, startsWith('**GROUP COMPOSITION**'));
      expect(out, isNot(contains('Let me analyse')));
    });

    test('slices at a CHARACTER A opener when the model leads with the cast',
        () {
      const raw = 'Alright, ensemble of two.\n\nCHARACTER A\nA knight in armour.';
      final out = stripVisionReasoningPreamble(raw);
      expect(out, startsWith('CHARACTER A'));
      expect(out, isNot(contains('Alright')));
    });

    test('slices at LOCATION TYPE for a setting image', () {
      const raw =
          'This is clearly a place, not a character.\n\nLOCATION TYPE\nA ruined cathedral.';
      final out = stripVisionReasoningPreamble(raw);
      expect(out, startsWith('LOCATION TYPE'));
      expect(out, isNot(contains('This is clearly')));
    });

    test('returns text unchanged when no recognised header is present', () {
      // Never nuke an unusual-but-valid reply to nothing.
      const raw =
          'Some unusual freeform description with no canonical headers at all.';
      expect(stripVisionReasoningPreamble(raw), raw.trim());
    });
  });
}
