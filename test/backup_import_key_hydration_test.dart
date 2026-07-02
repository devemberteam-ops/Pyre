// F1 (SEVERE) — "Keep mine" restore must NOT blank the live API key.
//
// The import-apply loop used to unconditionally set `p.apiKey = ''` after
// deciding whether to persist the backup's key into SecureKeys. When the
// user picks "Keep mine" (importKeys == false), that left the in-memory
// provider keyless for the rest of the session — the user is silently
// locked out until the next app restart (which re-hydrates via
// AppStore.load()).
//
// The fix — `reconcileImportedProviderKeys` — mirrors load()'s hydration
// exactly: on the keep-mine branch it reads the EXISTING key back out of
// SecureKeys instead of leaving it blank, and it does so even when the
// backup carried no key at all (previously the `if (p.apiKey.isNotEmpty)`
// guard skipped that case entirely).
//
// These tests fake the `flutter_secure_storage` platform channel
// (plugins.it_nomads.com/flutter_secure_storage) with an in-memory map so
// SecureKeys.read/write exercise real code paths without hitting a real
// OS keystore (unavailable in `flutter test`'s VM).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/backup_restore_screen.dart';
import 'package:pyre/services/secure_keys.dart';

/// Fakes the flutter_secure_storage MethodChannel with an in-memory store,
/// keyed exactly like the real plugin (`options.write/read/delete` with a
/// `key`/`value` argument map). See
/// flutter_secure_storage_platform_interface's MethodChannelFlutterSecureStorage
/// for the channel name + method/argument shapes this mirrors.
class _FakeSecureStorageChannel {
  _FakeSecureStorageChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static const MethodChannel _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  final Map<String, String> store = {};

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
    switch (call.method) {
      case 'write':
        final key = args['key'] as String;
        final value = args['value'] as String;
        store[key] = value;
        return null;
      case 'read':
        final key = args['key'] as String;
        return store[key];
      case 'delete':
        final key = args['key'] as String;
        store.remove(key);
        return null;
      case 'deleteAll':
        store.clear();
        return null;
      case 'containsKey':
        final key = args['key'] as String;
        return store.containsKey(key);
      case 'readAll':
        return store;
    }
    return null;
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorageChannel fakeChannel;

  setUp(() {
    fakeChannel = _FakeSecureStorageChannel();
  });

  tearDown(() {
    fakeChannel.dispose();
  });

  group('F1 — keep-mine restore re-hydrates the live key', () {
    test(
        'importKeys=false: live apiKey is re-hydrated from the PRE-EXISTING '
        'SecureKeys value, and SecureKeys is not overwritten', () async {
      // Pre-existing session key already in SecureKeys (as if load() had
      // hydrated it at app start).
      await SecureKeys.write('p1', 'sk-existing-session-key');

      final providers = [
        ApiProvider(id: 'p1', name: 'Test', apiKey: 'sk-DIFFERENT-from-backup'),
      ];

      await reconcileImportedProviderKeys(providers, importKeys: false);

      // Live provider keeps working with the pre-existing key.
      expect(providers.single.apiKey, 'sk-existing-session-key');
      // SecureKeys must NOT have been overwritten with the backup's key.
      expect(await SecureKeys.read('p1'), 'sk-existing-session-key');

      // Persist-hygiene verification: even though the re-hydrated plaintext
      // key now lives in-memory on the provider, the main-state persist
      // path (AppStore._persist -> provider.toJson() with NO args, default
      // includeApiKey: false) must never leak it into the next JSON blob —
      // this is the exact same post-condition AppStore.load() already
      // relies on, and this fix must not change it.
      final persisted = providers.single.toJson();
      expect(persisted.containsKey('apiKey'), isFalse,
          reason: 'plaintext key must never ride the default toJson() used '
              'by the main-state persist path');
    });

    test(
        'importKeys=false with an EMPTY backup key still re-hydrates '
        '(the old `if (apiKey.isNotEmpty)` guard used to skip this case)',
        () async {
      await SecureKeys.write('p1', 'sk-existing-session-key');
      final providers = [ApiProvider(id: 'p1', name: 'Test', apiKey: '')];

      await reconcileImportedProviderKeys(providers, importKeys: false);

      expect(providers.single.apiKey, 'sk-existing-session-key');
    });

    test('importKeys=false with no existing SecureKeys entry → empty (safe)',
        () async {
      final providers = [
        ApiProvider(id: 'p-new', name: 'New', apiKey: 'sk-from-backup'),
      ];

      await reconcileImportedProviderKeys(providers, importKeys: false);

      expect(providers.single.apiKey, '');
      expect(await SecureKeys.read('p-new'), '');
    });

    test('importKeys=true: backup key IS written to SecureKeys and blanked '
        'in-memory (unchanged behaviour, not in scope)', () async {
      final providers = [
        ApiProvider(id: 'p2', name: 'Test', apiKey: 'sk-from-backup'),
      ];

      await reconcileImportedProviderKeys(providers, importKeys: true);

      expect(await SecureKeys.read('p2'), 'sk-from-backup');
      expect(providers.single.apiKey, '');
    });
  });
}
