// 1.2.1 item #4: "Export as JSON card" — the payload builder is the same
// `buildCharaCardV2Json` the PNG export already uses (lib/services/
// png_encoder.dart), just pretty-printed to a standalone `.card.json`
// instead of embedded in a PNG tEXt chunk. These tests exercise the pure
// data path (no widget/file I/O): build → JSON-encode → JSON-decode →
// round-trip through Pyre's real chara_card JSON importer
// (`parseCharaCardJson` + `characterFromCharaCard`, lib/services/
// png_parser.dart + card_import.dart), proving the exported JSON is a
// valid, spec-compliant chara_card_v2 that re-imports cleanly.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/card_import.dart';
import 'package:pyre/services/lorebook_import.dart';
import 'package:pyre/services/png_encoder.dart';
import 'package:pyre/services/png_parser.dart';

void main() {
  group('buildCharaCardV2Json → JSON export round-trip', () {
    test('rich character + bound lorebook survives export → re-import', () {
      final book = Lorebook(
        id: 'book1',
        name: 'World Lore',
        description: 'The setting.',
        entries: [
          LoreEntry(
              id: 'e1', content: 'Overview of the world.',
              constant: true, order: 100),
          // Batch E Fix 3: non-default values for EVERY field
          // `_charaCardBookEntry` (png_encoder.dart) emits for a keyed
          // entry, so the round-trip assertions below actually prove
          // something — default values (empty secondaryKeys, andAny, null
          // case/whole-word, 100/false probability) would round-trip even
          // if the field were silently dropped on either side.
          LoreEntry(
            id: 'e2',
            keys: const ['Gate'],
            content: 'A Gate connects realms.',
            order: 50,
            secondaryKeys: const ['Ashveil', 'sealed'],
            selectiveLogic: LoreSelectiveLogic.andAll,
            caseSensitive: true,
            matchWholeWords: false,
            probability: 30,
            useProbability: true,
          ),
          // A DISABLED entry — proves `enabled: false` survives the JSON
          // export → re-import round-trip rather than always reading back
          // as the default (true, like every other entry in this fixture).
          LoreEntry(
            id: 'e3',
            keys: const ['Rumor'],
            content: 'A disabled rumor entry.',
            order: 10,
            enabled: false,
          ),
        ],
      );
      final c = Character(
        id: 'c1',
        name: 'Vesna',
        description: 'A wolfkin delver.',
        personality: 'Curious, guarded.',
        scenario: 'Deep in the ruins.',
        firstMes: 'Hello, traveler.',
        alternateGreetings: const ['Welcome back.', 'Oh, it is you.'],
        tags: const ['fantasy', 'delver'],
        creator: 'Ember Team',
        tagline: 'A wolfkin delver with a mysterious past.',
        depthPrompt: 'Remember the Gate is sacred.',
        depthPromptDepth: 3,
        lorebookIds: const ['book1'],
      );

      final map = buildCharaCardV2Json(c, lorebook: book);

      // Pretty-print exactly the way the JSON export does, then round-trip
      // it through jsonEncode/jsonDecode as if it were written to a file
      // and read back.
      final jsonText = const JsonEncoder.withIndent('  ').convert(map);
      final decoded = jsonDecode(jsonText);
      expect(decoded, isA<Map<String, dynamic>>());

      // Feed it through Pyre's real JSON chara-card importer.
      final card = parseCharaCardJson(jsonText);
      final reimported = characterFromCharaCard(card);

      expect(reimported.name, c.name);
      expect(reimported.description, c.description);
      expect(reimported.personality, c.personality);
      expect(reimported.scenario, c.scenario);
      expect(reimported.firstMes, c.firstMes);
      expect(reimported.alternateGreetings, c.alternateGreetings);
      expect(reimported.tags, c.tags);
      expect(reimported.creator, c.creator);
      expect(reimported.tagline, c.tagline);
      expect(reimported.depthPrompt, c.depthPrompt);
      expect(reimported.depthPromptDepth, c.depthPromptDepth);

      // The lorebook travelled as `character_book` and re-extracts cleanly.
      final cb = extractCharacterBook(card.card);
      expect(cb, isNotNull, reason: 'character_book should be embedded');
      final backBook = lorebookFromCharacterBook(cb!);
      expect(backBook.entries.length, 3);
      final overview = backBook.entries.firstWhere((e) => e.constant);
      expect(overview.content, 'Overview of the world.');
      expect(overview.enabled, isTrue);

      final keyed =
          backBook.entries.firstWhere((e) => e.keys.contains('Gate'));
      expect(keyed.content, 'A Gate connects realms.');
      expect(keyed.order, 50);
      expect(keyed.secondaryKeys, ['Ashveil', 'sealed']);
      expect(keyed.selectiveLogic, LoreSelectiveLogic.andAll);
      expect(keyed.caseSensitive, isTrue);
      expect(keyed.matchWholeWords, isFalse);
      expect(keyed.probability, 30);
      expect(keyed.useProbability, isTrue);
      expect(keyed.enabled, isTrue);

      final disabled =
          backBook.entries.firstWhere((e) => e.keys.contains('Rumor'));
      expect(disabled.content, 'A disabled rumor entry.');
      expect(disabled.enabled, isFalse,
          reason: 'the `enabled: false` JSON round-trip must not silently '
              'reset to the default (true)');
    });

    test('pretty-printed output is valid, spec-compliant JSON', () {
      final c = Character(id: 'c2', name: 'Plain');
      final map = buildCharaCardV2Json(c);
      final jsonText = const JsonEncoder.withIndent('  ').convert(map);

      // Genuinely pretty-printed (indented), not a single line.
      expect(jsonText.contains('\n'), isTrue);

      final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
      expect(decoded['spec'], 'chara_card_v2');
      expect(decoded['spec_version'], '2.0');
      expect(decoded['data'], isA<Map<String, dynamic>>());
      expect((decoded['data'] as Map)['name'], 'Plain');
    });

    test('avatarless character still produces a valid, importable payload',
        () {
      // No avatar set at all — the JSON export must NOT require one (unlike
      // the PNG export, which needs avatar bytes to embed the chunk into).
      final c = Character(id: 'c3', name: 'Ghost', avatar: null);
      expect(c.avatar, isNull);

      final map = buildCharaCardV2Json(c);
      final jsonText = const JsonEncoder.withIndent('  ').convert(map);
      final card = parseCharaCardJson(jsonText);
      final reimported = characterFromCharaCard(card);

      expect(reimported.name, 'Ghost');
      // No image bytes went in, so the JSON path yields no avatar either —
      // that's fine, the card itself is still fully valid.
      expect(card.imageBytes, isNull);
      expect(card.avatarDataUrl, isNull);
    });
  });
}
