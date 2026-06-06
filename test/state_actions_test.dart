// Mega-audit 2026-06-04 — STATE batch.
//
//   datamodel-appstore-macros-slash-05 — `clearMessages(chatId)` empties a
//     chat in ONE shot with a single notify (the `/clear` loop fired N notifies
//     via per-message removeMessage).
//   datamodel-appstore-macros-slash-11 — `updateLiveSheetSettings` /
//     `updateScriptSettings` give those settings the same encapsulated
//     mutation funnel as the other update* actions (notify + persist).

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

Message _msg(String id) =>
    Message(id: id, kind: MessageKind.user, variants: ['t'], createdAt: 1);

void main() {
  group('datamodel-appstore-macros-slash-05 — clearMessages', () {
    test('empties the chat in one shot with exactly ONE notify', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c1', characterIds: const ['x']);
      chat.messages.addAll([_msg('a'), _msg('b'), _msg('c'), _msg('d')]);
      store.chats.add(chat);

      var notifies = 0;
      store.addListener(() => notifies++);

      store.clearMessages('c1');

      expect(chat.messages, isEmpty);
      expect(notifies, 1, reason: 'one bulk clear → one notifyListeners');
      // Sync metadata bumped like removeMessage.
      expect(chat.mtime, greaterThan(0));
      expect(chat.updatedAt, greaterThan(0));

      await store.flushPersist();
    });

    test('no-op (no notify) on an unknown chat id', () async {
      final store = AppStore(storage: _NoopBackend());
      var notifies = 0;
      store.addListener(() => notifies++);
      store.clearMessages('does-not-exist');
      expect(notifies, 0);
      await store.flushPersist();
    });

    test('no-op (no notify) when the chat is already empty', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c2', characterIds: const ['x']);
      store.chats.add(chat);
      var notifies = 0;
      store.addListener(() => notifies++);
      store.clearMessages('c2');
      expect(notifies, 0);
      await store.flushPersist();
    });
  });

  group('datamodel-appstore-macros-slash-11 — encapsulated settings actions', () {
    test('updateLiveSheetSettings swaps the object and notifies', () async {
      final store = AppStore(storage: _NoopBackend());
      var notifies = 0;
      store.addListener(() => notifies++);

      final next = LiveSheetSettings()..autoEvery = 7;
      store.updateLiveSheetSettings(next);

      expect(identical(store.liveSheetSettings, next), isTrue);
      expect(store.liveSheetSettings.autoEvery, 7);
      expect(notifies, 1);
      await store.flushPersist();
    });

    test('updateScriptSettings swaps the object and notifies', () async {
      final store = AppStore(storage: _NoopBackend());
      var notifies = 0;
      store.addListener(() => notifies++);

      final next = ScriptSettings(beatsCap: 5);
      store.updateScriptSettings(next);

      expect(identical(store.scriptSettings, next), isTrue);
      expect(store.scriptSettings.beatsCap, 5);
      expect(notifies, 1);
      await store.flushPersist();
    });
  });
}
