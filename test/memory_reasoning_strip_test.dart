import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/memory.dart';

void main() {
  group('stripRecapReasoningPreamble', () {
    test('drops leading meta-reasoning planning lines, keeps the recap tail',
        () {
      // The exact shape of leak the audit describes: a reasoning model dumps
      // its planning ("The user wants…/I should…/wait…") before the recap.
      const raw = '''
The user wants me to summarise the events so far as long-term memory.
I should write this in past tense and not continue the story.
Let me recap what happened between Ren and Vesna.
Wait, I also need to keep it as flowing prose.

Ren stumbled through the Sunken Gate and met Vesna at the ruins. They argued over the map, then agreed to travel together toward the next aether well.''';
      final out = stripRecapReasoningPreamble(raw);
      expect(out, startsWith('Ren stumbled through the Sunken Gate'));
      expect(out, isNot(contains('The user wants')));
      expect(out, isNot(contains('I should write')));
      expect(out, isNot(contains('Let me recap')));
      expect(out, isNot(contains('Wait,')));
      // The narrative recap tail is preserved verbatim.
      expect(out, contains('agreed to travel together'));
    });

    test('leaves a clean narrative recap unchanged', () {
      const raw =
          'Ren and Vesna crossed the bridge and reached the keep. They made '
          'camp as the storm rolled in, and Vesna kept first watch.';
      expect(stripRecapReasoningPreamble(raw), raw.trim());
    });

    test('strips a <think> wrapper and keeps the recap', () {
      const raw = '<think>Okay, the user wants a recap. Let me write it in past '
          'tense.</think>\nRen reached the village and bartered for supplies.';
      final out = stripRecapReasoningPreamble(raw);
      expect(out, startsWith('Ren reached the village'));
      expect(out, isNot(contains('think')));
      expect(out, isNot(contains('the user wants')));
    });

    test('never nukes a recap that is ALL meta-style lines to empty', () {
      // Defensive: if every line looks like reasoning we return the original
      // rather than an empty string (a thin recap beats none).
      const raw = 'I should summarise this.\nLet me think about the events.';
      final out = stripRecapReasoningPreamble(raw);
      expect(out, isNotEmpty);
    });

    test('does not strip a narrative line that merely starts with a word '
        'shared with a marker', () {
      // "Letting go" must not be mistaken for the "Let me/Let's" planning marker.
      const raw = 'Letting go of the railing, Ren slid down into the dark.';
      expect(stripRecapReasoningPreamble(raw), raw.trim());
    });
  });
}
