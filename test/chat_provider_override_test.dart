@TestOn('vm')
library;

// Per-chat preferred provider (owner 2026-07-13: an in-chat provider swap must
// affect ONLY that chat). Device-local `chatProviderOverrides` (Codex: NOT a
// synced Chat field — avoids whole-record LWW clobber + web steering the host).
// Pins: resolver falls back to the global, dangling never picks "first", the
// map is cleaned on provider delete, and it stays OUT of the synced settings.

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
  Future<void> save(Map<String, dynamic> blob) async => saved = blob;
  @override
  Future<void> clear() async {}
}

Chat _chat(String id) =>
    Chat(id: id, characterIds: ['c'], messages: [], createdAt: 0, updatedAt: 0);

AppStore _store() {
  final store = AppStore(storage: _NoopBackend());
  store.providers
    ..add(ApiProvider(id: 'p1', name: 'Global'))
    ..add(ApiProvider(id: 'p2', name: 'Uncensored'))
    ..add(ApiProvider(id: 'p3', name: 'Vision'));
  store.activeProviderId = 'p1';
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no override → the chat uses the global active provider', () {
    final store = _store();
    expect(store.chatPrimaryProvider(_chat('ch'))?.id, 'p1');
  });

  test('a set override wins for THAT chat only', () {
    final store = _store();
    store.setChatProvider('ch', 'p2');
    expect(store.chatPrimaryProvider(_chat('ch'))?.id, 'p2');
    // A different chat is untouched — still the global.
    expect(store.chatPrimaryProvider(_chat('other'))?.id, 'p1');
    // The GLOBAL active is unchanged (the whole point).
    expect(store.activeProviderId, 'p1');
  });

  test('a dangling override falls back to the global, never "first provider"',
      () {
    final store = _store();
    store.chatProviderOverrides['ch'] = 'deleted-id'; // not in providers
    expect(store.chatPrimaryProvider(_chat('ch'))?.id, 'p1',
        reason: 'dangling → global active, not providers.first');
  });

  test('setChatProvider(null) and unknown ids clear the override', () {
    final store = _store();
    store.setChatProvider('ch', 'p2');
    store.setChatProvider('ch', null);
    expect(store.chatProviderOverrides.containsKey('ch'), isFalse);
    store.setChatProvider('ch', 'nonexistent'); // unknown → no override stored
    expect(store.chatProviderOverrides.containsKey('ch'), isFalse);
    expect(store.chatPrimaryProvider(_chat('ch'))?.id, 'p1');
  });

  test('chatFallbackChain(chat) puts the override at the head', () {
    final store = _store();
    store.uiPrefs.askToSwitchOnFailure = true; // keep the full chain
    store.setChatProvider('ch', 'p2');
    final chain = store.chatFallbackChain(_chat('ch'));
    expect(chain.first.id, 'p2', reason: 'preferred provider leads');
    expect(chain.map((p) => p.id), containsAll(['p1', 'p3']),
        reason: 'failover to the rest is preserved');
  });

  test('deleting a provider clears chats that preferred it', () {
    final store = _store();
    store.setChatProvider('a', 'p2');
    store.setChatProvider('b', 'p3');
    store.removeProvider('p2');
    expect(store.chatProviderOverrides.containsKey('a'), isFalse,
        reason: 'chat a preferred the deleted p2 → override dropped');
    expect(store.chatProviderOverrides['b'], 'p3',
        reason: 'chat b preferred p3 → untouched');
    expect(store.chatPrimaryProvider(_chat('a'))?.id, 'p1');
  });

  test('the override map persists LOCALLY but never in synced settings',
      () async {
    final backend = _CapturingBackend();
    final store = AppStore(storage: backend);
    store.providers.add(ApiProvider(id: 'p2', name: 'Uncensored'));
    store.setChatProvider('ch', 'p2');
    await store.flushPersist();
    expect(backend.saved?['chatProviderOverrides'], {'ch': 'p2'},
        reason: 'device-local persistence keeps it across restarts');
    expect(store.syncedSettingsToJson().containsKey('chatProviderOverrides'),
        isFalse,
        reason: 'a provider is a local capability — it must NOT ride sync');
  });
}
