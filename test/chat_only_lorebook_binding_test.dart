// State-order audit #1: "Edit (this chat only)" lorebook binding edits used
// to be written into `chat.characterSnapshots[cid].lorebookIds` — a dead
// end, since `collectBoundLorebooks` reads bindings LIVE-first from the
// library character and only falls back to the snapshot when the library
// card has been deleted. The edit looked like it saved (the editor even
// read the snapshot back) but never actually changed what fired.
//
// The fix routes the edit through `applyChatOnlyBindingEdit`, which mutates
// the chat's own per-chat sets (`attachedLorebookIds` /
// `disabledInheritedLorebookIds`) — the ones `collectBoundLorebooks` already
// honours. These are pure-level tests: build a Chat + Character directly and
// assert against `collectBoundLorebooks`, exactly like the engine would see
// it at send time.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/character_edit_screen.dart';
import 'package:pyre/services/chat_only_lorebook_binding.dart';
import 'package:pyre/services/lorebook_inject.dart';
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

void main() {
  // A single shared LIVE library character bound to book A, used across
  // two different chats to prove the per-chat edit is scoped to ONE chat.
  Character liveCharBoundToA() => Character(
        id: 'char-1',
        name: 'Vera',
        description: 'A quiet archivist.',
        lorebookIds: const ['book-a'],
      );

  List<Lorebook> boundBooksFor(Chat chat, Character liveChar) =>
      collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: (id) => {
          'book-a': Lorebook(id: 'book-a', name: 'A', entries: const []),
          'book-b': Lorebook(id: 'book-b', name: 'B', entries: const []),
        }[id],
        lookupCharacter: (id) => id == liveChar.id ? liveChar : null,
      );

  group('applyChatOnlyBindingEdit', () {
    test('removing a live-bound book from the edited list disables it for '
        'THIS chat only — a second chat with the same character still '
        'gets it', () {
      final liveChar = liveCharBoundToA();

      final chatA = Chat(
        id: 'chat-edited',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: liveChar},
      );
      final chatB = Chat(
        id: 'chat-untouched',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: liveChar},
      );

      // User opens "Edit (this chat only)" on chatA and removes book-a.
      applyChatOnlyBindingEdit(chatA, liveChar.lorebookIds, const []);

      expect(chatA.disabledInheritedLorebookIds, contains('book-a'));
      expect(
        boundBooksFor(chatA, liveChar).map((b) => b.id),
        isNot(contains('book-a')),
        reason: 'the edited chat must stop injecting book-a',
      );
      expect(
        boundBooksFor(chatB, liveChar).map((b) => b.id),
        contains('book-a'),
        reason: 'an untouched chat with the same character keeps injecting '
            'the live binding',
      );
    });

    test('adding a book NOT on the live character attaches it per-chat '
        'only — injected in that chat only', () {
      final liveChar = liveCharBoundToA(); // bound to book-a only

      final chatA = Chat(
        id: 'chat-edited',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: liveChar},
      );
      final chatB = Chat(
        id: 'chat-untouched',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: liveChar},
      );

      // User adds book-b (not on the live character) in chatA's editor.
      applyChatOnlyBindingEdit(
          chatA, liveChar.lorebookIds, const ['book-a', 'book-b']);

      expect(chatA.attachedLorebookIds, contains('book-b'));
      expect(
        boundBooksFor(chatA, liveChar).map((b) => b.id),
        containsAll(['book-a', 'book-b']),
      );
      expect(
        boundBooksFor(chatB, liveChar).map((b) => b.id),
        isNot(contains('book-b')),
        reason: 'book-b was only attached to chatA, not the character',
      );
    });

    test('re-adding a previously-removed live binding clears the '
        'disabled-inherited entry and injects again', () {
      final liveChar = liveCharBoundToA();
      final chat = Chat(
        id: 'chat-1',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: liveChar},
      );

      // Step 1: remove book-a.
      applyChatOnlyBindingEdit(chat, liveChar.lorebookIds, const []);
      expect(chat.disabledInheritedLorebookIds, contains('book-a'));
      expect(boundBooksFor(chat, liveChar).map((b) => b.id),
          isNot(contains('book-a')));

      // Step 2: user re-opens the editor and re-adds book-a.
      applyChatOnlyBindingEdit(
          chat, liveChar.lorebookIds, const ['book-a']);
      expect(chat.disabledInheritedLorebookIds, isNot(contains('book-a')));
      expect(boundBooksFor(chat, liveChar).map((b) => b.id),
          contains('book-a'));
    });

    test('a book previously per-chat-attached but removed from the edited '
        'list is dropped from attachedLorebookIds (not left dangling as '
        'always-on)', () {
      final liveChar = liveCharBoundToA();
      final chat = Chat(
        id: 'chat-1',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: liveChar},
      );

      // Attach book-b per-chat.
      applyChatOnlyBindingEdit(
          chat, liveChar.lorebookIds, const ['book-a', 'book-b']);
      expect(chat.attachedLorebookIds, contains('book-b'));

      // User re-opens the editor and removes book-b again.
      applyChatOnlyBindingEdit(
          chat, liveChar.lorebookIds, const ['book-a']);
      expect(chat.attachedLorebookIds, isNot(contains('book-b')));
      expect(boundBooksFor(chat, liveChar).map((b) => b.id),
          isNot(contains('book-b')));
    });

    test('narrative snapshot fields (and its lorebookIds) are untouched by '
        'a binding edit — only chat-level sets change', () {
      final liveChar = liveCharBoundToA();
      final snapshot = Character(
        id: liveChar.id,
        name: 'Vera (frozen)',
        description: 'Frozen narrative text at chat creation.',
        lorebookIds: const ['book-a'], // whatever it happened to be frozen at
      );
      final chat = Chat(
        id: 'chat-1',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: snapshot},
      );

      applyChatOnlyBindingEdit(chat, liveChar.lorebookIds, const []);

      final snapAfter = chat.characterSnapshots[liveChar.id]!;
      expect(snapAfter.name, 'Vera (frozen)');
      expect(snapAfter.description, 'Frozen narrative text at chat creation.');
      expect(snapAfter.lorebookIds, ['book-a'],
          reason: 'the snapshot\'s lorebookIds must be left exactly as it '
              'was — the engine ignores it for a live character, and the '
              'snapshot stays a pure narrative freeze');
    });
  });

  // ── Widget wiring: CharacterEditScreen "Edit (this chat only)" mode ──────
  //
  // End-to-end proof that the screen's Save button actually routes through
  // applyChatOnlyBindingEdit — not just the pure function in isolation.
  group('CharacterEditScreen "Edit (this chat only)" wiring', () {
    testWidgets(
        'removing the bound chip + Save disables it via '
        'disabledInheritedLorebookIds, leaves the snapshot lorebookIds '
        'untouched, and still flushes narrative edits', (tester) async {
      final store = AppStore(storage: _NoopBackend());
      final liveChar = Character(
        id: 'char-1',
        name: 'Vera',
        description: 'A quiet archivist.',
        lorebookIds: const ['book-a'],
      );
      store.characters.add(liveChar);
      store.lorebooks.add(Lorebook(id: 'book-a', name: 'BookA', entries: const []));
      // Frozen snapshot with its OWN lorebookIds — proves it's left alone.
      final snapshot = Character(
        id: 'char-1',
        name: 'Vera',
        description: 'Frozen narrative text.',
        lorebookIds: const [],
      );
      final chat = Chat(
        id: 'chat-1',
        characterIds: const ['char-1'],
        characterSnapshots: {'char-1': snapshot},
      );
      store.chats.add(chat);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: const MaterialApp(
            home: CharacterEditScreen(
              characterId: 'char-1',
              overrideChatId: 'chat-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The lorebook binding section is far down the scrollable form —
      // scroll it into view before asserting/interacting.
      final scrollable = find.byType(Scrollable).first;
      await tester.dragUntilVisible(
        find.byIcon(Icons.close),
        scrollable,
        const Offset(0, -300),
      );

      // Sanity: the binding section was seeded from the LIVE binding (book-a
      // shows up as a chip), not the (empty) snapshot.
      expect(find.textContaining('BookA'), findsOneWidget);

      // Tap the chip's delete (×) icon to remove book-a from the edited list.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.textContaining('BookA'), findsNothing);

      // Also touch a narrative field so we can confirm narrative edits still
      // flush to the snapshot exactly as before. Scroll back up to reach it.
      await tester.dragUntilVisible(
        find.widgetWithText(TextField, 'Description'),
        scrollable,
        const Offset(0, 300),
      );
      await tester.enterText(
          find.widgetWithText(TextField, 'Description'), 'Updated text.');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();

      // Binding edit landed in the chat's per-chat sets, NOT the snapshot.
      expect(chat.disabledInheritedLorebookIds, contains('book-a'));
      expect(
        collectBoundLorebooks(
          chat: chat,
          persona: null,
          lookupBook: store.lorebookById,
          lookupCharacter: store.characterById,
        ).map((b) => b.id),
        isNot(contains('book-a')),
        reason: 'the live binding must actually stop firing for this chat',
      );
      final savedSnapshot = chat.characterSnapshots['char-1']!;
      expect(savedSnapshot.lorebookIds, const <String>[],
          reason: 'the snapshot\'s lorebookIds must stay untouched by the '
              'binding edit');
      // Narrative edit DID flush to the snapshot (unchanged policy).
      expect(savedSnapshot.description, 'Updated text.');
      // The LIVE library character's own bindings are untouched too.
      expect(store.characterById('char-1')!.lorebookIds, const ['book-a']);
    });
  });
}
