// Wave CY.18.151: encodeCharaCardPng's optional `lorebook:` param embeds a
// bound book as a chara_card_v2 `character_book`, so the world lore travels
// inside the exported card. These tests prove the full round-trip:
// encode → parse → extract → re-import, with the standard field names so any
// frontend reads it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/card_import.dart';
import 'package:pyre/services/lorebook_import.dart';
import 'package:pyre/services/png_encoder.dart';
import 'package:pyre/services/png_parser.dart';

// A minimal valid 1x1 PNG — enough for parsePngChunks to accept as the
// avatar carrier (the encoder copies its chunks verbatim + injects `chara`).
const _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  final avatar = base64Decode(_png1x1);
  final char = Character(id: 'c1', name: 'Vesna');
  final book = Lorebook(
    id: 'b1',
    name: 'The Vael — World Lore',
    description: 'Shared world.',
    entries: [
      LoreEntry(
          id: 'e1', content: 'Overview', constant: true, order: 100),
      // Batch E Fix 3: non-default values for EVERY field
      // `_charaCardBookEntry` (png_encoder.dart) emits for a keyed entry, so
      // the round-trip assertion below actually proves something — default
      // values (empty secondaryKeys, andAny, null case/whole-word, 100/false
      // probability) would round-trip even if the field were silently
      // dropped on either side.
      LoreEntry(
        id: 'e2',
        keys: const ['Gate'],
        content: 'A Gate is…',
        order: 50,
        secondaryKeys: const ['Ashveil', 'sealed'],
        selectiveLogic: LoreSelectiveLogic.andAll,
        caseSensitive: true,
        matchWholeWords: false,
        probability: 30,
        useProbability: true,
      ),
      // A DISABLED entry — `enabled` defaults to true on every other entry
      // in this fixture, so this is the only one that proves `enabled:
      // false` actually survives export → re-import rather than always
      // reading back as the default.
      LoreEntry(
        id: 'e3',
        keys: const ['Rumor'],
        content: 'A disabled rumor entry.',
        order: 10,
        enabled: false,
      ),
    ],
  );

  group('encodeCharaCardPng — embedded lorebook (Wave CY.18.151)', () {
    test('with lorebook → character_book round-trips with all entries', () {
      final png = encodeCharaCardPng(char, avatar, lorebook: book);
      final parsed = parseCharaCardPng(png);
      expect(parsed.card['name'], 'Vesna');

      final cb = extractCharacterBook(parsed.card);
      expect(cb, isNotNull, reason: 'character_book should be embedded');

      final back = lorebookFromCharacterBook(cb!);
      expect(back.entries.length, 3);

      final overview = back.entries.firstWhere((e) => e.constant);
      expect(overview.content, 'Overview');
      expect(overview.enabled, isTrue);

      final keyed = back.entries.firstWhere((e) => e.keys.contains('Gate'));
      expect(keyed.content, 'A Gate is…');
      expect(keyed.order, 50); // insertion_order → order, preserved
      expect(keyed.secondaryKeys, ['Ashveil', 'sealed']);
      expect(keyed.selectiveLogic, LoreSelectiveLogic.andAll);
      expect(keyed.caseSensitive, isTrue);
      expect(keyed.matchWholeWords, isFalse);
      expect(keyed.probability, 30);
      expect(keyed.useProbability, isTrue);
      expect(keyed.enabled, isTrue);

      final disabled = back.entries.firstWhere((e) => e.keys.contains('Rumor'));
      expect(disabled.content, 'A disabled rumor entry.');
      expect(disabled.enabled, isFalse,
          reason: 'the `enabled: false` PNG round-trip must not silently '
              'reset to the default (true)');
    });

    test('without lorebook → no character_book (unchanged behaviour)', () {
      final png = encodeCharaCardPng(char, avatar);
      final parsed = parseCharaCardPng(png);
      expect(extractCharacterBook(parsed.card), isNull);
    });

    test('empty lorebook → skipped (no character_book key)', () {
      final png = encodeCharaCardPng(char, avatar,
          lorebook: Lorebook(id: 'b2', name: 'Empty'));
      final parsed = parseCharaCardPng(png);
      expect(extractCharacterBook(parsed.card), isNull);
    });
  });

  group('encodeCharaCardPng — tagline in extensions.pyre (Fix #5)', () {
    test('tagline → extensions.pyre.tagline → round-trips on re-import', () {
      final withTagline =
          Character(id: 'c2', name: 'Vesna', tagline: 'A wolfkin delver.');
      final png = encodeCharaCardPng(withTagline, avatar);
      final parsed = parseCharaCardPng(png);

      // Carried under the Pyre namespace, not as a bare data field.
      final ext = parsed.card['extensions'] as Map;
      expect((ext['pyre'] as Map)['tagline'], 'A wolfkin delver.');
      expect(parsed.card.containsKey('tagline'), isFalse);

      // Re-import reads it back into Character.tagline.
      final back = characterFromCharaCard(parsed);
      expect(back.tagline, 'A wolfkin delver.');
    });

    test('empty tagline → no pyre namespace', () {
      final png = encodeCharaCardPng(char, avatar); // char has no tagline
      final parsed = parseCharaCardPng(png);
      final ext = parsed.card['extensions'] as Map;
      expect(ext.containsKey('pyre'), isFalse);
      expect(characterFromCharaCard(parsed).tagline, isNull);
    });

    test('top-level tagline wins over the pyre fallback', () {
      final withTagline =
          Character(id: 'c3', name: 'Vesna', tagline: 'pyre value');
      final png = encodeCharaCardPng(withTagline, avatar);
      final parsed = parseCharaCardPng(png);
      // Simulate a foreign card that also put a top-level tagline.
      parsed.card['tagline'] = 'top-level value';
      expect(characterFromCharaCard(parsed).tagline, 'top-level value');
    });
  });
}
