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
    show
        buildCardReferenceExtract,
        buildPersonaReferenceExtract,
        buildLorebookReferenceExtract,
        personaReferenceJson;

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

  group('buildPersonaReferenceExtract', () {
    test('curated persona JSON drops internal fields, keeps voice fields', () {
      final p = Persona(
        id: 'p1',
        name: 'Kael',
        tagline: 'the quiet blade',
        description: 'A wary duelist.',
        dialogueExamples: '<START>\nKael: "..."',
        avatar: 'data:image/png;base64,AAAA',
      );
      final j = personaReferenceJson(p);
      expect(j['name'], 'Kael');
      expect(j['description'], 'A wary duelist.');
      expect(j['dialogue_examples'], contains('Kael'));
      // Internal / heavy fields never leak into the reference.
      expect(j.containsKey('id'), isFalse);
      expect(j.containsKey('avatar'), isFalse);
      expect(j.containsKey('mtime'), isFalse);

      final text = buildPersonaReferenceExtract('Kael (from your library)', j);
      expect(text, contains('Kael (from your library)'));
      expect(text.toLowerCase(), contains('persona'));
      final start = text.indexOf('```json');
      final end = text.indexOf('```', start + 7);
      expect(jsonDecode(text.substring(start + 7, end).trim())['name'], 'Kael');
    });
  });

  group('buildLorebookReferenceExtract', () {
    test('labels the source and embeds parseable world-info JSON', () {
      final book = Lorebook(
        id: 'b1',
        name: 'Aetheria',
        description: 'The floating isles.',
        entries: [
          LoreEntry(id: 'e1', keys: const ['isles'], content: 'They drift.'),
        ],
      );
      final raw = charaCardBookJson(book);
      final text =
          buildLorebookReferenceExtract('Aetheria (from your library)', raw);
      expect(text, contains('Aetheria (from your library)'));
      expect(text.toLowerCase(), contains('lorebook'));
      final start = text.indexOf('```json');
      final end = text.indexOf('```', start + 7);
      final decoded = jsonDecode(text.substring(start + 7, end).trim());
      expect(decoded['entries'], isNotEmpty);
    });
  });
}
