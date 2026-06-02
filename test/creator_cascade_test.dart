import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_cascade.dart';

// Wave CY.18.231 (Creator Structured Build): the old `<<SHEET>>`-marker
// completeness cascade was deleted when the BUILD step moved to the
// deterministic structured-JSON pipeline. The pure functions that drove it
// (`isCardComplete`, `floorFor`, `proseFields`, `looksTerminated`,
// `cascadeProgressed`, `incompleteRequiredLabels`, `fieldLabel`,
// `reviewVerdict`) are gone — and so are their tests. What remains here are
// the functions the new pipeline / renderer / save flow still use:
// `requiredKeysFor`, `requiredDescriptionSectionsFor`,
// `parseDescriptionSections`, `mergeDescriptionSections`, `canvasText`, and
// `withCopyNameSuffix`.

void main() {
  group('requiredKeysFor', () {
    test('character set', () {
      expect(
          requiredKeysFor('character'),
          containsAll(<String>[
            'name',
            'description',
            'scenario',
            'first_mes',
            'mes_example',
            'tagline',
            'creator_notes',
            'tags',
          ]));
      expect(requiredKeysFor('character'),
          isNot(contains('post_history_instructions')));
    });
    test('scenario adds post_history_instructions', () {
      expect(requiredKeysFor('scenario'),
          contains('post_history_instructions'));
    });
    test('null/unknown mode falls back to character set', () {
      expect(requiredKeysFor(null), equals(requiredKeysFor('character')));
    });
    test('persona set is name + description + mes_example only', () {
      expect(requiredKeysFor('persona'),
          equals(<String>['name', 'description', 'mes_example']));
      // No character/scenario-only keys leak in.
      expect(requiredKeysFor('persona'), isNot(contains('scenario')));
      expect(requiredKeysFor('persona'), isNot(contains('first_mes')));
      expect(requiredKeysFor('persona'), isNot(contains('tags')));
      expect(requiredKeysFor('persona'), isNot(contains('creator_notes')));
    });
  });

  group('requiredDescriptionSectionsFor', () {
    test('scenario lists the six canonical sections in order', () {
      expect(
          requiredDescriptionSectionsFor('scenario'),
          equals(<String>[
            'Narrator',
            'Reading the Persona',
            'Scene Setup',
            'Tone',
            'World',
            'NPCs',
          ]));
    });
    test('character / null have no required sections', () {
      expect(requiredDescriptionSectionsFor('character'), isEmpty);
      expect(requiredDescriptionSectionsFor(null), isEmpty);
    });
  });

  group('canvasText', () {
    test('strings pass through unchanged', () {
      expect(canvasText('hello world'), 'hello world');
    });
    test('lists join with ", "', () {
      expect(canvasText(<String>['a', 'b', 'c']), 'a, b, c');
    });
    test('null / other types → empty string', () {
      expect(canvasText(null), '');
      expect(canvasText(42), '');
    });
  });

  group('parseDescriptionSections', () {
    test('round-trips multi-word (spaced) tags', () {
      const text = '<Narrator>Be fair.</Narrator>\n'
          '<Reading the Persona>Use the sheet.</Reading the Persona>\n'
          '<Scene Setup>A quiet town.</Scene Setup>';
      final sections = parseDescriptionSections(text);
      expect(sections.map((s) => s.tag).toList(),
          equals(['Narrator', 'Reading the Persona', 'Scene Setup']));
      expect(sections[1].value, 'Use the sheet.');
      expect(sections[2].value, 'A quiet town.');
    });
    test('captures untagged prose between sections as a separate entry', () {
      const text = 'leading prose\n<Tone>Warm.</Tone>\ntrailing prose';
      final sections = parseDescriptionSections(text);
      final tags = sections.map((s) => s.tag).toList();
      // Tagged section is parsed; untagged prose preserved with empty tag.
      expect(tags, contains('Tone'));
      final untagged =
          sections.where((s) => s.tag.isEmpty).map((s) => s.value).join('\n');
      expect(untagged, contains('leading prose'));
      expect(untagged, contains('trailing prose'));
    });
    test('an unclosed tag is NOT parsed as a section', () {
      const text = '<Scene Setup>this never closes';
      final sections = parseDescriptionSections(text);
      expect(sections.where((s) => s.tag == 'Scene Setup'), isEmpty);
    });
  });

  group('mergeDescriptionSections', () {
    test('merging a full multi-section incoming into empty current = replace',
        () {
      const incoming = '<Narrator>Be fair and consistent.</Narrator>\n'
          '<Reading the Persona>Honor the sheet.</Reading the Persona>\n'
          '<Scene Setup>A bathhouse at dusk.</Scene Setup>\n'
          '<Tone>Warm, sensual.</Tone>\n'
          '<World>No indecency laws.</World>\n'
          '<NPCs>## Mira</NPCs>';
      final merged = mergeDescriptionSections('', incoming);
      final tags = parseDescriptionSections(merged).map((s) => s.tag).toList();
      expect(
          tags,
          containsAllInOrder(<String>[
            'Narrator',
            'Reading the Persona',
            'Scene Setup',
            'Tone',
            'World',
            'NPCs',
          ]));
    });
    test('replaces a matching tag in place, leaving others untouched', () {
      const current = '<Narrator>old narrator.</Narrator>\n'
          '<Scene Setup>old scene.</Scene Setup>';
      const incoming = '<Scene Setup>new scene at the docks.</Scene Setup>';
      final merged = mergeDescriptionSections(current, incoming);
      final sections = parseDescriptionSections(merged);
      // Same number of sections (replace, not append).
      expect(sections.length, 2);
      expect(sections.firstWhere((s) => s.tag == 'Narrator').value,
          'old narrator.');
      expect(sections.firstWhere((s) => s.tag == 'Scene Setup').value,
          'new scene at the docks.');
    });
    test('appends a new tag in canonical order', () {
      // current already has Tone + NPCs; incoming adds World, which in
      // canonical order sits BETWEEN Tone and NPCs.
      const current = '<Tone>Warm.</Tone>\n<NPCs>## Mira</NPCs>';
      const incoming = '<World>Androids have no rights.</World>';
      final merged = mergeDescriptionSections(current, incoming);
      final tags = parseDescriptionSections(merged).map((s) => s.tag).toList();
      expect(tags, equals(['Tone', 'World', 'NPCs']));
    });
    test('a malformed/unclosed incoming tag is NOT merged', () {
      const current = '<Narrator>Be fair.</Narrator>';
      const incoming = '<Scene Setup>truncated, never closes';
      final merged = mergeDescriptionSections(current, incoming);
      // Nothing added; current is returned unchanged.
      expect(merged, current);
      expect(parseDescriptionSections(merged).where((s) => s.tag == 'Scene Setup'),
          isEmpty);
    });
    test('preserves untagged prose already in current', () {
      const current = 'legacy intro prose\n<Narrator>Be fair.</Narrator>';
      const incoming = '<Scene Setup>A new scene.</Scene Setup>';
      final merged = mergeDescriptionSections(current, incoming);
      expect(merged, contains('legacy intro prose'));
      expect(merged, contains('<Narrator>Be fair.</Narrator>'));
      expect(merged, contains('<Scene Setup>A new scene.</Scene Setup>'));
    });
  });

  group('withCopyNameSuffix', () {
    test('appends " (copy)" to a plain name', () {
      expect(withCopyNameSuffix('Ren Brennan'), 'Ren Brennan (copy)');
    });
    test('trims surrounding whitespace before suffixing', () {
      expect(withCopyNameSuffix('  Vesna  '), 'Vesna (copy)');
    });
    test('does not pile up when the name already ends in (copy)', () {
      expect(withCopyNameSuffix('Ren (copy)'), 'Ren (copy)');
    });
    test('(copy) match is case-insensitive', () {
      expect(withCopyNameSuffix('Ren (Copy)'), 'Ren (Copy)');
      expect(withCopyNameSuffix('Ren (COPY)'), 'Ren (COPY)');
    });
    test('only the trailing (copy) is treated as the marker', () {
      // A "(copy)" in the MIDDLE is not the trailing marker → still suffixed.
      expect(withCopyNameSuffix('A (copy) thing'), 'A (copy) thing (copy)');
    });
    test('empty / whitespace-only name becomes "(copy)"', () {
      expect(withCopyNameSuffix(''), '(copy)');
      expect(withCopyNameSuffix('   '), '(copy)');
    });
  });
}
