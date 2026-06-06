// Mega-audit 2026-06-05 (M-3): a failing persist must SIGNAL (latch a flag +
// notify) instead of becoming a swallowed unhandled async error, and the
// latch must clear on the next successful save so the warning doesn't linger.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

/// A backend whose `save` throws while [fail] is true. Flip it to false to
/// simulate the disk recovering (space freed, volume remounted).
class _ToggleFailBackend implements StoreBackend {
  bool fail;
  int saves = 0;
  _ToggleFailBackend({this.fail = false});

  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> blob) async {
    saves++;
    if (fail) throw const _DiskFull();
  }

  @override
  Future<void> clear() async {}
}

class _DiskFull implements Exception {
  const _DiskFull();
  @override
  String toString() => 'No space left on device';
}

void main() {
  group('M-3 — persist failure flag', () {
    test('a failing save latches lastPersistFailed + notifies', () async {
      final backend = _ToggleFailBackend(fail: true);
      final store = AppStore(storage: backend);

      expect(store.lastPersistFailed, isFalse);
      expect(store.hasUnshownPersistError, isFalse);

      var notifies = 0;
      store.addListener(() => notifies++);

      await store.flushPersist();

      expect(backend.saves, greaterThan(0));
      expect(store.lastPersistFailed, isTrue,
          reason: 'a thrown save() must set the latch');
      expect(store.hasUnshownPersistError, isTrue,
          reason: 'an un-acknowledged failure is surfaceable');
      expect(notifies, greaterThan(0),
          reason: 'the failure transition must notify listeners');
    });

    test('a subsequent successful save clears the latch', () async {
      final backend = _ToggleFailBackend(fail: true);
      final store = AppStore(storage: backend);

      await store.flushPersist();
      expect(store.lastPersistFailed, isTrue);

      // Disk recovers — the next save succeeds.
      backend.fail = false;
      await store.flushPersist();

      expect(store.lastPersistFailed, isFalse,
          reason: 'a successful save must clear the failure latch');
      expect(store.hasUnshownPersistError, isFalse);
    });

    test('acknowledge hides the warning until a fresh failure', () async {
      final backend = _ToggleFailBackend(fail: true);
      final store = AppStore(storage: backend);

      await store.flushPersist();
      expect(store.hasUnshownPersistError, isTrue);

      // The UI shows the warning once and acknowledges it.
      store.acknowledgePersistError();
      expect(store.hasUnshownPersistError, isFalse,
          reason: 'acknowledged failure is no longer surfaceable');
      expect(store.lastPersistFailed, isTrue,
          reason: 'but the underlying failure latch is still set');

      // A recovery then a NEW failure re-arms the surfaceable flag.
      backend.fail = false;
      await store.flushPersist();
      expect(store.lastPersistFailed, isFalse);

      backend.fail = true;
      await store.flushPersist();
      expect(store.hasUnshownPersistError, isTrue,
          reason: 'a fresh failure after recovery surfaces again');
    });

    test('a clean install never flags an error on a healthy save', () async {
      final backend = _ToggleFailBackend(fail: false);
      final store = AppStore(storage: backend);
      await store.flushPersist();
      expect(store.lastPersistFailed, isFalse);
      expect(store.hasUnshownPersistError, isFalse);
    });
  });
}
