// Wave CY.18.225 (Creator Structured Build, Task 1): the per-mode card
// schema — the single source of truth for the structured-output request
// batches and the deterministic renderer (creator_render.dart, Task 2).
//
// PURE Dart. NO Flutter imports — unit-testable headless, mirroring
// `creator_cascade.dart` / `live_sheet.dart`'s pure-fn pattern.
//
// This replaces the LLM-owned `<<SHEET>>` / `<<BLOCK_END>>` marker protocol
// + completeness cascade. Here the model only supplies semantic prose per
// typed field; Pyre renders format/order/spacing/language deterministically
// and guarantees completeness BY CONSTRUCTION — every required field is
// requested in exactly one batch (proven by the static coverage test in
// `test/creator_schema_test.dart`, spec acceptance #1).
//
// The field LABELS + ordering come from the persona/character architect's
// canonical Description section list (card_assist_prompts.dart, Full Name →
// Notes, with Detailed Features / Clothing / Intimate Details as
// nested-bullet parents) and the scenario architect's XML sections
// (`<Narrator>` / `<Reading the Persona>` / `<Scene Setup>` / `<Tone>` /
// `<World>` / `<NPCs>`). The bundled Ren / Vesna / Sunken-Gate example cards
// are the tiebreaker when the prompt and the rendered cards disagree.
//
// `guidance` strings are SHORT pointers only — the long content rules
// (anti-seed-collapse, traits-manifest, frank, no-meta, JSON shape) live in
// the build prompt (creator_build_prompts.dart, Task 5), not here.

/// What a field renders/parses as.
///
/// - [prose]            — a single free-prose String value.
/// - [nestedBullets]    — a parent label whose entries render as tight
///                        `  * Sub: …` bullet lines. Two flavours: a FIXED set
///                        of canonical [CardField.children] (Detailed Features,
///                        Clothing, Intimate Details), OR a VARIABLE,
///                        model-chosen set with NO `children` list (Inner
///                        Circle, Likes & Dislikes, Behavioral Modes, Fetishes &
///                        Kinks, …) — the value is a `{SubLabel: text}` object
///                        whose keys the model picks.
/// - [bulletList]       — a parent label whose value is a FLAT list of short
///                        strings (no sub-labels), rendered as one `  * item`
///                        line each (Core Traits, Interests, Core Beliefs,
///                        Abilities). The value arrives as a JSON array (or a
///                        newline/`*`-delimited String, tolerated).
/// - [dialogueExamples] — the `<START>`-separated `mes_example` list; exists
///                        only as the JSON request/parse shape (the renderer
///                        serialises it to the single stored String field).
/// - [tags]             — the tags list (stored as a list field).
/// - [topLevel]         — a top-level chara_card_v2 canvas field that is NOT
///                        part of the labeled/XML Description (tagline,
///                        first_mes, creator_notes, post_history_instructions).
/// - [greetingsList]    — the chara_card_v2 `alternate_greetings` list: a list
///                        of FULL standalone opening messages (each the same
///                        shape/voice as first_mes). The renderer surfaces it as
///                        `out['alternate_greetings']` (a `List<String>`); it is
///                        NEVER folded into the labeled/XML Description. Value
///                        arrives as a JSON array of strings (a single String or
///                        absent is tolerated → 1-element / empty list).
enum CardFieldKind {
  prose,
  nestedBullets,
  bulletList,
  dialogueExamples,
  tags,
  topLevel,
  greetingsList
}

/// The three Creator build modes.
enum CreatorMode { character, scenario, persona }

/// Wave CY.18.265: the user-chosen DESIRED size of the Creator-generated
/// "Description" field (the assembled character / persona sheet). A SOFT
/// target the build aims for — never a hard cap and never the token limit.
/// Applies to CHARACTER and PERSONA builds only (scenario assembles
/// differently and is left untouched). `standard` reproduces Pyre's original
/// ~5,000-token aim verbatim, so existing users who never touch the control
/// see ZERO change.
enum CreatorDescriptionSize { concise, standard, detailed, veryDetailed }

/// One ordered field descriptor in a mode's schema.
class CardField {
  /// Stable id used as the JSON key + the field-map key, e.g. `background`,
  /// `detailedFeatures`, `first_mes`.
  final String key;

  /// Rendered label, e.g. `Background`, `Detailed Features`, `First Message`.
  /// For [CardFieldKind.nestedBullets] this is the parent label; for a child
  /// it is the sub-bullet label (`Face`, `Hair`, …).
  final String label;

  final CardFieldKind kind;

  /// Sub-fields for [CardFieldKind.nestedBullets] (null otherwise).
  final List<CardField>? children;

  /// Whether this field gates "complete" (drives [requiredKeysFor]).
  final bool required;

  /// Short pointer to what to write. Long content rules live in the build
  /// prompt (Task 5).
  final String guidance;

  const CardField({
    required this.key,
    required this.label,
    required this.kind,
    this.children,
    this.required = false,
    this.guidance = '',
  });
}

// ── Reusable child sets for the nestedBullets parents ─────────────────────

const List<CardField> _detailedFeaturesChildren = <CardField>[
  CardField(key: 'face', label: 'Face', kind: CardFieldKind.prose),
  CardField(key: 'hair', label: 'Hair', kind: CardFieldKind.prose),
  CardField(key: 'eyes', label: 'Eyes', kind: CardFieldKind.prose),
  CardField(key: 'eyelashes', label: 'Eyelashes', kind: CardFieldKind.prose),
  CardField(key: 'skin', label: 'Skin', kind: CardFieldKind.prose),
  CardField(key: 'voice', label: 'Voice', kind: CardFieldKind.prose),
  CardField(key: 'scent', label: 'Scent', kind: CardFieldKind.prose),
  CardField(key: 'movement', label: 'Movement', kind: CardFieldKind.prose),
];

const List<CardField> _clothingChildren = <CardField>[
  CardField(key: 'torsoTop', label: 'Torso / Top', kind: CardFieldKind.prose),
  CardField(
      key: 'legsBottom', label: 'Legs / Bottom', kind: CardFieldKind.prose),
  CardField(
      key: 'armsAccessories',
      label: 'Arms / Accessories',
      kind: CardFieldKind.prose),
  CardField(key: 'footwear', label: 'Footwear', kind: CardFieldKind.prose),
  CardField(
      key: 'notableSymbolicDetails',
      label: 'Notable Magical/Symbolic Details',
      kind: CardFieldKind.prose),
];

const List<CardField> _intimateDetailsChildren = <CardField>[
  CardField(
      key: 'chestBreasts',
      label: 'Chest / Breasts',
      kind: CardFieldKind.prose),
  CardField(key: 'milk', label: 'Milk', kind: CardFieldKind.prose),
  CardField(key: 'genitals', label: 'Genitals', kind: CardFieldKind.prose),
  CardField(key: 'buttAnus', label: 'Butt / Anus', kind: CardFieldKind.prose),
  CardField(
      key: 'responsiveness',
      label: 'Responsiveness',
      kind: CardFieldKind.prose),
  CardField(
      key: 'piercingsPlugs',
      label: 'Piercings / Plugs / Enchantments',
      kind: CardFieldKind.prose),
  CardField(
      key: 'constructedFeatures',
      label: 'Magical or Constructed Features',
      kind: CardFieldKind.prose),
];

// ── Character / Persona shared Description sections (Full Name → Notes) ────
//
// The canonical ordered list from the persona/character architect prompts.
// `prose` unless a nestedBullets parent. The `required` flags mirror
// `creator_cascade.requiredKeysFor`'s SEMANTICS at the canvas level
// (description/name must be present) translated down to the fine-grained
// fields that carry that weight: a card is "complete" when it has a name,
// the core identity/appearance, a personality spine, and a background.

const List<CardField> _descriptionSections = <CardField>[
  CardField(
      key: 'fullName',
      label: 'Full Name',
      kind: CardFieldKind.prose,
      required: true,
      guidance:
          'The character\'s NAME ONLY — given + family (e.g. "Akemi Tanaka"); '
          'aliases, nicknames, "goes by", and how others address them belong '
          'in other fields, NOT here.'),
  CardField(
      key: 'apparentAge',
      label: 'Apparent Age, Height & Weight',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'Concrete years; height + weight in cm/kg or ft/lbs.'),
  CardField(
      key: 'race',
      label: 'Race',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'Species / heritage — more than just "human".'),
  CardField(
      key: 'bornGender',
      label: 'Born Gender & Gender Expression',
      kind: CardFieldKind.prose,
      guidance: 'Birth sex AND how they present.'),
  CardField(
      key: 'pronouns', label: 'Pronouns', kind: CardFieldKind.prose),
  CardField(
      key: 'bodyType',
      label: 'Body Type',
      kind: CardFieldKind.prose,
      guidance: 'Build, silhouette, sensual presence.'),
  CardField(
      key: 'attractiveness',
      label: 'Attractiveness',
      kind: CardFieldKind.prose),
  CardField(
      key: 'detailedFeatures',
      label: 'Detailed Features',
      kind: CardFieldKind.nestedBullets,
      children: _detailedFeaturesChildren,
      guidance: 'Per-feature physical specifics.'),
  CardField(
      key: 'clothing',
      label: 'Clothing',
      kind: CardFieldKind.nestedBullets,
      children: _clothingChildren,
      guidance: 'The default outfit, layer by layer.'),
  CardField(
      key: 'alternativeClothing',
      label: 'Alternative Clothing',
      kind: CardFieldKind.prose,
      guidance: 'Sleepwear, swimwear, alt looks.'),
  CardField(
      key: 'intimateDetails',
      label: 'Intimate Details',
      kind: CardFieldKind.nestedBullets,
      children: _intimateDetailsChildren,
      guidance: 'Anatomically explicit, frank, factual (or n/a if SFW).'),
  CardField(
      key: 'generalAppearance',
      label: 'General Appearance',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'Posture, presence, aura — how the visual reads.'),
  CardField(
      key: 'coreTraits',
      label: 'Core Traits',
      kind: CardFieldKind.bulletList,
      required: true,
      guidance: 'A JSON array of 5-7 sharp single-descriptor strings, one '
          'trait each.'),
  CardField(
      key: 'moralAlignment',
      label: 'Moral Alignment',
      kind: CardFieldKind.prose),
  CardField(
      key: 'behavioralBias',
      label: 'Behavioral Bias',
      kind: CardFieldKind.prose),
  CardField(
      key: 'responsePattern',
      label: 'Response Pattern',
      kind: CardFieldKind.prose,
      guidance: 'Tone, verbal tics, speech rhythm.'),
  CardField(
      key: 'languageStyle',
      label: 'Language / Writing Style / Spelling',
      kind: CardFieldKind.prose),
  CardField(
      key: 'psychologicalProfile',
      label: 'Psychological Profile',
      kind: CardFieldKind.prose,
      guidance: 'Trauma, repression, paradoxes — a few sentences.'),
  CardField(
      key: 'cognitiveAwareness',
      label: 'Cognitive Awareness',
      kind: CardFieldKind.prose),
  CardField(
      key: 'inhibitionLevel',
      label: 'Inhibition Level',
      kind: CardFieldKind.prose),
  CardField(
      key: 'routine',
      label: 'Routine / Typical Day',
      kind: CardFieldKind.prose),
  CardField(
      key: 'educationLevel',
      label: 'Education Level',
      kind: CardFieldKind.prose),
  CardField(
      key: 'voiceInnerVoice',
      label: 'Voice to Others / Inner Voice',
      kind: CardFieldKind.prose),
  CardField(
      key: 'strengthsWeaknesses',
      label: 'Strengths & Weaknesses',
      kind: CardFieldKind.nestedBullets,
      guidance: 'An object with two sub-labelled entries — "Strengths" and '
          '"Weaknesses" — each a tight description.'),
  CardField(
      key: 'likesDislikes',
      label: 'Likes & Dislikes',
      kind: CardFieldKind.nestedBullets,
      guidance: 'An object with two sub-labelled entries — "Likes" and '
          '"Dislikes" — each a tight description.'),
  CardField(
      key: 'interests',
      label: 'Interests',
      kind: CardFieldKind.bulletList,
      guidance: 'A JSON array of short strings — one interest / hobby each.'),
  CardField(
      key: 'instinctualBehavior',
      label: 'Instinctual Behavior / Desires',
      kind: CardFieldKind.prose),
  CardField(
      key: 'temporalMindset',
      label: 'Temporal Mindset',
      kind: CardFieldKind.prose),
  CardField(
      key: 'coreBeliefs',
      label: 'Core Beliefs',
      kind: CardFieldKind.bulletList,
      guidance: 'A JSON array of short strings — one belief / creed each.'),
  CardField(
      key: 'moralLogic',
      label: 'Moral Logic / Justification System',
      kind: CardFieldKind.prose),
  CardField(
      key: 'hiddenContradictions',
      label: 'Hidden Contradictions',
      kind: CardFieldKind.prose),
  CardField(
      key: 'personalRituals',
      label: 'Personal Rituals & Habits',
      kind: CardFieldKind.nestedBullets,
      guidance: 'An object of sub-labelled entries — one per ritual or habit: '
          'a short label naming it + when / how it shows.'),
  CardField(
      key: 'intimateExperience',
      label: 'Intimate Experience',
      kind: CardFieldKind.prose),
  CardField(
      key: 'relationalDynamics',
      label: 'Relational Dynamics',
      kind: CardFieldKind.prose),
  CardField(
      key: 'possessiveness',
      label: 'Possessiveness / Jealousy Level',
      kind: CardFieldKind.prose),
  CardField(
      key: 'horninessLevel',
      label: 'Horniness Level',
      kind: CardFieldKind.prose),
  CardField(
      key: 'fetishesKinks',
      label: 'Fetishes & Kinks',
      kind: CardFieldKind.nestedBullets,
      guidance: 'An object of sub-labelled entries — one per kink: a short '
          'label naming it + a specific description (physical, emotional, '
          'symbolic, taboo). Use as many as fit.'),
  CardField(
      key: 'abilities',
      label: 'Abilities',
      kind: CardFieldKind.bulletList,
      guidance: 'A JSON array of short strings — one power / skill each (or a '
          'single-item array like ["None — a regular person"]).'),
  CardField(
      key: 'powerScale', label: 'Power Scale', kind: CardFieldKind.prose),
  CardField(
      key: 'combatBehavior',
      label: 'Combat Behavior & Approach',
      kind: CardFieldKind.prose),
  CardField(
      key: 'storageItems',
      label: 'Storage & Carried Items',
      kind: CardFieldKind.nestedBullets,
      guidance: 'An object of sub-labelled entries — one per item: a short '
          'label naming the item + what it is / why it is carried.'),
  CardField(
      key: 'specialObject',
      label: 'Special Object',
      kind: CardFieldKind.prose),
  CardField(
      key: 'speciesNotes',
      label: 'Species / Classification Notes',
      kind: CardFieldKind.prose),
  CardField(
      key: 'vulnerabilities',
      label: 'Vulnerabilities & Countermeasures',
      kind: CardFieldKind.nestedBullets,
      guidance: 'An object of sub-labelled entries — one per vulnerability: a '
          'short label naming it + the matching countermeasure.'),
  CardField(
      key: 'behavioralModes',
      label: 'Behavioral Modes',
      kind: CardFieldKind.nestedBullets,
      guidance: 'An object of sub-labelled entries — one per mode: a short name '
          'for the mode + what triggers it / how they act in it.'),
  CardField(
      key: 'background',
      label: 'Background',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'Origin, journey, transformation — a few sentences.'),
  CardField(
      key: 'innerCircle',
      label: 'Inner Circle',
      kind: CardFieldKind.nestedBullets,
      guidance: 'NAMED people with ages + a concrete bond each '
          '(one bullet per person).'),
  CardField(
      key: 'knownByRumors',
      label: 'Known By / Rumors',
      kind: CardFieldKind.prose),
  CardField(
      key: 'livingSpace', label: 'Living Space', kind: CardFieldKind.prose),
  CardField(
      key: 'worldFamiliarity',
      label: 'World Familiarity',
      kind: CardFieldKind.prose),
  CardField(
      key: 'environmentalReactions',
      label: 'Environmental Reactions',
      kind: CardFieldKind.prose),
  CardField(
      key: 'whatTheyWant',
      label: 'What They Want From the Future',
      kind: CardFieldKind.prose),
  CardField(
      key: 'notes',
      label: 'Notes',
      kind: CardFieldKind.prose,
      guidance:
          'ONLY genuinely extra info NOT already covered by any other section '
          '(background, living space, relationships, objects, etc.). If '
          'everything is covered elsewhere, keep this short or minimal. Never '
          'restate other fields. In-world clarifications only — never '
          'author/meta notes.'),
];

// ── Top-level card fields (shared shapes) ─────────────────────────────────

const CardField _tagline = CardField(
    key: 'tagline',
    label: 'Tagline',
    kind: CardFieldKind.topLevel,
    guidance: 'One short evocative line.');

const CardField _firstMes = CardField(
    key: 'first_mes',
    label: 'First Message',
    kind: CardFieldKind.topLevel,
    required: true,
    guidance: 'The opening message, in-character, action-interlaced.');

const CardField _dialogueExamples = CardField(
    key: 'dialogueExamples',
    label: 'Dialogue Examples',
    kind: CardFieldKind.dialogueExamples,
    required: true,
    guidance:
        '4-6 exchanges; **bold** speech, *italic* action; ≥1 charged beat.');

// Wave CY.18.270: the chara_card_v2 top-level `alternate_greetings` list.
// PREVIOUSLY MISSING from EVERY mode's schema — so the structured build never
// requested, mapped, or checked it, and a user who asked the Creator chat to
// "add alternate greetings" got an acknowledgement but NO greetings on the card
// (the conversational layer said it did; the deterministic build had no slot).
// greetingsList so renderCard surfaces it as out['alternate_greetings'] (a
// List<String>), NEVER folded into the Description. NOT required — extra
// greetings beyond first_mes are always optional. CHARACTER + SCENARIO only;
// persona has no greetings of its own by design (the persona-mode schema /
// batches exclude it).
const CardField _alternateGreetings = CardField(
    key: 'alternate_greetings',
    label: 'Alternate Greetings',
    kind: CardFieldKind.greetingsList,
    guidance:
        '0-3 ALTERNATE opening messages. Each is a COMPLETE, standalone '
        'greeting written in the SAME voice, tense, and formatting as '
        'first_mes (in-character, action-interlaced), but offering a DIFFERENT '
        'entry into the scene (a different mood, time, or hook) — not a '
        'rewrite of first_mes. Empty list if none fit.');

const CardField _tags = CardField(
    key: 'tags',
    label: 'Tags',
    kind: CardFieldKind.tags,
    guidance: 'Short, conventional, searchable discovery tags.');

const CardField _creatorNotes = CardField(
    key: 'creator_notes',
    label: 'Creator Notes',
    kind: CardFieldKind.topLevel,
    guidance: 'Notes to the human reader (out-of-world).');

const CardField _postHistory = CardField(
    key: 'post_history_instructions',
    label: 'Post-History Instructions',
    kind: CardFieldKind.topLevel,
    guidance: 'Narrator anti-drift reminders (scenario).');

// ── Scenario XML Description sections ─────────────────────────────────────

// The scenario card's display name. A scenario has NO Full Name field (that is
// a character/persona concept), so without this the rendered card would have an
// empty top-level `name`. topLevel (NOT prose) so it never emits a `<Name>`
// block into the XML Description — `renderCard` surfaces it as `out['name']`.
const CardField _scenarioName = CardField(
    key: 'name',
    label: 'Name',
    kind: CardFieldKind.topLevel,
    required: true,
    guidance:
        'The scenario\'s TITLE only — the world / event / place name (e.g. '
        '"The Sunken Gate", "Nexus Fest"). A few words, no description, no '
        'punctuation-run-on. This becomes the card\'s display name.');

const List<CardField> _scenarioSections = <CardField>[
  CardField(
      key: 'narrator',
      label: 'Narrator',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'Who the narrator is + the never-act-for-{{user}} rule.'),
  CardField(
      key: 'readingThePersona',
      label: 'Reading the Persona',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'How {{user}}\'s persona changes the world\'s reaction.'),
  CardField(
      key: 'sceneSetup',
      label: 'Scene Setup',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'The opening situation — already in motion.'),
  CardField(
      key: 'tone',
      label: 'Tone',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'Genre, pacing, how escalation feels.'),
  CardField(
      key: 'world',
      label: 'World',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'The setting, factions, rules, places.'),
  CardField(
      key: 'npcs',
      label: 'NPCs',
      kind: CardFieldKind.prose,
      required: true,
      guidance: 'Named NPCs, each with a defining trait + agenda.'),
];

// Wave CY.18.269: the chara_card_v2 top-level `scenario` field for scenario
// cards. PREVIOUSLY MISSING from the scenario schema entirely — so the build
// never requested, mapped, or checked it, and the `scenario` Sheet slot always
// came back blank (the user had to hand-fill it). topLevel so renderCard's
// passthrough surfaces it as out['scenario']; required so missingRequired
// flags it and the per-field re-request gives it a second chance.
const CardField _scenario = CardField(
    key: 'scenario',
    label: 'Scenario',
    kind: CardFieldKind.topLevel,
    required: true,
    guidance:
        'A concise, present-tense summary of the opening situation {{user}} is '
        'dropped into — two to four sentences. This fills the card\'s top-level '
        '`scenario` field; it is the short framing, DISTINCT from the fuller '
        '<Scene Setup> section (do not just repeat it).');

// The CHARACTER-card top-level `scenario` field. PREVIOUSLY MISSING from the
// character schema + batches entirely — so a character build never requested,
// mapped, or checked it, and the Scenario Sheet slot always came back blank.
// Distinct from `_scenario` above: a character card has NO <Scene Setup>
// section, so the guidance is worded for the meeting context, not the scenario
// card's XML. Same top-level key `'scenario'` so renderCard's passthrough
// surfaces it as out['scenario'] → Character.scenario. required so
// missingRequired flags it if the model leaves it empty.
const CardField _charScenario = CardField(
    key: 'scenario',
    label: 'Scenario',
    kind: CardFieldKind.topLevel,
    required: true,
    guidance:
        'The situation {{user}} meets {{char}} in — 2 to 4 sentences '
        'establishing where they are, the immediate circumstances, and why '
        'they\'re together. Sets the opening stage for roleplay; keep it '
        'open-ended, not a full scene.');

// ── Per-mode ordered schemas ──────────────────────────────────────────────

/// Ordered field set for [mode]. The Description sections come first (in
/// canonical order), then the top-level card fields in render order.
List<CardField> schemaFor(CreatorMode mode) {
  switch (mode) {
    case CreatorMode.character:
      return <CardField>[
        ..._descriptionSections,
        _tagline,
        _charScenario,
        _firstMes,
        _alternateGreetings,
        _dialogueExamples,
        _tags,
        _creatorNotes,
      ];
    case CreatorMode.persona:
      // Same Description sections as character, but a persona has NO scenario
      // / first_mes / alternate_greetings of its own (persona rules). Its
      // dialogue examples are written in the {{user}} voice (the renderer +
      // build prompt handle that distinction). Tagline is allowed.
      return <CardField>[
        ..._descriptionSections,
        _dialogueExamples,
        _tagline,
      ];
    case CreatorMode.scenario:
      return <CardField>[
        _scenarioName,
        ..._scenarioSections,
        _scenario,
        _firstMes,
        _alternateGreetings,
        _dialogueExamples,
        _tags,
        _postHistory,
        _creatorNotes,
        _tagline,
      ];
  }
}

/// The fixed batch grouping for [mode] (spec §B). Each batch is an ordered
/// list of field keys requested together as one structured JSON call. Every
/// [required] field appears in exactly one batch (the completeness guarantee
/// — proven by the static coverage test).
///
/// Batches reference the FIELD-MAP keys: nestedBullets parents are requested
/// as whole objects (their children are nested in the JSON), so a batch lists
/// the PARENT key (`detailedFeatures`), not the child keys.
List<List<String>> batchesFor(CreatorMode mode) {
  switch (mode) {
    case CreatorMode.character:
      return const <List<String>>[
        // 1. identity + appearance (Full Name … General Appearance).
        [
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
        ],
        // 2. personality + psychology + kinks (Core Traits … Fetishes & Kinks).
        [
          'coreTraits',
          'moralAlignment',
          'behavioralBias',
          'responsePattern',
          'languageStyle',
          'psychologicalProfile',
          'cognitiveAwareness',
          'inhibitionLevel',
          'routine',
          'educationLevel',
          'voiceInnerVoice',
          'strengthsWeaknesses',
          'likesDislikes',
          'interests',
          'instinctualBehavior',
          'temporalMindset',
          'coreBeliefs',
          'moralLogic',
          'hiddenContradictions',
          'personalRituals',
          'intimateExperience',
          'relationalDynamics',
          'possessiveness',
          'horninessLevel',
          'fetishesKinks',
        ],
        // 3. abilities + relationships + background + world-fit
        //    (Abilities … What They Want).
        [
          'abilities',
          'powerScale',
          'combatBehavior',
          'storageItems',
          'specialObject',
          'speciesNotes',
          'vulnerabilities',
          'behavioralModes',
          'background',
          'innerCircle',
          'knownByRumors',
          'livingSpace',
          'worldFamiliarity',
          'environmentalReactions',
          'whatTheyWant',
        ],
        // 4. closing: scenario + first_mes + alternate greetings + dialogue +
        //    tags + notes + tagline.
        [
          'notes',
          'scenario',
          'first_mes',
          'alternate_greetings',
          'dialogueExamples',
          'tags',
          'creator_notes',
          'tagline',
        ],
      ];
    case CreatorMode.persona:
      return const <List<String>>[
        // 1. identity + appearance.
        [
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
        ],
        // 2. personality + psychology + kinks + relationships + background.
        [
          'coreTraits',
          'moralAlignment',
          'behavioralBias',
          'responsePattern',
          'languageStyle',
          'psychologicalProfile',
          'cognitiveAwareness',
          'inhibitionLevel',
          'routine',
          'educationLevel',
          'voiceInnerVoice',
          'strengthsWeaknesses',
          'likesDislikes',
          'interests',
          'instinctualBehavior',
          'temporalMindset',
          'coreBeliefs',
          'moralLogic',
          'hiddenContradictions',
          'personalRituals',
          'intimateExperience',
          'relationalDynamics',
          'possessiveness',
          'horninessLevel',
          'fetishesKinks',
          'abilities',
          'powerScale',
          'combatBehavior',
          'storageItems',
          'specialObject',
          'speciesNotes',
          'vulnerabilities',
          'behavioralModes',
          'background',
          'innerCircle',
          'knownByRumors',
          'livingSpace',
          'worldFamiliarity',
          'environmentalReactions',
          'whatTheyWant',
          'notes',
        ],
        // 3. dialogue examples ({{user}} voice) + tagline + Notes-tail.
        [
          'dialogueExamples',
          'tagline',
        ],
      ];
    case CreatorMode.scenario:
      return const <List<String>>[
        // 1. name (the scenario title) + scenario (short framing) + narrator +
        //    readingThePersona + sceneSetup + tone.
        [
          'name',
          'scenario',
          'narrator',
          'readingThePersona',
          'sceneSetup',
          'tone',
        ],
        // 2. world + npcs.
        [
          'world',
          'npcs',
        ],
        // 3. first_mes + alternate greetings + dialogue + tags + post_history +
        //    creator_notes + tagline.
        [
          'first_mes',
          'alternate_greetings',
          'dialogueExamples',
          'tags',
          'post_history_instructions',
          'creator_notes',
          'tagline',
        ],
      ];
  }
}

/// The set of REQUIRED schema-field keys for [mode] — derived from the
/// schema's per-field [CardField.required] flags (flattening nestedBullets
/// parents; children are never independently required).
///
/// NOTE (review #7): this is the FINE-GRAINED per-schema-field required set,
/// distinct from `creator_cascade.requiredKeysFor`, which returns the COARSE
/// canvas keys (`name`/`description`/`first_mes`/`mes_example`/`tags`…) used
/// for the post-render `missingRequired` check (Task 2). The two key spaces
/// are intentionally separate — do not conflate them.
Set<String> requiredKeysFor(CreatorMode mode) {
  final required = <String>{};
  for (final f in schemaFor(mode)) {
    if (f.required) required.add(f.key);
  }
  return required;
}
