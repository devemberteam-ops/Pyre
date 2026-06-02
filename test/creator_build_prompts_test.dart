// Wave CY.18.225 (Creator Structured Build, Task 5): tests for the pure
// prompt-builder that requests one batch of card fields from the model as a
// single structured JSON object, and the bounded JSON-continuation retry.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_api.dart' show ChatTurn;
import 'package:pyre/services/creator_build_prompts.dart';
import 'package:pyre/services/creator_schema.dart';

String _allContent(List<ChatTurn> turns) =>
    turns.map((t) => t.content).join('\n\n');

void main() {
  group('buildBatchTurns — every mode, every batch', () {
    for (final mode in CreatorMode.values) {
      final batches = batchesFor(mode);
      for (var i = 0; i < batches.length; i++) {
        final batch = batches[i];
        test('$mode batch $i requests its exact keys + contract', () {
          final turns = buildBatchTurns(
            mode: mode,
            batchKeys: batch,
            transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
          );
          final all = _allContent(turns);

          // Every requested key is named in the prompt.
          for (final key in batch) {
            expect(all, contains(key),
                reason: 'key "$key" missing for $mode batch $i');
          }

          // Output contract: JSON object + English.
          expect(all, contains('JSON object'));
          expect(all, contains('English'));

          // Quality rules carried forward from the architect.
          expect(all.toLowerCase(), contains('meta'),
              reason: 'no-meta rule missing for $mode batch $i');
          expect(all.toLowerCase(), contains('seed'),
              reason: 'anti-seed-collapse rule missing for $mode batch $i');

          // Transcript context is carried into the turns.
          expect(all, contains('shy catgirl named Mina'),
              reason: 'transcript not carried for $mode batch $i');

          // A system role turn is present (role-setting).
          expect(turns.any((t) => t.role == 'system'), isTrue);
          // The final turn is the user request turn.
          expect(turns.last.role, 'user');

          // FIX D: the FULL sheet map + scoping instruction is present.
          // Every section label of the mode appears somewhere in the prompt
          // (so the model knows the other passes exist).
          for (final f in schemaFor(mode)) {
            expect(all, contains(f.label),
                reason: 'full-sheet-map label "${f.label}" missing for '
                    '$mode batch $i');
          }
          // The scoping instruction names what THIS pass fills and forbids
          // cramming / repeating across sections.
          final lower = all.toLowerCase();
          expect(lower, contains('right now you are filling'),
              reason: 'scoping line missing for $mode batch $i');
          expect(lower, contains('filled separately'),
              reason: 'separate-pass note missing for $mode batch $i');
          expect(lower.contains('do not cram') || lower.contains("don't cram"),
              isTrue,
              reason: 'anti-cram instruction missing for $mode batch $i');
        });
      }
    }
  });

  group('buildBatchTurns — FIX D full sheet map + scoping', () {
    test('marks which sections are in THIS batch vs the rest', () {
      final batches = batchesFor(CreatorMode.character);
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batches.first, // identity + appearance pass
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);

      // This batch's labels are named as the current focus.
      expect(all, contains('Full Name'));
      // A later-pass label (Background) is in the FULL map but the prompt
      // says the other sections will be filled separately.
      expect(all, contains('Background'));
      expect(all.toLowerCase(), contains('right now you are filling'));
      expect(all.toLowerCase(), contains('several passes'));
    });
  });

  group('buildBatchTurns — system turn isolation', () {
    test('prior system turns in the transcript are dropped', () {
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batchesFor(CreatorMode.character).first,
        transcript: [
          ChatTurn('system', 'POISON-INSTRUCTION-SHOULD-NOT-APPEAR'),
          ChatTurn('user', 'make a shy catgirl named Mina'),
          ChatTurn('assistant', 'Got it, building Mina.'),
        ],
      );
      final all = _allContent(turns);
      expect(all, isNot(contains('POISON-INSTRUCTION-SHOULD-NOT-APPEAR')));
      expect(all, contains('shy catgirl named Mina'));
      expect(all, contains('Got it, building Mina.'));
      // Exactly one system turn — ours, not the transcript's.
      expect(turns.where((t) => t.role == 'system').length, 1);
    });
  });

  group('buildBatchTurns — kind-specific shape hints', () {
    test('nestedBullets batch demands {"label","value"} array shape', () {
      // character batch 0 contains detailedFeatures / clothing (nestedBullets).
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: ['detailedFeatures'],
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);
      expect(all, contains('"label"'));
      expect(all, contains('"value"'));
    });

    test('nestedBullets hint ENUMERATES the schema\'s canonical sub-labels '
        '(drives the full Ren-depth breakdown, not 1-2 generic bullets)', () {
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: ['detailedFeatures'],
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);
      // The canonical detailedFeatures children must be listed as sub-points.
      expect(all, contains('Face'));
      expect(all, contains('Hair'));
      expect(all, contains('Eyes'));
      expect(all, contains('sub-point'));
    });

    test('bulletList (Group B, Wave CY.18.241) demands a JSON array of short '
        'strings', () {
      // coreTraits / interests / coreBeliefs / abilities are bulletList.
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: ['coreTraits', 'interests', 'coreBeliefs', 'abilities'],
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);
      expect(all, contains('JSON array of short strings'),
          reason: 'bulletList shape hint missing');
      // It is NOT asked for as a {label,value} object array (that is the
      // variable-nestedBullets shape) for these flat-list fields.
      // (We only assert the bulletList phrasing is present — sufficient.)
    });

    test('variable nestedBullets (Group A, Wave CY.18.241) get the childless '
        'object-array hint — same as innerCircle, no enumerated sub-points',
        () {
      // likesDislikes / strengthsWeaknesses / fetishesKinks / behavioralModes /
      // vulnerabilities / storageItems / personalRituals are now childless
      // nestedBullets.
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: ['likesDislikes', 'behavioralModes'],
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);
      // The variable-nestedBullets fields get the {"label","value"} array shape.
      expect(all, contains('"label"'));
      expect(all, contains('"value"'));
      // The field-specific guidance steers toward sub-labelled entries.
      expect(all, contains('sub-label'),
          reason: 'Group-A guidance should mention sub-labelled entries');
      // They are NOT bulletList (no flat array-of-short-strings hint mixed in
      // for these object-shaped fields specifically).
    });

    test('dialogueExamples batch demands action/dialogue array shape', () {
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: ['dialogueExamples'],
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);
      expect(all, contains('"action"'));
      expect(all, contains('"dialogue"'));
    });

    test('tags batch demands a JSON array of discovery tags', () {
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: ['tags'],
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);
      expect(all, contains('JSON array of'));
      expect(all, contains('discovery tags'));
    });

    test('FIX E: tags hint demands searchable conventional tags, NOT '
        'snake_case prose, no spoilers, with example tags', () {
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: ['tags'],
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final all = _allContent(turns);
      final lower = all.toLowerCase();
      // The hint steers toward searchable discovery tags…
      expect(lower, contains('search'),
          reason: 'tags hint should mention searchability');
      // …and explicitly forbids snake_case + spoilers.
      expect(lower, contains('snake_case'),
          reason: 'tags hint should forbid snake_case');
      expect(lower, contains('spoiler'),
          reason: 'tags hint should forbid spoilers');
      // A couple of concrete example tags are shown.
      expect(all, contains('Female'));
      expect(all, contains('NSFW'));
    });
  });

  group('buildBatchTurns — FIX G priorFields continuity', () {
    List<String> batchWithCoreTraits() {
      for (final batch in batchesFor(CreatorMode.character)) {
        if (batch.contains('coreTraits')) return batch;
      }
      return ['coreTraits'];
    }

    test('non-empty priorFields adds a CONTINUITY block listing decided '
        'facts; distinct from the EDIT block', () {
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batchWithCoreTraits(),
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
        priorFields: {
          'fullName': 'Mina Sato',
          'apparentAge': '19yo — 150 cm / 44 kg',
        },
      );
      final all = _allContent(turns);
      expect(all, contains('CONTINUITY'),
          reason: 'priorFields should add a continuity block');
      // The decided facts are carried compactly.
      expect(all, contains('Mina Sato'));
      expect(all, contains('19yo — 150 cm / 44 kg'));
      // It is NOT framed as an edit (no "THIS IS AN EDIT" / "current value").
      expect(all, isNot(contains('THIS IS AN EDIT')));
      expect(all, isNot(contains('current value')));
    });

    test('null / empty priorFields = NO continuity block (byte-identical to '
        'no-priorFields)', () {
      final batch = batchWithCoreTraits();
      final transcript = [ChatTurn('user', 'make a shy catgirl named Mina')];

      final base = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batch,
        transcript: transcript,
      );
      final nullPrior = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batch,
        transcript: transcript,
        priorFields: null,
      );
      final emptyPrior = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batch,
        transcript: transcript,
        priorFields: const {},
      );

      final baseAll = _allContent(base);
      expect(baseAll, isNot(contains('CONTINUITY')));
      expect(_allContent(nullPrior), baseAll);
      expect(_allContent(emptyPrior), baseAll);
    });

    test('priorFields (create-consistency) and existingFields (edit) can BOTH '
        'be present — both blocks appear', () {
      final batch = batchWithCoreTraits();
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batch,
        transcript: [ChatTurn('user', 'make her bolder')],
        existingFields: {'coreTraits': 'Warm and shy.'},
        priorFields: {'fullName': 'Mina Sato'},
      );
      final all = _allContent(turns);
      expect(all, contains('CONTINUITY'));
      expect(all, contains('Mina Sato'));
      expect(all, contains('THIS IS AN EDIT'));
      expect(all, contains('Warm and shy.'));
    });
  });

  group('buildBatchTurns — edit framing (existingFields)', () {
    // A character batch that contains coreTraits.
    List<String> batchWithCoreTraits() {
      for (final batch in batchesFor(CreatorMode.character)) {
        if (batch.contains('coreTraits')) return batch;
      }
      // Fallback: synthesise a single-key batch so the test still exercises
      // the edit path even if the schema is reorganised.
      return ['coreTraits'];
    }

    test('non-null existingFields injects the current value + an edit '
        'instruction', () {
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batchWithCoreTraits(),
        transcript: [ChatTurn('user', 'make her bolder')],
        existingFields: {'coreTraits': 'Warm and shy.'},
      );
      final all = _allContent(turns);
      // The current value is carried into the prompt verbatim.
      expect(all, contains('Warm and shy.'));
      expect(all, contains('current value'));
      // An edit instruction is present.
      expect(all, contains('EDIT'));
      final lower = all.toLowerCase();
      expect(lower.contains('verbatim') || lower.contains('unchanged'), isTrue,
          reason: 'edit instruction should say verbatim/unchanged');
    });

    test('null existingFields = NO edit block (byte-identical to create '
        'mode)', () {
      final batch = batchWithCoreTraits();
      final transcript = [ChatTurn('user', 'make her bolder')];

      final createTurns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batch,
        transcript: transcript,
      );
      final nullEditTurns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batch,
        transcript: transcript,
        existingFields: null,
      );

      final createAll = _allContent(createTurns);
      // The edit block is ABSENT in create mode.
      expect(createAll, isNot(contains('current value')));
      expect(createAll, isNot(contains('THIS IS AN EDIT')));

      // Passing existingFields: null is byte-identical to passing nothing.
      expect(_allContent(nullEditTurns), createAll);
    });

    test('empty existingFields also produces NO edit block', () {
      final batch = batchWithCoreTraits();
      final turns = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batch,
        transcript: [ChatTurn('user', 'make her bolder')],
        existingFields: const {},
      );
      final all = _allContent(turns);
      expect(all, isNot(contains('current value')));
      expect(all, isNot(contains('THIS IS AN EDIT')));
    });
  });

  group('buildContinuationTurns', () {
    test('appends partial + a continue/JSON user turn', () {
      final prior = buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: batchesFor(CreatorMode.character).first,
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      );
      final turns =
          buildContinuationTurns(priorTurns: prior, partial: '{"a":"x"');

      // The partial is present as an assistant turn.
      expect(
          turns.any((t) => t.role == 'assistant' && t.content == '{"a":"x"'),
          isTrue);

      // Last turn is a user turn telling the model to continue the JSON.
      expect(turns.last.role, 'user');
      expect(turns.last.content.toLowerCase(), contains('continue'));
      expect(turns.last.content, contains('JSON'));

      // Prior turns are preserved at the front.
      expect(turns.length, prior.length + 2);
    });
  });

  group('buildBatchTurns — Description size (Wave CY.18.265)', () {
    final charBatch = batchesFor(CreatorMode.character).first;
    final personaBatch = batchesFor(CreatorMode.persona).first;
    final scenarioBatch = batchesFor(CreatorMode.scenario).first;

    String buildChar([CreatorDescriptionSize? size]) => _allContent(
          buildBatchTurns(
            mode: CreatorMode.character,
            batchKeys: charBatch,
            transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
            descriptionSize: size ?? CreatorDescriptionSize.standard,
          ),
        );

    test('default (omitted) == Standard == the original ~5,000 directive', () {
      final omitted = _allContent(buildBatchTurns(
        mode: CreatorMode.character,
        batchKeys: charBatch,
        transcript: [ChatTurn('user', 'make a shy catgirl named Mina')],
      ));
      // Byte-identical to explicitly passing Standard.
      expect(omitted, buildChar(CreatorDescriptionSize.standard));
      // And it carries the historical ~5,000 aim + the 1-3 sentence guidance.
      expect(omitted, contains('LENGTH DISCIPLINE'));
      expect(omitted, contains('~5,000'));
      expect(omitted, contains('typically 1-3 sentences'));
    });

    test('each size injects its own token budget into the directive', () {
      expect(buildChar(CreatorDescriptionSize.concise), contains('~2,500'));
      expect(buildChar(CreatorDescriptionSize.concise),
          contains('typically 1-2 sentences'));
      expect(buildChar(CreatorDescriptionSize.detailed), contains('~8,000'));
      expect(
          buildChar(CreatorDescriptionSize.veryDetailed), contains('~12,000'));
      // The smaller budget must NOT carry the standard number.
      expect(
          buildChar(CreatorDescriptionSize.concise), isNot(contains('~5,000')));
    });

    test('persona mode honours the size too (char + persona only)', () {
      final personaDetailed = _allContent(buildBatchTurns(
        mode: CreatorMode.persona,
        batchKeys: personaBatch,
        transcript: [ChatTurn('user', 'I play a quiet archivist')],
        descriptionSize: CreatorDescriptionSize.detailed,
      ));
      expect(personaDetailed, contains('LENGTH DISCIPLINE'));
      expect(personaDetailed, contains('~8,000'));
    });

    test('scenario mode never gets the length directive, for ANY size', () {
      for (final size in CreatorDescriptionSize.values) {
        final all = _allContent(buildBatchTurns(
          mode: CreatorMode.scenario,
          batchKeys: scenarioBatch,
          transcript: [ChatTurn('user', 'a haunted seaside inn')],
          descriptionSize: size,
        ));
        expect(all, isNot(contains('LENGTH DISCIPLINE')),
            reason: 'scenario must not carry the brevity directive for $size');
      }
    });
  });
}
