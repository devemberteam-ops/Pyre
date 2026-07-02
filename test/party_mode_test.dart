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
  });
}
