@TestOn('vm')
library;

// OOC convention (2026-07-12, owner-reported: "the story sometimes treats OOC as
// character speech"). The prompt builder now injects a one-time post-history
// system note teaching the model what an `[OOC]:` turn means — but ONLY when an
// OOC turn is actually replayed. These tests pin: appears with OOC, absent
// without, and does NOT fire for an OOC hidden by a non-selected greeting variant.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

const _needle = 'out-of-character instructions';

Message _m(String id, MessageKind kind, List<String> variants, {int sel = 0}) =>
    Message(id: id, kind: kind, variants: variants, selectedVariant: sel);

bool _hasConvention(List<Message> messages) {
  final character = Character(
      id: 'c', name: 'Sera', description: 'A quiet blacksmith.',
      createdAt: 0, updatedAt: 0);
  final chat = Chat(
    id: 'ch',
    characterIds: [character.id],
    characterSnapshots: {character.id: character},
    messages: messages,
    createdAt: 0,
    updatedAt: 0,
  );
  final result = buildChatPrompt(ChatPromptInputs(
    chat: chat,
    character: character,
    persona: null,
    preset: null,
    responderId: character.id,
    beatsCap: 3,
    lookupCharacter: (id) => id == character.id ? character : null,
    lookupBook: (id) => null,
    inFlightMessageId: null,
  ));
  return result.turns.any(
      (t) => t.role == 'system' && t.content.contains(_needle));
}

void main() {
  test('an OOC turn adds the convention note (as a system turn)', () {
    expect(
        _hasConvention([
          _m('g', MessageKind.char, ['*Sera looks up.*']),
          _m('u', MessageKind.user, ['Hi.']),
          _m('o', MessageKind.ooc, ['make her colder']),
          _m('u2', MessageKind.user, ['Still there?']),
        ]),
        isTrue);
  });

  test('no OOC turn → no convention note (byte-clean for classic chats)', () {
    expect(
        _hasConvention([
          _m('g', MessageKind.char, ['*Sera looks up.*']),
          _m('u', MessageKind.user, ['Hi.']),
          _m('a', MessageKind.char, ['"Evening."']),
        ]),
        isFalse);
  });

  test('an OOC hidden by a non-selected greeting variant does NOT fire the gate',
      () {
    // Greeting (first char message) sits on variant 0; the OOC note is bound to
    // greeting variant 1, so it is NOT part of this branch → skipped → no note.
    final ooc = _m('o', MessageKind.ooc, ['secret aside'])..greetingVariant = 1;
    expect(
        _hasConvention([
          _m('g', MessageKind.char, ['Hi v0', 'Hi v1'], sel: 0),
          ooc,
          _m('u', MessageKind.user, ['hello']),
        ]),
        isFalse);
  });
}
