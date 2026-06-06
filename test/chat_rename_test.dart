// Mega-audit 2026-06-05 — completeness-gaps batch.
//
// Chat rename: chats are the only top-level user-created entity with no name.
//   - `Chat.title` is a nullable manual override that round-trips through JSON
//     (omitted from toJson when null/blank so existing chats stay byte-clean).
//   - `displayTitle(fallback)` returns the trimmed title when set, else the
//     caller-supplied derived label.
//   - `AppStore.renameChat(id, title)` mirrors `renameCreatorSession`: a blank
//     title clears the override (back to null); it bumps updatedAt + mtime and
//     notifies once; unknown id is a silent no-op (no notify).

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

class _CapturingBackend implements StoreBackend {
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {
    saved = blob;
  }

  @override
  Future<void> clear() async {}
}

void main() {
  group('Chat.title model', () {
    test('defaults to null and is omitted from toJson when unset', () {
      final chat = Chat(id: 'c1', characterIds: const ['x']);
      expect(chat.title, isNull);
      expect(chat.toJson().containsKey('title'), isFalse);
    });

    test('round-trips a set title through toJson/fromJson', () {
      final chat = Chat(id: 'c1', characterIds: const ['x'], title: 'My run');
      final restored = Chat.fromJson(chat.toJson());
      expect(restored.title, 'My run');
    });

    test('fromJson tolerates a missing title key (legacy chats)', () {
      final restored = Chat.fromJson({
        'id': 'c1',
        'characterIds': ['x'],
      });
      expect(restored.title, isNull);
    });

    test('displayTitle returns the title when set, else the fallback', () {
      final named = Chat(id: 'c1', characterIds: const ['x'], title: '  Run 2 ');
      final unnamed = Chat(id: 'c2', characterIds: const ['x']);
      expect(named.displayTitle('Aria'), 'Run 2');
      expect(unnamed.displayTitle('Aria'), 'Aria');
    });

    test('displayTitle treats a blank title as unset', () {
      final blank = Chat(id: 'c1', characterIds: const ['x'], title: '   ');
      expect(blank.displayTitle('Aria'), 'Aria');
    });
  });

  group('AppStore.renameChat', () {
    test('sets the title, bumps metadata, notifies once', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c1', characterIds: const ['x']);
      store.chats.add(chat);

      var notifies = 0;
      store.addListener(() => notifies++);

      store.renameChat('c1', 'Boss fight');

      expect(chat.title, 'Boss fight');
      expect(notifies, 1);
      expect(chat.updatedAt, greaterThan(0));
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('trims the title before storing', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c1', characterIds: const ['x']);
      store.chats.add(chat);
      store.renameChat('c1', '  spaced  ');
      expect(chat.title, 'spaced');
      await store.flushPersist();
    });

    test('a blank/whitespace title clears the override back to null', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c1', characterIds: const ['x'], title: 'Old');
      store.chats.add(chat);
      store.renameChat('c1', '   ');
      expect(chat.title, isNull);
      await store.flushPersist();
    });

    test('null title clears the override', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c1', characterIds: const ['x'], title: 'Old');
      store.chats.add(chat);
      store.renameChat('c1', null);
      expect(chat.title, isNull);
      await store.flushPersist();
    });

    test('unknown chat id is a silent no-op (no notify)', () async {
      final store = AppStore(storage: _NoopBackend());
      var notifies = 0;
      store.addListener(() => notifies++);
      store.renameChat('nope', 'x');
      expect(notifies, 0);
      await store.flushPersist();
    });
  });

  group('AppStore.setPersonaFavoritesExpanded — header parity', () {
    test('defaults to expanded', () {
      final store = AppStore(storage: _NoopBackend());
      expect(store.personaFavoritesExpanded, isTrue);
    });

    test('toggles + notifies, and is written to the persisted blob', () async {
      final backend = _CapturingBackend();
      final store = AppStore(storage: backend);
      var notifies = 0;
      store.addListener(() => notifies++);

      store.setPersonaFavoritesExpanded(false);
      expect(store.personaFavoritesExpanded, isFalse);
      expect(notifies, 1);

      await store.flushPersist();
      expect(backend.saved?['personaFavoritesExpanded'], isFalse);
    });

    test('setting the same value is a no-op (no notify)', () async {
      final store = AppStore(storage: _NoopBackend());
      var notifies = 0;
      store.addListener(() => notifies++);
      store.setPersonaFavoritesExpanded(true); // already true
      expect(notifies, 0);
      await store.flushPersist();
    });
  });
}
