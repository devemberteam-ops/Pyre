// Wave CY.18.242 (Build by message): unit coverage for the two pure pieces
// of the message-driven build trigger that replaced the floating "Build the
// sheet" pill:
//   - `detectAndStripBuildMarker` — finds + strips the `[[BUILD_SHEET]]`
//     marker the architect emits, returning (stripped text, found?).
//   - `isBuildCommand` — matches the deterministic `/build` typed command.
// Both live in `lib/services/creator_cascade.dart` so they're testable
// without a Flutter widget / BuildContext.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_cascade.dart';

void main() {
  group('detectAndStripBuildMarker', () {
    test('marker on its own final line → stripped + found', () {
      const raw = "Got it — building the sheet now.\n\n[[BUILD_SHEET]]";
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text, 'Got it — building the sheet now.');
      expect(r.text.contains('[[BUILD_SHEET]]'), isFalse);
    });

    test('no marker → returns text unchanged (trimmed), found false', () {
      const raw = 'I think we have enough. Want me to build it, or keep going?';
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isFalse);
      expect(r.text, raw);
    });

    test('case-insensitive: lowercase marker still detected + stripped', () {
      const raw = "Building it.\n[[build_sheet]]";
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text, 'Building it.');
    });

    test('mixed case marker detected', () {
      const raw = "Done.\n[[Build_Sheet]]";
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text, 'Done.');
    });

    test('whitespace inside the brackets is tolerated', () {
      const raw = "Ok.\n[[ BUILD_SHEET ]]";
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text, 'Ok.');
    });

    test('trailing whitespace/newlines after marker are absorbed', () {
      const raw = "Sure.\n\n[[BUILD_SHEET]]\n   \n";
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text, 'Sure.');
    });

    test('marker inline mid-text is still stripped (no leftover)', () {
      const raw = 'Confirming. [[BUILD_SHEET]] (building)';
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text.contains('[[BUILD_SHEET]]'), isFalse);
      // The surrounding prose survives.
      expect(r.text.contains('Confirming.'), isTrue);
      expect(r.text.contains('(building)'), isTrue);
    });

    test('multiple markers all stripped, still found', () {
      const raw = "[[BUILD_SHEET]]\nBuilding.\n[[BUILD_SHEET]]";
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text.contains('[[BUILD_SHEET]]'), isFalse);
      expect(r.text.contains('Building.'), isTrue);
    });

    test('a non-ASCII confirmation line is preserved verbatim', () {
      // The confirmation is the model's own words (whatever language it is
      // writing in); only the fixed ASCII marker is stripped. A line with
      // non-ASCII glyphs must survive intact.
      const raw = 'Building the sheet now — здесь, 了解.\n[[BUILD_SHEET]]';
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isTrue);
      expect(r.text, 'Building the sheet now — здесь, 了解.');
    });

    test('text that merely mentions building is NOT a marker', () {
      const raw = 'Should I build the sheet now?';
      final r = detectAndStripBuildMarker(raw);
      expect(r.found, isFalse);
      expect(r.text, raw);
    });
  });

  group('isBuildCommand', () {
    test('exact /build matches', () {
      expect(isBuildCommand('/build'), isTrue);
    });

    test('/build the sheet matches', () {
      expect(isBuildCommand('/build the sheet'), isTrue);
    });

    test('case-insensitive', () {
      expect(isBuildCommand('/BUILD'), isTrue);
      expect(isBuildCommand('/Build The Sheet'), isTrue);
    });

    test('surrounding whitespace tolerated', () {
      expect(isBuildCommand('  /build  '), isTrue);
      expect(isBuildCommand('\t/build the sheet\n'), isTrue);
    });

    test('partial / extra text → not a build command', () {
      expect(isBuildCommand('/builder'), isFalse);
      expect(isBuildCommand('/build now'), isFalse);
      expect(isBuildCommand('build'), isFalse);
      expect(isBuildCommand('please /build'), isFalse);
      expect(isBuildCommand('/build the'), isFalse);
      expect(isBuildCommand(''), isFalse);
      expect(isBuildCommand('a normal message about /build'), isFalse);
    });
  });

  // C-2 (CRITICAL): a normal send during an in-flight structured build must be
  // blocked, or it bumps `_streamGen` and the build silently discards itself.
  group('creatorSendBlocked', () {
    test('blocks a send while a structured build is in flight', () {
      expect(
        creatorSendBlocked(
          trimmedText: 'hello',
          hasPendingAttachments: false,
          generating: false,
          structuredBuilding: true,
        ),
        isTrue,
        reason: 'mid-build send must be blocked (would discard the build)',
      );
    });

    test('blocks a send while a normal generation is in flight', () {
      expect(
        creatorSendBlocked(
          trimmedText: 'hello',
          hasPendingAttachments: false,
          generating: true,
          structuredBuilding: false,
        ),
        isTrue,
      );
    });

    test('blocks an empty send (no text, no attachments)', () {
      expect(
        creatorSendBlocked(
          trimmedText: '',
          hasPendingAttachments: false,
          generating: false,
          structuredBuilding: false,
        ),
        isTrue,
      );
    });

    test('allows a normal send when idle with text', () {
      expect(
        creatorSendBlocked(
          trimmedText: 'hello',
          hasPendingAttachments: false,
          generating: false,
          structuredBuilding: false,
        ),
        isFalse,
      );
    });

    test('allows an attachment-only send (empty text, has attachment)', () {
      expect(
        creatorSendBlocked(
          trimmedText: '',
          hasPendingAttachments: true,
          generating: false,
          structuredBuilding: false,
        ),
        isFalse,
      );
    });

    test('attachment-only send is still blocked while building', () {
      expect(
        creatorSendBlocked(
          trimmedText: '',
          hasPendingAttachments: true,
          generating: false,
          structuredBuilding: true,
        ),
        isTrue,
      );
    });
  });
}
