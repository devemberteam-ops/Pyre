// Wave CY.18.210: regression net for the prompt-assembly extraction.
//
// `buildChatPrompt` is the verbatim move of `chat_screen._buildTurns`, and
// the Creator builders mirror `character_assistant_screen.dart`'s per-turn
// assembly. These tests lock the EXACT turn shape + the labeled
// `PromptSegment` ordering so any accidental drift in the assembly fails
// here (and, via the goldens in a later wave, in PR review).
//
// Fixtures load the bundled example cards (Ren persona-source, Vesna char,
// the Vael world lorebook, the Sunken Gate scenario) straight off disk via
// `dart:io` — same approach as `example_seed_test.dart`, validating the
// SHIPPED files without a test-asset bundle.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/card_assist_prompts.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  // ── shared fixtures ──────────────────────────────────────────────────
  Map<String, dynamic> readAsset(String relPath) {
    final file = File('assets/examples/$relPath');
    expect(file.existsSync(), isTrue,
        reason: 'missing bundled asset: ${file.path}');
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  late Character vesna; // bound to the world lorebook
  late Lorebook world;
  late Persona renPersona;

  setUp(() {
    vesna = Character.fromJson(readAsset('vesna.json'));
    world = Lorebook.fromJson(readAsset('world.json'));
    // Build a persona from Ren's card (name + description + a dialogue line).
    final ren = Character.fromJson(readAsset('ren.json'));
    renPersona = Persona(
      id: 'p-ren',
      name: ren.name,
      description: ren.description,
      dialogueExamples: '{{user}}: "...whatever. fine."',
    );
  });

  // A FIXED message list (so {{random:}} is deterministic across runs).
  Message userMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.user, variants: [text], createdAt: 1);
  Message charMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.char, variants: [text], createdAt: 1);

  group('buildChatPrompt — fallback (no preset) full assembly', () {
    test('turns + segments have the expected shape and order', () {
      final chat = Chat(
        id: 'c1',
        characterIds: [vesna.id],
        characterSnapshots: {vesna.id: vesna},
        personaId: renPersona.id,
        // The world lorebook is attached to the chat.
        attachedLorebookIds: [world.id],
        memoryEnabled: true,
        memoryCheckpoints: [
          MemoryCheckpoint(
            id: 'mc1',
            summary: 'They met at the Sunken Gate and struck a wary truce.',
            anchorMessageIdx: 0, // covers message[0]; replay starts at 1
            pathHash: '', // empty = always valid
            createdAt: 1,
          ),
        ],
        liveSheetEnabled: true,
        liveSheetSnapshots: [
          LiveSheetSnapshot(
            id: 'ls1',
            anchorMessageId: 'm1',
            pathHash: '',
            createdAt: 1,
            entities: [
              LiveSheetEntity(
                id: 'e1',
                name: 'Vesna',
                kind: LiveSheetEntityKind.char,
                sections: {
                  for (final s in LiveSheetSection.values) s: <LiveSheetFact>[],
                  LiveSheetSection.conditions: [
                    LiveSheetFact(text: 'a fresh cut on her left forearm'),
                  ],
                },
              ),
            ],
          ),
        ],
        storyBeats: [
          StoryBeat(id: 'b1', text: 'They reach the second Gate by nightfall.'),
        ],
        messages: [
          // message[0] is covered by the checkpoint (anchor 0).
          userMsg('m0', 'covered by recap, should NOT replay'),
          // message[1] mentions "aether" → fires world lorebook entry 1.
          userMsg('m1', 'Do you feel the aether here too?'),
          charMsg('m2', 'Vesna nods, ears flat.'),
        ],
      );

      final inputs = ChatPromptInputs(
        chat: chat,
        character: vesna,
        persona: renPersona,
        preset: null,
        responderId: vesna.id,
        beatsCap: 0,
        lookupCharacter: (id) => id == vesna.id ? vesna : null,
        lookupBook: (id) => id == world.id ? world : null,
        inFlightMessageId: null,
      );

      final result = buildChatPrompt(inputs);

      // ── system turn first, then history, then script ──
      expect(result.turns.first.role, 'system');
      final sys = result.turns.first.content;
      // Fallback system prompt opens with "You are <name>."
      expect(sys, startsWith('You are ${vesna.name}.'));
      // Persona surfaced.
      expect(sys, contains('The user appears as "${renPersona.name}".'));
      // Wave CY.18.216: {{user}}/{{char}} are now substituted GLOBALLY across
      // the whole assembled system block — including INSIDE the persona's
      // dialogue example (which is authored as `{{user}}: "..."`). It must
      // come out as the persona NAME, and NO literal macro may survive
      // anywhere in the system prompt (the bug the Prompt-Lab audit caught:
      // card-authored {{user}}/{{char}} reaching the model literally).
      expect(sys, contains('${renPersona.name}: "...whatever. fine."'));
      expect(sys, isNot(contains('{{user}}')));
      expect(sys, isNot(contains('{{char}}')));
      // Lore inlined (default branch). Constant entry 0 always fires; the
      // "aether" message fires entry 1.
      expect(sys, contains('--- Lore ---'));
      // LTM recap.
      expect(sys, contains('--- Story so far (recap) ---'));
      expect(sys, contains('struck a wary truce'));
      // Live Sheet block.
      expect(sys, contains('a fresh cut on her left forearm'));

      // History: message[0] is recap-covered (skipped); [1] user, [2] char.
      final history =
          result.turns.where((t) => t != result.turns.first).toList();
      // last turn is the Script (system) since beats are present.
      expect(history.last.role, 'system');
      expect(history.last.content, contains('second Gate by nightfall'));
      // The two replayed messages:
      final replayed = history.sublist(0, history.length - 1);
      expect(replayed.length, 2);
      expect(replayed[0].role, 'user');
      expect(replayed[0].content, 'Do you feel the aether here too?');
      expect(replayed[1].role, 'assistant');
      expect(replayed[1].content, 'Vesna nods, ears flat.');
      // The recap-covered message[0] is NOT replayed.
      expect(result.turns.any((t) => t.content.contains('should NOT replay')),
          isFalse);

      // ── segment kinds in order ──
      final kinds = result.segments.map((s) => s.kind).toList();
      expect(kinds, [
        PromptSegmentKind.character,
        PromptSegmentKind.persona,
        PromptSegmentKind.lorebookBefore,
        PromptSegmentKind.ltmRecap,
        PromptSegmentKind.liveSheet,
        // no groupRoster (single char)
        PromptSegmentKind.history,
        PromptSegmentKind.script,
        // no postHistory (no preset)
      ]);
    });
  });

  group('buildChatPrompt — preset path', () {
    test('main prompt + {{wiBefore}} + post-history segments', () {
      final preset = Preset(
        id: 'pr1',
        name: 'Test',
        mainPrompt: 'You play {{char}} for {{user}}. Lore:\n{{wiBefore}}',
        postHistoryInstructions: 'Stay in character as {{char}}.',
      );
      final chat = Chat(
        id: 'c2',
        characterIds: [vesna.id],
        characterSnapshots: {vesna.id: vesna},
        attachedLorebookIds: [world.id],
        messages: [userMsg('m1', 'Tell me about the Vael.')],
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: vesna,
        persona: null,
        preset: preset,
        responderId: vesna.id,
        beatsCap: 0,
        lookupCharacter: (id) => id == vesna.id ? vesna : null,
        lookupBook: (id) => id == world.id ? world : null,
      );

      final result = buildChatPrompt(inputs);
      final sys = result.turns.first.content;
      // Token substitution happened.
      expect(sys, contains('You play ${vesna.name} for You.'));
      // {{wiBefore}} expanded to the fired lore (the "Vael" keyword + the
      // constant entry both fire).
      expect(sys, isNot(contains('{{wiBefore}}')));
      // post-history is the LAST turn, role system, char-name substituted.
      expect(result.turns.last.role, 'system');
      expect(result.turns.last.content, 'Stay in character as ${vesna.name}.');

      final kinds = result.segments.map((s) => s.kind).toList();
      expect(kinds.first, PromptSegmentKind.systemPrompt);
      expect(kinds.contains(PromptSegmentKind.history), isTrue);
      expect(kinds.last, PromptSegmentKind.postHistory);
      // No separate persona/character/lore segments in the preset branch.
      expect(kinds.contains(PromptSegmentKind.persona), isFalse);
      expect(kinds.contains(PromptSegmentKind.lorebookBefore), isFalse);
    });
  });

  group('buildChatPrompt — group roster + inFlight skip', () {
    test('roster lists the other member; in-flight message is skipped', () {
      final other = Character(id: 'cb', name: 'Kael', description: 'A guard.');
      final chat = Chat(
        id: 'c3',
        characterIds: [vesna.id, other.id],
        characterSnapshots: {vesna.id: vesna, other.id: other},
        messages: [
          userMsg('m1', 'hi'),
          charMsg('m2', 'streaming reply in progress'),
        ],
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: vesna,
        persona: null,
        preset: null,
        responderId: vesna.id,
        beatsCap: 0,
        lookupCharacter: (id) => {vesna.id: vesna, other.id: other}[id],
        lookupBook: (_) => null,
        inFlightMessageId: 'm2', // skip the streaming assistant slot
      );
      final result = buildChatPrompt(inputs);
      final sys = result.turns.first.content;
      expect(sys, contains('--- Other characters in this scene ---'));
      expect(sys, contains('Kael'));
      // The in-flight message must NOT be replayed.
      expect(
          result.turns.any((t) => t.content.contains('streaming reply')), isFalse);
      final kinds = result.segments.map((s) => s.kind).toList();
      expect(kinds.contains(PromptSegmentKind.groupRoster), isTrue);
    });
  });

  // ── CREATOR assembly-only builders ───────────────────────────────────
  group('creatorArchitectPrompt — per-mode base selection', () {
    test('character mode uses kCardAssistantPrompt + freeform appendix', () {
      final p = creatorArchitectPrompt(mode: 'character');
      expect(p, contains(kCardAssistantPrompt));
      expect(p, contains(kFreeformModeAppendix));
    });
    test('scenario mode uses kScenarioArchitectPrompt + freeform appendix', () {
      final p = creatorArchitectPrompt(mode: 'scenario');
      expect(p, contains(kScenarioArchitectPrompt));
      expect(p, contains(kFreeformModeAppendix));
    });
    test('edit mode uses kCardEditorFreeFormPrompt, NO freeform appendix', () {
      final p = creatorArchitectPrompt(mode: 'edit');
      expect(p, contains(kCardEditorFreeFormPrompt));
      expect(p, isNot(contains(kFreeformModeAppendix)));
    });
    test('persona mode uses kPersonaArchitectPrompt, NO freeform appendix', () {
      final p = creatorArchitectPrompt(mode: 'persona');
      expect(p, contains(kPersonaArchitectPrompt));
      expect(p, isNot(contains(kFreeformModeAppendix)));
    });
    test('preset override field wins when non-empty', () {
      final p = creatorArchitectPrompt(
        mode: 'character',
        characterPrompt: 'CUSTOM ARCHITECT',
      );
      expect(p, startsWith('CUSTOM ARCHITECT'));
      expect(p, isNot(contains(kCardAssistantPrompt)));
    });
    test('blank override falls back to the shipped const', () {
      final p = creatorArchitectPrompt(mode: 'character', characterPrompt: '   ');
      expect(p, contains(kCardAssistantPrompt));
    });
    test('addendum appended with the USER ADDITIONS framing', () {
      final p = creatorArchitectPrompt(
        mode: 'character',
        addendum: 'Always reply in PT-BR.',
      );
      expect(p, contains('--- USER ADDITIONS'));
      expect(p, contains('Always reply in PT-BR.'));
    });
  });

  group('buildCreatorCanvasStateMessage', () {
    test('empty canvas → empty string', () {
      expect(buildCreatorCanvasStateMessage(const {}, mode: 'character'), '');
    });
    test('filled canvas → status board with filled + empty lists', () {
      final s = buildCreatorCanvasStateMessage(
        {'name': 'Lyra', 'description': 'A ranger.'},
        mode: 'character',
      );
      expect(s, contains('[PYRE RUNTIME — CANVAS STATE]'));
      expect(s, contains('· name:'));
      expect(s, contains('Empty (MUST fill before card-done)'));
      // not edit mode → snippet form, not FIELD envelopes.
      expect(s, isNot(contains('===== FIELD')));
    });
    test('edit mode dumps full FIELD envelopes', () {
      final s = buildCreatorCanvasStateMessage(
        {'name': 'Lyra', 'description': 'A ranger with a long history...'},
        mode: 'edit',
      );
      expect(s, contains('Edit mode.'));
      expect(s, contains('===== FIELD: name ====='));
      expect(s, contains('===== END FIELD: name ====='));
    });
  });

  group('buildCreatorArchitectTurns', () {
    test('assembles [system(architect+canvas), ...conversation]', () {
      final turns = buildCreatorArchitectTurns(
        canvas: {'name': 'Lyra'},
        conversation: const [
          CreatorTurn('user', 'Make me a ranger.'),
          CreatorTurn('assistant', 'Sure — what region?'),
        ],
        mode: 'character',
      );
      expect(turns.first.role, 'system');
      expect(turns.first.content, contains(kCardAssistantPrompt));
      expect(turns.first.content, contains('[PYRE RUNTIME — CANVAS STATE]'));
      expect(turns[1].role, 'user');
      expect(turns[1].content, 'Make me a ranger.');
      expect(turns[2].role, 'assistant');
      expect(turns[2].content, 'Sure — what region?');
    });
    test('empty canvas → system message is the architect prompt alone', () {
      final turns = buildCreatorArchitectTurns(
        canvas: const {},
        conversation: const [CreatorTurn('user', 'hi')],
        mode: 'character',
      );
      // No canvas-state block is APPENDED — the system message equals the
      // resolved architect prompt verbatim. (We can't assert the literal
      // "CANVAS STATE" is absent: the freeform appendix itself references
      // the runtime header in its instructions.)
      expect(turns.first.content,
          creatorArchitectPrompt(mode: 'character'));
    });
    test('trailing user turn appended last', () {
      final turns = buildCreatorArchitectTurns(
        canvas: const {},
        conversation: const [CreatorTurn('user', 'hi')],
        mode: 'character',
        trailingUserTurn: '[Pyre runtime — continuation] resume.',
      );
      expect(turns.last.role, 'user');
      expect(turns.last.content, '[Pyre runtime — continuation] resume.');
    });
    test('systemPromptOverride wins over the per-mode architect', () {
      const override = 'OVERRIDE SYSTEM PROMPT — one-shot.';
      final turns = buildCreatorArchitectTurns(
        canvas: const {},
        conversation: const [CreatorTurn('user', 'hi')],
        mode: 'character',
        systemPromptOverride: override,
      );
      expect(turns.first.content, contains(override));
      expect(turns.first.content, isNot(contains(kCardAssistantPrompt)));
    });
  });

  group('buildCreatorVisionTurns', () {
    const dataUrl = 'data:image/png;base64,AAAA';
    test('two turns: vision prompt + image (no note)', () {
      final turns = buildCreatorVisionTurns(imageDataUrl: dataUrl);
      expect(turns.length, 2);
      expect(turns[0].role, 'system');
      expect(turns[0].content, kImageAnalysisPrompt);
      expect(turns[1].role, 'user');
      expect(turns[1].content, ''); // empty note → empty user text
      expect(turns[1].imageDataUrls, [dataUrl]);
    });
    test('user note is folded into the user text', () {
      final turns =
          buildCreatorVisionTurns(imageDataUrl: dataUrl, userNote: 'her scar');
      expect(turns[1].content, contains('Note from the user'));
      expect(turns[1].content, contains('her scar'));
      expect(turns[1].imageDataUrls, [dataUrl]);
    });
    test('mirrors describeCharacterImage exactly (closed circuit)', () {
      // No architect prompt / conversation / canvas — only the vision
      // prompt + the image, matching image_describe.dart.
      final turns = buildCreatorVisionTurns(imageDataUrl: dataUrl);
      expect(turns.every((t) => t.content != kCardAssistantPrompt), isTrue);
    });
  });
}
