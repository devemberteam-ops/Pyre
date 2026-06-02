// Wave CY.18.121: tests for the bundled example cards feature.
//
// Two concerns:
//   1. The PURE seed gate `shouldSeedExamples` — full truth table.
//   2. The bundled JSON assets parse into REAL (non-hollow) Pyre models.
//      `Character.fromJson` / `Lorebook.fromJson` never THROW on a wrong
//      shape (every field has a `?? ''` / `?? []` fallback), so "parses
//      without throwing" is insufficient — we assert real content.
//
// For (2) we read the asset files straight off disk via `dart:io`
// (relative to the test's working dir, which is the package root under
// `flutter test`). This validates the EXACT shipped files and sidesteps
// any test-asset-bundle quirks with non-package assets.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/example_seed.dart';

void main() {
  group('shouldSeedExamples — truth table', () {
    test('fresh install (not seeded, empty, not onboarded) → true', () {
      expect(
        shouldSeedExamples(
          alreadySeeded: false,
          charactersEmpty: true,
          seenOnboarding: false,
        ),
        isTrue,
      );
    });

    test('already seeded → false', () {
      expect(
        shouldSeedExamples(
          alreadySeeded: true,
          charactersEmpty: true,
          seenOnboarding: false,
        ),
        isFalse,
      );
    });

    test('library not empty → false', () {
      expect(
        shouldSeedExamples(
          alreadySeeded: false,
          charactersEmpty: false,
          seenOnboarding: false,
        ),
        isFalse,
      );
    });

    test('onboarding already seen → false', () {
      expect(
        shouldSeedExamples(
          alreadySeeded: false,
          charactersEmpty: true,
          seenOnboarding: true,
        ),
        isFalse,
      );
    });

    test('all flags unfavourable → false', () {
      expect(
        shouldSeedExamples(
          alreadySeeded: true,
          charactersEmpty: false,
          seenOnboarding: true,
        ),
        isFalse,
      );
    });
  });

  group('shouldRemoveAsSeededVesnaPersona — Wave CY.18.188 migration guard', () {
    // Helper: build a minimal Persona for testing purposes.
    Persona makePersona({
      required String name,
      List<String> lorebookIds = const [],
    }) =>
        Persona(
          id: 'test-persona-${name.toLowerCase()}',
          name: name,
          description: '',
          lorebookIds: List<String>.from(lorebookIds),
        );

    test('stale seeded Vesna (name + world lorebook) → true', () {
      final vesna = makePersona(
        name: 'Vesna',
        lorebookIds: [kExampleWorldLorebookId],
      );
      expect(shouldRemoveAsSeededVesnaPersona(vesna), isTrue);
    });

    test('Vesna without the world lorebook → false (user-created)', () {
      final vesna = makePersona(name: 'Vesna');
      expect(shouldRemoveAsSeededVesnaPersona(vesna), isFalse);
    });

    test('different name but with world lorebook → false (e.g. Ren bind)', () {
      final ren = makePersona(
        name: 'Ren',
        lorebookIds: [kExampleWorldLorebookId],
      );
      expect(shouldRemoveAsSeededVesnaPersona(ren), isFalse);
    });

    test('unrelated persona → false', () {
      final other = makePersona(
        name: 'Alice',
        lorebookIds: ['some-other-lorebook'],
      );
      expect(shouldRemoveAsSeededVesnaPersona(other), isFalse);
    });

    test('Vesna with world lorebook AND extra lorebooks → still true', () {
      final vesna = makePersona(
        name: 'Vesna',
        lorebookIds: [kExampleWorldLorebookId, 'user-added-book'],
      );
      expect(shouldRemoveAsSeededVesnaPersona(vesna), isTrue);
    });

    test('name case-sensitive — "vesna" (lowercase) → false', () {
      // buildPersonaFromCharacter copies the name verbatim from the
      // Character; vesna.json has name "Vesna". An accidentally
      // lower-cased name would NOT match — which is the safe direction.
      final vesna = makePersona(
        name: 'vesna',
        lorebookIds: [kExampleWorldLorebookId],
      );
      expect(shouldRemoveAsSeededVesnaPersona(vesna), isFalse);
    });
  });

  group('shouldUnfavoriteSeededRen — Wave CY.18.204/209 migration guard', () {
    // Helper: build a minimal Persona with an explicit favorite flag.
    Persona makePersona({
      required String name,
      bool favorite = false,
      List<String> lorebookIds = const [],
    }) =>
        Persona(
          id: 'test-persona-${name.toLowerCase()}',
          name: name,
          description: '',
          favorite: favorite,
          lorebookIds: List<String>.from(lorebookIds),
        );

    test(
        'seeded "Ren Brennan" (real card name + favorite + no lorebook) → true',
        () {
      // Wave CY.18.209 REGRESSION TEST: the seeded persona is built by
      // buildPersonaFromCharacter, which copies the source card name, and
      // assets/examples/ren.json has name "Ren Brennan". The original
      // Wave-204 guard matched `== 'Ren'` and so NEVER matched this — the
      // migration was a silent no-op. The corrected guard matches it.
      final ren = makePersona(name: 'Ren Brennan', favorite: true);
      expect(shouldUnfavoriteSeededRen(ren), isTrue);
    });

    test('bare "Ren" (favorite + no lorebook) → true', () {
      // The startsWith('Ren') match also covers a bare "Ren", so the guard
      // is robust to a future card-name tweak.
      final ren = makePersona(name: 'Ren', favorite: true);
      expect(shouldUnfavoriteSeededRen(ren), isTrue);
    });

    test('"Ren Brennan" but NOT favourited → false (already unstarred)', () {
      final ren = makePersona(name: 'Ren Brennan');
      expect(shouldUnfavoriteSeededRen(ren), isFalse);
    });

    test('favourited "Ren Brennan" WITH a lorebook bind → false', () {
      // The seeded Ren is deliberately setting-neutral and carries NO
      // lorebook, so a bound + favourited "Ren …" is the user's own — leave
      // their star alone.
      final ren = makePersona(
        name: 'Ren Brennan',
        favorite: true,
        lorebookIds: [kExampleWorldLorebookId],
      );
      expect(shouldUnfavoriteSeededRen(ren), isFalse);
    });

    test('favourited non-Ren persona → false', () {
      final other = makePersona(name: 'Vesna', favorite: true);
      expect(shouldUnfavoriteSeededRen(other), isFalse);
    });

    test('name case-sensitive — "ren brennan" (lowercase) favourited → false',
        () {
      // startsWith is case-sensitive; the real card name is capitalised, so
      // an accidentally lower-cased "ren" does NOT match (the safe direction).
      final ren = makePersona(name: 'ren brennan', favorite: true);
      expect(shouldUnfavoriteSeededRen(ren), isFalse);
    });
  });

  group('bundled example assets — parse + real content', () {
    // Helper: read + JSON-decode an asset from disk, relative to the
    // package root (the cwd under `flutter test`).
    Map<String, dynamic> readAsset(String relPath) {
      final file = File('assets/examples/$relPath');
      expect(file.existsSync(), isTrue,
          reason: 'missing bundled asset: ${file.path}');
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }

    Character readCharacter(String relPath) =>
        Character.fromJson(readAsset(relPath));

    test('world.json is a real lorebook with the expected id + entries', () {
      final book = Lorebook.fromJson(readAsset('world.json'));
      expect(book.id, kExampleWorldLorebookId);
      expect(book.name.trim(), isNotEmpty);
      expect(book.entries, isNotEmpty);
      // Every entry must carry real trigger keys + content (not hollow).
      for (final e in book.entries) {
        expect(e.keys, isNotEmpty, reason: 'entry ${e.id} has no keys');
        expect(e.content.trim(), isNotEmpty,
            reason: 'entry ${e.id} has no content');
      }
    });

    test('ren.json is a non-hollow persona-source character', () {
      final ren = readCharacter('ren.json');
      expect(ren.id, 'example-char-ren');
      expect(ren.name.trim(), isNotEmpty);
      // Wave CY.18.209: the migration guard matches the seeded persona by
      // `name.trim().startsWith('Ren')` — assert the real card name actually
      // satisfies that, so the guard can never silently drift out of sync
      // with the asset again (this is exactly the bug Wave 209 fixed: the
      // card is "Ren Brennan", not "Ren").
      expect(ren.name.trim().startsWith('Ren'), isTrue);
      expect(ren.description.trim(), isNotEmpty);
      expect(ren.firstMes.trim(), isNotEmpty);
      // Authored in the character architect's labeled-Description format.
      expect(ren.description, contains('Full Name:'));
      expect(ren.mesExample.trim(), isNotEmpty);
      expect(ren.tags, contains('example'));
      expect(ren.createdInPyre, isFalse);
      // Wave CY.18.161: Ren is the default user persona now and MUST be
      // setting-neutral so he fits any scenario — no Vael/Sunken-Gate lore
      // anywhere in his sheet or examples, and no world lorebook bind.
      final blob =
          '${ren.description}\n${ren.tagline ?? ''}\n${ren.mesExample}\n'
                  '${ren.creatorNotes}\n${ren.scenario}'
              .toLowerCase();
      for (final banned in [
        'vael',
        'aldermere',
        'gate',
        'vekhi',
        'aether',
        'conclave',
        'outsider',
        'isekai',
        'saolen',
      ]) {
        // Word-START boundary so innocent substrings (e.g. "surrogate"
        // contains "gate", "navigate" contains "gate") don't false-fail —
        // we only flag the actual lore terms and their inflections
        // ("Gate", "Gates", "Gate-spat").
        expect(RegExp('\\b$banned').hasMatch(blob), isFalse,
            reason: 'Ren persona sheet still references "$banned"');
      }
      expect(ren.lorebookIds, isEmpty);
    });

    test('vesna.json is a non-hollow character bound to the world lore', () {
      final vesna = readCharacter('vesna.json');
      expect(vesna.id, 'example-char-vesna');
      expect(vesna.name.trim(), isNotEmpty);
      expect(vesna.description.trim(), isNotEmpty);
      expect(vesna.firstMes.trim(), isNotEmpty);
      expect(vesna.description, contains('Full Name:'));
      expect(vesna.lorebookIds, contains(kExampleWorldLorebookId));
      expect(vesna.tags, contains('example'));
      expect(vesna.createdInPyre, isFalse);
    });

    test('scenario.json is a non-hollow narrator card bound to the lore', () {
      final scenario = readCharacter('scenario.json');
      expect(scenario.id, 'example-scenario-sunken-gate');
      expect(scenario.name.trim(), isNotEmpty);
      expect(scenario.description.trim(), isNotEmpty);
      expect(scenario.firstMes.trim(), isNotEmpty);
      // Authored in the scenario architect's XML-section Description format.
      expect(scenario.description, contains('<Narrator>'));
      expect(scenario.description, contains('<World>'));
      expect(scenario.description, contains('<NPCs>'));
      // Narrator cards carry post-history reminders.
      expect(scenario.postHistoryInstructions.trim(), isNotEmpty);
      expect(scenario.lorebookIds, contains(kExampleWorldLorebookId));
      expect(scenario.tags, contains('example'));
      expect(scenario.createdInPyre, isFalse);
    });

    test('every example card round-trips fromJson → toJson cleanly', () {
      for (final path in ['ren.json', 'vesna.json', 'scenario.json']) {
        final original = readCharacter(path);
        final restored = Character.fromJson(original.toJson());
        expect(restored.id, original.id, reason: '$path id');
        expect(restored.name, original.name, reason: '$path name');
        expect(restored.description, original.description,
            reason: '$path description');
        expect(restored.firstMes, original.firstMes, reason: '$path firstMes');
        expect(restored.lorebookIds, original.lorebookIds,
            reason: '$path lorebookIds');
      }
    });
  });
}
