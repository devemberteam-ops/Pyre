import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_schema.dart';

/// All field keys reachable in a mode's schema, flattening nestedBullets
/// children one level (children are addressed by their own keys for batch
/// coverage; the parent key is also a schema field key).
Set<String> _allSchemaKeys(CreatorMode mode) {
  final keys = <String>{};
  for (final f in schemaFor(mode)) {
    keys.add(f.key);
    for (final c in f.children ?? const <CardField>[]) {
      keys.add(c.key);
    }
  }
  return keys;
}

/// The ordered TOP-LEVEL field keys for a mode (children excluded).
List<String> _topLevelKeys(CreatorMode mode) =>
    schemaFor(mode).map((f) => f.key).toList();

CardField _field(CreatorMode mode, String key) =>
    schemaFor(mode).firstWhere((f) => f.key == key);

void main() {
  group('schemaFor(character)', () {
    test('contains the canonical Description sections in order, Full Name '
        '→ Notes, then the top-level card fields', () {
      final keys = _topLevelKeys(CreatorMode.character);

      // A representative spine of the canonical ordered section list.
      final spine = <String>[
        'fullName',
        'apparentAge',
        'race',
        'bornGender',
        'pronouns',
        'bodyType',
        'attractiveness',
        'detailedFeatures',
        'clothing',
        'alternativeClothing',
        'intimateDetails',
        'generalAppearance',
        'coreTraits',
        'moralAlignment',
        'fetishesKinks',
        'abilities',
        'background',
        'innerCircle',
        'whatTheyWant',
        'notes',
      ];
      // Each spine key present, and in strictly increasing index order.
      var prev = -1;
      for (final k in spine) {
        final i = keys.indexOf(k);
        expect(i, greaterThan(prev),
            reason: 'expected "$k" present and after the previous spine key');
        prev = i;
      }

      // Full Name is first; Notes is the last Description section (top-level
      // card fields come after it).
      expect(keys.first, 'fullName');
      expect(keys.contains('notes'), isTrue);

      // Top-level card fields present.
      for (final k in [
        'tagline',
        'first_mes',
        'dialogueExamples',
        'tags',
        'creator_notes',
      ]) {
        expect(keys.contains(k), isTrue, reason: 'missing top-level field $k');
      }
    });

    test('detailedFeatures / clothing / intimateDetails are nestedBullets '
        'with non-empty children', () {
      for (final parentKey in [
        'detailedFeatures',
        'clothing',
        'intimateDetails',
      ]) {
        final f = _field(CreatorMode.character, parentKey);
        expect(f.kind, CardFieldKind.nestedBullets,
            reason: '$parentKey should be nestedBullets');
        expect(f.children, isNotNull, reason: '$parentKey needs children');
        expect(f.children!, isNotEmpty,
            reason: '$parentKey children should be non-empty');
      }

      // Detailed Features children include the canonical sub-labels.
      final df = _field(CreatorMode.character, 'detailedFeatures');
      final dfChildKeys = df.children!.map((c) => c.key).toSet();
      for (final k in ['face', 'hair', 'eyes', 'skin', 'voice', 'movement']) {
        expect(dfChildKeys.contains(k), isTrue,
            reason: 'detailedFeatures missing child $k');
      }
    });

    test('dialogueExamples / tags are list-shaped kinds, prose sections are '
        'prose', () {
      expect(_field(CreatorMode.character, 'dialogueExamples').kind,
          CardFieldKind.dialogueExamples);
      expect(_field(CreatorMode.character, 'tags').kind, CardFieldKind.tags);
      expect(_field(CreatorMode.character, 'background').kind,
          CardFieldKind.prose);
    });
  });

  group('schemaFor(persona)', () {
    test('= same Description sections, NO scenario / first_mes / '
        'alternate_greetings; dialogueExamples present', () {
      final keys = _allSchemaKeys(CreatorMode.persona);

      // Shares the Description spine with character.
      for (final k in [
        'fullName',
        'detailedFeatures',
        'intimateDetails',
        'coreTraits',
        'background',
        'innerCircle',
        'notes',
      ]) {
        expect(keys.contains(k), isTrue,
            reason: 'persona Description section missing: $k');
      }

      // Persona has dialogueExamples + tagline.
      expect(keys.contains('dialogueExamples'), isTrue);
      expect(keys.contains('tagline'), isTrue);

      // Persona has NO scenario / first_mes / alternate_greetings.
      expect(keys.contains('first_mes'), isFalse);
      expect(keys.contains('scenario'), isFalse);
      expect(keys.contains('alternate_greetings'), isFalse);
    });
  });

  group('schemaFor(scenario)', () {
    test('has narrator…npcs XML sections + first_mes / dialogueExamples / '
        'tags / post_history / creator_notes', () {
      final keys = _topLevelKeys(CreatorMode.scenario);

      // XML Description sections in canonical order.
      final xml = <String>[
        'narrator',
        'readingThePersona',
        'sceneSetup',
        'tone',
        'world',
        'npcs',
      ];
      var prev = -1;
      for (final k in xml) {
        final i = keys.indexOf(k);
        expect(i, greaterThan(prev),
            reason: 'scenario section "$k" missing or out of order');
        prev = i;
      }

      // Top-level scenario fields.
      for (final k in [
        'first_mes',
        'dialogueExamples',
        'tags',
        'post_history_instructions',
        'creator_notes',
      ]) {
        expect(keys.contains(k), isTrue,
            reason: 'scenario missing top-level $k');
      }

      // Scenario does NOT carry character Description labels.
      expect(keys.contains('fullName'), isFalse);
      expect(keys.contains('detailedFeatures'), isFalse);
    });
  });

  group('batch coverage (the completeness guarantee)', () {
    for (final mode in CreatorMode.values) {
      test('every required field is in exactly one batch, and every batched '
          'key exists in the schema — mode=$mode', () {
        final batches = batchesFor(mode);
        final schemaKeys = _allSchemaKeys(mode);

        // 1. Every batched key exists in the schema.
        for (final batch in batches) {
          for (final key in batch) {
            expect(schemaKeys.contains(key), isTrue,
                reason: 'batched key "$key" is not a schema field key '
                    '(mode=$mode)');
          }
        }

        // 2. No key appears in more than one batch.
        final seen = <String>{};
        for (final batch in batches) {
          for (final key in batch) {
            expect(seen.contains(key), isFalse,
                reason: 'key "$key" appears in more than one batch '
                    '(mode=$mode)');
            seen.add(key);
          }
        }

        // 3. Every required field appears in exactly one batch.
        for (final reqKey in requiredKeysFor(mode)) {
          final count = batches
              .expand((b) => b)
              .where((k) => k == reqKey)
              .length;
          expect(count, 1,
              reason: 'required key "$reqKey" must appear in exactly one '
                  'batch but appears $count times (mode=$mode)');
        }
      });
    }

    test('requiredKeysFor returns only keys that exist in the schema', () {
      for (final mode in CreatorMode.values) {
        final schemaKeys = _allSchemaKeys(mode);
        for (final k in requiredKeysFor(mode)) {
          expect(schemaKeys.contains(k), isTrue,
              reason: 'required key "$k" is not a schema field (mode=$mode)');
        }
      }
    });
  });
}
