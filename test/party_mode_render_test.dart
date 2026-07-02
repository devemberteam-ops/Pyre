@TestOn('vm')
library;

// Pyre 1.2 — Party mode v1, Layer 4 (render).
//
// OWNER DECISION (2026-07, revised after live testing): a party-scene message
// (a char message with `characterId == null` in a party-mode group chat)
// renders with:
//   1. A "Narrator" header (matches the prompt-side framing; who is in the
//      party is conveyed by the avatar cluster, not the header).
//   2. A stacked mini-avatar cluster (up to 3 circles) instead of one portrait.
// A normal single-responder group message (characterId set) keeps rendering
// exactly as before — one name, one avatar.
//
// This test pumps the REAL `ChatScreen` (mirrors test/context_recovery_test.dart's
// harness) so it exercises the actual widget tree, not a hand-built fixture.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_screen.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';
import 'package:pyre/widgets/avatar.dart';

class _MemoryBackend implements StoreBackend {
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

  Future<String> pumpGroupChat(
    WidgetTester tester, {
    required bool partyMode,
    required List<Character> members,
    required List<Message> messages,
  }) async {
    final backend = _MemoryBackend();
    final store = AppStore(storage: backend);
    for (final m in members) {
      store.characters.add(m);
    }
    final chat = Chat(
      id: 'chat-1',
      characterIds: [for (final m in members) m.id],
      characterSnapshots: {for (final m in members) m.id: m},
      messages: messages,
      memoryEnabled: false,
      liveSheetEnabled: false,
      partyMode: partyMode,
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
    return chat.id;
  }

  testWidgets(
      'party-scene message (characterId null, partyMode on) shows a '
      '"Narrator" header and a stacked avatar cluster', (tester) async {
    final sera = Character(id: 'a', name: 'Sera', createdAt: 0, updatedAt: 0);
    final talia =
        Character(id: 'b', name: 'Talia', createdAt: 0, updatedAt: 0);
    final orin = Character(id: 'c', name: 'Orin', createdAt: 0, updatedAt: 0);

    await pumpGroupChat(
      tester,
      partyMode: true,
      members: [sera, talia, orin],
      messages: [
        Message(
          id: 'm2',
          kind: MessageKind.char,
          characterId: null, // party scene message
          variants: const [
            'Sera: *hammers steadily.* Talia: "Anyone hungry?" '
                'Orin: *stands watch, silent.*'
          ],
          createdAt: 0,
          mtime: 0,
        ),
      ],
    );

    // Header reads "Narrator" (owner decision after live testing — matches
    // the prompt-side framing; WHO is in the party is shown by the avatar
    // cluster). Scoped to the speaker-name header widget (Key) to avoid
    // colliding with the AppBar title / avatar fallback-letter text.
    final header = find.byKey(const Key('speakerNameHeader'));
    expect(header, findsOneWidget);
    expect(tester.widget<Text>(header).data, 'Narrator');

    // Stacked cluster: 3 mini AvatarBubbles for the party message (one per
    // member), scoped to the message LIST (excludes the AppBar's own
    // primary-character avatar, which is unrelated to this bubble).
    final listAvatars = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(AvatarBubble),
    );
    expect(listAvatars, findsNWidgets(3));
  });

  testWidgets(
      'single-responder group message (characterId set) keeps rendering one '
      'name + one avatar, even in a party-mode chat', (tester) async {
    final sera = Character(id: 'a', name: 'Sera', createdAt: 0, updatedAt: 0);
    final talia =
        Character(id: 'b', name: 'Talia', createdAt: 0, updatedAt: 0);

    await pumpGroupChat(
      tester,
      partyMode: true,
      members: [sera, talia],
      messages: [
        Message(
          id: 'm1',
          kind: MessageKind.char,
          characterId: sera.id, // single author, NOT a party-scene message
          variants: const ['*Sera nods.* "Morning."'],
          createdAt: 0,
          mtime: 0,
        ),
      ],
    );

    // Only Sera's name shows in the header (not a joined header).
    final header = find.byKey(const Key('speakerNameHeader'));
    expect(header, findsOneWidget);
    expect(tester.widget<Text>(header).data, 'Sera');
    // Exactly one avatar for this single-author message (scoped to the
    // message list — excludes the AppBar's own avatar; party mode is on so
    // the responder chips, which would add a 2nd avatar per member, are
    // hidden here).
    final listAvatars = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(AvatarBubble),
    );
    expect(listAvatars, findsNWidgets(1));
  });

  testWidgets(
      'party mode OFF: a characterId-null group message keeps falling back '
      'to the primary character (pre-existing edge case, unaffected)',
      (tester) async {
    final sera = Character(id: 'a', name: 'Sera', createdAt: 0, updatedAt: 0);
    final talia =
        Character(id: 'b', name: 'Talia', createdAt: 0, updatedAt: 0);

    await pumpGroupChat(
      tester,
      partyMode: false,
      members: [sera, talia],
      messages: [
        Message(
          id: 'm1',
          kind: MessageKind.char,
          characterId: null,
          variants: const ['*Someone speaks.*'],
          createdAt: 0,
          mtime: 0,
        ),
      ],
    );

    // Falls back to the primary character's name/avatar exactly as before —
    // no joined header, no cluster. (Party mode is OFF here, so the
    // responder chips ARE visible — scope strictly to the message list so
    // this assertion is about the BUBBLE's avatar, not the chips.)
    final header = find.byKey(const Key('speakerNameHeader'));
    expect(header, findsOneWidget);
    expect(tester.widget<Text>(header).data, 'Sera');
    final listAvatars = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(AvatarBubble),
    );
    expect(listAvatars, findsNWidgets(1));
  });
}
