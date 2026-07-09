// Round-trip tests for the Pyre chat IMPORTER (services/chat_import.dart), the
// inverse of services/chat_export.dart. We EXPORT a known chat with each
// exporter, IMPORT it back, and assert the reconstruction matches — for BOTH
// Pyre formats — plus foreign SillyTavern JSONL and malformed-input handling.
//
// PURE: no Flutter bindings, no store. importChat is a plain function.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_export.dart';
import 'package:pyre/services/chat_import.dart';

Character _hero() => Character(id: 'char_hero', name: 'Hero', description: 'A brave knight');

/// A chat exercising every MessageKind, a multi-variant message with a
/// non-default selection, and fixed timestamps so order/roles/variants/times
/// are all assertable on the way back in.
Chat _sampleChat({String? title}) => Chat(
      id: 'chat_orig_1',
      title: title,
      characterIds: ['char_hero'],
      characterSnapshots: {'char_hero': _hero()},
      messages: [
        Message(
          id: 'm1',
          kind: MessageKind.char,
          characterId: 'char_hero',
          variants: ['Hello there', 'General Kenobi', 'Greetings, traveler'],
          selectedVariant: 1,
          createdAt: 1000,
        ),
        Message(
            id: 'm2',
            kind: MessageKind.user,
            variants: ['I raise my sword'],
            createdAt: 2000),
        Message(
            id: 'm3',
            kind: MessageKind.ooc,
            variants: ['can we slow the pace?'],
            createdAt: 3000),
        Message(
            id: 'm4',
            kind: MessageKind.scene,
            variants: ['Thunder cracks overhead.'],
            createdAt: 4000),
        Message(
            id: 'm5',
            kind: MessageKind.char,
            characterId: 'char_hero',
            variants: ['As you wish.'],
            createdAt: 5000),
      ],
    );

const _expectedTexts = [
  'General Kenobi',
  'I raise my sword',
  'can we slow the pace?',
  'Thunder cracks overhead.',
  'As you wish.',
];
const _expectedKinds = [
  MessageKind.char,
  MessageKind.user,
  MessageKind.ooc,
  MessageKind.scene,
  MessageKind.char,
];

void main() {
  group('pyre.chat.v1 (full fidelity)', () {
    test('round-trips messages, order, variants, title, ids, timestamps', () {
      final chat = _sampleChat(title: 'The Renamed Saga');
      final json = chatToPyreJson(chat);

      final r = importChat(json, knownCharacterIds: {'char_hero'});

      expect(r.summary.format, ChatImportFormat.pyreJson);
      final imported = r.chat;
      expect(imported.messages.length, 5);
      expect(imported.messages.map((m) => m.text).toList(), _expectedTexts);
      expect(imported.messages.map((m) => m.kind).toList(), _expectedKinds);
      expect(imported.messages.map((m) => m.createdAt).toList(),
          [1000, 2000, 3000, 4000, 5000]);
      // Variants + selection survive on the multi-variant message.
      expect(imported.messages[0].variants,
          ['Hello there', 'General Kenobi', 'Greetings, traveler']);
      expect(imported.messages[0].selectedVariant, 1);
      // Renamed title round-trips (full-fidelity format carries it).
      expect(imported.title, 'The Renamed Saga');
      // Character binding kept; id preserved (no collision).
      expect(imported.characterIds, ['char_hero']);
      expect(r.summary.characterBound, isTrue);
      expect(imported.id, 'chat_orig_1');
    });

    test('id collision → fresh id + a warning (no clobber)', () {
      final json = chatToPyreJson(_sampleChat());
      final r = importChat(json, existingChatIds: {'chat_orig_1'});
      expect(r.chat.id, isNot('chat_orig_1'));
      expect(r.summary.warnings, isNotEmpty);
    });

    test('unknown character → unbound, but self-contained snapshot survives',
        () {
      final json = chatToPyreJson(_sampleChat());
      final r = importChat(json, knownCharacterIds: {}); // empty library
      expect(r.summary.characterBound, isFalse);
      expect(r.chat.characterSnapshots.containsKey('char_hero'), isTrue);
      expect(r.summary.warnings, isNotEmpty);
      expect(r.chat.messages.length, 5); // fully imported, not partial
    });
  });

  group('Pyre JSONL', () {
    test('round-trips messages, order, kinds, variants, timestamps', () {
      final chat = _sampleChat(title: 'ignored-by-jsonl');
      final jsonl = chatToSillyTavernJsonl(
          chat: chat, userName: 'User', characterName: 'Hero');

      final r = importChat(jsonl, knownCharacterIds: {'char_hero'});

      expect(r.summary.format, ChatImportFormat.pyreJsonl);
      final imported = r.chat;
      expect(imported.messages.length, 5);
      expect(imported.messages.map((m) => m.text).toList(), _expectedTexts);
      expect(imported.messages.map((m) => m.kind).toList(), _expectedKinds);
      expect(imported.messages.map((m) => m.createdAt).toList(),
          [1000, 2000, 3000, 4000, 5000]);
      // [OOC]:/[Scene]: prefixes are stripped — the real kind is in pyre_kind.
      expect(imported.messages[2].text, 'can we slow the pace?');
      expect(imported.messages[3].text, 'Thunder cracks overhead.');
      // pyre_variants restore the alternates + the correct selection.
      expect(imported.messages[0].variants,
          ['Hello there', 'General Kenobi', 'Greetings, traveler']);
      expect(imported.messages[0].selectedVariant, 1);
      // Bound via extra.pyre_character_id.
      expect(imported.characterIds, ['char_hero']);
      expect(r.summary.characterBound, isTrue);
    });

    test('unknown character id → unbound chat, no crash, warned', () {
      final jsonl = chatToSillyTavernJsonl(
          chat: _sampleChat(), userName: 'User', characterName: 'Hero');
      final r = importChat(jsonl, knownCharacterIds: {}); // empty library
      expect(r.summary.characterBound, isFalse);
      expect(r.chat.characterIds, isEmpty);
      expect(r.chat.messages.length, 5);
      expect(r.summary.warnings, isNotEmpty);
    });

    test('pyre_chat_id preserved when there is no collision', () {
      final jsonl = chatToSillyTavernJsonl(
          chat: _sampleChat(), userName: 'User', characterName: 'Hero');
      final r = importChat(jsonl);
      expect(r.chat.id, 'chat_orig_1');
    });
  });

  group('foreign SillyTavern JSONL (no Pyre hints)', () {
    test('best-effort maps is_user/is_system → kind', () {
      final jsonl = [
        jsonEncode({
          'user_name': 'Alice',
          'character_name': 'Bob',
          'create_date': '2024-01-01',
          'chat_metadata': <String, dynamic>{},
        }),
        jsonEncode({
          'name': 'Bob',
          'is_user': false,
          'is_system': false,
          'send_date': 1000,
          'mes': 'Hi Alice',
        }),
        jsonEncode({
          'name': 'Alice',
          'is_user': true,
          'send_date': 2000,
          'mes': 'Hi Bob',
        }),
      ].join('\n');

      final r = importChat(jsonl);

      expect(r.summary.format, ChatImportFormat.foreignJsonl);
      expect(r.chat.messages.length, 2);
      expect(r.chat.messages[0].kind, MessageKind.char);
      expect(r.chat.messages[1].kind, MessageKind.user);
      expect(r.chat.messages.map((m) => m.text).toList(), ['Hi Alice', 'Hi Bob']);
    });

    test('swipes[] become variants (ST re-rolls)', () {
      final jsonl = [
        jsonEncode({'user_name': 'A', 'character_name': 'B', 'chat_metadata': {}}),
        jsonEncode({
          'name': 'B',
          'is_user': false,
          'mes': 'roll two',
          'swipes': ['roll one', 'roll two', 'roll three'],
          'swipe_id': 1,
          'send_date': 10,
        }),
      ].join('\n');
      final r = importChat(jsonl);
      expect(r.chat.messages.single.variants,
          ['roll one', 'roll two', 'roll three']);
      expect(r.chat.messages.single.selectedVariant, 1);
    });
  });

  group('malformed / unsupported input', () {
    test('garbage → readable ChatImportException, nothing imported', () {
      expect(
        () => importChat('this is not json at all\n{ broken'),
        throwsA(isA<ChatImportException>()),
      );
    });

    test('header-only Pyre JSONL (zero messages) → empty error', () {
      final headerOnly = jsonEncode({
        'user_name': 'U',
        'character_name': 'C',
        'create_date': '2024',
        'chat_metadata': {'pyre_origin': true, 'pyre_chat_id': 'x'},
      });
      expect(() => importChat(headerOnly),
          throwsA(isA<ChatImportException>()));
    });

    test('the error message is human-readable', () {
      try {
        importChat('%%%% nonsense %%%%');
        fail('expected a ChatImportException');
      } on ChatImportException catch (e) {
        expect(e.message, isNotEmpty);
        expect(e.message.toLowerCase(), contains('chat'));
      }
    });
  });
}
