// 2026-07-04 (Gui): "o continue na conversa não funciona muito bem."
// Root cause: the Continue stream APPENDED blindly (`existing + chunk`) —
// when the model repeats the quoted tail (very common) the text duplicates,
// and when it starts at a word boundary the words glue together
// ("...ela sorriuela sorriu e disse" / "wordword"). This pure helper fixes
// the merge: trims the longest repeated overlap and inserts the missing
// space at the seam. Also reused by the prefill ("Start reply with")
// display path, where OpenAI-compat backends may echo the prefill back.
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/continuation_merge.dart';

void main() {
  group('mergeContinuationText', () {
    test('plain continuation gets a space at a word seam', () {
      expect(
        mergeContinuationText(
            existing: 'She opened the door', continuation: 'and stepped in.'),
        'She opened the door and stepped in.',
      );
    });

    test('no space added when the continuation starts with punctuation', () {
      expect(
        mergeContinuationText(
            existing: 'She opened the door', continuation: ', slowly.'),
        'She opened the door, slowly.',
      );
    });

    test('no space added when existing already ends with whitespace', () {
      expect(
        mergeContinuationText(
            existing: 'She opened the door ', continuation: 'and left.'),
        'She opened the door and left.',
      );
    });

    test('model repeating the tail is deduplicated', () {
      const existing = 'The rain fell hard on the tin roof as she waited.';
      expect(
        mergeContinuationText(
          existing: existing,
          continuation:
              'on the tin roof as she waited. Finally, headlights appeared.',
        ),
        '$existing Finally, headlights appeared.',
      );
    });

    test('repeated tail with extra leading whitespace still deduplicated',
        () {
      const existing = 'He counted the coins twice before answering.';
      expect(
        mergeContinuationText(
          existing: existing,
          continuation:
              '  twice before answering. "Not enough," he said at last.',
        ),
        '$existing "Not enough," he said at last.',
      );
    });

    test('full-message restart is collapsed (short message)', () {
      const existing = 'Vael narrows his eyes at the stranger.';
      expect(
        mergeContinuationText(
          existing: existing,
          continuation:
              'Vael narrows his eyes at the stranger. "Who sent you?"',
        ),
        '$existing "Who sent you?"',
      );
    });

    test('short accidental matches are NOT trimmed (min overlap guard)', () {
      // "in." (3 chars) appears at the end AND the continuation genuinely
      // starts with a word containing it — too short to count as a repeat.
      expect(
        mergeContinuationText(
            existing: 'They walked in.', continuation: 'Inside, it was dark.'),
        'They walked in. Inside, it was dark.',
      );
    });

    test('empty inputs pass through', () {
      expect(mergeContinuationText(existing: '', continuation: 'abc'), 'abc');
      expect(mergeContinuationText(existing: 'abc', continuation: ''), 'abc');
    });

    test('prefill echo: backend that repeats the prefill is deduplicated',
        () {
      expect(
        mergeContinuationText(
          existing: 'Vael: I told you already —',
          continuation: 'Vael: I told you already — the vault stays sealed.',
        ),
        'Vael: I told you already — the vault stays sealed.',
      );
    });
  });

  group('resolveStartReplyWith', () {
    test('null/blank → null (request stays byte-identical)', () {
      expect(
        resolveStartReplyWith(raw: null, charName: 'V', userName: 'U'),
        isNull,
      );
      expect(
        resolveStartReplyWith(raw: '   ', charName: 'V', userName: 'U'),
        isNull,
      );
    });

    test('fills macros case-insensitively and trims (Anthropic rejects a '
        'trailing-whitespace assistant prefix)', () {
      expect(
        resolveStartReplyWith(
            raw: '{{Char}}: fine, {{USER}} — ', charName: 'Vael',
            userName: 'Ren'),
        'Vael: fine, Ren —',
      );
    });
  });
}
