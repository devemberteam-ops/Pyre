// 2026-07-04 (Gui, approved BIG item): GRANULAR AI editing — "o editor deve
// saber adicionar greetings, mexer em creator notes e coisas do tipo SEM
// mexer na card inteira." The edit architect can now emit a SCOPED build
// marker `[[BUILD_SHEET: key1, key2]]`; the build then re-generates ONLY the
// named top-level fields (greetings, first message, creator notes, tags,
// tagline, scenario, dialogue examples) and the Description stays
// byte-untouched. Anything touching the Description body still runs the full
// rebuild. Also locks the coverage-based foreign-card heuristic (the old
// `<2 recognized labels` check let a partly-labelled import be treated as
// native, and the rebuild silently re-invented the user's authored
// Description).
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_api.dart' show ChatTurn;
import 'package:pyre/services/creator_build_prompts.dart';
import 'package:pyre/services/creator_cascade.dart';
import 'package:pyre/services/creator_render.dart';
import 'package:pyre/services/creator_schema.dart' as cs;

void main() {
  group('scoped build marker parsing', () {
    test('plain marker → found, no scope (full build)', () {
      final r = detectAndStripBuildMarker('Applying it now.\n[[BUILD_SHEET]]');
      expect(r.found, isTrue);
      expect(r.scopedKeys, isNull);
      expect(r.text, 'Applying it now.');
    });

    test('scoped marker → keys parsed and stripped from the text', () {
      final r = detectAndStripBuildMarker(
          'Adding the greeting.\n[[BUILD_SHEET: alternate_greetings, creator_notes]]');
      expect(r.found, isTrue);
      expect(r.scopedKeys, ['alternate_greetings', 'creator_notes']);
      expect(r.text, 'Adding the greeting.');
    });

    test('scope whitespace/case tolerated; empty scope = full build', () {
      final r = detectAndStripBuildMarker(
          'ok\n[[ build_sheet :  first_mes ]]');
      expect(r.found, isTrue);
      expect(r.scopedKeys, ['first_mes']);
      final empty = detectAndStripBuildMarker('ok\n[[BUILD_SHEET: ]]');
      expect(empty.found, isTrue);
      expect(empty.scopedKeys, isNull);
    });

    test('no marker → not found', () {
      final r = detectAndStripBuildMarker('Just chatting.');
      expect(r.found, isFalse);
      expect(r.scopedKeys, isNull);
    });
  });

  // Feature C (Gui): edit ANY Description section — including custom ones the
  // schema doesn't model (a card's own "World Notes"/"Tone") — surgically.
  // `[[BUILD_SHEET: description]]` routes to the surgical text-edit.
  group('free-text description scope', () {
    test('the single `description` key is the free-text scope', () {
      expect(isFreeTextDescriptionScope(['description']), isTrue);
      expect(isFreeTextDescriptionScope(['Description']), isTrue); // case/space
      expect(isFreeTextDescriptionScope([' description ']), isTrue);
    });
    test('a real scoped marker parses `description` as its key', () {
      final r = detectAndStripBuildMarker(
          'Adding a World Notes section.\n[[BUILD_SHEET: description]]');
      expect(r.scopedKeys, ['description']);
      expect(isFreeTextDescriptionScope(r.scopedKeys), isTrue);
    });
    test('anything else is NOT the free-text scope', () {
      expect(isFreeTextDescriptionScope(null), isFalse);
      expect(isFreeTextDescriptionScope(['first_mes']), isFalse);
      // description PLUS another key is not the pure free-text edit.
      expect(isFreeTextDescriptionScope(['description', 'tags']), isFalse);
    });
    test('`description` is NOT a schema field (so it never scopes as a batch)',
        () {
      expect(cs.keysAreScopedEditable(['description'], cs.CreatorMode.character),
          isFalse);
    });
  });

  group('keysAreScopedEditable', () {
    test('top-level character fields pass', () {
      expect(
          cs.keysAreScopedEditable(
              ['alternate_greetings', 'creator_notes', 'tags', 'first_mes'],
              cs.CreatorMode.character),
          isTrue);
    });

    test('Description-section keys are scoped-editable too (Gui: "esperava '
        'que Description pudesse ser alterado sem editar toda a '
        'description")', () {
      expect(
          cs.keysAreScopedEditable(
              ['background', 'creator_notes'], cs.CreatorMode.character),
          isTrue);
      expect(
          cs.keysAreScopedEditable(
              ['apparentAge', 'detailedFeatures'], cs.CreatorMode.character),
          isTrue);
    });

    test('unknown keys and empty scope force the full rebuild', () {
      expect(cs.keysAreScopedEditable(['bogus'], cs.CreatorMode.character),
          isFalse);
      expect(cs.keysAreScopedEditable([], cs.CreatorMode.character),
          isFalse);
    });

    test('persona mode: greetings are not part of the persona schema', () {
      expect(
          cs.keysAreScopedEditable(
              ['alternate_greetings'], cs.CreatorMode.persona),
          isFalse);
      expect(cs.keysAreScopedEditable(['tagline'], cs.CreatorMode.persona),
          isTrue);
      expect(cs.keysAreScopedEditable(['background'], cs.CreatorMode.persona),
          isTrue);
    });
  });

  group('descriptionSectionKeys', () {
    test('sections in, top-level fields out', () {
      final keys = cs.descriptionSectionKeys(cs.CreatorMode.character);
      expect(keys, contains('background'));
      expect(keys, contains('detailedFeatures'));
      expect(keys, contains('apparentAge'));
      expect(keys, isNot(contains('first_mes')));
      expect(keys, isNot(contains('alternate_greetings')));
      expect(keys, isNot(contains('tags')));
      expect(keys, isNot(contains('creator_notes')));
    });
  });

  group('filterBatchesToKeys', () {
    test('keeps only targeted keys, drops emptied batches', () {
      final batches = cs.filterBatchesToKeys(
        cs.batchesFor(cs.CreatorMode.character),
        {'alternate_greetings', 'creator_notes'},
      );
      expect(batches, [
        ['alternate_greetings', 'creator_notes'],
      ]);
    });
  });

  group('coverage-based foreign-card heuristic', () {
    test('fewer than 2 recognized sections → foreign (old rule kept)', () {
      expect(
        isForeignDescription(
          description: 'A long plain-prose card with no labels at all. ' * 5,
          recognized: const {'fullName': 'Vael'},
        ),
        isTrue,
      );
    });

    test('2+ labels but MOSTLY unlabeled prose → foreign (the new rule: '
        'partly-labelled imports must not be rewritten)', () {
      final prose = 'Unlabeled authored prose the user wrote by hand. ' * 20;
      expect(
        isForeignDescription(
          description: 'Full Name: Vael\nRace: Elf\n$prose',
          recognized: const {'fullName': 'Vael', 'race': 'Elf'},
        ),
        isTrue,
      );
    });

    test('a genuinely Pyre-labelled card stays native', () {
      const desc = 'Full Name: Vael\n'
          'Race: High elf of the northern courts\n'
          'Background: Raised in the citadel archives, exiled at twenty.\n'
          'Core Traits: guarded, meticulous, quietly romantic.';
      expect(
        isForeignDescription(
          description: desc,
          recognized: const {
            'fullName': 'Vael',
            'race': 'High elf of the northern courts',
            'background': 'Raised in the citadel archives, exiled at twenty.',
            'coreTraits': 'guarded, meticulous, quietly romantic.',
          },
        ),
        isFalse,
      );
    });

    test('empty description is never foreign (nothing to protect)', () {
      expect(
        isForeignDescription(description: '   ', recognized: const {}),
        isFalse,
      );
    });
  });

  // 2026-07-04 (Gui): "imaginava que desse para a LLM entender que eu só
  // quero editar X parte sem precisar ser no nosso modelo" — foreign-format
  // Descriptions get a SURGICAL TEXT EDIT (model receives the text verbatim
  // + the conversation, returns it with only the requested change applied).
  group('surgical description edit (foreign cards)', () {
    test('turns: system contract + conversation + verbatim text last', () {
      final turns = buildSurgicalDescriptionEditTurns(
        description: '[character("Vael") + Mind("guarded")]',
        transcript: [
          ChatTurn('user', 'make him 25 instead of 30'),
          ChatTurn('assistant', 'Got it — applying.'),
        ],
      );
      expect(turns.first.role, 'system');
      expect(turns.first.content, contains('ONLY the change'));
      expect(turns[1].content, 'make him 25 instead of 30');
      expect(turns.last.role, 'user');
      expect(turns.last.content, contains('[character("Vael")'));
    });

    test('acceptance: good edit passes; fences stripped', () {
      final original = 'A long hand-written prose card about Vael. ' * 4;
      final edited = '${'A long hand-written prose card about Vael. ' * 3}'
          'Now aged 25.';
      expect(
        acceptSurgicalDescriptionEdit(original: original, edited: edited),
        edited,
      );
      expect(
        acceptSurgicalDescriptionEdit(
            original: original, edited: '```\n$edited\n```'),
        edited,
      );
    });

    test('acceptance: empty or suspiciously short (summarised) → rejected '
        '(original kept)', () {
      final original = 'A long hand-written prose card about Vael. ' * 6;
      expect(
        acceptSurgicalDescriptionEdit(original: original, edited: '   '),
        isNull,
      );
      expect(
        acceptSurgicalDescriptionEdit(
            original: original, edited: 'Vael, now 25.'),
        isNull,
      );
    });
  });
}
