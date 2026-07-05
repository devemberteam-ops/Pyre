// 2026-07-05 (Gui, "grande bug"): the Fill-In scenario OOC note (1) applied
// to EVERY greeting variant — it was made chat-level canon in an earlier
// round, but the real-world result is a custom scenario glued above the
// card's canonical greetings — and (2) deleting it with cascade delete ON
// wiped the ENTIRE chat (the note sits at index 0; cascade removeRange took
// the greeting message with all its variants and stashed branches).
//
// Fixes locked here:
//   A. Cascade delete NEVER applies to aux notes (OOC / Scene / System) —
//      deleting a note deletes just the note. The explicit
//      cascadeOverride:true ("Truncate from here") still cascades.
//   B. The Fill-In note is BOUND to the greeting variant it generated
//      (Message.greetingVariant): it renders and replays into the prompt
//      only while that variant is selected. Unbound notes (legacy / manual
//      OOCs) behave exactly as before.
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
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

Message _m(String id, MessageKind kind, String text,
        {int? greetingVariant}) =>
    Message(
      id: id,
      kind: kind,
      variants: [text],
      createdAt: 0,
    )..greetingVariant = greetingVariant;

void main() {
  group('Message.greetingVariant', () {
    test('round-trips; omitted from json when null (legacy byte-compat)', () {
      final bound = _m('a', MessageKind.ooc, 'Scenario: x', greetingVariant: 2);
      expect(Message.fromJson(bound.toJson()).greetingVariant, 2);
      final plain = _m('b', MessageKind.ooc, 'manual note');
      expect(plain.toJson().containsKey('greetingVariant'), isFalse);
      expect(Message.fromJson(plain.toJson()).greetingVariant, isNull);
    });
  });

  group('hiddenByGreetingVariant', () {
    List<Message> chatMsgs({required int selected}) => [
          _m('ooc0', MessageKind.ooc, 'Scenario: tavern', greetingVariant: 1),
          Message(
            id: 'greet',
            kind: MessageKind.char,
            variants: const ['card greeting', 'fill-in greeting'],
            selectedVariant: selected,
            createdAt: 0,
          ),
        ];

    test('bound note shows only while ITS greeting variant is selected', () {
      final onFillIn = chatMsgs(selected: 1);
      expect(hiddenByGreetingVariant(onFillIn, onFillIn.first), isFalse);
      final onCanon = chatMsgs(selected: 0);
      expect(hiddenByGreetingVariant(onCanon, onCanon.first), isTrue);
    });

    test('unbound notes and non-OOC messages are never hidden', () {
      final msgs = chatMsgs(selected: 0)
        ..insert(0, _m('manual', MessageKind.ooc, 'manual note'));
      expect(hiddenByGreetingVariant(msgs, msgs.first), isFalse);
      expect(hiddenByGreetingVariant(msgs, msgs.last), isFalse);
    });

    test('no greeting message at all → nothing hidden', () {
      final msgs = [
        _m('ooc0', MessageKind.ooc, 'Scenario: x', greetingVariant: 0)
      ];
      expect(hiddenByGreetingVariant(msgs, msgs.first), isFalse);
    });
  });

  group('cascade delete vs aux notes (the data-loss half)', () {
    AppStore storeWithChat() {
      final s = AppStore(storage: _NoopBackend());
      final chat = Chat(
        id: 'c1',
        characterIds: const ['x'],
        messages: [
          _m('note', MessageKind.ooc, 'Scenario: tavern', greetingVariant: 1),
          Message(
            id: 'greet',
            kind: MessageKind.char,
            variants: const ['g1', 'g2'],
            createdAt: 0,
          ),
          _m('u1', MessageKind.user, 'hi'),
          _m('c2', MessageKind.char, 'reply'),
        ],
        createdAt: 0,
        updatedAt: 0,
      );
      s.chats.add(chat);
      s.chatSettings.deleteBehavior = DeleteBehavior.thisAndAfter;
      return s;
    }

    test('FAILING-BEFORE-FIX: deleting the scenario note with cascade ON '
        'keeps the rest of the chat', () {
      final s = storeWithChat();
      s.removeMessage('c1', 'note');
      final ids = s.chats.first.messages.map((m) => m.id).toList();
      expect(ids, ['greet', 'u1', 'c2'],
          reason: 'cascade must not wipe the chat below an aux note');
    });

    test('cascade still applies to REGULAR messages', () {
      final s = storeWithChat();
      s.removeMessage('c1', 'u1');
      expect(s.chats.first.messages.map((m) => m.id), ['note', 'greet']);
    });

    test('explicit cascadeOverride (Truncate from here) still cascades from '
        'an aux note', () {
      final s = storeWithChat();
      s.removeMessage('c1', 'note', cascadeOverride: true);
      expect(s.chats.first.messages, isEmpty);
    });
  });
}
