// 1.2.1: curated in-chat provider quick-swap (owner design).
//
// The owner pins a few providers in API Connections; a compact control in
// chat opens a sheet showing the active provider + the pinned ones, and
// tapping one swaps the chat's active provider (mirrors the existing
// preset switcher — `setActivePreset` / `_showPresetSwitcher`).
//
//   - `UiPrefs.chatSwapProviderIds` — the curated pin list. Round-trips
//     through toJson/fromJson; defaults to empty (including legacy JSON
//     blobs that predate this field).
//   - `AppStore.toggleChatSwapProvider(id)` — add/remove a pin, persist,
//     notify (mirrors `setCharactersSegment` / other uiPrefs setters).
//   - `AppStore.setActiveProvider(id)` — already existed pre-slice; this
//     test just locks in the "sets activeProviderId + persists" contract
//     the chat sheet depends on.

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
  group('UiPrefs.chatSwapProviderIds', () {
    test('defaults to empty', () {
      final prefs = UiPrefs.fromJson(const <String, dynamic>{});
      expect(prefs.chatSwapProviderIds, isEmpty);
    });

    test('round-trips through toJson/fromJson', () {
      final prefs = UiPrefs(chatSwapProviderIds: const ['prov1', 'prov2']);
      final json = prefs.toJson();
      final restored = UiPrefs.fromJson(json);
      expect(restored.chatSwapProviderIds, ['prov1', 'prov2']);
    });

    test('legacy JSON without the key defaults to empty, no crash', () {
      final restored = UiPrefs.fromJson(const <String, dynamic>{
        'activeTab': 'characters',
        'charactersSegment': 'characters',
      });
      expect(restored.chatSwapProviderIds, isEmpty);
    });

    test('toJson omits the key when the list is empty', () {
      final prefs = UiPrefs();
      expect(prefs.toJson().containsKey('chatSwapProviderIds'), isFalse);
    });
  });

  group('AppStore.toggleChatSwapProvider', () {
    test('adds then removes an id', () async {
      final store = AppStore(storage: _NoopBackend());
      expect(store.uiPrefs.chatSwapProviderIds, isEmpty);

      store.toggleChatSwapProvider('prov1');
      expect(store.uiPrefs.chatSwapProviderIds, ['prov1']);

      store.toggleChatSwapProvider('prov1');
      expect(store.uiPrefs.chatSwapProviderIds, isEmpty);
      await store.flushPersist();
    });

    test('notifies and persists the pin list', () async {
      final backend = _CapturingBackend();
      final store = AppStore(storage: backend);
      var notifies = 0;
      store.addListener(() => notifies++);

      store.toggleChatSwapProvider('prov9');
      expect(notifies, 1);

      await store.flushPersist();
      final savedPrefs = backend.saved?['uiPrefs'] as Map?;
      expect(savedPrefs?['chatSwapProviderIds'], ['prov9']);
    });

    test('supports multiple pins independently', () {
      final store = AppStore(storage: _NoopBackend());
      store.toggleChatSwapProvider('a');
      store.toggleChatSwapProvider('b');
      expect(store.uiPrefs.chatSwapProviderIds, ['a', 'b']);
      store.toggleChatSwapProvider('a');
      expect(store.uiPrefs.chatSwapProviderIds, ['b']);
    });
  });

  group('AppStore.setActiveProvider', () {
    test('sets activeProviderId', () {
      final store = AppStore(storage: _NoopBackend());
      store.addProvider(name: 'Prov A', baseUrl: 'https://a.example/v1');
      final p2 = store.addProvider(name: 'Prov B', baseUrl: 'https://b.example/v1');

      store.setActiveProvider(p2.id);
      expect(store.activeProviderId, p2.id);
    });

    test('persists the active provider id', () async {
      final backend = _CapturingBackend();
      final store = AppStore(storage: backend);
      final p = store.addProvider(name: 'Prov A', baseUrl: 'https://a.example/v1');

      store.setActiveProvider(p.id);
      await store.flushPersist();
      expect(backend.saved?['activeProviderId'], p.id);
    });
  });
}
