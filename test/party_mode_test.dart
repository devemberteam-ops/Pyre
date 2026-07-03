// Pyre 1.2 — Party mode v1 (group chats).
//
// Layer 1 (model + persist + sync): `Chat.partyMode` defaults to false,
// round-trips through toJson/fromJson, is omitted from toJson when false
// (byte-clean for the overwhelming majority of chats), and
// `AppStore.setChatPartyMode` mirrors `renameChat` — sets the field, bumps
// `updatedAt`/`mtime` (so the toggle propagates over LAN sync), and notifies
// once. Unknown chat id is a silent no-op.
//
// Layer 2 (prompt assembly): when `partyMode` is true on a chat with >1
// member, `buildChatPrompt` assembles a JOINT leading-system block with
// every member's card (delimited per character) followed by an
// OWNER-TUNABLE joint-scene instruction, INSTEAD OF the single-responder
// card + thin roster. When `partyMode` is false (the default for every
// existing call site), assembly is unaffected — proven by the untouched
// 15-scenario golden net (test/prompt_golden_test.dart), not re-verified here.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_screen.dart'
    show buildFillInOpenerPrompt, groupChatHeaderTitle;
import 'package:pyre/services/chat_api.dart' show ChatTurn;
import 'package:pyre/services/chat_prompt_builder.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

Character? Function(String) _charLookup(List<Character> chars) {
  final byId = {for (final c in chars) c.id: c};
  return (id) => byId[id];
}

String _serialize(List<ChatTurn> turns) =>
    [for (final t in turns) '${t.role}\n${t.content}'].join('\n===TURN===\n');

void main() {
  group('Chat.partyMode model', () {
    test('defaults to false and is omitted from toJson when false', () {
      final chat = Chat(id: 'c1', characterIds: const ['a', 'b']);
      expect(chat.partyMode, isFalse);
      expect(chat.toJson().containsKey('partyMode'), isFalse);
    });

    test('round-trips a true value through toJson/fromJson', () {
      final chat =
          Chat(id: 'c1', characterIds: const ['a', 'b'], partyMode: true);
      expect(chat.toJson()['partyMode'], true);
      final restored = Chat.fromJson(chat.toJson());
      expect(restored.partyMode, isTrue);
    });

    test('fromJson tolerates a missing partyMode key (legacy/old chats)', () {
      final restored = Chat.fromJson({
        'id': 'c1',
        'characterIds': ['a', 'b'],
      });
      expect(restored.partyMode, isFalse);
    });
  });

  group('AppStore.setChatPartyMode', () {
    test('sets the flag, bumps mtime/updatedAt, notifies once', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c1', characterIds: const ['a', 'b']);
      store.chats.add(chat);

      var notifies = 0;
      store.addListener(() => notifies++);

      store.setChatPartyMode('c1', true);

      expect(chat.partyMode, isTrue);
      expect(notifies, 1);
      expect(chat.updatedAt, greaterThan(0));
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('can turn it back off', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat =
          Chat(id: 'c1', characterIds: const ['a', 'b'], partyMode: true);
      store.chats.add(chat);
      store.setChatPartyMode('c1', false);
      expect(chat.partyMode, isFalse);
      await store.flushPersist();
    });

    test('unknown chat id is a silent no-op (no notify)', () async {
      final store = AppStore(storage: _NoopBackend());
      var notifies = 0;
      store.addListener(() => notifies++);
      store.setChatPartyMode('nope', true);
      expect(notifies, 0);
      await store.flushPersist();
    });
  });

  group('AppStore.setChatPersonaParty', () {
    AppStore storeWithPersonas(List<String> ids) {
      final store = AppStore(storage: _NoopBackend());
      for (final id in ids) {
        store.personas.add(Persona(
            id: id, name: id, description: 'x', createdAt: 0, updatedAt: 0));
      }
      return store;
    }

    test('>1 live persona → a party (personaIds set, primary = first)',
        () async {
      final store = storeWithPersonas(['a', 'b']);
      final chat = Chat(id: 'c1', characterIds: const ['ch']);
      store.chats.add(chat);
      store.setChatPersonaParty('c1', ['a', 'b']);
      expect(chat.personaIds, ['a', 'b']);
      expect(chat.personaId, 'a');
      expect(chat.isPersonaParty, isTrue);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('exactly 1 → collapses to a single-persona chat (no party)',
        () async {
      final store = storeWithPersonas(['a', 'b']);
      final chat = Chat(
          id: 'c1', characterIds: const ['ch'], personaIds: ['a', 'b']);
      store.chats.add(chat);
      store.setChatPersonaParty('c1', ['a']);
      expect(chat.personaIds, isEmpty);
      expect(chat.personaId, 'a');
      expect(chat.isPersonaParty, isFalse);
      await store.flushPersist();
    });

    test('drops deleted / duplicate / sentinel ids', () async {
      final store = storeWithPersonas(['a', 'b']);
      store.personas.add(Persona(
          id: 'dead',
          name: 'dead',
          description: 'x',
          deleted: true,
          createdAt: 0,
          updatedAt: 0));
      final chat = Chat(id: 'c1', characterIds: const ['ch']);
      store.chats.add(chat);
      store.setChatPersonaParty('c1', ['a', 'a', 'dead', 'b']);
      expect(chat.personaIds, ['a', 'b']); // deduped, live only
      await store.flushPersist();
    });

    test('empty selection → explicit no-persona', () async {
      final store = storeWithPersonas(['a']);
      final chat = Chat(id: 'c1', characterIds: const ['ch'], personaId: 'a');
      store.chats.add(chat);
      store.setChatPersonaParty('c1', const []);
      expect(chat.personaIds, isEmpty);
      expect(chat.personaId, kExplicitNoPersonaId);
      await store.flushPersist();
    });
  });

  group('buildChatPrompt — party mode joint scene', () {
    test(
        'partyMode true + >1 member assembles ALL member cards + the joint '
        'instruction, instead of single-responder card + thin roster', () {
      final a = Character(
        id: 'pm-char-a',
        name: 'Sera',
        description: 'A quiet blacksmith with soot-stained hands.',
        personality: 'Reserved, dry humor.',
        scenario: 'A small forge.',
        mesExample: '<START>\n{{char}}: *hammers steadily*',
        createdAt: 0,
        updatedAt: 0,
      );
      final b = Character(
        id: 'pm-char-b',
        name: 'Talia',
        description: 'A sharp-tongued merchant.',
        personality: 'Bold, quick to laugh.',
        scenario: 'Runs the market stall next door.',
        createdAt: 0,
        updatedAt: 0,
      );
      final c = Character(
        id: 'pm-char-c',
        name: 'Orin',
        description: 'A watchful town guard.',
        personality: 'Stoic, dutiful.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'pm-persona-1',
        name: 'Alex',
        description: 'A traveling merchant.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        Message(
          id: 'pm-m1',
          kind: MessageKind.user,
          variants: const ['Hello, everyone.'],
          createdAt: 0,
          mtime: 0,
        ),
      ];
      final chat = Chat(
        id: 'pm-chat-1',
        characterIds: [a.id, b.id, c.id],
        characterSnapshots: {a.id: a, b.id: b, c.id: c},
        personaId: persona.id,
        messages: messages,
        partyMode: true,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: a, // the "selected responder" is irrelevant in party mode
        persona: persona,
        preset: null,
        responderId: a.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([a, b, c]),
        lookupBook: (_) => null,
        inFlightMessageId: null,
        partyMode: true,
      );
      final result = buildChatPrompt(inputs);
      final text = _serialize(result.turns);

      // All three members' cards are present.
      for (final ch in [a, b, c]) {
        expect(text, contains(ch.name));
        expect(text, contains(ch.description));
        if (ch.personality.isNotEmpty) {
          expect(text, contains(ch.personality));
        }
      }
      // The joint-scene instruction fired.
      expect(text, contains('narrating a group scene'));
      expect(text, contains('Never speak, act, think, or decide for Alex'));
      // The OLD thin roster ("• Name: tagline") must NOT appear — party mode
      // replaces it with the full joint block.
      expect(text, isNot(contains('Other characters in this scene')));
    });

    test('partyMode false (default) is unaffected — single responder card + '
        'thin roster, exactly as before', () {
      final a = Character(
        id: 'pm2-char-a',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        tagline: 'The town blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final b = Character(
        id: 'pm2-char-b',
        name: 'Talia',
        description: 'A sharp-tongued merchant.',
        tagline: 'Runs the market stall.',
        createdAt: 0,
        updatedAt: 0,
      );
      final chat = Chat(
        id: 'pm2-chat-1',
        characterIds: [a.id, b.id],
        characterSnapshots: {a.id: a, b.id: b},
        messages: const [],
        partyMode: false,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: a,
        persona: null,
        preset: null,
        responderId: a.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([a, b]),
        lookupBook: (_) => null,
        inFlightMessageId: null,
      );
      final result = buildChatPrompt(inputs);
      final text = _serialize(result.turns);

      expect(text, contains('You are Sera.'));
      expect(text, contains('Other characters in this scene'));
      expect(text, isNot(contains('narrating a group scene')));
      // Talia's full description is NOT inlined (only her thin roster line).
      expect(text, isNot(contains(b.description)));
    });

    test(
        'partyMode true with the FLAT locked-default preset (card markers, '
        'no promptBlocks) still assembles the joint block — this preset does '
        'NOT go through injectCardFallback, it goes through fill()\'s '
        '{{description}} substitution', () {
      final a = Character(
        id: 'pm3-char-a',
        name: 'Sera',
        description: 'A quiet blacksmith with soot-stained hands.',
        personality: 'Reserved, dry humor.',
        createdAt: 0,
        updatedAt: 0,
      );
      final b = Character(
        id: 'pm3-char-b',
        name: 'Talia',
        description: 'A sharp-tongued merchant.',
        personality: 'Bold, quick to laugh.',
        createdAt: 0,
        updatedAt: 0,
      );
      final preset = buildLockedDefaultPreset();
      final chat = Chat(
        id: 'pm3-chat-1',
        characterIds: [a.id, b.id],
        characterSnapshots: {a.id: a, b.id: b},
        presetId: preset.id,
        messages: const [],
        partyMode: true,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: a,
        persona: null,
        preset: preset,
        responderId: a.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([a, b]),
        lookupBook: (_) => null,
        inFlightMessageId: null,
        partyMode: true,
      );
      final result = buildChatPrompt(inputs);
      final text = _serialize(result.turns);

      expect(text, contains(a.description));
      expect(text, contains(a.personality));
      expect(text, contains(b.description));
      expect(text, contains(b.personality));
      expect(text, contains('narrating a group scene'));
      expect(text, isNot(contains('Other characters in this scene')));

      // Owner decision (2026-07): in party mode the PRESET's {{char}}
      // resolves to 'Narrator' — the model is the scene's narrator, not any
      // single member. The locked default preset opens with
      // "You are a Gamemaster..." but uses {{char}} later ("...depending on
      // the context..." / card-law prose names {{char}}) — assert the
      // narrator substitution actually landed somewhere.
      expect(text, contains('Narrator'));
      expect(text, isNot(contains('{{char}}')),
          reason: 'no unresolved {{char}} may survive party assembly');
    });

    test(
        'party mode fills {{char}} INSIDE each member card with that '
        'member\'s OWN name (ST-Join parity) and injects no per-member '
        '"You are X." line', () {
      final a = Character(
        id: 'pm4-char-a',
        name: 'Sera',
        description: '{{char}} is a quiet blacksmith. {{char}} trusts {{user}}.',
        createdAt: 0,
        updatedAt: 0,
      );
      final b = Character(
        id: 'pm4-char-b',
        name: 'Talia',
        description: '{{char}} is a sharp-tongued merchant.',
        createdAt: 0,
        updatedAt: 0,
      );
      final world = Character(
        id: 'pm4-world',
        name: 'Eldoria',
        description: 'A rain-soaked frontier town where iron is currency.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'pm4-persona',
        name: 'Alex',
        description: 'A curious traveler.',
        createdAt: 0,
        updatedAt: 0,
      );
      final chat = Chat(
        id: 'pm4-chat-1',
        characterIds: [a.id, b.id, world.id],
        characterSnapshots: {a.id: a, b.id: b, world.id: world},
        personaId: persona.id,
        messages: const [],
        partyMode: true,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: a,
        persona: persona,
        preset: null,
        responderId: a.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([a, b, world]),
        lookupBook: (_) => null,
        inFlightMessageId: null,
        partyMode: true,
      );
      final result = buildChatPrompt(inputs);
      final text = _serialize(result.turns);

      // Each member's self-referential {{char}} resolved to their OWN name —
      // Talia's description must NOT carry Sera's (primary) name.
      expect(text, contains('Sera is a quiet blacksmith. Sera trusts Alex.'));
      expect(text, contains('Talia is a sharp-tongued merchant.'));
      expect(text, isNot(contains('Sera is a sharp-tongued merchant.')));

      // No contradictory per-member identity line — nonsense for a world
      // card ("You are Eldoria.") and impossible with several members.
      expect(text, isNot(contains('You are Sera.')));
      expect(text, isNot(contains('You are Talia.')));
      expect(text, isNot(contains('You are Eldoria.')));
      // The world card still enters as delimited scene context.
      expect(text, contains('--- Eldoria ---'));
      expect(text, contains('A rain-soaked frontier town'));
    });

    test(
        'Fill-In opener with a jointPartyBlock sets up the WHOLE party '
        '(owner feedback: a party-mode "new greeting" opened as the primary '
        'character only)', () {
      final a = Character(
        id: 'fi-char-a',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        createdAt: 0,
        updatedAt: 0,
      );
      final b = Character(
        id: 'fi-char-b',
        name: 'Talia',
        description: 'A sharp-tongued merchant.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'fi-persona',
        name: 'Alex',
        description: 'A curious traveler.',
        createdAt: 0,
        updatedAt: 0,
      );
      final chat = Chat(
        id: 'fi-chat-1',
        characterIds: [a.id, b.id],
        characterSnapshots: {a.id: a, b.id: b},
        messages: const [],
        partyMode: true,
        createdAt: 0,
        updatedAt: 0,
      );
      final joint = buildJointPartyBlock(
        chat: chat,
        persona: persona,
        lookupCharacter: (_) => null,
      );

      final sys = buildFillInOpenerPrompt(
        responder: a,
        persona: persona,
        filledScenario: 'The party gathers at the forge.',
        loreHits: const [],
        presetMainPrompt: '',
        jointPartyBlock: joint,
      );

      // Every member's card is in the opener prompt, via the SAME joint
      // block the ongoing scene turns use.
      expect(sys, contains('--- Sera ---'));
      expect(sys, contains('--- Talia ---'));
      expect(sys, contains(b.description));
      expect(sys, contains('narrating a group scene'));
      // The single-responder canon section is REPLACED, not doubled.
      expect(sys, isNot(contains('You are Sera.')));
      // The opener's own scenario + output instruction still close it out.
      expect(sys, contains('The party gathers at the forge.'));
      expect(sys, contains('Output ONLY the opening message'));
    });
  });

  // Persona party end-to-end: personaParty flows through the REAL builder into
  // the assembled turns (fallback / marker-less path), and a single persona
  // keeps the classic "The user appears as X" line (byte-neutral branch).
  group('buildChatPrompt — persona party', () {
    Character char() => Character(
          id: 'pp-char',
          name: 'Sera',
          description: 'A quiet blacksmith.',
          createdAt: 0,
          updatedAt: 0,
        );
    Persona persona(String id, String name, String desc) =>
        Persona(id: id, name: name, description: desc, createdAt: 0, updatedAt: 0);
    Message userMsg() => Message(
          id: 'pp-m1',
          kind: MessageKind.user,
          variants: const ['We enter the hall.'],
          createdAt: 0,
          mtime: 0,
        );

    test('persona party assembles the joint persona block + collective '
        'instruction, not the single "appears as" line', () {
      final a = persona('pp-a', 'Kael', 'A wandering swordsman.');
      final b = persona('pp-b', 'Mira', 'A sharp-tongued mage.');
      final c = char();
      final chat = Chat(
        id: 'pp-chat',
        characterIds: [c.id],
        characterSnapshots: {c.id: c},
        personaIds: [a.id, b.id],
        messages: [userMsg()],
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: c,
        persona: a, // primary
        personaParty: [a, b],
        preset: null, // fallback / marker-less path
        responderId: c.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([c]),
        lookupBook: (_) => null,
        inFlightMessageId: null,
      );
      final text = _serialize(buildChatPrompt(inputs).turns);
      // Both personas' cards present.
      expect(text, contains('Kael'));
      expect(text, contains('A wandering swordsman.'));
      expect(text, contains('Mira'));
      expect(text, contains('A sharp-tongued mage.'));
      // The collective instruction fired, naming the roster.
      expect(text, contains('Kael, Mira'));
      expect(text.toLowerCase(), contains('collective'));
      // The single-persona line is REPLACED, not doubled.
      expect(text, isNot(contains('The user appears as "Kael".')));
    });

    test('single persona (no party) keeps the classic "appears as" line', () {
      final a = persona('pp-a', 'Kael', 'A wandering swordsman.');
      final c = char();
      final chat = Chat(
        id: 'pp-chat-single',
        characterIds: [c.id],
        characterSnapshots: {c.id: c},
        personaId: a.id,
        messages: [userMsg()],
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: c,
        persona: a,
        // personaParty defaults to [] → single-persona path, byte-neutral.
        preset: null,
        responderId: c.id,
        beatsCap: 3,
        lookupCharacter: _charLookup([c]),
        lookupBook: (_) => null,
        inFlightMessageId: null,
      );
      final text = _serialize(buildChatPrompt(inputs).turns);
      expect(text, contains('The user appears as "Kael".'));
      expect(text.toLowerCase(), isNot(contains('collective')));
    });
  });

  // Persona party (owner 2026-07): the user's side is a GROUP — every persona
  // card feeds the prompt + a collective instruction frames the user's
  // messages as the whole group's action ("a mensagem representa o grupo").
  group('buildJointPersonaBlock', () {
    Persona persona(String name, String desc, {String examples = ''}) =>
        Persona(
          id: 'p-$name',
          name: name,
          description: desc,
          dialogueExamples: examples,
        );

    test('empty roster → empty string (single-persona path stays byte-clean)',
        () {
      expect(buildJointPersonaBlock(const []), '');
    });

    test('includes every persona name + description, delimited', () {
      final block = buildJointPersonaBlock([
        persona('Kael', 'A wandering swordsman.'),
        persona('Mira', 'A sharp-tongued mage.'),
      ]);
      expect(block, contains('--- Kael ---'));
      expect(block, contains('A wandering swordsman.'));
      expect(block, contains('--- Mira ---'));
      expect(block, contains('A sharp-tongued mage.'));
    });

    test('collective instruction names the group + frames msgs as the group',
        () {
      final block = buildJointPersonaBlock([
        persona('Kael', 'x'),
        persona('Mira', 'y'),
      ]);
      // roster named in the instruction
      expect(block, contains('Kael, Mira'));
      // frames the user's message as the whole group's action
      expect(block.toLowerCase(), contains('collective'));
      // never takes over the user's group
      expect(block.toLowerCase(), contains('never'));
    });

    test('surfaces dialogue examples when present', () {
      final block = buildJointPersonaBlock([
        persona('Kael', 'x', examples: '{{user}}: For the crown!'),
      ]);
      expect(block, contains('For the crown!'));
    });
  });

  // Group chat header (owner: "essa informação não é atualizada no header").
  group('groupChatHeaderTitle', () {
    test('joins member names with " · "', () {
      expect(groupChatHeaderTitle(['Aria', 'Bran', 'Cyra']),
          'Aria · Bran · Cyra');
    });

    test('skips blank / whitespace names', () {
      expect(groupChatHeaderTitle(['Aria', '', '  ', 'Cyra']), 'Aria · Cyra');
    });

    test('single name → just that name', () {
      expect(groupChatHeaderTitle(['Aria']), 'Aria');
    });

    test('no names → empty string', () {
      expect(groupChatHeaderTitle(const []), '');
      expect(groupChatHeaderTitle(['', '   ']), '');
    });
  });

  // C (#129): Continuing a party SCENE message (characterId == null, voiced by
  // the Narrator over the whole party) must keep the narrator framing. The
  // plain char continue nudge resumes in the PRIMARY character's voice, which
  // collapses a multi-character scene into one voice.
  group('buildPartyContinueNudge', () {
    test('quotes the literal tail so the model extends, not restarts', () {
      final nudge = buildPartyContinueNudge(
        tail: '…and the door creaked open.',
        memberNames: ['Aria', 'Bran'],
        userName: 'Kai',
      );
      expect(nudge, contains('…and the door creaked open.'));
      expect(nudge, contains('EXACTLY from where it stops'));
    });

    test('keeps narrator framing: voice all members, do not collapse to one',
        () {
      final nudge = buildPartyContinueNudge(
        tail: 'x',
        memberNames: ['Aria', 'Bran', 'Cyra'],
        userName: 'Kai',
      );
      // names the roster and forbids single-character collapse
      expect(nudge, contains('Aria, Bran, Cyra'));
      expect(nudge.toLowerCase(), contains('single character'));
      // never speak for the user persona
      expect(nudge, contains('Kai'));
    });

    test('degrades gracefully when member names are missing/blank', () {
      final nudge = buildPartyContinueNudge(
        tail: 'x',
        memberNames: ['', '  '],
        userName: 'Kai',
      );
      expect(nudge, contains('the characters in the scene'));
      // no dangling empty roster like "voicing  in their"
      expect(nudge, isNot(contains('voicing  ')));
    });
  });
}
