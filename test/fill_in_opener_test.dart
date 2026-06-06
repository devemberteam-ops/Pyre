// chat-core-2-05 (deferred portion) — the Fill-In scenario opener must share
// the SAME baseline context the ongoing chat runs on: the responder's canon
// (description / personality / scenario / examples), the user persona, AND the
// bound lorebook hits + the active preset's main prompt. Previously the opener
// omitted lore + preset, so a generated greeting could contradict the lore /
// preset every later turn enforces.
//
// `buildFillInOpenerPrompt` is the pure assembly extracted from the dialog
// closure so it can be pinned here.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_screen.dart';

void main() {
  group('buildFillInOpenerPrompt', () {
    final responder = Character(
      id: 'c1',
      name: 'Vesna',
      description: 'A wolfkin delver.',
      personality: 'Wry, loyal.',
      scenario: 'The jungle Gate has just opened.',
      mesExample: '{{char}}: "Stay close."',
    );
    final persona = Persona(
      id: 'p1',
      name: 'Ren',
      description: 'A clueless outsider.',
    );

    test('includes the bound lorebook hits', () {
      final sys = buildFillInOpenerPrompt(
        responder: responder,
        persona: persona,
        filledScenario: 'Late evening at the Gate.',
        loreHits: [
          LoreEntry(id: 'l1', content: 'Aether powers the Gates.'),
          LoreEntry(id: 'l2', content: 'The Vekhi tribe guards the ruins.'),
        ],
        presetMainPrompt: '',
      );
      expect(sys, contains('Aether powers the Gates.'));
      expect(sys, contains('The Vekhi tribe guards the ruins.'));
    });

    test('includes the active preset main prompt', () {
      final sys = buildFillInOpenerPrompt(
        responder: responder,
        persona: persona,
        filledScenario: 'Late evening at the Gate.',
        loreHits: const [],
        presetMainPrompt: 'You write in a frank, literary register.',
      );
      expect(sys, contains('You write in a frank, literary register.'));
    });

    test('still includes responder canon and the typed scenario', () {
      final sys = buildFillInOpenerPrompt(
        responder: responder,
        persona: persona,
        filledScenario: 'Late evening at the Gate.',
        loreHits: const [],
        presetMainPrompt: '',
      );
      expect(sys, contains('You are Vesna.'));
      expect(sys, contains('A wolfkin delver.'));
      expect(sys, contains('The jungle Gate has just opened.'));
      expect(sys, contains('Late evening at the Gate.'));
      // Persona folded in.
      expect(sys, contains('Ren'));
    });

    test('empty lore + empty preset → no stray Lore/preset headers', () {
      final sys = buildFillInOpenerPrompt(
        responder: responder,
        persona: persona,
        filledScenario: 'Late evening at the Gate.',
        loreHits: const [],
        presetMainPrompt: '   ',
      );
      expect(sys, isNot(contains('--- Lore ---')));
      // The instruction tail is still present.
      expect(sys, contains('Output ONLY the opening message'));
    });

    test('null responder still produces a usable prompt with lore', () {
      final sys = buildFillInOpenerPrompt(
        responder: null,
        persona: null,
        filledScenario: 'A quiet room.',
        loreHits: [LoreEntry(id: 'l1', content: 'Magic is forbidden here.')],
        presetMainPrompt: '',
      );
      expect(sys, contains('A quiet room.'));
      expect(sys, contains('Magic is forbidden here.'));
    });

    // C-4: personas built via `buildPersonaFromCharacter` ALWAYS carry literal
    // {{user}}/{{char}} macros; the responder card can too. The opener builder
    // wrote those blocks RAW (only `filledScenario` was pre-substituted), so
    // the macros leaked into the opener-generation prompt verbatim. The fix
    // applies the main path's name-fill over the whole assembled prompt.
    test('FAILING-BEFORE-FIX: persona/responder {{user}}/{{char}} macros are '
        'resolved, none leak literally', () {
      final macroResponder = Character(
        id: 'c2',
        name: 'Vesna',
        description: 'Sizes up {{user}} the moment they stumble through.',
        personality: 'Protective of {{user}}.',
        scenario: '{{char}} has been delving alone.',
        mesExample: '{{char}}: "Stay behind me, {{user}}."',
      );
      final macroPersona = Persona(
        id: 'p2',
        name: 'Ren',
        description: '{{user}} is a clueless outsider; {{char}} unnerves them.',
        dialogueExamples: '{{user}}: "Where... am I?"',
      );

      final sys = buildFillInOpenerPrompt(
        responder: macroResponder,
        persona: macroPersona,
        filledScenario: 'Late evening at the Gate.',
        loreHits: const [],
        presetMainPrompt: '',
      );

      // No literal macros survive (case-insensitive, mirroring the resolver).
      expect(
        RegExp(r'\{\{\s*(user|char)\s*\}\}', caseSensitive: false)
            .hasMatch(sys),
        isFalse,
        reason: 'opener prompt must not ship literal {{user}}/{{char}}',
      );
      // Substituted to the right names: {{user}}=persona, {{char}}=responder.
      expect(sys, contains('Sizes up Ren the moment'));
      expect(sys, contains('Protective of Ren.'));
      expect(sys, contains('Vesna has been delving alone.'));
      expect(sys, contains('"Stay behind me, Ren."'));
      expect(sys, contains('Ren is a clueless outsider; Vesna unnerves them.'));
    });
  });
}
