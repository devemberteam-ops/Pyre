@TestOn('vm')
library;

// Design study round 3 — the "first-message wall" fix.
//
// Before the fix, `_send` cleared the composer and PERSISTED the user's turn
// before `_runGenerationInto` discovered there was no provider: the typed
// message was left as an orphan turn under a dead "Retry" (Retry re-failed
// forever, since the cause is structural). This test drives a REAL ChatScreen
// with NO provider configured and asserts the preflight now:
//   1. does NOT append the user's turn (no orphan message);
//   2. KEEPS the typed draft in the composer;
//   3. shows an ACTIONABLE "Set up provider" prompt (deep-link), not a
//      "go to More → API Connections" path instruction.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_screen.dart';
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

Widget _host(AppStore store, Widget screen) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: screen),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'no provider: send keeps the draft, appends no turn, and offers a '
      'Set up provider deep-link (first-message wall)', (tester) async {
    final store = AppStore(storage: _NoopBackend());

    final character = Character(
      id: 'char-1',
      name: 'Sera',
      description: 'A quiet blacksmith.',
      personality: 'Reserved.',
      scenario: 'A forge.',
      createdAt: 0,
      updatedAt: 0,
    );
    store.characters.add(character);
    // Deliberately NO provider: providers stays empty, activeProviderId null.

    final chat = Chat(
      id: 'chat-1',
      characterIds: [character.id],
      characterSnapshots: {character.id: character},
      messages: [
        Message(
          id: 'g0',
          kind: MessageKind.char,
          characterId: character.id,
          variants: ['*Sera looks up from the anvil.*'],
          createdAt: 0,
          mtime: 0,
        ),
      ],
      memoryEnabled: false,
      liveSheetEnabled: false,
      createdAt: 0,
      updatedAt: 0,
    );
    store.chats.add(chat);

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_host(store, ChatScreen(chatId: chat.id)));
    await tester.pump();

    final messagesBefore = chat.messages.length; // just the greeting

    await tester.enterText(find.byType(TextField).first, 'Hello there Sera');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump(); // preflight runs synchronously
    await tester.pump(const Duration(milliseconds: 300)); // snackbar animates in

    // (1) No orphan turn: the user's message was NOT appended.
    expect(chat.messages.length, messagesBefore,
        reason: 'with no provider the send must be blocked BEFORE it '
            'persists a user turn — no orphan message');
    expect(chat.messages.any((m) => m.text.contains('Hello there Sera')),
        isFalse,
        reason: 'the typed text must not have been committed to the chat');

    // (2) Draft preserved: the text is still in the composer.
    expect(find.text('Hello there Sera'), findsOneWidget,
        reason: 'a blocked send must keep the draft so the user does not '
            'retype it after connecting a provider');

    // (3) Actionable recovery: a "Set up provider" action (deep-link), not a
    // navigation instruction the user has to follow by hand.
    expect(find.text('Set up provider'), findsOneWidget,
        reason: 'the block must offer a one-tap route to API Connections');

    // Let the snackbar's auto-dismiss timer fire so no timer dangles into
    // teardown (simulated time — instant).
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
  });
}
