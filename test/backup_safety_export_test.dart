// F2 (SEVERE) — the pre-factory-reset SAFETY backup must embed attachment
// BYTES, not just `pyre://attachment/<hash>` refs.
//
// `_factoryReset` builds its auto-backup via `_exportBlob(...)` but (before
// this fix) never called `embedBackupAttachments`, so the written JSON held
// reference strings only. `factoryReset` then wipes every attachment file
// (`gcOrphans({})`), so restoring the safety backup resolved every avatar /
// gallery / background ref to nothing — blank images across the board.
//
// The fix: the safety-backup path must embed attachment bytes exactly like
// the three normal export paths already do. `buildSafetyBackupBlob` is the
// extracted, testable helper the screen now calls.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/backup_restore_screen.dart';
import 'package:pyre/services/attachment_store.dart';
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

/// Minimal fake PathProviderPlatform so AttachmentStore writes real `.bin`
/// files under a throwaway temp dir (mirrors backup_attachments_test.dart).
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
  @override
  Future<String?> getTemporaryPath() async => docsPath;
  @override
  Future<String?> getApplicationSupportPath() async => docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('pyre_safety_backup_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('F2 — safety backup embeds attachment bytes', () {
    test(
        'buildSafetyBackupBlob embeds real avatar bytes, not just a pyre:// ref',
        () async {
      final bytes = Uint8List.fromList(
          List<int>.generate(300, (i) => (i * 3 + 1) % 256));
      final ref = await AttachmentStore.store(bytes, mime: 'image/png');
      expect(ref, isNotNull);

      final store = AppStore(storage: _NoopBackend());
      store.characters = [
        Character(id: 'c1', name: 'Avatar Owner', avatar: ref),
      ];

      final blob = await buildSafetyBackupBlob(store);

      // The raw record still carries the ref string (unpacked shape).
      final chars = blob['characters'] as List;
      expect((chars.first as Map)['avatar'], ref);

      // But the blob must ALSO carry the actual bytes, embedded exactly like
      // the normal export paths (embedBackupAttachments' contract).
      final attachments = blob['attachments'];
      expect(attachments, isA<Map>(),
          reason: 'safety backup must embed attachment bytes, not just refs');
      final hash = ref!.substring(AttachmentStore.urlPrefix.length);
      expect((attachments as Map).containsKey(hash), isTrue);
      expect(base64Decode(attachments[hash] as String), bytes);
    });

    test('safety backup never carries API keys (includeApiKeys: false)',
        () async {
      final store = AppStore(storage: _NoopBackend());
      store.providers = [
        ApiProvider(id: 'p1', name: 'Test', apiKey: 'sk-super-secret'),
      ];

      final blob = await buildSafetyBackupBlob(store);

      expect(blob['containsApiKeys'], isFalse);
      final providers = blob['providers'] as List;
      final p = providers.first as Map;
      // toJson(includeApiKey: false) must not carry the plaintext key.
      expect(p['apiKey'], anyOf(isNull, isEmpty));
    });
  });
}
