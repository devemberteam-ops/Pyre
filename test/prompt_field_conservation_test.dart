// Audit fix (2026-07-09) — prompt-field conservation.
//
// The shipped lore bug: user-bound lore was scanned, then silently dropped
// because injection was gated on a preset marker existing (fixed via
// `injectLoreSegment` + the `referencesWiBefore` pre-scan). This is the
// regression net for 4 sibling fields the same audit found still falling in
// that hole:
//
//   1. the persona's dialogueExamples, dropped by the `{{persona}}` MARKER
//      FILL (the fallback path always carried it — the two paths had
//      drifted).
//   2. `character.systemPrompt` — no `{{...}}` macro exists for it anywhere
//      in `fill()`, so a marker-carrying preset (including the LOCKED
//      DEFAULT) can never "own" it and silently dropped it.
//   3. `character.postHistoryInstructions` — consumed NOWHERE (round-trips
//      import/export, shown in the UI, counted by token_estimate.dart, never
//      sent).
//   4. the persona block itself, dropped whenever a preset referenced SOME
//      OTHER card marker (e.g. {{description}}) but not {{persona}}
//      specifically.
//   5. `character.mesExample`, forgotten by the marker-less card fallback
//      (party mode and the Fill-In opener both already carried it).
//
// THE POLICY (do not re-litigate — see chat_prompt_builder.dart's audit-fix
// comments):
//   - No marker exists for a field anywhere → ALWAYS inject when non-empty
//     (systemPrompt, postHistoryInstructions).
//   - Marker exists + USER-side identity data → rescue when the marker is
//     absent EVERYWHERE, even if other card markers are present (persona).
//   - Marker exists + CARD content (description/personality/scenario/
//     mesExample) → marker presence governs; the no-marker fallback must
//     carry ALL card fields.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  Map<String, dynamic> readAsset(String relPath) {
    final file = File('assets/examples/$relPath');
    expect(file.existsSync(), isTrue,
        reason: 'missing bundled asset: ${file.path}');
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  late Character vesna;
  late Persona renPersona;

  setUp(() {
    vesna = Character.fromJson(readAsset('vesna.json'));
    final ren = Character.fromJson(readAsset('ren.json'));
    renPersona = Persona(
      id: 'p-ren',
      name: ren.name,
      description: ren.description,
      dialogueExamples: '{{user}}: "...whatever. fine."',
    );
  });

  Message userMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.user, variants: [text], createdAt: 1);

  Chat soloChat(Character c, {String? personaId}) => Chat(
        id: 'c-${c.id}-${personaId ?? 'nopersona'}',
        characterIds: [c.id],
        characterSnapshots: {c.id: c},
        personaId: personaId,
        messages: [userMsg('m1', 'Say something.')],
      );

  ChatPromptInputs inputsFor({
    required Chat chat,
    required Character character,
    Persona? persona,
    Preset? preset,
  }) =>
      ChatPromptInputs(
        chat: chat,
        character: character,
        persona: persona,
        preset: preset,
        responderId: character.id,
        beatsCap: 0,
        lookupCharacter: (id) => id == character.id ? character : null,
        lookupBook: (_) => null,
      );

  // ── 1. {{persona}} marker fill must carry dialogueExamples ─────────────
  group('1. persona dialogueExamples via the {{persona}} marker', () {
    test(
        'locked default preset + persona WITH dialogueExamples → the '
        'dialogue-examples block is present', () {
      final preset = buildLockedDefaultPreset();
      final chat = soloChat(vesna, personaId: renPersona.id);
      final inputs = inputsFor(
        chat: chat,
        character: vesna,
        persona: renPersona,
        preset: preset,
      );
      final sys = buildChatPrompt(inputs).turns.first.content;
      expect(sys, contains("${renPersona.name}'s dialogue style"));
      expect(sys, contains('...whatever. fine.'));
    });
  });

  // ── 2. character.systemPrompt — no marker anywhere → always injected ───
  group('2. character.systemPrompt has no macro → markerless injection', () {
    test('locked default preset + character with systemPrompt → present',
        () {
      final withSystemPrompt = Character.fromJson(readAsset('vesna.json'))
        ..systemPrompt = 'SYSTEM-PROMPT-SENTINEL: never break character.';
      final preset = buildLockedDefaultPreset();
      final chat = soloChat(withSystemPrompt);
      final inputs = inputsFor(
        chat: chat,
        character: withSystemPrompt,
        preset: preset,
      );
      final sys = buildChatPrompt(inputs).turns.first.content;
      expect(sys, contains('SYSTEM-PROMPT-SENTINEL'));
    });
  });

  // ── 3. character.postHistoryInstructions is consumed nowhere ───────────
  group('3. character.postHistoryInstructions reaches the post-history slot',
      () {
    test('WITH a preset: appended AFTER the preset\'s own PHI', () {
      final withPhi = Character.fromJson(readAsset('vesna.json'))
        ..postHistoryInstructions = 'CHAR-PHI-SENTINEL.';
      final preset = Preset(
        id: 'pr-phi',
        name: 'PHI test',
        mainPrompt: 'You are {{char}}.',
        postHistoryInstructions: 'PRESET-PHI-SENTINEL.',
      );
      final chat = soloChat(withPhi);
      final inputs =
          inputsFor(chat: chat, character: withPhi, preset: preset);
      final turns = buildChatPrompt(inputs).turns;
      final last = turns.last.content;
      expect(last, contains('PRESET-PHI-SENTINEL.'));
      expect(last, contains('CHAR-PHI-SENTINEL.'));
      expect(last.indexOf('PRESET-PHI-SENTINEL.'),
          lessThan(last.indexOf('CHAR-PHI-SENTINEL.')),
          reason: "preset's post-history instructions come first, the "
              "character's after");
    });

    test('WITHOUT a preset: still reaches the post-history slot', () {
      final withPhi = Character.fromJson(readAsset('vesna.json'))
        ..postHistoryInstructions = 'CHAR-PHI-SENTINEL.';
      final chat = soloChat(withPhi);
      final inputs = inputsFor(chat: chat, character: withPhi, preset: null);
      final turns = buildChatPrompt(inputs).turns;
      expect(turns.any((t) => t.content.contains('CHAR-PHI-SENTINEL.')),
          isTrue);
    });
  });

  // ── 4. modular preset, {{description}} only — persona rescued, scenario
  //       stays marker-governed (locks the policy) ────────────────────────
  group(
      '4. modular preset with {{description}} only: persona rescued, '
      'scenario NOT auto-injected', () {
    test('persona present (rescue); vesna.scenario absent (card content, '
        'marker governs)', () {
      final preset = Preset(
        id: 'pr-desc-only',
        name: 'Description only',
        promptBlocks: [
          PromptBlock(id: 'b1', name: 'Core', content: 'CORE. {{description}}'),
        ],
      );
      final chat = soloChat(vesna, personaId: renPersona.id);
      final inputs = inputsFor(
        chat: chat,
        character: vesna,
        persona: renPersona,
        preset: preset,
      );
      final sys = buildChatPrompt(inputs).turns.first.content;
      // Persona rescued even though a DIFFERENT card marker ({{description}})
      // is present and blocks the FULL card fallback.
      expect(sys, contains(renPersona.name));
      expect(sys, contains(renPersona.description));
      // Scenario is CARD content — marker presence governs it, so with no
      // {{scenario}} marker anywhere it stays excluded (locks the policy).
      expect(sys, isNot(contains(vesna.scenario)));
    });
  });

  // ── 5. no-preset fallback: mesExample now present + persona byte-compat ─
  group('5. no-preset fallback: mesExample present + persona byte-compat',
      () {
    test('mesExample now reaches the model', () {
      final chat = soloChat(vesna);
      final inputs = inputsFor(chat: chat, character: vesna, preset: null);
      final sys = buildChatPrompt(inputs).turns.first.content;
      expect(sys, contains('Example dialogue:'));
      // The trailing global name-fill pass resolves {{char}}/{{user}} inside
      // mesExample (no persona here → {{user}} becomes 'You'), so compare
      // against the resolved form rather than the raw fixture text.
      final resolvedMesExample = vesna.mesExample
          .replaceAll(RegExp(r'\{\{char\}\}', caseSensitive: false), vesna.name)
          .replaceAll(RegExp(r'\{\{user\}\}', caseSensitive: false), 'You');
      expect(sys, contains(resolvedMesExample));
    });

    test('persona block in the fallback is byte-identical to the '
        'pre-refactor construction (guards the buildSinglePersonaBlock '
        'extraction)', () {
      final chat = soloChat(vesna, personaId: renPersona.id);
      final inputs = inputsFor(
        chat: chat,
        character: vesna,
        persona: renPersona,
        preset: null,
      );
      final sys = buildChatPrompt(inputs).turns.first.content;
      // The pre-refactor fallback wrote (via 3 separate `writeln`s):
      //   '\nThe user appears as "Name". Description'
      //   '\nName\'s dialogue style (...):'
      //   'dialogueExamples'
      // which — after the final name-fill pass resolves {{user}} inside the
      // dialogue example — collapses to this exact string.
      final expected =
          'The user appears as "${renPersona.name}". ${renPersona.description}'
          '\n\n${renPersona.name}\'s dialogue style (examples — match this '
          'cadence when writing or quoting ${renPersona.name}):\n'
          '${renPersona.name}: "...whatever. fine."';
      expect(sys, contains(expected));
    });
  });

  // ── 6. no-double-inject guards ──────────────────────────────────────────
  group('6. no-double-inject guards', () {
    test('preset WITH {{persona}} → persona block appears exactly once', () {
      final preset = Preset(
        id: 'pr-has-persona',
        name: 'Has persona marker',
        mainPrompt: 'You are {{char}}. {{description}}\nUser: {{persona}}',
      );
      final chat = soloChat(vesna, personaId: renPersona.id);
      final inputs = inputsFor(
        chat: chat,
        character: vesna,
        persona: renPersona,
        preset: preset,
      );
      final sys = buildChatPrompt(inputs).turns.first.content;
      final occurrences = RegExp(RegExp.escape(renPersona.description))
          .allMatches(sys)
          .length;
      expect(occurrences, 1);
    });

    test('fallback path → character.systemPrompt appears exactly once', () {
      final withSystemPrompt = Character.fromJson(readAsset('vesna.json'))
        ..systemPrompt = 'UNIQUE-SYS-SENTINEL.';
      final chat = soloChat(withSystemPrompt);
      final inputs =
          inputsFor(chat: chat, character: withSystemPrompt, preset: null);
      final sys = buildChatPrompt(inputs).turns.first.content;
      final occurrences =
          'UNIQUE-SYS-SENTINEL.'.allMatches(sys).length;
      expect(occurrences, 1);
    });
  });
}
