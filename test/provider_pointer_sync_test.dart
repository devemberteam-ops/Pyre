// 1.1.2 fix: the provider-ROLE pointers (active/creator/vision) are device-local
// — they point into a device's OWN provider list. A web (non-native) peer has a
// DIFFERENT provider list (providers never sync to web), so letting the pointer
// LWW-sync makes selecting a provider on one device clobber the other's
// selection (→ "No provider configured" / 503 / 403 on the LAN proxy).
//
// Two guards make this safe and are unit-tested here:
//   1. `withoutProviderRolePointers` — the pure strip applied to the settings
//      unit before it crosses to/from a non-native peer.
//   2. `applySyncedSettings` must PRESERVE the local pointer when the incoming
//      record OMITS the key (stripped), instead of nulling it. An EXPLICIT null
//      (key present, value null) still clears it (a real "no override").

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
  group('withoutProviderRolePointers', () {
    test('removes the 3 role pointers, keeps everything else, no mutation', () {
      final src = {
        'mtime': 123,
        'activeProviderId': 'a',
        'creatorProviderId': 'c',
        'visionProviderId': 'v',
        'modelSettings': {'temperature': 0.7},
      };
      final out = withoutProviderRolePointers(src);
      expect(out.containsKey('activeProviderId'), isFalse);
      expect(out.containsKey('creatorProviderId'), isFalse);
      expect(out.containsKey('visionProviderId'), isFalse);
      expect(out['mtime'], 123);
      expect(out['modelSettings'], {'temperature': 0.7});
      // original untouched
      expect(src.containsKey('activeProviderId'), isTrue);
    });
  });

  group('applySyncedSettings provider-pointer preservation', () {
    test('an incoming record WITHOUT the pointer keys does NOT clear them', () {
      final store = AppStore(storage: _NoopBackend());
      store.activeProviderId = 'desktop-Y';
      store.creatorProviderId = 'creator-Z';
      store.visionProviderId = 'vision-W';
      store.settingsMtime = 1000;

      // A newer settings push from a web peer — pointers stripped on the wire.
      store.applySyncedSettings({
        'mtime': 2000,
        'modelSettings': {'temperature': 0.5},
      });

      expect(store.activeProviderId, 'desktop-Y',
          reason: 'absent pointer must be preserved, not nulled');
      expect(store.creatorProviderId, 'creator-Z');
      expect(store.visionProviderId, 'vision-W');
      expect(store.settingsMtime, 2000, reason: 'the rest of settings still applies');
    });

    test('an incoming record WITH a pointer key still applies it (native sync)', () {
      final store = AppStore(storage: _NoopBackend());
      store.activeProviderId = 'old';
      store.settingsMtime = 1000;
      store.applySyncedSettings({'mtime': 2000, 'activeProviderId': 'new'});
      expect(store.activeProviderId, 'new');
    });

    test('an EXPLICIT null (key present) still clears the pointer', () {
      final store = AppStore(storage: _NoopBackend());
      store.activeProviderId = 'x';
      store.settingsMtime = 1000;
      store.applySyncedSettings({'mtime': 2000, 'activeProviderId': null});
      expect(store.activeProviderId, isNull);
    });
  });
}
