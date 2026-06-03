// Lorebook import shape coverage.
//
// Regression target (reported by a user on r/SillyTavernAI): a STANDALONE
// SillyTavern World Info / lorebook .json was rejected ("Pyre will not
// recognize it"). Root cause: ST's standalone export stores `entries` as an
// OBJECT keyed by uid ("0","1",…), but the importer only handled `entries`
// as a List (the chara_card_v2 `character_book` array shape). Both shapes
// must parse.

import 'package:flutter_test/flutter_test.dart';
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
}
