// White-footer fix: the "update available" notice (launch snackbar + More
// footer pill) no longer re-nags on every app load. shouldShowUpdateNotice is
// the shared gate; AppStore.dismissUpdate records the dismissed version.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/services/update_check.dart';
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
  group('shouldShowUpdateNotice', () {
    const u = UpdateInfo(latestVersion: '1.2.0', url: 'x', notes: '');

    test('no update → never shows', () {
      expect(shouldShowUpdateNotice(null, null), isFalse);
      expect(shouldShowUpdateNotice(null, '1.2.0'), isFalse);
    });

    test('update + nothing dismissed → shows', () {
      expect(shouldShowUpdateNotice(u, null), isTrue);
    });

    test('update dismissed for THIS version → hidden', () {
      expect(shouldShowUpdateNotice(u, '1.2.0'), isFalse);
    });

    test('a NEWER version than the dismissed one → shows again', () {
      // user dismissed 1.1.0 earlier; 1.2.0 is now available
      expect(shouldShowUpdateNotice(u, '1.1.0'), isTrue);
    });
  });

  group('AppStore.dismissUpdate', () {
    test('records the dismissed version (idempotent)', () {
      final s = AppStore(storage: _NoopBackend());
      expect(s.dismissedUpdateVersion, isNull);
      s.dismissUpdate('1.2.0');
      expect(s.dismissedUpdateVersion, '1.2.0');
      // no-op on the same version (no throw / change)
      s.dismissUpdate('1.2.0');
      expect(s.dismissedUpdateVersion, '1.2.0');
      // a newer dismissal overwrites
      s.dismissUpdate('1.3.0');
      expect(s.dismissedUpdateVersion, '1.3.0');
    });
  });
}
