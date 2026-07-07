// 2026-07-07 (Gui): "Attach character card" in the Creator should also let
// you pick a card ALREADY in the app, not only browse the device. Both paths
// stage the SAME reference-card attachment text, so the architect can't tell
// (nor should it) whether the card came from a file or the library.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/png_encoder.dart';
import 'package:pyre/services/png_parser.dart';
import 'package:pyre/screens/character_assistant_screen.dart'
    show buildCardReferenceExtract;

void main() {
  group('buildCardReferenceExtract', () {
    test('labels the source and embeds parseable chara_card_v2 JSON', () {
      final c = Character(
        id: 'x',
        name: 'Vael',
        description: 'A storm-touched wanderer.',
        firstMes: 'The wind carries your name.',
        tags: const ['fantasy'],
      );
      final raw = buildCharaCardV2Json(c);
      final text = buildCardReferenceExtract('Vael (from your library)', raw);

      // Source label is present so the user's chip + the prompt name it.
      expect(text, contains('Vael (from your library)'));
      // Same authoritative-context framing the file path used.
      expect(text, contains('authoritative context'));

      // The embedded JSON block round-trips back to a valid card.
      final start = text.indexOf('```json');
      final end = text.indexOf('```', start + 7);
      expect(start, greaterThanOrEqualTo(0));
      final jsonBlock = text.substring(start + 7, end).trim();
      final card = parseCharaCardJson(jsonBlock);
      expect(card.raw['data']['name'], 'Vael');
      // Sanity: the JSON we embedded is exactly the card we built.
      expect(jsonDecode(jsonBlock)['spec'], 'chara_card_v2');
    });
  });
}
