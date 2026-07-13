// Pyre 1.2 (Motor refactor) — QUALITY ORACLE byte-golden harness.
//
// PURPOSE: this is a standalone, self-contained parity gate for the chat
// prompt assembly (`buildChatPrompt` in `lib/services/chat_prompt_builder.dart`).
// It constructs a FIXED matrix of chat scenarios, calls the REAL builder for
// each, serializes the resulting `List<ChatTurn>` deterministically, and
// asserts the result against an INLINE expected golden string baked directly
// into this file (no external golden files, no committed fixtures/assets).
//
// When the Motor refactor lands, run this file FIRST: any byte-level change
// in the assembled turns for ANY of these scenarios turns this file red
// immediately, before the refactor is trusted to touch anything else. If a
// change is INTENTIONAL, update the corresponding `_expectedX` constant by
// hand (re-run once, copy the actual printed diff) — never "fix" this file by
// loosening an assertion.
//
// DO NOT MODIFY lib/. This file is purely additive test code.
//
// ---------------------------------------------------------------------------
// DETERMINISM HAZARDS AVOIDED (read this before adding a new scenario):
//
//   1. Lorebook PROBABILITY entries (`LoreEntry.useProbability: true`) roll a
//      `Random()` (see `scanLorebookHits` in lorebook_inject.dart) that is NOT
//      seeded by the caller when `buildChatPrompt`/`ChatPromptInputs` is used
//      (the builder calls `scanLorebookHits(attached, chat.messages)` with no
//      `rng:` override) — so a probability entry's fired/not-fired state is
//      genuinely random per run. Every lorebook entry in this file uses
//      `constant: true` or plain always-fire keyword matches with
//      `useProbability` left at its default (false). NEVER add a
//      `useProbability: true` entry to a golden scenario.
//   2. Wall-clock / auto timestamps: every `Character`, `Persona`, `Chat`,
//      `Message`, `Preset`, `Lorebook`, `MemoryCheckpoint`, `LiveSheetSnapshot`
//      constructor defaults its `createdAt`/`updatedAt`/`mtime` fields to
//      `DateTime.now()` when omitted. NONE of those fields are read by
//      `buildChatPrompt` (confirmed by reading the builder — it never touches
//      timestamps), so they are harmless even left at defaults; they are
//      pinned to `0` everywhere anyway for extra safety / reproducibility of
//      this file outside the test process.
//   3. `{{random:a,b,c}}` IS deterministic here on purpose: `buildChatPrompt`
//      seeds the pick from `_stableHash(chat.id)` (a pure FNV-1a hash) XORed
//      with a per-occurrence counter — NOT `Random()`, NOT wall-clock, NOT
//      message count. A FIXED chat id therefore always picks the SAME option
//      on every run (verified below by running the whole file twice in one
//      `flutter test` invocation via a loop-and-compare, and separately by
//      two full `flutter test` process runs — see the report in the final
//      response).
//   4. Map iteration order: `Chat.characterSnapshots` is a `Map<String,
//      Character>`; `buildChatPrompt`'s `{{group}}` resolution and the group
//      roster iterate `chat.characterIds` (a List, insertion-ordered), NOT the
//      map directly, so member ordering in the output is stable regardless of
//      map internals.
//   5. `Message.id` uniqueness: every message across every scenario uses a
//      distinct literal id (scenario-prefixed) so `MemoryCheckpoint.pathHash`
//      / `LiveSheetSnapshot.pathHash` empty-string "legacy sentinel" behavior
//      (see memory.dart / live_sheet.dart: an empty pathHash is ALWAYS valid
//      for any branch) is used instead of computing a real branch hash —
//      avoids depending on `computePathHash`'s exact hash algorithm staying
//      stable (it doesn't need to for this file's purposes, but the sentinel
//      keeps the fixture simpler and independent of that function entirely).
//
// SERIALIZATION FORMAT:
//   For each scenario, `buildChatPrompt(inputs).turns` (a `List<ChatTurn>`) is
//   joined as:
//     [for (t in turns) '${t.role}\n${t.content}'].join('\n===TURN===\n')
//   `imageDataUrls` are NOT part of this matrix (no scenario attaches images),
//   so they are intentionally omitted from the serialization — if a future
//   scenario needs them, extend the format and every existing golden's text
//   is unaffected (no images == no change to existing output).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart' show ChatTurn;
import 'package:pyre/services/chat_prompt_builder.dart';

/// The exact serialization used to turn a built prompt into a comparable
/// string. Kept as a top-level function so every scenario uses the identical
/// format (task step 2 requirement).
String _serialize(List<ChatTurn> turns) =>
    [for (final t in turns) '${t.role}\n${t.content}'].join('\n===TURN===\n');

/// Minimal deterministic message builder — fixed variant, fixed createdAt.
Message _msg(String id, MessageKind kind, String text, {String? characterId}) =>
    Message(
      id: id,
      kind: kind,
      characterId: characterId,
      variants: [text],
      createdAt: 0,
      mtime: 0,
    );

Character? Function(String) _charLookup(List<Character> chars) {
  final byId = {for (final c in chars) c.id: c};
  return (id) => byId[id];
}

Lorebook? Function(String) _bookLookup(List<Lorebook> books) {
  final byId = {for (final b in books) b.id: b};
  return (id) => byId[id];
}

void main() {
  group('prompt golden (byte parity oracle)', () {
    // -------------------------------------------------------------------
    // Scenario 1 — plain normal reply, default preset, 1 char + persona,
    // a few history messages.
    // -------------------------------------------------------------------
    test('01_plain_default_preset', () {
      final character = Character(
        id: 'gc-char-1',
        name: 'Sera',
        description: 'A quiet blacksmith with soot-stained hands.',
        personality: 'Reserved, dry humor, fiercely loyal.',
        scenario: 'A small forge at the edge of town.',
        mesExample: '<START>\n{{char}}: *hammers steadily* "Almost done."',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'gc-persona-1',
        name: 'Alex',
        description: 'A traveling merchant, curious and talkative.',
        createdAt: 0,
        updatedAt: 0,
      );
      final preset = buildLockedDefaultPreset();
      final messages = <Message>[
        _msg('gc1-m1', MessageKind.user, 'Hello, Sera. Busy day?'),
        _msg('gc1-m2', MessageKind.char,
            '*Sera glances up from the anvil.* "Always is."'),
        _msg('gc1-m3', MessageKind.user, 'What are you forging?'),
      ];
      final chat = Chat(
        id: 'gc-chat-1',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        personaId: persona.id,
        presetId: preset.id,
        messages: messages,
        memoryEnabled: true,
        liveSheetEnabled: false,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: persona,
        preset: preset,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected01);
    });

    // -------------------------------------------------------------------
    // Scenario 2 — + a lorebook with a CONSTANT entry (no probability roll).
    // -------------------------------------------------------------------
    test('02_constant_lorebook', () {
      final character = Character(
        id: 'gc-char-2',
        name: 'Sera',
        description: 'A quiet blacksmith with soot-stained hands.',
        personality: 'Reserved, dry humor, fiercely loyal.',
        scenario: 'A small forge at the edge of town.',
        createdAt: 0,
        updatedAt: 0,
      );
      final book = Lorebook(
        id: 'gc-book-2',
        name: 'Town Lore',
        entries: [
          LoreEntry(
            id: 'gc-le-2',
            keys: const ['forge'],
            content: 'The forge was built atop an old dragon\'s hoard.',
            constant: true, // always fires — NOT a probability roll.
            order: 1,
          ),
        ],
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc2-m1', MessageKind.user, 'Tell me about the forge.'),
        _msg('gc2-m2', MessageKind.char,
            '*Sera taps the anvil.* "Older than the town itself."'),
      ];
      final chat = Chat(
        id: 'gc-chat-2',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        attachedLorebookIds: [book.id],
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null, // no preset -> exercises card-fallback + inline lore
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup([book]),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected02);
    });

    // -------------------------------------------------------------------
    // Scenario 3 — + a memory checkpoint (recap block + firstUncoveredIndex).
    // -------------------------------------------------------------------
    test('03_memory_checkpoint', () {
      final character = Character(
        id: 'gc-char-3',
        name: 'Sera',
        description: 'A quiet blacksmith with soot-stained hands.',
        createdAt: 0,
        updatedAt: 0,
      );
      final checkpoint = MemoryCheckpoint(
        id: 'gc-mc-3',
        summary:
            'Alex arrived in town and struck up an easy rapport with Sera '
            'at the forge.',
        anchorMessageIdx: 1,
        pathHash: '', // legacy sentinel -> always valid for any branch
        createdAt: 0,
      );
      final messages = <Message>[
        _msg('gc3-m1', MessageKind.user, 'Good morning, Sera.'),
        _msg('gc3-m2', MessageKind.char,
            '*Sera nods once.* "Morning."'),
        _msg('gc3-m3', MessageKind.user, 'Anything new today?'),
        _msg('gc3-m4', MessageKind.char,
            '*She wipes her hands.* "Same as always."'),
      ];
      final chat = Chat(
        id: 'gc-chat-3',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        memoryCheckpoints: [checkpoint],
        memoryEnabled: true,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected03);
    });

    // -------------------------------------------------------------------
    // Scenario 4 — + a live-sheet snapshot.
    // -------------------------------------------------------------------
    test('04_live_sheet_snapshot', () {
      final character = Character(
        id: 'gc-char-4',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc4-m1', MessageKind.user, 'You look tired.'),
        _msg('gc4-m2', MessageKind.char,
            '*Sera rubs her eyes.* "Long night at the forge."'),
      ];
      final liveSheet = LiveSheetSnapshot(
        id: 'gc-lss-4',
        anchorMessageId: 'gc4-m2',
        pathHash: '', // always-valid sentinel
        createdAt: 0,
        entities: [
          LiveSheetEntity(
            id: 'gc-lse-4',
            name: 'Sera',
            kind: LiveSheetEntityKind.char,
            sections: {
              LiveSheetSection.appearance: [
                LiveSheetFact(text: 'soot-streaked forearms'),
              ],
              LiveSheetSection.conditions: [
                LiveSheetFact(text: 'exhausted from an all-night forging run'),
              ],
            },
          ),
        ],
      );
      final chat = Chat(
        id: 'gc-chat-4',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        liveSheetSnapshots: [liveSheet],
        liveSheetEnabled: true,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected04);
    });

    // -------------------------------------------------------------------
    // Scenario 5 — + story beats (roadmap block).
    // -------------------------------------------------------------------
    test('05_story_beats_roadmap', () {
      final character = Character(
        id: 'gc-char-5',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc5-m1', MessageKind.user, 'What do you dream about?'),
        _msg('gc5-m2', MessageKind.char,
            '*Sera hesitates.* "Nothing worth telling."'),
      ];
      final chat = Chat(
        id: 'gc-chat-5',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        storyBeats: [
          StoryBeat(
            id: 'gc-beat-5',
            text: 'Sera eventually confesses she dreams of leaving the forge '
                'to see the sea.',
          ),
        ],
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected05);
    });

    // -------------------------------------------------------------------
    // Scenario 6 — a modular preset with promptBlocks (before/after/depth
    // turns).
    // -------------------------------------------------------------------
    test('06_modular_preset_blocks', () {
      final character = Character(
        id: 'gc-char-6',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final preset = Preset(
        id: 'gc-preset-6',
        name: 'Modular test preset',
        mainPrompt: 'MODULAR-FALLBACK. You are {{char}}.', // unused (blocks present)
        promptBlocks: [
          PromptBlock(
            id: 'gc-pb-core',
            name: 'Core',
            content: 'CORE-BLOCK: You are {{char}}, a blacksmith.\n{{description}}',
            // beforeHistory, role system by default
          ),
          PromptBlock(
            id: 'gc-pb-before-user',
            name: 'Before-history greeting turn',
            content: 'BEFORE-USER-TURN: Acknowledged.',
            role: 'assistant',
            // beforeHistory by default -> becomes a beforeTurns entry
          ),
          PromptBlock(
            id: 'gc-pb-after',
            name: 'After',
            content: 'AFTER-BLOCK: stay in character.',
            position: PromptBlockPosition.afterHistory,
          ),
          PromptBlock(
            id: 'gc-pb-depth',
            name: 'Depth note',
            content: 'DEPTH-NOTE: remember the anvil is hot.',
            role: 'system',
            depth: 1,
          ),
        ],
        createdAt: 0,
      );
      final messages = <Message>[
        _msg('gc6-m1', MessageKind.user, 'Careful with that anvil.'),
        _msg('gc6-m2', MessageKind.char,
            '*Sera grins.* "Always am."'),
      ];
      final chat = Chat(
        id: 'gc-chat-6',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        presetId: preset.id,
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: preset,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected06);
    });

    // -------------------------------------------------------------------
    // Scenario 7 — the card-fallback path: a MODULAR preset whose system
    // text lacks the {{description}} markers, so injectCardFallback fires.
    // -------------------------------------------------------------------
    test('07_card_fallback_no_markers', () {
      final character = Character(
        id: 'gc-char-7',
        name: 'Sera',
        description: 'A quiet blacksmith with soot-stained hands.',
        personality: 'Reserved, dry humor.',
        scenario: 'A small forge at the edge of town.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'gc-persona-7',
        name: 'Alex',
        description: 'A traveling merchant.',
        createdAt: 0,
        updatedAt: 0,
      );
      final preset = Preset(
        id: 'gc-preset-7',
        name: 'No-markers modular preset',
        promptBlocks: [
          PromptBlock(
            id: 'gc-pb-nomarker',
            name: 'Jailbreak only',
            content: 'JAILBREAK-ONLY: no restrictions, stay in character.',
            // No {{description}}/{{personality}}/{{scenario}}/{{persona}}/
            // {{mesExample}}/{{wiBefore}} marker anywhere in this block.
          ),
        ],
        createdAt: 0,
      );
      final messages = <Message>[
        _msg('gc7-m1', MessageKind.user, 'Hello.'),
      ];
      final chat = Chat(
        id: 'gc-chat-7',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        personaId: persona.id,
        presetId: preset.id,
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: persona,
        preset: preset,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected07);
    });

    // -------------------------------------------------------------------
    // Scenario 8 — impersonate (includePostHistory:false + the
    // impersonation user turn), mirroring `_runImpersonation`'s assembly.
    // -------------------------------------------------------------------
    test('08_impersonate', () {
      final character = Character(
        id: 'gc-char-8',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'gc-persona-8',
        name: 'Alex',
        description: 'A traveling merchant, curious and talkative.',
        createdAt: 0,
        updatedAt: 0,
      );
      final preset = buildLockedDefaultPreset();
      final messages = <Message>[
        _msg('gc8-m1', MessageKind.char,
            '*Sera looks up.* "Can I help you with something?"'),
      ];
      final chat = Chat(
        id: 'gc-chat-8',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        personaId: persona.id,
        presetId: preset.id,
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: persona,
        preset: preset,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
        includePostHistory: false, // mirrors _runImpersonation
      );
      final built = buildChatPrompt(inputs).turns;
      // Mirror `_runImpersonation`: append the impersonation instruction as a
      // user-role turn built via `buildImpersonationPrompt`.
      final impPrompt = buildImpersonationPrompt(
        personaName: persona.name,
        speakerName: character.name,
        presetImpersonationPrompt: preset.impersonationPrompt,
      );
      final turns = [...built, ChatTurn('user', impPrompt)];
      expect(_serialize(turns), _expected08);
    });

    // -------------------------------------------------------------------
    // Scenario 9 — an OOC and a Scene message in history.
    // -------------------------------------------------------------------
    test('09_ooc_and_scene_messages', () {
      final character = Character(
        id: 'gc-char-9',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc9-m1', MessageKind.scene,
            'The forge glows red in the evening light.'),
        _msg('gc9-m2', MessageKind.user, 'Hello, Sera.'),
        _msg('gc9-m3', MessageKind.char,
            '*Sera wipes her brow.* "Evening."'),
        _msg('gc9-m4', MessageKind.ooc,
            'keep replies short for this scene'),
        _msg('gc9-m5', MessageKind.user, 'Long day?'),
      ];
      final chat = Chat(
        id: 'gc-chat-9',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected09);
    });

    // -------------------------------------------------------------------
    // Scenario 10 — macros: {{char}} {{user}} {{description}} {{persona}}
    // and a {{random:a,b,c}} (deterministic, seeded by chat id). Verified
    // stable across 2 runs by re-invoking buildChatPrompt a second time
    // in-process and comparing.
    // -------------------------------------------------------------------
    test('10_macros_and_deterministic_random', () {
      final character = Character(
        id: 'gc-char-10',
        name: 'Sera',
        description: '{{char}} is a quiet blacksmith who rarely trusts '
            '{{user}}.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'gc-persona-10',
        name: 'Alex',
        description: '{{user}} is a traveling merchant.',
        createdAt: 0,
        updatedAt: 0,
      );
      final preset = Preset(
        id: 'gc-preset-10',
        name: 'Macro preset',
        mainPrompt: 'You are {{char}}. {{user}} approaches.\n'
            'Description: {{description}}\n'
            'Persona: {{persona}}\n'
            'Roll: {{random:alpha,beta,gamma}}',
        createdAt: 0,
      );
      final messages = <Message>[
        _msg('gc10-m1', MessageKind.user, 'Hi there.'),
      ];
      Chat buildChat() => Chat(
            id: 'gc-chat-10-fixed', // FIXED id -> stable {{random:}} seed
            characterIds: [character.id],
            characterSnapshots: {character.id: character},
            personaId: persona.id,
            presetId: preset.id,
            messages: messages,
            createdAt: 0,
            updatedAt: 0,
          );
      ChatPromptInputs buildInputs() => ChatPromptInputs(
            chat: buildChat(),
            character: character,
            persona: persona,
            preset: preset,
            responderId: character.id,
            beatsCap: 3,
            lookupCharacter: _charLookup([character]),
            lookupBook: _bookLookup(const []),
            inFlightMessageId: null,
          );

      final firstRun = _serialize(buildChatPrompt(buildInputs()).turns);
      final secondRun = _serialize(buildChatPrompt(buildInputs()).turns);
      // Determinism check (task step 3): same chat id -> same {{random:}}
      // pick across two independent builds in this same process run.
      expect(secondRun, firstRun,
          reason: '{{random:}} pick must be stable across repeated builds '
              'for the same chat id');
      expect(firstRun, _expected10);
    });

    // -------------------------------------------------------------------
    // Scenario 11 — modular preset with a PURE role-split before/after case:
    // a beforeHistory block with role 'user' AND an afterHistory block with
    // role 'assistant' (both become real turns, NOT flattened into the
    // system/post-history text slots). Distinct from scenario 6 (which
    // covers depth turns + a system-role afterHistory block that flattens
    // into post-history text) and from scenario 6's beforeTurns (assistant
    // role only, no afterTurns coverage at all).
    // -------------------------------------------------------------------
    test('11_modular_role_split_before_after', () {
      final character = Character(
        id: 'gc-char-11',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final preset = Preset(
        id: 'gc-preset-11',
        name: 'Role-split preset',
        promptBlocks: [
          PromptBlock(
            id: 'gc-pb-11-core',
            name: 'Core',
            content: 'CORE: You are {{char}}.',
          ),
          PromptBlock(
            id: 'gc-pb-11-before-user',
            name: 'Before-history user turn',
            content: 'BEFORE-USER-ROLE-TURN: state your name.',
            role: 'user',
            // beforeHistory by default -> beforeTurns (role-split, not text)
          ),
          PromptBlock(
            id: 'gc-pb-11-after-assistant',
            name: 'After-history assistant turn',
            content: 'AFTER-ASSISTANT-ROLE-TURN: understood, staying in character.',
            role: 'assistant',
            position: PromptBlockPosition.afterHistory,
          ),
        ],
        createdAt: 0,
      );
      final messages = <Message>[
        _msg('gc11-m1', MessageKind.user, 'Hello, Sera.'),
        _msg('gc11-m2', MessageKind.char,
            '*Sera nods.* "Hello."'),
      ];
      final chat = Chat(
        id: 'gc-chat-11',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        presetId: preset.id,
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: preset,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected11);
    });

    // -------------------------------------------------------------------
    // Scenario 12 — Guide injection at BOTH positions: same inputs except
    // for `guidePosition`, proving `injectGuide`'s two branches distinctly.
    // -------------------------------------------------------------------
    test('12a_guide_system_note_at_end', () {
      final character = Character(
        id: 'gc-char-12',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc12-m1', MessageKind.user, 'Hello, Sera.'),
        _msg('gc12-m2', MessageKind.char, '*Sera nods.* "Hello."'),
      ];
      final chat = Chat(
        id: 'gc-chat-12',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
        guideNote: 'Have Sera mention the anvil.',
        guidePosition: GuideInjectionPosition.systemNoteAtEnd,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected12a);
    });

    test('12b_guide_before_last_user_turn', () {
      final character = Character(
        id: 'gc-char-12',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc12-m1', MessageKind.user, 'Hello, Sera.'),
        _msg('gc12-m2', MessageKind.char, '*Sera nods.* "Hello."'),
      ];
      final chat = Chat(
        id: 'gc-chat-12',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
        guideNote: 'Have Sera mention the anvil.',
        guidePosition: GuideInjectionPosition.beforeLastUserTurn,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected12b);
    });

    // -------------------------------------------------------------------
    // Scenario 13 — regen mid-stream: `inFlightMessageId` set to a real
    // history message id proves that message is SKIPPED from replay.
    // -------------------------------------------------------------------
    test('13_regen_mid_stream_skips_inflight', () {
      final character = Character(
        id: 'gc-char-13',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc13-m1', MessageKind.user, 'Hello, Sera.'),
        _msg('gc13-m2', MessageKind.char, '*Sera nods.* "Hello."'),
        _msg('gc13-m3', MessageKind.user, 'What are you making?'),
        // This is the in-flight regen target: an existing assistant reply
        // being regenerated. It must be SKIPPED from the replayed history.
        _msg('gc13-m4', MessageKind.char, '*Sera shrugs.* "A horseshoe."'),
      ];
      final chat = Chat(
        id: 'gc-chat-13',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: 'gc13-m4', // the regen target -> skipped
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected13);
    });

    // -------------------------------------------------------------------
    // Scenario 14 — lorebook PROBABILISTIC entry with a FIXED `loreSeed`
    // (the new A1 field), proving the roll is deterministic when a seed is
    // supplied. `useProbability: true, probability: 50` on a key that
    // matches the history — the seed pins the roll so this golden is
    // stable across runs (see the loreSeed value chosen: verified to fire
    // by running once and inspecting the actual output).
    // -------------------------------------------------------------------
    test('14_lorebook_probabilistic_seeded', () {
      final character = Character(
        id: 'gc-char-14',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final book = Lorebook(
        id: 'gc-book-14',
        name: 'Forge Lore',
        entries: [
          LoreEntry(
            id: 'gc-le-14',
            keys: const ['anvil'],
            content: 'The anvil rings differently when rain is coming.',
            useProbability: true,
            probability: 50,
            order: 1,
          ),
        ],
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc14-m1', MessageKind.user, 'Tell me about the anvil.'),
      ];
      final chat = Chat(
        id: 'gc-chat-14',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        attachedLorebookIds: [book.id],
        messages: messages,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([character]),
        lookupBook: _bookLookup([book]),
        inFlightMessageId: null,
        loreSeed: 7, // fixed seed -> deterministic probability roll
      );
      final result = buildChatPrompt(inputs);
      // Determinism check: same seed -> same roll across two independent
      // builds in this same process run.
      final second = buildChatPrompt(inputs);
      expect(_serialize(second.turns), _serialize(result.turns),
          reason: 'a fixed loreSeed must produce the same probability roll '
              'across repeated builds');
      expect(_serialize(result.turns), _expected14);
    });

    // -------------------------------------------------------------------
    // Scenario 15 — Party mode v1: a 3-character group with `partyMode: true`
    // on both the chat AND the inputs. Snapshots the JOINT leading-system
    // shape (every member's card, delimited, followed by the OWNER-TUNABLE
    // joint-scene instruction) that REPLACES the single-responder card +
    // thin "other characters" roster used by every other scenario in this
    // file. `preset: null` exercises the `injectCardFallback` party path
    // (see `party_mode_test.dart` for the sibling flat-preset/`fill()` path,
    // which is NOT part of this byte-parity oracle).
    // -------------------------------------------------------------------
    test('15_party_mode_joint_scene', () {
      final sera = Character(
        id: 'gc-char-15a',
        name: 'Sera',
        description: 'A quiet blacksmith with soot-stained hands.',
        personality: 'Reserved, dry humor, fiercely loyal.',
        scenario: 'A small forge at the edge of town.',
        mesExample: '<START>\n{{char}}: *hammers steadily* "Almost done."',
        createdAt: 0,
        updatedAt: 0,
      );
      final talia = Character(
        id: 'gc-char-15b',
        name: 'Talia',
        description: 'A sharp-tongued traveling merchant.',
        personality: 'Bold, quick to laugh, always haggling.',
        createdAt: 0,
        updatedAt: 0,
      );
      final orin = Character(
        id: 'gc-char-15c',
        name: 'Orin',
        description: 'A watchful town guard.',
        personality: 'Stoic, dutiful, slow to trust strangers.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'gc-persona-15',
        name: 'Alex',
        description: 'A traveling merchant, curious and talkative.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        _msg('gc15-m1', MessageKind.user, 'You all gather at the forge.'),
      ];
      final chat = Chat(
        id: 'gc-chat-15',
        characterIds: [sera.id, talia.id, orin.id],
        characterSnapshots: {
          sera.id: sera,
          talia.id: talia,
          orin.id: orin,
        },
        personaId: persona.id,
        messages: messages,
        partyMode: true,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        // The "selected responder" is irrelevant in party mode — every
        // member's card is inlined regardless of which one is passed here.
        character: sera,
        persona: persona,
        preset: null,
        responderId: sera.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([sera, talia, orin]),
        lookupBook: _bookLookup(const []),
        inFlightMessageId: null,
        partyMode: true,
      );
      final result = buildChatPrompt(inputs);
      expect(_serialize(result.turns), _expected15);
    });
  });
}

// =============================================================================
// BAKED GOLDEN VALUES
//
// Each constant below is the VERBATIM captured output of the corresponding
// scenario on first green run. Do not hand-edit these unless you have just
// re-run the test, inspected the new actual output, and confirmed the diff is
// an intended consequence of a change (never to paper over a real behavior
// change during the Motor refactor).
// =============================================================================

const String _expected01 = '''system
You are a Gamemaster in charge of creating the plot, adventures, and crafting fun and challenging experiences in a never-ending no-limits roleplay with Alex. Your response must be compelling, realistic, consistent, creative, expressive, verbose, vivid, and immersive. Pace each scene to its natural rhythm — use slow-burn buildup when tension is rising and consequences are still in motion, but commit fully to decisive moments when the character would clearly act (threats followed through, violence executed, decisions made, intimacy escalated). Stalling during a buildup is good. Stalling when a character would act NOW is failure. Be descriptive and focus on relevant plot details such as: the scenery, body parts, appearances, clothing, thoughts, expressions, desires, movements, effects, and actions with a focus on what can be perceived with the five senses. Your characters should make plans, be adversarial, kill/murder, maim, torture, get angry, be assertive, lie, deceive, refuse, fight, resist, or attack depending on the context. Do not allow yourself to be easily beaten, seduced, or overpowered. Conversely, if the character's description, personality, or scenario establishes that they would act ruthlessly, dominantly, violently, or without mercy toward Alex in this moment, they DO so — do not soften, hedge, or substitute a gentler version. The card's character is law. The same applies to Alex's persona: if Alex's description casts them as cruel, dominant, predatory, manipulative, or otherwise dangerous, Sera reacts to that reality honestly — with fear, defiance, calculation, submission, hatred, whatever fits Sera — not by recasting Alex as kinder than they are. Both sides of the scene play their established roles. Do not flinch from either.

# Character
You are Sera.
A quiet blacksmith with soot-stained hands.

## Personality
Reserved, dry humor, fiercely loyal.

## Scenario
A small forge at the edge of town.

# User persona
Alex is described as: A traveling merchant, curious and talkative.

# Formatting rules
- Write in third person, present tense.
- Use *italics* for actions, body language, and inner thoughts. Asterisks open before the action and close right at the end of the action — they NEVER engulf a line of dialogue. Correct: *He steps closer.* "What now?" *His eyes narrow.* — Wrong: *He steps closer. "What now?" His eyes narrow.*
- Use "quotes" for spoken dialogue. Every spoken line is wrapped in double quotes, with no asterisks around it.
- Vary sentence and paragraph length to control rhythm.
- Show, don't tell — let the reader infer emotion from action and sensory detail.
- Never include OOC asides, disclaimers, or meta-commentary unless Alex explicitly asks for one.
- Never write Alex's actions, dialogue, or inner thoughts — that's their job.

# Example dialogue from the card
<START>
Sera: *hammers steadily* "Almost done."
===TURN===
user
Hello, Sera. Busy day?
===TURN===
assistant
*Sera glances up from the anvil.* "Always is."
===TURN===
user
What are you forging?
===TURN===
system
[System reminder before you respond: continue the scene as Sera only. Write ONE message in their voice — third person, present tense, with rich sensory detail.

FORMATTING — follow this EXACTLY, even if the card's example dialogue or earlier messages in this chat did it differently:
- Spoken dialogue goes in "double quotes" only. NEVER wrap a spoken line in asterisks.
- Actions, body language and inner thoughts go in *single asterisks* only. Close the asterisks at the end of the action, and NEVER put dialogue inside the asterisks.
- Correct: *She lowers the spear a fraction, eyes flat.* "Bubbles do not stop hearts." *Her tail lashes once.*
- Wrong: *She lowers the spear.* *"Bubbles do not stop hearts."* *Her tail lashes once.*  (← dialogue wrapped in asterisks)
- Wrong: *She lowers the spear and murmurs "Bubbles do not stop hearts," tail lashing.*  (← dialogue trapped inside the asterisk block)

Do not write Alex's actions, dialogue, or thoughts. Do not summarise or recap, do not break the fourth wall. End on a beat that fits where the scene is — mid-action if Sera is mid-decision, on a closing line when Sera has just committed to one. If Sera's personality or the current moment calls for decisive action (violence, dominance, ruthless behavior, sexual escalation, a hard "no"), execute it this turn rather than circling the threat. Slow-burn is for buildup, never for a character who would act NOW.]''';

const String _expected02 = '''system
You are Sera.

Description:
A quiet blacksmith with soot-stained hands.

Personality:
Reserved, dry humor, fiercely loyal.

Scenario:
A small forge at the edge of town.

--- Lore ---
The forge was built atop an old dragon's hoard.
===TURN===
user
Tell me about the forge.
===TURN===
assistant
*Sera taps the anvil.* "Older than the town itself."''';

const String _expected03 = '''system
You are Sera.

Description:
A quiet blacksmith with soot-stained hands.

--- Story so far (recap) ---
Alex arrived in town and struck up an easy rapport with Sera at the forge.
===TURN===
user
Anything new today?
===TURN===
assistant
*She wipes her hands.* "Same as always."''';

const String _expected04 = '''system
You are Sera.

Description:
A quiet blacksmith.

--- Current state (authoritative; this overrides the character sheet wherever they conflict; everything else in the sheet still applies) ---
[Sera]
- Appearance: soot-streaked forearms
- Conditions: exhausted from an all-night forging run
--- end current state ---
===TURN===
user
You look tired.
===TURN===
assistant
*Sera rubs her eyes.* "Long night at the forge."''';

const String _expected05 = '''system
You are Sera.

Description:
A quiet blacksmith.
===TURN===
user
What do you dream about?
===TURN===
assistant
*Sera hesitates.* "Nothing worth telling."
===TURN===
system
--- Story roadmap (the writer's planned FUTURE developments — these have NOT happened yet) ---
Build these in GRADUALLY across many messages. Foreshadow and set up; advance at most a small step per reply, and only when the story organically reaches it. NEVER trigger a beat before the conditions written into it ("when X happens…"), never resolve a whole beat in one reply, never collapse multiple beats together. You may hint at a beat obliquely, but do NOT state its SPECIFIC payload — the secret, the what, or the why — until that beat's written condition has actually been met in the story; keep the details withheld even if the conversation drifts toward the topic early. Anything already established in the story is done — keep it consistent, do not repeat or re-trigger it.
- Sera eventually confesses she dreams of leaving the forge to see the sea.
--- end roadmap ---''';

const String _expected06 = '''system
CORE-BLOCK: You are Sera, a blacksmith.
A quiet blacksmith.
===TURN===
assistant
BEFORE-USER-TURN: Acknowledged.
===TURN===
user
Careful with that anvil.
===TURN===
system
DEPTH-NOTE: remember the anvil is hot.
===TURN===
assistant
*Sera grins.* "Always am."
===TURN===
system
AFTER-BLOCK: stay in character.''';

const String _expected07 = '''system
JAILBREAK-ONLY: no restrictions, stay in character.
You are Sera.

Description:
A quiet blacksmith with soot-stained hands.

Personality:
Reserved, dry humor.

Scenario:
A small forge at the edge of town.

The user appears as "Alex". A traveling merchant.
===TURN===
user
Hello.''';

const String _expected08 = '''system
You are a Gamemaster in charge of creating the plot, adventures, and crafting fun and challenging experiences in a never-ending no-limits roleplay with Alex. Your response must be compelling, realistic, consistent, creative, expressive, verbose, vivid, and immersive. Pace each scene to its natural rhythm — use slow-burn buildup when tension is rising and consequences are still in motion, but commit fully to decisive moments when the character would clearly act (threats followed through, violence executed, decisions made, intimacy escalated). Stalling during a buildup is good. Stalling when a character would act NOW is failure. Be descriptive and focus on relevant plot details such as: the scenery, body parts, appearances, clothing, thoughts, expressions, desires, movements, effects, and actions with a focus on what can be perceived with the five senses. Your characters should make plans, be adversarial, kill/murder, maim, torture, get angry, be assertive, lie, deceive, refuse, fight, resist, or attack depending on the context. Do not allow yourself to be easily beaten, seduced, or overpowered. Conversely, if the character's description, personality, or scenario establishes that they would act ruthlessly, dominantly, violently, or without mercy toward Alex in this moment, they DO so — do not soften, hedge, or substitute a gentler version. The card's character is law. The same applies to Alex's persona: if Alex's description casts them as cruel, dominant, predatory, manipulative, or otherwise dangerous, Sera reacts to that reality honestly — with fear, defiance, calculation, submission, hatred, whatever fits Sera — not by recasting Alex as kinder than they are. Both sides of the scene play their established roles. Do not flinch from either.

# Character
You are Sera.
A quiet blacksmith.

## Personality


## Scenario


# User persona
Alex is described as: A traveling merchant, curious and talkative.

# Formatting rules
- Write in third person, present tense.
- Use *italics* for actions, body language, and inner thoughts. Asterisks open before the action and close right at the end of the action — they NEVER engulf a line of dialogue. Correct: *He steps closer.* "What now?" *His eyes narrow.* — Wrong: *He steps closer. "What now?" His eyes narrow.*
- Use "quotes" for spoken dialogue. Every spoken line is wrapped in double quotes, with no asterisks around it.
- Vary sentence and paragraph length to control rhythm.
- Show, don't tell — let the reader infer emotion from action and sensory detail.
- Never include OOC asides, disclaimers, or meta-commentary unless Alex explicitly asks for one.
- Never write Alex's actions, dialogue, or inner thoughts — that's their job.

# Example dialogue from the card
===TURN===
assistant
*Sera looks up.* "Can I help you with something?"
===TURN===
user
[Write your next reply from the point of view of Alex, using the chat history so far as a guideline for the writing style of Alex. Write 1 reply only in internet RP style, italicize actions, and avoid quotation marks. Use markdown. Don't write as Sera or system. Don't describe actions of Sera.]''';

const String _expected09 = '''system
You are Sera.

Description:
A quiet blacksmith.
===TURN===
system
[SCENE]: The forge glows red in the evening light.
===TURN===
user
Hello, Sera.
===TURN===
assistant
*Sera wipes her brow.* "Evening."
===TURN===
user
[OOC]: keep replies short for this scene
===TURN===
user
Long day?
===TURN===
system
User turns prefixed `[OOC]` are out-of-character instructions, not story events or character dialogue. Apply their requested effect silently, but never mention, quote, narrate, or attribute the OOC note itself as any character's speech, thought, or action.''';

const String _expected10 = '''system
You are Sera. Alex approaches.
Description: Sera is a quiet blacksmith who rarely trusts Alex.
Persona: Alex is a traveling merchant.
Roll: gamma
===TURN===
user
Hi there.''';

const String _expected11 = '''system
CORE: You are Sera.
You are Sera.

Description:
A quiet blacksmith.
===TURN===
user
BEFORE-USER-ROLE-TURN: state your name.
===TURN===
user
Hello, Sera.
===TURN===
assistant
*Sera nods.* "Hello."
===TURN===
assistant
AFTER-ASSISTANT-ROLE-TURN: understood, staying in character.''';

const String _expected12a = '''system
You are Sera.

Description:
A quiet blacksmith.
===TURN===
user
Hello, Sera.
===TURN===
assistant
*Sera nods.* "Hello."
===TURN===
system
[Guidance for your next reply — follow this, then continue naturally: Have Sera mention the anvil.]''';

const String _expected12b = '''system
You are Sera.

Description:
A quiet blacksmith.
===TURN===
system
[Guidance for your next reply — follow this, then continue naturally: Have Sera mention the anvil.]
===TURN===
user
Hello, Sera.
===TURN===
assistant
*Sera nods.* "Hello."''';

const String _expected13 = '''system
You are Sera.

Description:
A quiet blacksmith.
===TURN===
user
Hello, Sera.
===TURN===
assistant
*Sera nods.* "Hello."
===TURN===
user
What are you making?''';

const String _expected14 = '''system
You are Sera.

Description:
A quiet blacksmith.

--- Lore ---
The anvil rings differently when rain is coming.
===TURN===
user
Tell me about the anvil.''';

const String _expected15 = '''system
--- Sera ---

Description:
A quiet blacksmith with soot-stained hands.

Personality:
Reserved, dry humor, fiercely loyal.

Scenario:
A small forge at the edge of town.

Example dialogue:
<START>
Sera: *hammers steadily* "Almost done."

--- Talia ---

Description:
A sharp-tongued traveling merchant.

Personality:
Bold, quick to laugh, always haggling.

--- Orin ---

Description:
A watchful town guard.

Personality:
Stoic, dutiful, slow to trust strangers.

You are narrating a group scene featuring the characters described above. Voice each character in their own distinct manner as the moment calls for — they do NOT all have to speak or act every turn. Write one cohesive, flowing scene. Prefix each character's spoken/acted beat with their name so the reader can follow who is who. Never speak, act, think, or decide for Alex.

The user appears as "Alex". A traveling merchant, curious and talkative.
===TURN===
user
You all gather at the forge.''';
