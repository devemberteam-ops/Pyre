// Wave CY.18.211 (Prompt Observability — `inspect` harness): the FIXTURE
// builders for the prompt-lab harness.
//
// Each builder returns a fully-resolved set of inputs for the pure prompt
// assembly (`buildChatPrompt` / the Creator turn builders in
// `chat_prompt_builder.dart`) constructed from the BUNDLED EXAMPLE CARDS
// (`assets/examples/{ren,vesna,world,scenario}.json`). NO AppStore, NO
// Flutter bindings, NO model — the example JSON is read straight off disk
// via `dart:io` (mirrors `test/example_seed_test.dart`), so a fixture can
// be built under either `flutter test` or a plain `dart run`.
//
// DETERMINISM: the chat fixtures use FIXED-LENGTH message lists so the
// `{{random:a,b,c}}` resolver (seeded off `chat.messages.length + s.length`
// inside `buildChatPrompt`) picks the SAME option on every run. This keeps
// the dumped reports / future goldens stable.

import 'dart:convert';
import 'dart:io';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart' show ChatTurn;
import 'package:pyre/services/chat_prompt_builder.dart';
import 'package:pyre/services/creator_build_prompts.dart' show buildBatchTurns;
import 'package:pyre/services/creator_render.dart' show renderCard;
import 'package:pyre/services/creator_schema.dart'
    show CreatorMode, batchesFor;
import 'package:pyre/services/regex_rules.dart'
    show RegexRule, RegexStream;

// ---------------------------------------------------------------------------
// Example-card loading (off disk — binding-free)
// ---------------------------------------------------------------------------

/// Root of the bundled example assets, relative to the package root (the
/// cwd under `flutter test` / `dart run` from `flutter_app/`).
const _examplesDir = 'assets/examples';

Map<String, dynamic> _readAssetJson(String fileName) {
  final file = File('$_examplesDir/$fileName');
  if (!file.existsSync()) {
    throw StateError(
      'Missing bundled example asset: ${file.absolute.path}. '
      'Run the harness from the flutter_app/ package root.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// The four bundled example records, parsed once via the NATIVE Pyre
/// fromJson (NOT the chara_card_v2 path — that would hollow them).
class ExampleCards {
  final Character ren; // 21yo isekai'd femboy NEET (char + persona source)
  final Character vesna; // wolfkin delver, bound to the world lore
  final Character scenario; // "The Sunken Gate" narrator card
  final Lorebook world; // "The Vael — World Lore"
  const ExampleCards({
    required this.ren,
    required this.vesna,
    required this.scenario,
    required this.world,
  });

  static ExampleCards load() => ExampleCards(
        ren: Character.fromJson(_readAssetJson('ren.json')),
        vesna: Character.fromJson(_readAssetJson('vesna.json')),
        scenario: Character.fromJson(_readAssetJson('scenario.json')),
        world: Lorebook.fromJson(_readAssetJson('world.json')),
      );
}

// ---------------------------------------------------------------------------
// Scenario descriptors
// ---------------------------------------------------------------------------

/// A chat-assembly scenario: a stable [id] + the resolved [ChatPromptInputs].
class ChatScenario {
  final String id;
  final String description;
  final ChatPromptInputs inputs;
  const ChatScenario(this.id, this.description, this.inputs);
}

/// A Creator-assembly scenario: a stable [id] + the assembled turns it should
/// dump. The turns are built eagerly (pure, no model) by the builder below.
///
/// Wave CY.18.233: the architect/marker cascade was replaced by a deterministic
/// structured-JSON pipeline. The Creator scenarios now build the FIRST batch's
/// structured request via `buildBatchTurns` (a representative, reviewable dump)
/// AND attach the deterministic `renderCard` output of a known fixture field
/// map as a trailing synthetic `render` turn, so the golden shows BOTH the
/// structured request AND what Pyre renders from a field map.
///
/// [mode] + [fields] are carried so LIVE mode can score a real reply via the
/// renderer's signal (`missingRequired(fields, mode).isEmpty` / a non-empty
/// rendered Description) over the SAME fixture field map the render turn used.
/// They are null for vision (no field-map notion there).
class CreatorScenario {
  final String id;
  final String description;
  final List<ChatTurn> turns;
  final CreatorMode? mode;
  final Map<String, dynamic>? fields;
  const CreatorScenario(
    this.id,
    this.description,
    this.turns, {
    this.mode,
    this.fields,
  });
}

// ---------------------------------------------------------------------------
// Shared fixture helpers
// ---------------------------------------------------------------------------

/// A small lookup-by-id closure over a fixed character list (stands in for
/// `store.characterById`). Snapshots are consulted first AT each call site
/// inside `buildChatPrompt`, exactly as in production.
Character? Function(String) _charLookup(List<Character> chars) {
  final byId = {for (final c in chars) c.id: c};
  return (id) => byId[id];
}

Lorebook? Function(String) _bookLookup(List<Lorebook> books) {
  final byId = {for (final b in books) b.id: b};
  return (id) => byId[id];
}

/// Build a deterministic chat message (single fixed variant, stable id).
Message _msg(String id, MessageKind kind, String text, {String? characterId}) =>
    Message(
      id: id,
      kind: kind,
      characterId: characterId,
      variants: [text],
      createdAt: 0, // fixed so reports never churn on timestamps
    );

// ---------------------------------------------------------------------------
// CHAT scenarios
// ---------------------------------------------------------------------------

/// **chat_single** — Vesna as the responder, Ren-as-persona on the user
/// side, an LTM checkpoint, a Live Sheet snapshot, a Script beat, and the
/// shared world lorebook attached. A user message mentions "Gate" so the
/// keyed world entry fires (the overview entry is `constant` and always
/// fires regardless).
ChatScenario buildChatSingle(ExampleCards ex) {
  // Ren becomes the user's persona for this scene (the canonical pairing).
  final persona = Persona(
    id: 'pl-persona-ren',
    name: 'Ren',
    description:
        'A clueless Outsider, recently spat out of the Sunken Gate — '
        'soft-spoken, anxious, secretly keeping his head above water in '
        'Aldermere by doing odd jobs.',
    dialogueExamples:
        '<START>\n{{user}}: "...okay. Okay. I can do this." *He does not '
        'look like he can do this.*',
    createdAt: 0,
    updatedAt: 0,
  );

  final messages = <Message>[
    _msg('pl-m1', MessageKind.user,
        'I edge toward the cold breath coming up out of the Gate. "What '
        'IS that down there?"'),
    _msg('pl-m2', MessageKind.char,
        '*Vesna catches my sleeve.* "The Maw doesn\'t answer questions. It '
        'just takes."'),
    _msg('pl-m3', MessageKind.ooc,
        'keep Vesna wary but not unkind here'),
    _msg('pl-m4', MessageKind.user,
        '"Then why are we standing at the edge of it?"'),
  ];

  // An LTM checkpoint covering messages [0..1]. Empty pathHash = legacy
  // sentinel, treated as ALWAYS valid for any branch (so the recap and the
  // history-window start at index 2 deterministically).
  final checkpoint = MemoryCheckpoint(
    id: 'pl-mc1',
    summary:
        'Vesna found {{user}} dazed at the foot of the Sunken Gate and, '
        'against her better judgement, decided not to leave them to the '
        'jungle. They have edged together toward the Maw\'s cold throat.',
    anchorMessageIdx: 1,
    pathHash: '',
    createdAt: 0,
  );

  // A Live Sheet snapshot with two entities, a couple of facts each.
  final liveSheet = LiveSheetSnapshot(
    id: 'pl-lss1',
    anchorMessageId: 'pl-m4',
    pathHash: '', // always-valid sentinel (mirrors the LTM convention)
    createdAt: 0,
    entities: [
      LiveSheetEntity(
        id: 'pl-lse-ren',
        name: 'Ren',
        kind: LiveSheetEntityKind.user,
        sections: {
          LiveSheetSection.appearance: [
            LiveSheetFact(text: 'short, slight, dark hair'),
          ],
          LiveSheetSection.clothing: [
            LiveSheetFact(text: 'oversized skull hoodie, no trousers'),
          ],
          LiveSheetSection.conditions: [
            LiveSheetFact(text: 'shivering in the Gate-cold'),
          ],
        },
      ),
      LiveSheetEntity(
        id: 'pl-lse-vesna',
        name: 'Vesna',
        kind: LiveSheetEntityKind.char,
        sections: {
          LiveSheetSection.appearance: [
            LiveSheetFact(text: 'sun-dark tan, white-tipped tail', locked: true),
          ],
          LiveSheetSection.possessions: [
            LiveSheetFact(text: 'coil of delver rope, antivenom'),
          ],
        },
      ),
    ],
  );

  final chat = Chat(
    id: 'pl-chat-single',
    characterIds: [ex.vesna.id],
    characterSnapshots: {ex.vesna.id: ex.vesna},
    personaId: persona.id,
    attachedLorebookIds: [ex.world.id],
    messages: messages,
    memoryCheckpoints: [checkpoint],
    memoryEnabled: true,
    liveSheetSnapshots: [liveSheet],
    liveSheetEnabled: true,
    storyBeats: [
      StoryBeat(
        id: 'pl-beat1',
        text:
            'When {{user}} finally trusts Vesna, she admits the Charter sent '
            'her to map the Maw, not to rescue strays.',
      ),
    ],
    createdAt: 0,
    updatedAt: 0,
  );

  final inputs = ChatPromptInputs(
    chat: chat,
    character: ex.vesna,
    persona: persona,
    preset: null, // no preset → exercises the fallback system-prompt branch
    responderId: ex.vesna.id,
    beatsCap: 3,
    lookupCharacter: _charLookup([ex.vesna, ex.ren]),
    lookupBook: _bookLookup([ex.world]),
    inFlightMessageId: null,
  );

  return ChatScenario(
    'chat_single',
    'Single-char chat (Vesna responder, Ren persona) with LTM recap, Live '
        'Sheet, Script beat, and the world lorebook (constant + keyed hits).',
    inputs,
  );
}

/// **chat_group** — a 2-character scene (Vesna + Ren-as-character). Exercises
/// the group-roster segment + `{{group}}` resolution. A preset with a
/// `{{group}}`-bearing main prompt is supplied so the roster + template
/// resolution both show up in the dump.
ChatScenario buildChatGroup(ExampleCards ex) {
  final preset = Preset(
    id: 'pl-preset-group',
    name: 'Prompt Lab — Group',
    mainPrompt:
        'You are {{char}}. This is a group scene with: {{group}}. Stay in '
        'character; let others speak for themselves.\n\n{{description}}',
    postHistoryInstructions:
        '[Reminder: write only {{char}}\'s next reply. {{random:Keep it '
        'grounded.,Let the jungle press in.}}]',
    createdAt: 0,
  );

  final messages = <Message>[
    _msg('pl-g1', MessageKind.user,
        'I look between the two of you. "So neither of you is from... here, '
        'exactly?"'),
    _msg('pl-g2', MessageKind.char,
        '*Vesna\'s ear flicks.* "I\'m Vekhi-blooded, not Vael-born. Close '
        'enough they spit on me in Aldermere."',
        characterId: ex.vesna.id),
    _msg('pl-g3', MessageKind.char,
        '*Ren laughs, thin and nervous.* "I fell out of the sky. Does that '
        'count?"',
        characterId: ex.ren.id),
  ];

  final chat = Chat(
    id: 'pl-chat-group',
    characterIds: [ex.vesna.id, ex.ren.id],
    characterSnapshots: {ex.vesna.id: ex.vesna, ex.ren.id: ex.ren},
    personaId: null,
    presetId: preset.id,
    messages: messages,
    createdAt: 0,
    updatedAt: 0,
  );

  final inputs = ChatPromptInputs(
    chat: chat,
    character: ex.vesna, // Vesna is the responder for this turn
    persona: null,
    preset: preset,
    responderId: ex.vesna.id,
    beatsCap: 3,
    lookupCharacter: _charLookup([ex.vesna, ex.ren]),
    lookupBook: _bookLookup([ex.world]),
    inFlightMessageId: null,
  );

  return ChatScenario(
    'chat_group',
    'Group chat (Vesna + Ren) with a preset main-prompt that uses {{group}} '
        '+ {{random:}}, exercising the group-roster segment.',
    inputs,
  );
}

// ---------------------------------------------------------------------------
// Pyre 1.1 prompt-feature scenarios (F1 / F3 / F4 / F6)
// ---------------------------------------------------------------------------
//
// Each of these layers ONE 1.1 feature on top of the same bundled-fixture
// shape used by `chat_single`, so the inspect dump isolates exactly what the
// feature changes in the assembled prompt. The message arrays are FIXED length
// (determinism), the LTM checkpoint uses the empty-pathHash legacy sentinel
// (always-valid), and lookups reuse the example cards.

/// Unique sentinel strings used by the 1.1 scenarios so the inspect assertions
/// can grep for an exact, collision-free phrase.
const _kSummarySentinel =
    'RECAP-SENTINEL: Ren and Vesna reached the Maw and made a fragile truce.';
const _kLoreEntryContent =
    'LORE-SENTINEL: The Maw at the bottom of the Gate exhales raw aether that '
    'warps anything it touches.';

/// **chat_summary_macro** (F1) — a chat WITH an LTM recap and a preset whose
/// mainPrompt embeds `{{summary}}`. Goal at inspect: the recap text appears
/// EXACTLY ONCE (at the macro position inside the system prompt) and the
/// hardcoded "--- Story so far (recap) ---" block is NOT separately emitted.
ChatScenario buildChatSummaryMacro(ExampleCards ex) {
  // A checkpoint with a LITERAL summary (no {{user}}/{{char}} macros) so the
  // recap text is byte-stable through the final name-fill pass — the
  // assertion can match it verbatim.
  final checkpoint = MemoryCheckpoint(
    id: 'pl-sm-mc1',
    summary: _kSummarySentinel,
    anchorMessageIdx: 1,
    pathHash: '', // legacy sentinel → always valid
    createdAt: 0,
  );

  final messages = <Message>[
    _msg('pl-sm-m1', MessageKind.user, 'We made it. Barely.'),
    _msg('pl-sm-m2', MessageKind.char,
        '*Vesna nods, jaw tight.* "Barely is still alive. Move."'),
    _msg('pl-sm-m3', MessageKind.user, '"Where to now?"'),
  ];

  final preset = Preset(
    id: 'pl-preset-summary',
    name: 'Prompt Lab — Summary Macro',
    // The {{summary}} macro is embedded mid-prompt so the inspect dump shows
    // the recap injected AT that spot (not at the default hardcoded position).
    mainPrompt: 'You are {{char}}, a wary delver.\n\n'
        'Story so far: {{summary}}\n\n'
        'Stay in character and keep the scene moving.',
    createdAt: 0,
  );

  final chat = Chat(
    id: 'pl-chat-summary',
    characterIds: [ex.vesna.id],
    characterSnapshots: {ex.vesna.id: ex.vesna},
    presetId: preset.id,
    messages: messages,
    memoryCheckpoints: [checkpoint],
    memoryEnabled: true,
    createdAt: 0,
    updatedAt: 0,
  );

  final inputs = ChatPromptInputs(
    chat: chat,
    character: ex.vesna,
    persona: null,
    preset: preset,
    responderId: ex.vesna.id,
    beatsCap: 3,
    lookupCharacter: _charLookup([ex.vesna, ex.ren]),
    lookupBook: _bookLookup([ex.world]),
    inFlightMessageId: null,
  );

  return ChatScenario(
    'chat_summary_macro',
    'F1 {{summary}} macro: a preset mainPrompt embeds {{summary}}; the LTM '
        'recap is injected at the macro position and the hardcoded recap block '
        'is suppressed (no double-inject).',
    inputs,
  );
}

/// Build a lorebook with ONE selective entry: primary key "gate",
/// secondaryKeys ["aether"], selectiveLogic andAll — fires only when BOTH
/// "gate" AND "aether" appear in the scanned window.
Lorebook _selectiveLoreBook() => Lorebook(
      id: 'pl-lb-selective',
      name: 'Prompt Lab — Selective Lore',
      entries: [
        LoreEntry(
          id: 'pl-le-selective',
          keys: ['gate'],
          secondaryKeys: ['aether'],
          selectiveLogic: LoreSelectiveLogic.andAll,
          content: _kLoreEntryContent,
          order: 10,
        ),
      ],
      createdAt: 0,
      updatedAt: 0,
    );

ChatScenario _buildLorebookScenario({
  required String id,
  required String description,
  required ExampleCards ex,
  required List<Message> messages,
}) {
  final book = _selectiveLoreBook();
  final chat = Chat(
    id: 'pl-chat-$id',
    characterIds: [ex.vesna.id],
    characterSnapshots: {ex.vesna.id: ex.vesna},
    attachedLorebookIds: [book.id],
    messages: messages,
    createdAt: 0,
    updatedAt: 0,
  );
  final inputs = ChatPromptInputs(
    chat: chat,
    character: ex.vesna,
    persona: null,
    preset: null, // fallback branch → lore inlined under "--- Lore ---"
    responderId: ex.vesna.id,
    beatsCap: 3,
    lookupCharacter: _charLookup([ex.vesna, ex.ren]),
    lookupBook: _bookLookup([book]),
    inFlightMessageId: null,
  );
  return ChatScenario(id, description, inputs);
}

/// **chat_lorebook_on** (F3) — the window contains BOTH "gate" and "aether",
/// so the andAll selective entry FIRES. Goal: the entry content is present.
ChatScenario buildChatLorebookOn(ExampleCards ex) => _buildLorebookScenario(
      id: 'chat_lorebook_on',
      description:
          'F3 selective lore (andAll): chat mentions BOTH "gate" AND "aether" '
          '→ the selective entry FIRES (content present in the prompt).',
      ex: ex,
      messages: <Message>[
        _msg('pl-lon-m1', MessageKind.user,
            'I peer down into the gate. The cold aether stings my eyes.'),
        _msg('pl-lon-m2', MessageKind.char,
            '*Vesna grabs my arm.* "Don\'t breathe it in."'),
      ],
    );

/// **chat_lorebook_off** (F3) — the window contains ONLY "gate" (no "aether"),
/// so the andAll selective entry does NOT fire. Goal: entry content absent.
ChatScenario buildChatLorebookOff(ExampleCards ex) => _buildLorebookScenario(
      id: 'chat_lorebook_off',
      description:
          'F3 selective lore (andAll): chat mentions ONLY "gate" (no "aether") '
          '→ the selective entry does NOT fire (content absent from the prompt).',
      ex: ex,
      messages: <Message>[
        _msg('pl-loff-m1', MessageKind.user,
            'I peer down into the gate. It is dark all the way down.'),
        _msg('pl-loff-m2', MessageKind.char,
            '*Vesna grabs my arm.* "Don\'t lean so far."'),
      ],
    );

/// **chat_regex** (F4) — a non-destructive prompt-stage regex on the userInput
/// stream: `\bcolour\b` /gi → "color". The latest user turn contains "colour".
/// Goal: the OUTGOING user message reads "color" (transformed in-flight) while
/// the SOURCE fixture text still says "colour" (storage untouched).
ChatScenario buildChatRegex(ExampleCards ex) {
  final messages = <Message>[
    _msg('pl-rx-m1', MessageKind.char,
        '*Vesna eyes the strange moss.* "Tell me what you see."'),
    // The latest user turn carries the British spelling the rule rewrites.
    _msg('pl-rx-m2', MessageKind.user,
        'The moss is a sickly colour, and the Colour deepens near the water.'),
  ];

  final chat = Chat(
    id: 'pl-chat-regex',
    characterIds: [ex.vesna.id],
    characterSnapshots: {ex.vesna.id: ex.vesna},
    messages: messages,
    createdAt: 0,
    updatedAt: 0,
  );

  final rule = RegexRule(
    id: 'pl-rx-rule',
    name: 'colour → color',
    pattern: r'\bcolour\b',
    flags: 'gi',
    replacement: 'color',
    streams: [RegexStream.userInput],
    affectsPrompt: true,
    affectsDisplay: false,
  );

  final inputs = ChatPromptInputs(
    chat: chat,
    character: ex.vesna,
    persona: null,
    preset: null,
    responderId: ex.vesna.id,
    beatsCap: 3,
    lookupCharacter: _charLookup([ex.vesna, ex.ren]),
    lookupBook: _bookLookup([ex.world]),
    inFlightMessageId: null,
    regexRules: [rule],
  );

  return ChatScenario(
    'chat_regex',
    'F4 non-destructive regex (userInput, prompt-stage): /\\bcolour\\b/gi → '
        '"color"; outgoing user turn is transformed, source fixture stays '
        '"colour".',
    inputs,
  );
}

/// Shared chat shape for the F6 preset-switch pair — same messages + character,
/// only the [preset] differs, so the inspect dumps differ ONLY in the system
/// prompt.
ChatScenario _buildPresetScenario(
  ExampleCards ex,
  String id,
  String description,
  Preset preset,
) {
  final messages = <Message>[
    _msg('pl-ps-m1', MessageKind.user, 'Say something in character.'),
    _msg('pl-ps-m2', MessageKind.char,
        '*Vesna grunts.* "We don\'t have time for chatter."'),
  ];
  final chat = Chat(
    id: 'pl-chat-$id',
    characterIds: [ex.vesna.id],
    characterSnapshots: {ex.vesna.id: ex.vesna},
    presetId: preset.id,
    messages: messages,
    createdAt: 0,
    updatedAt: 0,
  );
  final inputs = ChatPromptInputs(
    chat: chat,
    character: ex.vesna,
    persona: null,
    preset: preset,
    responderId: ex.vesna.id,
    beatsCap: 3,
    lookupCharacter: _charLookup([ex.vesna, ex.ren]),
    lookupBook: _bookLookup([ex.world]),
    inFlightMessageId: null,
  );
  return ChatScenario(id, description, inputs);
}

/// **chat_preset_a** (F6) — assemble with preset A.
ChatScenario buildChatPresetA(ExampleCards ex) => _buildPresetScenario(
      ex,
      'chat_preset_a',
      'F6 preset switch (A): a terse, hardboiled system prompt. Compare the '
          'system prompt against chat_preset_b — same chat, different preset.',
      Preset(
        id: 'pl-preset-a',
        name: 'Prompt Lab — Preset A',
        mainPrompt:
            'PRESET-A-SENTINEL. You are {{char}}. Write terse, hardboiled '
            'prose. Never use flowery language.',
        createdAt: 0,
      ),
    );

/// **chat_preset_b** (F6) — assemble the SAME chat with a DIFFERENT preset.
ChatScenario buildChatPresetB(ExampleCards ex) => _buildPresetScenario(
      ex,
      'chat_preset_b',
      'F6 preset switch (B): a lush, romantic system prompt. Compare the '
          'system prompt against chat_preset_a — same chat, different preset.',
      Preset(
        id: 'pl-preset-b',
        name: 'Prompt Lab — Preset B',
        mainPrompt:
            'PRESET-B-SENTINEL. You are {{char}}. Write lush, romantic, '
            'sensory-rich prose. Linger on atmosphere.',
        createdAt: 0,
      ),
    );

// ---------------------------------------------------------------------------
// Pyre 1.1 Prompt Manager — MODULAR preset scenarios (toggle a block off)
// ---------------------------------------------------------------------------
//
// Where chat_preset_a/b swap a whole FLAT preset, this pair proves the MODULAR
// path: ONE preset built from three toggleable `beforeHistory` system blocks.
// `chat_modular_preset_on` has all three enabled; `chat_modular_preset_off` is
// the SAME preset with the middle "Lush prose module" block disabled. The
// inspect dumps differ ONLY in whether LUSH-SENTINEL appears in the system
// prompt, isolating exactly what toggling a block changes in the outgoing
// prompt. Assembly flows through `assemblePreset` inside `buildChatPrompt`.

/// The three modular system blocks. [lushEnabled] flips the middle block so the
/// ON / OFF scenarios share one definition (everything else stays identical).
List<PromptBlock> _modularBlocks({required bool lushEnabled}) => [
      PromptBlock(
        id: 'pl-mb-core',
        name: 'Core',
        content: 'CORE-SENTINEL. You are Vesna, a terse wolfkin delver.',
        // enabled defaults true.
      ),
      PromptBlock(
        id: 'pl-mb-lush',
        name: 'Lush prose module',
        content: 'LUSH-SENTINEL. Write lush, sensory, romantic prose.',
        enabled: lushEnabled,
      ),
      PromptBlock(
        id: 'pl-mb-pov',
        name: 'POV',
        content: 'POV-SENTINEL. Always write in second person.',
      ),
    ];

/// Shared chat shape for the modular-preset pair — same messages + character,
/// only the preset's block toggles differ.
ChatScenario _buildModularPresetScenario(
  ExampleCards ex,
  String id,
  String description, {
  required bool lushEnabled,
}) {
  final preset = Preset(
    id: 'pl-preset-$id',
    name: 'Prompt Lab — Modular ${lushEnabled ? 'ON' : 'OFF'}',
    // A flattened fallback string for any flat-path consumer; the BLOCKS are
    // what assemble (promptBlocks non-empty → modular path in assemblePreset).
    mainPrompt: 'MODULAR-FALLBACK-SENTINEL. You are {{char}}.',
    promptBlocks: _modularBlocks(lushEnabled: lushEnabled),
    createdAt: 0,
  );
  final messages = <Message>[
    _msg('pl-mp-m1', MessageKind.user, 'Say something in character.'),
    _msg('pl-mp-m2', MessageKind.char,
        '*Vesna grunts.* "We don\'t have time for chatter."'),
  ];
  final chat = Chat(
    id: 'pl-chat-$id',
    characterIds: [ex.vesna.id],
    characterSnapshots: {ex.vesna.id: ex.vesna},
    presetId: preset.id,
    messages: messages,
    createdAt: 0,
    updatedAt: 0,
  );
  final inputs = ChatPromptInputs(
    chat: chat,
    character: ex.vesna,
    persona: null,
    preset: preset,
    responderId: ex.vesna.id,
    beatsCap: 3,
    lookupCharacter: _charLookup([ex.vesna, ex.ren]),
    lookupBook: _bookLookup([ex.world]),
    inFlightMessageId: null,
  );
  return ChatScenario(id, description, inputs);
}

/// **chat_modular_preset_on** — a MODULAR preset with all three system blocks
/// (Core / Lush prose module / POV) ENABLED. Goal: the assembled system prompt
/// contains CORE-SENTINEL + LUSH-SENTINEL + POV-SENTINEL.
ChatScenario buildChatModularPresetOn(ExampleCards ex) =>
    _buildModularPresetScenario(
      ex,
      'chat_modular_preset_on',
      'Prompt Manager modular preset (all 3 blocks enabled): the system prompt '
          'assembles Core + Lush prose module + POV. Compare against '
          'chat_modular_preset_off — same preset, "Lush prose module" toggled '
          'off.',
      lushEnabled: true,
    );

/// **chat_modular_preset_off** — the SAME preset with the "Lush prose module"
/// block DISABLED. Goal: the system prompt contains CORE-SENTINEL + POV-SENTINEL
/// but NOT LUSH-SENTINEL, proving a block toggle changes the outgoing prompt.
ChatScenario buildChatModularPresetOff(ExampleCards ex) =>
    _buildModularPresetScenario(
      ex,
      'chat_modular_preset_off',
      'Prompt Manager modular preset ("Lush prose module" disabled): the system '
          'prompt assembles Core + POV only (no LUSH-SENTINEL). Compare against '
          'chat_modular_preset_on.',
      lushEnabled: false,
    );

// ---------------------------------------------------------------------------
// CREATOR scenarios
// ---------------------------------------------------------------------------

/// A small, fixed Creator conversation transcript — the user's seed brief.
/// The structured build (`buildBatchTurns`) carries this as context so the
/// dumped request shows what the model is being asked to flesh out.
List<ChatTurn> _creatorTranscript(CreatorMode mode) {
  switch (mode) {
    case CreatorMode.character:
      return [
        ChatTurn('user', 'make a shy catgirl barista named Mina'),
      ];
    case CreatorMode.scenario:
      return [
        ChatTurn(
            'user',
            'a moody late-night cafe where the barista and the last customer '
            'are the only two left'),
      ];
    case CreatorMode.persona:
      return [
        ChatTurn('user',
            'a quiet art student I play as — observant, sketches strangers'),
      ];
  }
}

/// A KNOWN field map for [mode] — a representative, deterministic set of filled
/// fields the renderer turns into a card. Kept small + fixed so the golden is
/// stable, but covering the required keys for the mode so `missingRequired` is
/// empty (the LIVE "complete" signal of the structured renderer).
Map<String, dynamic> _creatorFields(CreatorMode mode) {
  switch (mode) {
    case CreatorMode.character:
      return <String, dynamic>{
        'fullName': 'Mina Calloway',
        'apparentAge': '22, 158cm, 49kg',
        'race': 'Catgirl (felis heritage — tufted ears, slim tail)',
        'detailedFeatures': [
          {'label': 'Hair', 'value': 'Ash-brown bob, perpetual cowlick'},
          {'label': 'Eyes', 'value': 'Wide amber, quick to dart away'},
        ],
        'generalAppearance':
            'Small and self-effacing; folds in on herself behind the counter, '
            'ears flattening when spoken to.',
        'coreTraits': 'Shy, observant, secretly fierce, kind, anxious, deft.',
        'background':
            'Raised above the cafe by an aunt who taught her latte art before '
            'language; she stayed when the aunt passed, the espresso machine '
            'her only loud thing.',
        'first_mes':
            '*Mina freezes mid-pour, ears pinning back.* "O-oh — you\'re '
            'still here. Sorry, I didn\'t— what can I get you?"',
        'dialogueExamples': [
          {
            'action': 'twisting her apron',
            'dialogue': "It's just... no one usually stays this late.",
            'beat': 'nervous',
          },
        ],
      };
    case CreatorMode.scenario:
      return <String, dynamic>{
        'name': 'Last Call',
        'narrator':
            'You narrate the cafe and everyone in it except {{user}}; never '
            'speak or act for {{user}}.',
        'readingThePersona':
            'A brash persona makes Mina retreat; a gentle one coaxes her out.',
        'sceneSetup':
            'It is 1AM. The chairs are up, the rain is steady, and {{user}} '
            'is the only customer Mina has not yet asked to leave.',
        'tone': 'Quiet, slow-burn, charged understatement.',
        'world':
            'A single late-night cafe on a rain-slick corner; the city beyond '
            'is closed and dark.',
        'npcs':
            'Mina (22, the barista, shy) is the only other presence; the owner '
            'left hours ago.',
        'first_mes':
            '*The bell over the door has long since stopped ringing.* The last '
            'song fades, and Mina looks up from the counter.',
        'dialogueExamples': [
          {
            'action': 'wiping the same spot twice',
            'dialogue': "We close in ten. ...You can stay till then.",
            'beat': 'soft',
          },
        ],
      };
    case CreatorMode.persona:
      return <String, dynamic>{
        'fullName': 'Devon Reyes',
        'apparentAge': '20, 175cm, 64kg',
        'race': 'Human',
        'generalAppearance':
            'Lanky, ink-smudged fingers, a sketchbook always half-open.',
        'coreTraits': 'Observant, quiet, patient, dryly funny, watchful.',
        'background':
            'An art student who fills margins with strangers caught mid-gesture; '
            'prefers watching a room to being seen in it.',
        'dialogueExamples': [
          {
            'action': 'glancing up from the page',
            'dialogue': "Hold that — no, just for a second. There.",
            'beat': 'absorbed',
          },
        ],
      };
  }
}

/// Build the Creator structured-build scenario for one [mode]: the FIRST
/// batch's structured request turns (via `buildBatchTurns`) PLUS a trailing
/// synthetic `render` turn carrying the deterministic `renderCard` Description
/// of the known fixture field map, so the dump shows BOTH sides of the new
/// pipeline (the request to the model + what Pyre renders from a field map).
CreatorScenario buildCreatorBatch(CreatorMode mode) {
  final firstBatch = batchesFor(mode).first;
  final transcript = _creatorTranscript(mode);
  final turns = buildBatchTurns(
    mode: mode,
    batchKeys: firstBatch,
    transcript: transcript,
  );

  final fields = _creatorFields(mode);
  final rendered = renderCard(fields, mode);
  final renderedDescription = (rendered['description'] as String?) ?? '';

  // A synthetic, non-model turn so the golden + report carry the deterministic
  // render alongside the structured request. The role `render` is never sent to
  // a provider — the LIVE path uses `buildBatchTurns` only.
  final allTurns = <ChatTurn>[
    ...turns,
    ChatTurn('render', renderedDescription),
  ];

  return CreatorScenario(
    'creator_${mode.name}',
    'Creator structured build for mode "${mode.name}": first-batch JSON '
        'request (fields ${firstBatch.join(', ')}) + the deterministic '
        'renderCard Description of a known field map.',
    allTurns,
    mode: mode,
    fields: fields,
  );
}

/// Build the Creator VISION scenario — a tiny 1x1 transparent PNG data URL
/// (no real image bytes needed; the harness only dumps the request shape).
CreatorScenario buildCreatorVision() {
  // Smallest valid PNG (1x1 transparent), base64. Used only so the dumped
  // request has a realistic image_url payload — no model ever sees it.
  const onePxPng =
      'data:image/png;base64,'
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  final turns = buildCreatorVisionTurns(
    imageDataUrl: onePxPng,
    userNote: 'This is the delver — emphasise the scar and the tail.',
  );
  return CreatorScenario(
    'creator_vision',
    'Creator vision assembly (image-analysis prompt + a user note + a 1x1 '
        'placeholder image).',
    turns,
  );
}

// ---------------------------------------------------------------------------
// Scenario registry
// ---------------------------------------------------------------------------

/// All chat scenarios, built from the loaded example cards. The Pyre 1.1
/// prompt-feature scenarios (F1/F3/F4/F6) sit alongside the originals so they
/// dump under `inspect` and can be `--dart-define=scenario=<id>`-selected under
/// `live` without any extra wiring.
List<ChatScenario> buildChatScenarios(ExampleCards ex) => [
      buildChatSingle(ex),
      buildChatGroup(ex),
      // Pyre 1.1 prompt-feature scenarios.
      buildChatSummaryMacro(ex), // F1
      buildChatLorebookOn(ex), // F3 (fires)
      buildChatLorebookOff(ex), // F3 (does not fire)
      buildChatRegex(ex), // F4
      buildChatPresetA(ex), // F6 (A)
      buildChatPresetB(ex), // F6 (B)
      // Pyre 1.1 Prompt Manager — modular preset (toggle a block off).
      buildChatModularPresetOn(ex), // all 3 blocks enabled
      buildChatModularPresetOff(ex), // "Lush prose module" disabled
    ];

/// All Creator scenarios: the structured-build first batch for each mode
/// (character / scenario / persona) + the vision request. The old marker
/// cascade + review-pass scenarios were removed in Wave CY.18.233 (the
/// structured-JSON pipeline replaced them); there is no separate `edit` mode —
/// edit re-runs a `character`-mode batch over a decomposed field map.
List<CreatorScenario> buildCreatorScenarios() => [
      buildCreatorBatch(CreatorMode.character),
      buildCreatorBatch(CreatorMode.scenario),
      buildCreatorBatch(CreatorMode.persona),
      buildCreatorVision(),
    ];
