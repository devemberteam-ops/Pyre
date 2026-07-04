// 2026-07-03 (Gui): the dedicated Impersonate + Guide provider ROUTES were
// cut — they're the same text generation as chat, so a per-function pin
// wasn't worth the UI. Both getters now always resolve to the chat provider.
// (The impersonateProviderId / guideProviderId fields are kept dormant so old
// data / sync payloads don't error; no UI writes them anymore.)

import 'package:flutter_test/flutter_test.dart';
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
  AppStore freshStore() => AppStore(storage: _NoopBackend());

  group('impersonate/guide routing cut — both use the chat provider', () {
    test('with nothing set, both resolve to the active chat provider', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      s.setActiveProvider(chat.id);
      expect(s.impersonateProvider?.id, chat.id);
      expect(s.guideProvider?.id, chat.id);
    });

    test('a dormant pinned pointer is IGNORED — still the chat provider', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      final other = s.addProvider(name: 'Other');
      s.setActiveProvider(chat.id);
      // Simulate an old value persisted before the cut (public field; no
      // setter exists anymore). The getter must ignore it.
      s.impersonateProviderId = other.id;
      s.guideProviderId = other.id;
      expect(s.impersonateProvider?.id, chat.id);
      expect(s.guideProvider?.id, chat.id);
    });
  });

  group('duplicateProvider (clarkarch)', () {
    test('clones with a fresh id + "(copy)" name, right after the source', () {
      final s = freshStore();
      final p = s.addProvider(name: 'My API', baseUrl: 'http://x', model: 'm');
      final dup = s.duplicateProvider(p.id);
      expect(dup, isNotNull);
      expect(dup!.id, isNot(p.id));
      expect(dup.name, 'My API (copy)');
      expect(dup.baseUrl, 'http://x');
      expect(dup.model, 'm');
      // inserted right after the original; original untouched
      expect(s.providers.indexOf(dup), s.providers.indexOf(p) + 1);
      expect(p.name, 'My API');
    });

    test('unknown id → null', () {
      expect(freshStore().duplicateProvider('nope'), isNull);
    });
  });
}
