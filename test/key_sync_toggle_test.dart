// Mega-audit 2026-06-05 — key-sync toggle gating (S1).
//
// The desktop (key-holder) toggle "Sync providers & API keys" was inert:
// it flipped `uiPrefs.syncProviderKeys` and persisted, but did nothing
// else. The receiver's sync cursor has usually advanced past the
// providers' old `mtime`, and only the RECEIVER's full-resync re-pulls
// from since=0 — so when the holder enables the toggle SECOND, the
// providers (old mtime) never re-ship and "keys don't sync despite the
// opt-in".
//
// Fix: `AppStore.setSyncProviderKeys(true)` re-stamps every provider's
// mtime to now, so the next normal pull (`mtime > since`) ships them
// regardless of the receiver's advanced cursor. Turning it OFF does NOT
// restamp (no point). These tests lock in the gating + restamp.

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
  group('AppStore.setSyncProviderKeys', () {
    test('enabling sets the flag AND restamps all provider mtimes', () async {
      final store = AppStore(storage: _NoopBackend());
      // Two providers with stale (pre-watermark) mtimes.
      final a = store.addProvider(name: 'A', baseUrl: 'u', apiKey: 'k', model: 'm');
      final b = store.addProvider(name: 'B', baseUrl: 'u', apiKey: 'k', model: 'm');
      a.mtime = 1;
      b.mtime = 2;
      expect(store.uiPrefs.syncProviderKeys, isFalse);

      store.setSyncProviderKeys(true);

      expect(store.uiPrefs.syncProviderKeys, isTrue);
      // Both bumped well past their stale values (a real epoch-ms timestamp).
      expect(a.mtime, greaterThan(1000));
      expect(b.mtime, greaterThan(1000));
      await store.flushPersist();
    });

    test('disabling clears the flag and does NOT restamp', () async {
      final store = AppStore(storage: _NoopBackend());
      final a = store.addProvider(name: 'A', baseUrl: 'u', apiKey: 'k', model: 'm');
      store.setSyncProviderKeys(true);
      final stamped = a.mtime;
      // Force a distinguishable lower value, then turn OFF.
      a.mtime = stamped + 5;
      store.setSyncProviderKeys(false);
      expect(store.uiPrefs.syncProviderKeys, isFalse);
      expect(a.mtime, stamped + 5); // untouched by the OFF path
      await store.flushPersist();
    });

    test('setting the same value is a no-op (no notify, no restamp)', () async {
      final store = AppStore(storage: _NoopBackend());
      final a = store.addProvider(name: 'A', baseUrl: 'u', apiKey: 'k', model: 'm');
      a.mtime = 7;
      var notifies = 0;
      store.addListener(() => notifies++);
      store.setSyncProviderKeys(false); // already false
      expect(notifies, 0);
      expect(a.mtime, 7);
      await store.flushPersist();
    });

    test('enabling notifies exactly once', () async {
      final store = AppStore(storage: _NoopBackend());
      store.addProvider(name: 'A', baseUrl: 'u', apiKey: 'k', model: 'm');
      var notifies = 0;
      store.addListener(() => notifies++);
      store.setSyncProviderKeys(true);
      expect(notifies, 1);
      await store.flushPersist();
    });
  });
}
