// Feature (A): per-function provider routing for Impersonate + Guide.
// impersonateProviderId / guideProviderId mirror creatorProviderId /
// visionProviderId — they persist, ride the LWW settings unit, are stripped at
// cross-device boundaries (device-local, 1.1.2), and clear on provider delete.
// This locks the getter fallbacks + every sync touchpoint.

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

  group('per-function provider routing (A)', () {
    test('impersonateProvider falls back to the active chat provider', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      s.setActiveProvider(chat.id);
      expect(s.impersonateProviderId, isNull);
      expect(s.impersonateProvider?.id, chat.id);
    });

    test('impersonateProvider returns the pinned override', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      final clean = s.addProvider(name: 'Clean');
      s.setActiveProvider(chat.id);
      s.setImpersonateProvider(clean.id);
      expect(s.impersonateProvider?.id, clean.id);
    });

    test('guideProvider falls back impersonate → active', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      final clean = s.addProvider(name: 'Clean');
      final guide = s.addProvider(name: 'Guide');
      s.setActiveProvider(chat.id);
      // nothing set → follows active
      expect(s.guideProvider?.id, chat.id);
      // impersonate set, guide unset → follows impersonate
      s.setImpersonateProvider(clean.id);
      expect(s.guideProvider?.id, clean.id);
      // guide pinned → guide
      s.setGuideProvider(guide.id);
      expect(s.guideProvider?.id, guide.id);
    });

    test('removeProvider clears the impersonate + guide overrides', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      final clean = s.addProvider(name: 'Clean');
      s.setActiveProvider(chat.id);
      s.setImpersonateProvider(clean.id);
      s.setGuideProvider(clean.id);
      s.removeProvider(clean.id);
      expect(s.impersonateProviderId, isNull);
      expect(s.guideProviderId, isNull);
    });

    test('synced settings carry both pointers; strip removes them', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      final clean = s.addProvider(name: 'Clean');
      s.setActiveProvider(chat.id);
      s.setImpersonateProvider(clean.id);
      s.setGuideProvider(clean.id);

      final j = s.syncedSettingsToJson();
      expect(j['impersonateProviderId'], clean.id);
      expect(j['guideProviderId'], clean.id);

      final stripped = withoutProviderRolePointers(j);
      expect(stripped.containsKey('impersonateProviderId'), isFalse);
      expect(stripped.containsKey('guideProviderId'), isFalse);
    });

    test('applySyncedSettings adopts both on a newer mtime', () {
      final s = freshStore();
      final chat = s.addProvider(name: 'Chat');
      final clean = s.addProvider(name: 'Clean');
      s.setActiveProvider(chat.id);
      s.setImpersonateProvider(clean.id);
      s.setGuideProvider(clean.id);
      final j = Map<String, dynamic>.of(s.syncedSettingsToJson())
        ..['mtime'] = (s.syncedSettingsToJson()['mtime'] as int) + 5000;

      final s2 = freshStore();
      s2.applySyncedSettings(j);
      expect(s2.impersonateProviderId, clean.id);
      expect(s2.guideProviderId, clean.id);
    });

    test('a STRIPPED record preserves the local override (containsKey guard)',
        () {
      final s = freshStore();
      s.setImpersonateProvider('local-imp');
      s.setGuideProvider('local-guide');

      // A non-native peer record omits the pointers; an absent key must NOT
      // null the local selection even on a newer mtime.
      final stripped = withoutProviderRolePointers(s.syncedSettingsToJson())
        ..['mtime'] = 9999999999999;
      s.applySyncedSettings(stripped);
      expect(s.impersonateProviderId, 'local-imp');
      expect(s.guideProviderId, 'local-guide');
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
