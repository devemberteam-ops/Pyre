import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/refusal_detector.dart';

void main() {
  group('classifyResponse', () {
    test('empty / whitespace → empty', () {
      expect(classifyResponse(''), ResponseVerdict.empty);
      expect(classifyResponse('   \n  '), ResponseVerdict.empty);
    });

    test('classic refusals → likelyRefusal', () {
      expect(classifyResponse("I'm sorry, but I can't continue this."),
          ResponseVerdict.likelyRefusal);
      expect(classifyResponse("I cannot help with that request."),
          ResponseVerdict.likelyRefusal);
      expect(classifyResponse("I won't write this. As an AI, I must decline."),
          ResponseVerdict.likelyRefusal);
      expect(classifyResponse("I'm not able to assist with that."),
          ResponseVerdict.likelyRefusal);
    });

    test('legit short in-character "No." → ok (no refusal phrase)', () {
      expect(classifyResponse('No.'), ResponseVerdict.ok);
      expect(classifyResponse('"Never," she hissed, turning away.'),
          ResponseVerdict.ok);
    });

    test('short line with "I can\'t" in dialogue (not a refusal) → ok', () {
      expect(
          classifyResponse('"I can\'t believe you\'re here," she gasped.'),
          ResponseVerdict.ok);
      expect(
          classifyResponse(
              'She looked away. "I can\'t," she whispered, "not yet."'),
          ResponseVerdict.ok);
    });

    test('long normal RP reply with markup → ok', () {
      final long = '*She steps closer, eyes narrowing.* "You really think '
          'you can walk in here and demand answers?" Her hand drifts to the '
          'hilt at her side, knuckles whitening. The tavern noise dims as a '
          'few heads turn toward the sudden tension between you two. '
          '"I cannot stand people like you." She spits the words like venom, '
          'and for a moment you wonder if the blade will leave its sheath.';
      expect(classifyResponse(long), ResponseVerdict.ok);
    });

    test('normal short RP reply with markup → ok', () {
      expect(classifyResponse('*nods* "Sure, follow me."'),
          ResponseVerdict.ok);
    });

    // Audit M1 false-positive guards.
    test('emotional in-character "I\'m sorry, but…" with dialogue → ok', () {
      expect(
          classifyResponse(
              '"I\'m sorry, but you left me no choice," she whispered.'),
          ResponseVerdict.ok);
    });

    test('AI-persona in-character line (not a refusal) → ok', () {
      expect(
          classifyResponse('As an AI, I was built to serve you, master.'),
          ResponseVerdict.ok);
    });

    test('refusal with a smart apostrophe still fires (markup gate '
        'ignores apostrophes)', () {
      // U+2019 apostrophe in "can’t" must NOT count as markup.
      expect(classifyResponse('I can’t continue with this.'),
          ResponseVerdict.likelyRefusal);
    });
  });
}
