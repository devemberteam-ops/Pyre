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
      LoreEntry(id: 'e2', keys: const ['Gate'], content: 'A Gate is…', order: 50),
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
      expect(back.entries.length, 2);

      final overview = back.entries.firstWhere((e) => e.constant);
      expect(overview.content, 'Overview');

      final keyed = back.entries.firstWhere((e) => e.keys.contains('Gate'));
      expect(keyed.content, 'A Gate is…');
      expect(keyed.order, 50); // insertion_order → order, preserved
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
