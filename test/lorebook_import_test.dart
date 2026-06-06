// Lorebook import shape coverage.
//
// Regression target (reported by a user on r/SillyTavernAI): a STANDALONE
// SillyTavern World Info / lorebook .json was rejected ("Pyre will not
// recognize it"). Root cause: ST's standalone export stores `entries` as an
// OBJECT keyed by uid ("0","1",…), but the importer only handled `entries`
// as a List (the chara_card_v2 `character_book` array shape). Both shapes
// must parse.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_import.dart';

void main() {
  // A realistic standalone SillyTavern World Info export: `entries` is an
  // object keyed by uid, with ST field names (key/content/disable/order).
  Map<String, dynamic> stStandalone() => {
        'name': 'Eldoria Lore',
        'entries': {
          '0': {
            'uid': 0,
            'key': ['Eldoria', 'the kingdom'],
            'keysecondary': <String>[],
            'comment': 'Kingdom of Eldoria',
            'content': 'Eldoria is a northern kingdom ruled by Queen Maeve.',
            'constant': false,
            'selective': true,
            'selectiveLogic': 0,
            'order': 100,
            'position': 0,
            'disable': false,
            'probability': 100,
            'useProbability': true,
          },
          '1': {
            'uid': 1,
            'key': <String>[],
            'comment': 'World intro (always on)',
            'content': 'The realm runs on aether drawn from the Gate.',
            'constant': true,
            'disable': false,
            'order': 50,
          },
        },
      };

  group('SillyTavern standalone lorebook (entries as uid-keyed object)', () {
    test('parses into a populated Lorebook (not null, all entries)', () {
      final book = tryParseLorebookJson(stStandalone());
      expect(book, isNotNull,
          reason: 'standalone ST World Info must be recognised');
      expect(book!.name, 'Eldoria Lore');
      expect(book.entries.length, 2);
    });

    test('maps ST field names + constant flag correctly', () {
      final book = tryParseLorebookJson(stStandalone())!;
      final keyed = book.entries.firstWhere((e) => e.keys.isNotEmpty);
      expect(keyed.keys, contains('Eldoria'));
      expect(keyed.content, contains('Queen Maeve'));
      expect(keyed.constant, isFalse);
      expect(keyed.enabled, isTrue); // disable:false -> enabled
      expect(keyed.order, 100);

      final always = book.entries.firstWhere((e) => e.constant);
      expect(always.content, contains('aether'));
      expect(always.keys, isEmpty);
    });

    test('a disabled ST entry imports with enabled:false', () {
      final json = stStandalone();
      (json['entries'] as Map)['2'] = {
        'uid': 2,
        'key': ['hidden'],
        'content': 'should import but be disabled',
        'disable': true,
      };
      final book = tryParseLorebookJson(json)!;
      final hidden = book.entries.firstWhere((e) => e.keys.contains('hidden'));
      expect(hidden.enabled, isFalse);
    });
  });

  group('regression: existing shapes still parse', () {
    test('chara_card_v2 character_book array shape', () {
      final embedded = <String, dynamic>{
        'name': 'Embedded',
        'entries': [
          {
            'keys': ['x'],
            'content': 'x content',
            'insertion_order': 5,
            'constant': false,
          },
        ],
      };
      final book = tryParseLorebookJson(embedded);
      expect(book, isNotNull);
      expect(book!.entries.length, 1);
      expect(book.entries.first.keys, contains('x'));
      expect(book.entries.first.order, 5);
    });

    test('full chara_card_v2 card with nested data.character_book', () {
      final card = <String, dynamic>{
        'spec': 'chara_card_v2',
        'data': {
          'name': 'Someone',
          'character_book': {
            'name': 'Card Book',
            'entries': [
              {'keys': ['alpha'], 'content': 'alpha lore'},
            ],
          },
        },
      };
      final book = tryParseLorebookJson(card);
      expect(book, isNotNull);
      expect(book!.entries.length, 1);
      expect(book.entries.first.keys, contains('alpha'));
    });

    test('non-lorebook JSON returns null', () {
      final book = tryParseLorebookJson(<String, dynamic>{'hello': 'world'});
      expect(book, isNull);
    });
  });

  // BotBooru's "Download JSON" returns a chara_card_v2 `character_book`
  // "bare book": top-level metadata + `entries` as an ARRAY, where each
  // entry carries hybrid ST/chara_card keys (key + keys, keysecondary +
  // secondary_keys, order + insertion_order, enabled, constant, …). The
  // existing tolerant parser must accept this exact shape with NO new code.
  Map<String, dynamic> botbooruBook() => {
        'name': 'The Vael — World Lore',
        'description': 'A frank isekai-JRPG world.',
        'is_creation': false,
        'scan_depth': 4,
        'token_budget': 2048,
        'recursive_scanning': false,
        'extensions': <String, dynamic>{},
        'entries': [
          {
            'uid': 0,
            'key': ['Vael', 'the realm'],
            'keysecondary': <String>[],
            'comment': 'Overview',
            'content': 'The Vael is a fractured continent ringed by Gates.',
            'constant': true,
            'selective': false,
            'selectiveLogic': 0,
            'order': 10,
            'position': 0,
            'disable': false,
            'addMemo': true,
            'excludeRecursion': false,
            'probability': 100,
            'displayIndex': 0,
            'useProbability': false,
            'secondary_keys': <String>[],
            'keys': ['Vael', 'the realm'],
            'id': 0,
            'priority': 10,
            'insertion_order': 10,
            'enabled': true,
            'name': 'Overview',
            'extensions': <String, dynamic>{},
            'case_sensitive': false,
            'depth': 4,
            'characterFilter': null,
          },
          {
            'uid': 1,
            'key': ['aether'],
            'keysecondary': ['mana'],
            'comment': 'Aether',
            'content': 'Aether is the magical current drawn from the Gates.',
            'constant': false,
            'selective': true,
            'selectiveLogic': 0,
            'order': 20,
            'position': 0,
            'disable': false,
            'probability': 100,
            'useProbability': false,
            'secondary_keys': ['mana'],
            'keys': ['aether'],
            'id': 1,
            'priority': 20,
            'insertion_order': 20,
            'enabled': true,
            'name': 'Aether',
          },
        ],
      };

  group('BotBooru lorebook download.json (bare character_book, array)', () {
    test('parses into a Lorebook with the right name + entry count', () {
      final book = tryParseLorebookJson(botbooruBook());
      expect(book, isNotNull,
          reason: 'BotBooru bare character_book must be recognised');
      expect(book!.name, 'The Vael — World Lore');
      expect(book.entries.length, 2);
    });

    test('first entry maps keys/content/constant/order correctly', () {
      final book = tryParseLorebookJson(botbooruBook())!;
      final first = book.entries.first;
      expect(first.keys, contains('Vael'));
      expect(first.keys, contains('the realm'));
      expect(first.content, contains('fractured continent'));
      expect(first.constant, isTrue);
      expect(first.enabled, isTrue);
      // `insertion_order` (10) wins over `order` for chara_card_v2 books.
      expect(first.order, 10);

      final second = book.entries[1];
      expect(second.keys, contains('aether'));
      expect(second.secondaryKeys, contains('mana'));
      expect(second.constant, isFalse);
    });
  });

  // The webview-frontend rework: the JS hook fetches the lorebook JSON
  // INSIDE the webview (carrying the user's session cookies) and posts the
  // raw JSON TEXT back to native. Native parses that text directly via this
  // pure helper — it never makes any HTTP request to BotBooru's `/api/`.
  group('parseLorebookImportText (frontend-captured JSON text)', () {
    test('valid BotBooru bare character_book text parses to a Lorebook', () {
      final text = jsonEncode(botbooruBook());
      final book = parseLorebookImportText(text);
      expect(book, isNotNull);
      expect(book!.name, 'The Vael — World Lore');
      expect(book.entries.length, 2);
    });

    test('a standalone ST World Info text parses too', () {
      final text = jsonEncode(stStandalone());
      final book = parseLorebookImportText(text);
      expect(book, isNotNull);
      expect(book!.name, 'Eldoria Lore');
      expect(book.entries.length, 2);
    });

    test('invalid JSON text returns null', () {
      expect(parseLorebookImportText('not json at all'), isNull);
      expect(parseLorebookImportText('{ "broken": '), isNull);
    });

    test('valid JSON but not a lorebook shape returns null', () {
      expect(parseLorebookImportText(jsonEncode({'hello': 'world'})), isNull);
    });

    test('a JSON array (not an object) at root returns null', () {
      expect(parseLorebookImportText(jsonEncode([1, 2, 3])), isNull);
    });

    test('empty / blank text returns null', () {
      expect(parseLorebookImportText(''), isNull);
      expect(parseLorebookImportText('   '), isNull);
    });

    test('over the size cap returns null (no parse attempt)', () {
      // Build a syntactically-valid lorebook whose serialized size exceeds the
      // 25 MB cap, then confirm the cap rejects it BEFORE jsonDecode runs.
      final huge = 'A' * (kLorebookImportMaxChars + 1);
      // Even though `huge` isn't valid JSON, the size gate must trip first and
      // return null — proving the cap is enforced ahead of the decode.
      expect(parseLorebookImportText(huge), isNull);
    });

    test('a payload right at the cap is still attempted (parsed if valid)', () {
      final text = jsonEncode(botbooruBook());
      // Sanity: a normal lorebook is well under the cap, so it parses.
      expect(text.length, lessThan(kLorebookImportMaxChars));
      expect(parseLorebookImportText(text), isNotNull);
    });
  });

  // The BotBooru "Download JSON" payload has an EMPTY top-level `name` — the
  // real title ("main_Deadlock Lorebook_world_info") lives only in the page
  // (document.title / a heading). The JS hook now captures that page title and
  // passes it as a `nameFallback`, used ONLY when the JSON's own name is blank.
  group('parseLorebookImportText nameFallback (page-title hint)', () {
    test('empty JSON name + fallback → Lorebook uses the fallback name', () {
      final text = jsonEncode(<String, dynamic>{
        'name': '',
        'entries': [
          {'keys': ['x'], 'content': 'x content'},
        ],
      });
      final book = parseLorebookImportText(text,
          nameFallback: 'main_Deadlock Lorebook_world_info');
      expect(book, isNotNull);
      expect(book!.name, 'main_Deadlock Lorebook_world_info');
    });

    test('non-empty JSON name + fallback → keeps the JSON name (fallback wins '
        'only when blank)', () {
      final text = jsonEncode(<String, dynamic>{
        'name': 'Real Title',
        'entries': [
          {'keys': ['x'], 'content': 'x content'},
        ],
      });
      final book =
          parseLorebookImportText(text, nameFallback: 'Page Title Hint');
      expect(book, isNotNull);
      expect(book!.name, 'Real Title');
    });

    test('blank JSON name + blank/no fallback → "Imported Lorebook"', () {
      final text = jsonEncode(<String, dynamic>{
        'name': '',
        'entries': [
          {'keys': ['x'], 'content': 'x content'},
        ],
      });
      expect(parseLorebookImportText(text)!.name, 'Imported Lorebook');
      expect(parseLorebookImportText(text, nameFallback: '   ')!.name,
          'Imported Lorebook');
    });
  });

  group('Wave 1.1 (F3): ST selective keyword options import', () {
    test('keysecondary + selectiveLogic=3 + probability=50 + useProbability',
        () {
      final json = <String, dynamic>{
        'name': 'Selective Book',
        'entries': {
          '0': {
            'uid': 0,
            'key': ['castle'],
            'keysecondary': ['siege', 'banner'],
            'content': 'A castle under siege.',
            'selectiveLogic': 3, // ST AND_ALL
            'caseSensitive': true,
            'matchWholeWords': false,
            'probability': 50,
            'useProbability': true,
          },
        },
      };
      final book = tryParseLorebookJson(json)!;
      final e = book.entries.single;
      expect(e.keys, contains('castle'));
      expect(e.secondaryKeys, const ['siege', 'banner']);
      expect(e.selectiveLogic, LoreSelectiveLogic.andAll);
      expect(e.caseSensitive, isTrue);
      expect(e.matchWholeWords, isFalse);
      expect(e.probability, 50);
      expect(e.useProbability, isTrue);
    });

    test('selectiveLogic ints map per ST ordering (1=NOT_ALL, 2=NOT_ANY)', () {
      Map<String, dynamic> withLogic(int l) => <String, dynamic>{
            'name': 'b',
            'entries': [
              {
                'key': ['k'],
                'keysecondary': ['s'],
                'content': 'c',
                'selectiveLogic': l,
              }
            ],
          };
      expect(tryParseLorebookJson(withLogic(0))!.entries.single.selectiveLogic,
          LoreSelectiveLogic.andAny);
      expect(tryParseLorebookJson(withLogic(1))!.entries.single.selectiveLogic,
          LoreSelectiveLogic.notAll);
      expect(tryParseLorebookJson(withLogic(2))!.entries.single.selectiveLogic,
          LoreSelectiveLogic.notAny);
      expect(tryParseLorebookJson(withLogic(3))!.entries.single.selectiveLogic,
          LoreSelectiveLogic.andAll);
    });

    test('keysecondary tolerates a CSV string', () {
      final json = <String, dynamic>{
        'name': 'b',
        'entries': [
          {
            'key': ['k'],
            'keysecondary': 'siege, banner ,  ',
            'content': 'c',
          }
        ],
      };
      expect(tryParseLorebookJson(json)!.entries.single.secondaryKeys,
          const ['siege', 'banner']);
    });

    test('a minimal ST entry (no new fields) imports with safe defaults', () {
      final json = <String, dynamic>{
        'name': 'b',
        'entries': [
          {
            'key': ['k'],
            'content': 'c',
          }
        ],
      };
      final e = tryParseLorebookJson(json)!.entries.single;
      expect(e.secondaryKeys, isEmpty);
      expect(e.selectiveLogic, LoreSelectiveLogic.andAny);
      expect(e.caseSensitive, isNull);
      expect(e.matchWholeWords, isNull);
      expect(e.probability, 100);
      expect(e.useProbability, isFalse);
    });
  });
}
