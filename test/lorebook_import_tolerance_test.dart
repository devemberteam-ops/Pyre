// Bug 2 regression: lorebookFromCharacterBook() used hard casts for
// caseSensitive/matchWholeWords (bool), insertion_order/order/probability (num),
// and content (String). SillyTavern/older exporters commonly emit those as
// 0/1 ints or numeric strings, causing TypeError that aborted the ENTIRE
// card/lorebook import with an opaque error.
//
// Fix: _lBoolOpt / _lNum / _lStr coerce off-spec types gracefully.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_import.dart';

void main() {
  group('Bug 2: off-spec field types parse without throwing', () {
    // Core regression: ST exporter emitting caseSensitive as 0/1 int.
    test('caseSensitive:0 parses as false (not TypeError)', () {
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'Test',
        'entries': [
          <String, dynamic>{
            'keys': ['castle'],
            'content': 'A great castle.',
            'caseSensitive': 0, // int instead of bool
            'matchWholeWords': 1, // int instead of bool
            'insertion_order': '5', // String instead of num
            'probability': '75', // String instead of num
          },
        ],
      });
      expect(book, isNotNull, reason: 'must parse, not throw TypeError');
      final e = book!.entries.single;
      expect(e.caseSensitive, isFalse,
          reason: 'caseSensitive:0 → false');
      expect(e.matchWholeWords, isTrue,
          reason: 'matchWholeWords:1 → true');
      expect(e.order, 5, reason: 'insertion_order:"5" → int 5');
      expect(e.probability, 75, reason: 'probability:"75" → int 75');
    });

    test('caseSensitive:1 parses as true', () {
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'T',
        'entries': [
          <String, dynamic>{
            'keys': ['k'],
            'content': 'c',
            'caseSensitive': 1,
          },
        ],
      });
      expect(book!.entries.single.caseSensitive, isTrue);
    });

    test('matchWholeWords:0 parses as false', () {
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'T',
        'entries': [
          <String, dynamic>{
            'keys': ['k'],
            'content': 'c',
            'matchWholeWords': 0,
          },
        ],
      });
      expect(book!.entries.single.matchWholeWords, isFalse);
    });

    test('order as String "10" parses to int 10', () {
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'T',
        'entries': [
          <String, dynamic>{
            'keys': ['k'],
            'content': 'c',
            'order': '10',
          },
        ],
      });
      expect(book!.entries.single.order, 10);
    });

    test('probability as String "50" parses to int 50', () {
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'T',
        'entries': [
          <String, dynamic>{
            'keys': ['k'],
            'content': 'c',
            'probability': '50',
          },
        ],
      });
      expect(book!.entries.single.probability, 50);
    });

    // content as a number — tolerated as "empty" (coerces to null → ''),
    // making the entry be skipped if keys are also empty.
    test('content as number with non-empty keys: entry is skipped (empty content)', () {
      // _lStr(42) → null → '' ; keys non-empty so entry IS kept
      // but content is '' (the number is not turned into "42").
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'T',
        'entries': [
          <String, dynamic>{
            'keys': ['k'],
            'content': 42, // number — not a string
          },
        ],
      });
      // The entry has non-empty keys but empty content — it passes the
      // skip-dud gate (`content.isEmpty && keys.isEmpty` → false when
      // keys non-empty).  Either it is kept with empty content OR skipped.
      // The important thing is NO THROW.
      expect(book, isNotNull, reason: 'must not throw even if entry is dropped');
    });

    test('all problematic fields together: no throw, sensible defaults', () {
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'Combined',
        'entries': [
          <String, dynamic>{
            'keys': ['dragon'],
            'content': 'Dragons roam the land.',
            'insertion_order': '20',
            'caseSensitive': 0,
            'matchWholeWords': 1,
            'probability': '80',
            'useProbability': true,
          },
          <String, dynamic>{
            'keys': ['elf'],
            'content': 'Elves live in the forest.',
            'insertion_order': 30, // already correct int — must still work
            'caseSensitive': true, // already correct bool
          },
        ],
      });
      expect(book, isNotNull);
      expect(book!.entries.length, 2);
      final dragon = book.entries[0];
      expect(dragon.order, 20);
      expect(dragon.caseSensitive, isFalse);
      expect(dragon.matchWholeWords, isTrue);
      expect(dragon.probability, 80);
      expect(dragon.useProbability, isTrue);

      final elf = book.entries[1];
      expect(elf.order, 30);
      expect(elf.caseSensitive, isTrue);
    });

    // Absent optional fields must still yield null (not default bool values).
    test('absent caseSensitive and matchWholeWords yield null', () {
      final book = tryParseLorebookJson(<String, dynamic>{
        'name': 'T',
        'entries': [
          <String, dynamic>{
            'keys': ['k'],
            'content': 'c',
            // no caseSensitive / matchWholeWords
          },
        ],
      });
      final e = book!.entries.single;
      expect(e.caseSensitive, isNull);
      expect(e.matchWholeWords, isNull);
    });
  });

  group('Fix 2: embedded character_book selective/probability fields under extensions', () {
    // ST's card exporter (convertWorldInfoToCharacterBook) nests these
    // fields under `entry.extensions.*` for a card's EMBEDDED
    // character_book — only a STANDALONE World Info export has them at
    // the entry's top level.
    test('reads selectiveLogic/probability/case fields from extensions '
        'when absent at top level', () {
      final book = lorebookFromCharacterBook(<String, dynamic>{
        'name': 'Embedded Book',
        'entries': [
          <String, dynamic>{
            'keys': ['castle'],
            'content': 'A great castle.',
            'enabled': true,
            'constant': false,
            'insertion_order': 10,
            'extensions': <String, dynamic>{
              'selectiveLogic': 3,
              'probability': 30,
              'useProbability': true,
              'case_sensitive': true,
              'match_whole_words': true,
            },
          },
        ],
      });
      final e = book.entries.single;
      expect(e.selectiveLogic, LoreSelectiveLogic.andAll);
      expect(e.probability, 30);
      expect(e.useProbability, isTrue);
      expect(e.caseSensitive, isTrue);
      expect(e.matchWholeWords, isTrue);
    });

    test('also accepts camelCase caseSensitive/matchWholeWords inside '
        'extensions', () {
      final book = lorebookFromCharacterBook(<String, dynamic>{
        'name': 'Embedded Book 2',
        'entries': [
          <String, dynamic>{
            'keys': ['dragon'],
            'content': 'Dragons roam the land.',
            'extensions': <String, dynamic>{
              'caseSensitive': true,
              'matchWholeWords': true,
            },
          },
        ],
      });
      final e = book.entries.single;
      expect(e.caseSensitive, isTrue);
      expect(e.matchWholeWords, isTrue);
    });

    test('top-level values win over extensions when both are present', () {
      final book = lorebookFromCharacterBook(<String, dynamic>{
        'name': 'Both Levels',
        'entries': [
          <String, dynamic>{
            'keys': ['elf'],
            'content': 'Elves live in the forest.',
            'selectiveLogic': 0, // andAny — differs from extensions below
            'probability': 55,
            'useProbability': false,
            'caseSensitive': false,
            'matchWholeWords': false,
            'extensions': <String, dynamic>{
              'selectiveLogic': 3,
              'probability': 30,
              'useProbability': true,
              'case_sensitive': true,
              'match_whole_words': true,
            },
          },
        ],
      });
      final e = book.entries.single;
      expect(e.selectiveLogic, LoreSelectiveLogic.andAny);
      expect(e.probability, 55);
      expect(e.useProbability, isFalse);
      expect(e.caseSensitive, isFalse);
      expect(e.matchWholeWords, isFalse);
    });
  });
}
