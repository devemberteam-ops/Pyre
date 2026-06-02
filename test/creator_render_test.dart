// Wave CY.18.226 (Creator Structured Build, Task 2): the deterministic
// renderer + its inverse `decomposeDescription`.
//
// These tests lock the spacing contract (one blank line between top-level
// topics, tight nested bullets), the scenario XML balance, the mes_example
// `<START>` discipline, the empty-skip rule, and — the real safety net — the
// round-trip on the SHIPPED bundled cards (Ren / Vesna / Sunken Gate) plus a
// synthetic full-coverage card. If a bundled card uses a label the schema
// doesn't know, the round-trip surfaces it here instead of silently dropping.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_render.dart';
import 'package:pyre/services/creator_schema.dart';

/// Count of `\n\n` (blank-line separators) in [s].
int _blankLineCount(String s) => RegExp(r'\n\n').allMatches(s).length;

/// Normalise for round-trip comparison: strip trailing whitespace per line
/// and collapse a trailing run of blank lines, but keep internal structure.
String _norm(String s) {
  final lines = s.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+$'), ''));
  return lines.join('\n').replaceAll(RegExp(r'\n+$'), '').trimLeft();
}

Map<String, dynamic> _readAsset(String relPath) {
  final file = File('assets/examples/$relPath');
  expect(file.existsSync(), isTrue, reason: 'missing asset: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('renderCard — character Description', () {
    test('golden: exact labeled Description, one blank line between topics, '
        'tight nested bullets', () {
      final fields = <String, dynamic>{
        'fullName': 'Aimi Taniguchi',
        'apparentAge': '22yo — 158 cm / 47 kg',
        'detailedFeatures': <Map<String, String>>[
          {'label': 'Face', 'value': 'Round, soft.'},
          {'label': 'Hair', 'value': 'Black, long.'},
        ],
        'coreTraits': 'Warm, stubborn, sly.',
        'background': 'She grew up by the sea.',
      };

      final out = renderCard(fields, CreatorMode.character);
      final desc = out['description'] as String;

      const expected = 'Full Name: Aimi Taniguchi\n'
          '\n'
          'Apparent Age, Height & Weight: 22yo — 158 cm / 47 kg\n'
          '\n'
          'Detailed Features:\n'
          '  * Face: Round, soft.\n'
          '  * Hair: Black, long.\n'
          '\n'
          'Core Traits: Warm, stubborn, sly.\n'
          '\n'
          'Background: She grew up by the sea.';
      expect(desc, expected);

      // 4 blank-line separators for 5 top-level topics.
      expect(_blankLineCount(desc), 4);
      // No blank line INSIDE Detailed Features (tight bullets).
      final dfStart = desc.indexOf('Detailed Features:');
      final dfEnd = desc.indexOf('\n\nCore Traits:');
      expect(desc.substring(dfStart, dfEnd).contains('\n\n'), isFalse);

      // name carried up to the canvas.
      expect(out['name'], 'Aimi Taniguchi');
    });

    test('name is CLAMPED to just the leading name when fullName carries a '
        'descriptive tail; the Description Full Name keeps the full text', () {
      final fields = <String, dynamic>{
        'fullName': 'Akemi Tanaka — goes by Akemi alone; the family name is '
            'a ghost. Clients call her "Morte".',
        'coreTraits': 'Cold, precise.',
      };
      final out = renderCard(fields, CreatorMode.character);

      // Top-level display name is clamped to JUST the name.
      expect(out['name'], 'Akemi Tanaka');

      // The Description's Full Name line keeps the FULL descriptive text.
      final desc = out['description'] as String;
      expect(
          desc,
          startsWith('Full Name: Akemi Tanaka — goes by Akemi alone; the '
              'family name is a ghost. Clients call her "Morte".'));
    });

    test('name clamp cuts at the FIRST of the delimiters', () {
      // en-dash first
      expect(
          renderCard(
              {'fullName': 'Lyra Vance – the Hollow Saint'},
              CreatorMode.character)['name'],
          'Lyra Vance');
      // semicolon first
      expect(
          renderCard(
              {'fullName': 'Bram; a drifter'}, CreatorMode.character)['name'],
          'Bram');
      // period first
      expect(
          renderCard({'fullName': 'Juno. Or so they say.'},
              CreatorMode.character)['name'],
          'Juno');
      // parenthetical first (existing behaviour, still honoured)
      expect(
          renderCard({'fullName': 'Mina (the shy one)'},
              CreatorMode.character)['name'],
          'Mina');
      // a normal name with no delimiter is unchanged
      expect(
          renderCard({'fullName': 'Aimi Taniguchi'},
              CreatorMode.character)['name'],
          'Aimi Taniguchi');
    });

    test('empty optional field is skipped entirely (no "Label: —")', () {
      final fields = <String, dynamic>{
        'fullName': 'Solo',
        'race': '', // empty optional → skipped
        'coreTraits': 'Quiet.',
      };
      final desc = renderCard(fields, CreatorMode.character)['description']
          as String;
      expect(desc.contains('Race:'), isFalse);
      expect(desc.contains('—'), isFalse);
      expect(desc, 'Full Name: Solo\n\nCore Traits: Quiet.');
    });
  });

  group('renderCard — innerCircle nestedBullets (#8)', () {
    test('innerCircle renders one "  * Name: …" bullet per person', () {
      final fields = <String, dynamic>{
        'fullName': 'Hub',
        'innerCircle': <Map<String, String>>[
          {'label': 'Kaito Mori', 'value': '34, her handler — clipped, loyal.'},
          {'label': 'Sora', 'value': '19, a runaway she shelters.'},
        ],
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      // Parent label on its own line, each person a tight bullet.
      expect(desc, contains('Inner Circle:'));
      expect(desc, contains('  * Kaito Mori: 34, her handler — clipped, loyal.'));
      expect(desc, contains('  * Sora: 19, a runaway she shelters.'));
      // No blank line inside the bullet list (tight).
      final icStart = desc.indexOf('Inner Circle:');
      expect(desc.substring(icStart).contains('\n\n'), isFalse);
    });
  });

  group('renderCard — bulletList (Group B, Wave CY.18.241)', () {
    test('a List value renders as a "Label:" header + one "  * item" line each',
        () {
      final fields = <String, dynamic>{
        'fullName': 'L. Brigade',
        'coreTraits': <String>['Warm', 'Stubborn', 'Sly', 'Anxious'],
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      const expected = 'Full Name: L. Brigade\n'
          '\n'
          'Core Traits:\n'
          '  * Warm\n'
          '  * Stubborn\n'
          '  * Sly\n'
          '  * Anxious';
      expect(desc, expected);
      // No blank line inside the bullet block (tight, matching nestedBullets).
      final ctStart = desc.indexOf('Core Traits:');
      expect(desc.substring(ctStart).contains('\n\n'), isFalse);
    });

    test('a single-string (legacy prose) value renders INLINE, not as a bullet',
        () {
      final fields = <String, dynamic>{
        'fullName': 'Solo',
        'coreTraits': 'Warm, stubborn, sly.',
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      expect(desc, 'Full Name: Solo\n\nCore Traits: Warm, stubborn, sly.');
    });

    test('tolerates a newline/`*`-delimited String value (splits to bullets)',
        () {
      final fields = <String, dynamic>{
        'fullName': 'Hub',
        'abilities': '* Telekinesis\n* Foresight\n* Mending',
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      expect(desc, contains('Abilities:\n  * Telekinesis\n  * Foresight\n  * Mending'));
    });

    test('decompose→render round-trip is stable for a bulletList', () {
      final fields = <String, dynamic>{
        'fullName': 'Round Trip',
        'interests': <String>['Maps', 'Trivia', 'Old radios'],
        'background': 'A drifter.',
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      final back = decomposeDescription(desc, CreatorMode.character);
      final desc2 =
          renderCard(back, CreatorMode.character)['description'] as String;
      expect(_norm(desc2), _norm(desc),
          reason: 'bulletList must round-trip decompose→render unchanged');
      // The Interests block survived as bullets through the round-trip.
      expect(desc2, contains('Interests:\n  * Maps\n  * Trivia\n  * Old radios'));
    });
  });

  group('renderCard — variable nestedBullets (Group A, Wave CY.18.241)', () {
    test('an object value renders "  * Sub: value" lines for arbitrary keys',
        () {
      final fields = <String, dynamic>{
        'fullName': 'Two-Sided',
        'likesDislikes': <String, String>{
          'Likes': 'Quiet mornings and praise.',
          'Dislikes': 'Loud rooms; being perceived.',
        },
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      const expected = 'Full Name: Two-Sided\n'
          '\n'
          'Likes & Dislikes:\n'
          '  * Likes: Quiet mornings and praise.\n'
          '  * Dislikes: Loud rooms; being perceived.';
      expect(desc, expected);
    });

    test('an array of {label,value} objects renders the same as innerCircle',
        () {
      final fields = <String, dynamic>{
        'fullName': 'Modal',
        'behavioralModes': <Map<String, String>>[
          {'label': 'Spiral Mode', 'value': 'Anxious, fast, joking.'},
          {'label': 'Calm Mode', 'value': 'Rare, warm, sharp.'},
        ],
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      expect(desc, contains('Behavioral Modes:'));
      expect(desc, contains('  * Spiral Mode: Anxious, fast, joking.'));
      expect(desc, contains('  * Calm Mode: Rare, warm, sharp.'));
      // Tight — no blank line inside the block.
      final bmStart = desc.indexOf('Behavioral Modes:');
      expect(desc.substring(bmStart).contains('\n\n'), isFalse);
    });

    test('a single-string (legacy prose) value renders INLINE', () {
      final fields = <String, dynamic>{
        'fullName': 'Legacy',
        'fetishesKinks': 'Validation, praise, soft submission.',
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      expect(desc,
          'Full Name: Legacy\n\nFetishes & Kinks: Validation, praise, soft submission.');
    });

    test('decompose→render round-trip is stable for a variable nestedBullets',
        () {
      final fields = <String, dynamic>{
        'fullName': 'RT',
        'strengthsWeaknesses': <String, String>{
          'Strengths': 'Pattern-reading, wit.',
          'Weaknesses': 'No physical competence.',
        },
        'background': 'Origin story.',
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      final back = decomposeDescription(desc, CreatorMode.character);
      final desc2 =
          renderCard(back, CreatorMode.character)['description'] as String;
      expect(_norm(desc2), _norm(desc),
          reason:
              'variable nestedBullets must round-trip decompose→render unchanged');
      expect(desc2, contains('  * Strengths: Pattern-reading, wit.'));
      expect(desc2, contains('  * Weaknesses: No physical competence.'));
    });

    test('persona mode shares the Group-A/B bullet rendering', () {
      final fields = <String, dynamic>{
        'fullName': 'Persona Pat',
        'coreTraits': <String>['Curious', 'Bold'],
        'likesDislikes': <String, String>{
          'Likes': 'Adventure.',
          'Dislikes': 'Boredom.',
        },
      };
      final desc =
          renderCard(fields, CreatorMode.persona)['description'] as String;
      expect(desc, contains('Core Traits:\n  * Curious\n  * Bold'));
      expect(desc, contains('Likes & Dislikes:\n  * Likes: Adventure.\n  * Dislikes: Boredom.'));
    });
  });

  group('renderCard — scenario XML', () {
    test('balanced <Narrator>…</Narrator> … <NPCs>…</NPCs>', () {
      final fields = <String, dynamic>{
        'narrator': 'An omniscient narrator.',
        'sceneSetup': 'Already in motion.',
        'world': 'A jungle basin.',
        'npcs': '## Sehka\nThe lead warden.',
        'first_mes': 'Heat like a wet cloth.',
      };
      final out = renderCard(fields, CreatorMode.scenario);
      final desc = out['description'] as String;

      for (final tag in ['Narrator', 'Scene Setup', 'World', 'NPCs']) {
        expect(desc.contains('<$tag>'), isTrue, reason: 'missing open <$tag>');
        expect(desc.contains('</$tag>'), isTrue,
            reason: 'missing close </$tag>');
      }
      // Every open tag has a matching close.
      final opens = RegExp(r'<([\w ]+?)>').allMatches(desc).length;
      final closes = RegExp(r'</([\w ]+?)>').allMatches(desc).length;
      expect(opens, closes, reason: 'unbalanced XML tags');

      // first_mes carried through, but is NOT in the description.
      expect(out['first_mes'], 'Heat like a wet cloth.');
      expect(desc.contains('Heat like a wet cloth'), isFalse);
    });

    test('scenario name → card name, and does NOT leak a <Name> tag into the '
        'XML description', () {
      // The scenario `name` field is requested in batch 1.
      expect(batchesFor(CreatorMode.scenario).first, contains('name'));

      final out = renderCard(<String, dynamic>{
        'name': 'Nexus Fest',
        'world': 'A neon mega-convention spanning three halls.',
        'npcs': '## Mira\nThe overworked floor manager.',
      }, CreatorMode.scenario);

      // The title becomes the card display name.
      expect(out['name'], 'Nexus Fest');

      // The name is surfaced as a top-level field, NOT as a `<Name>` XML block
      // in the Description.
      final desc = out['description'] as String;
      expect(desc.contains('<Name>'), isFalse,
          reason: 'name must not leak into the XML description');
      expect(desc.contains('Nexus Fest'), isFalse,
          reason: 'the title belongs to the card name, not the description');
      // The real prose sections still render.
      expect(desc.contains('<World>'), isTrue);
      expect(desc.contains('<NPCs>'), isTrue);
    });
  });

  group('renderMesExample', () {
    test('<START>-separated, **bold**/*italic*, includes a charged beat', () {
      final examples = <dynamic>[
        {
          'action': 'She leans in, eyes bright.',
          'dialogue': 'You came back.',
        },
        {
          'action': 'a breathless, flushed gasp',
          'dialogue': 'd-don\'t stop looking at me—',
          'beat': 'charged',
        },
      ];
      final out = renderMesExample(examples);
      expect(out.contains('<START>'), isTrue);
      expect('<START>'.allMatches(out).length, greaterThanOrEqualTo(2));
      expect(out.contains('**'), isTrue, reason: 'bold dialogue missing');
      expect(out.contains('*'), isTrue, reason: 'italic action missing');
      // The charged beat survived.
      expect(out.contains('breathless'), isTrue);
    });

    test('tolerates pre-formatted string items', () {
      final out = renderMesExample(<dynamic>[
        '{{char}}: *waves* **hi there**',
      ]);
      expect(out.contains('<START>'), isTrue);
      expect(out.contains('hi there'), isTrue);
    });

    // I2: the {user, char} line-pair shape (legacy Persona.dialogueExamples,
    // Waves CN/CO) must render as two prefixed turns under one <START>.
    test('renders {user, char} line-pair exchanges (Shape B)', () {
      final out = renderMesExample(<dynamic>[
        {
          'user': 'What are you reading?',
          'char': 'Oh— nothing. *snaps the book shut, ears pink.*',
        },
      ]);
      expect(out.contains('<START>'), isTrue);
      expect(out.contains('{{user}}: What are you reading?'), isTrue);
      expect(out.contains('{{char}}: Oh— nothing.'), isTrue);
    });
  });

  group('decomposeDescription — I1 blank-line invariant', () {
    test('a label-like line embedded inside a prose value is NOT mis-split', () {
      // Background's value contains a sentence that starts like a label
      // ("Note: ...") on its own line, with no blank line before it. The
      // decomposer must keep it as part of Background, not open a new section.
      final fields = <String, dynamic>{
        'fullName': 'Edge Case',
        'background': 'Raised on the docks.\n'
            'Note: he still fears deep water.',
        'coreTraits': 'Wary.',
      };
      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      final back = decomposeDescription(desc, CreatorMode.character);

      // The embedded "Note:" line stayed inside Background.
      expect(back['background'], contains('Note: he still fears deep water.'));
      // It did NOT become its own foreign "Note" section.
      expect(back.containsKey('Note'), isFalse);
      // Round-trips byte-for-byte.
      final desc2 =
          renderCard(back, CreatorMode.character)['description'] as String;
      expect(_norm(desc2), _norm(desc));
    });
  });

  group('missingRequired', () {
    test('flags empty required schema keys', () {
      final fields = <String, dynamic>{
        'fullName': 'A',
        'generalAppearance': 'Tall.',
        // coreTraits, background, first_mes missing → required
      };
      final missing = missingRequired(fields, CreatorMode.character);
      expect(missing.contains('coreTraits'), isTrue);
      expect(missing.contains('background'), isTrue);
      expect(missing.contains('first_mes'), isTrue);
      expect(missing.contains('fullName'), isFalse);
    });
  });

  group('round-trip — synthetic full-coverage (review #2)', () {
    test('decompose(render(fields)) == fields, exercising flat + nested + '
        'Alternative Clothing + an empty optional', () {
      final fields = <String, dynamic>{
        // flat labels
        'fullName': 'Kira Vale',
        'race': 'Half-elf.',
        // a nested parent with >=2 children
        'detailedFeatures': <Map<String, String>>[
          {'label': 'Face', 'value': 'Sharp, freckled.'},
          {'label': 'Hair', 'value': 'Copper, braided.'},
          {'label': 'Eyes', 'value': 'Grey.'},
        ],
        // the inter-parent flat label
        'alternativeClothing': 'A travelling cloak when on the road.',
        // another nested parent
        'clothing': <Map<String, String>>[
          {'label': 'Torso / Top', 'value': 'A laced jerkin.'},
          {'label': 'Footwear', 'value': 'Worn boots.'},
        ],
        // a leaf prose section
        'background': 'Raised by a guild of cartographers.',
        // an optional left EMPTY (must be absent from the round-trip result)
        'notes': '',
      };

      final desc =
          renderCard(fields, CreatorMode.character)['description'] as String;
      final back = decomposeDescription(desc, CreatorMode.character);

      // Empty 'notes' was skipped → absent from the decomposed map.
      expect(back.containsKey('notes'), isFalse);

      // Flat labels round-trip exactly.
      expect(back['fullName'], 'Kira Vale');
      expect(back['race'], 'Half-elf.');
      expect(back['alternativeClothing'],
          'A travelling cloak when on the road.');
      expect(back['background'], 'Raised by a guild of cartographers.');

      // Nested parents round-trip: re-rendering the decomposed map reproduces
      // the same Description byte-for-byte (modulo trailing whitespace).
      final desc2 =
          renderCard(back, CreatorMode.character)['description'] as String;
      expect(_norm(desc2), _norm(desc));
    });
  });

  group('round-trip — bundled cards', () {
    test('Ren (character schema) decomposes with no lost labels + renders '
        'back equal', () {
      final ren = _readAsset('ren.json');
      final original = ren['description'] as String;

      final fields = decomposeDescription(original, CreatorMode.character);
      // No label lost: every top-level label line in the original is a key in
      // the decomposed map (known schema key OR a tolerated foreign label).
      expect(fields.isNotEmpty, isTrue);

      final rendered =
          renderCard(fields, CreatorMode.character)['description'] as String;
      expect(_norm(rendered), _norm(original),
          reason: 'Ren did not round-trip — schema/label mismatch to flag');
    });

    test('Vesna (character schema) round-trips', () {
      final vesna = _readAsset('vesna.json');
      final original = vesna['description'] as String;
      final fields = decomposeDescription(original, CreatorMode.character);
      final rendered =
          renderCard(fields, CreatorMode.character)['description'] as String;
      expect(_norm(rendered), _norm(original),
          reason: 'Vesna did not round-trip — schema/label mismatch to flag');
    });

    test('Sunken Gate (scenario schema) round-trips', () {
      final scn = _readAsset('scenario.json');
      final original = scn['description'] as String;
      final fields = decomposeDescription(original, CreatorMode.scenario);
      final rendered =
          renderCard(fields, CreatorMode.scenario)['description'] as String;
      expect(_norm(rendered), _norm(original),
          reason: 'Sunken Gate did not round-trip — scenario XML mismatch');
    });
  });
}
