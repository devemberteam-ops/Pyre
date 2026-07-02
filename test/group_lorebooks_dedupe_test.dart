// 2026-07 (owner feedback): in a group chat where several members carry the
// SAME lorebook, the Group chat & Lorebooks sheet used to list that book once
// per member ("From character · Vesna" / "From character · The Sunken Gate",
// each with its own switch) — N rows for what is ONE underlying state, since
// enable/disable is keyed on the BOOK id alone. The sheet now groups
// inherited books by book: one row, every origin joined in the subtitle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/group_lorebooks_sheet.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a lorebook shared by two members renders ONE row with both origins',
      (tester) async {
    final store = AppStore(storage: _NoopBackend());

    final book = Lorebook(
      id: 'lb-world',
      name: 'The Vael — World Lore',
      entries: [
        LoreEntry(id: 'e1', keys: ['vael'], content: 'Lore.'),
      ],
      createdAt: 0,
      updatedAt: 0,
    );
    store.lorebooks.add(book);

    final vesna = Character(
      id: 'ch-vesna',
      name: 'Vesna',
      lorebookIds: [book.id],
      createdAt: 0,
      updatedAt: 0,
    );
    final gate = Character(
      id: 'ch-gate',
      name: 'The Sunken Gate',
      lorebookIds: [book.id],
      createdAt: 0,
      updatedAt: 0,
    );
    store.characters.addAll([vesna, gate]);

    final chat = Chat(
      id: 'chat-1',
      characterIds: [vesna.id, gate.id],
      characterSnapshots: {vesna.id: vesna, gate.id: gate},
      messages: const [],
      createdAt: 0,
      updatedAt: 0,
    );
    store.chats.add(chat);

    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GroupAndLorebooksSheet(chatId: chat.id),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Exactly ONE row for the shared book (was two — one per member).
    expect(find.text(book.name), findsOneWidget);

    // Its subtitle names BOTH origins, joined.
    expect(
      find.textContaining('inherited from Vesna · The Sunken Gate'),
      findsOneWidget,
    );
  });
}
