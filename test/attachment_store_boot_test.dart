// Audit B1 (BLOCKER): AttachmentStore.warmUp() is awaited in main() BEFORE
// runApp(). `_attachDir()` used to do an unguarded `dir.exists()` +
// `dir.create(recursive: true)` — a stray FILE named `attachments` sitting
// where the directory needs to go (disk full / AV lock / a corrupted prior
// run) threw an uncaught FileSystemException, and the app never showed a
// window again, on every launch. Same class of bug as the fixed
// PYRE_DATA_DIR issue (see data_dir_test.dart).
//
// Fix: `_attachDir()` wraps the exists/create in try/catch; on failure it
// debugPrints and returns null (every caller already has null-dir
// semantics — web returns null the same way). The failure is NOT cached —
// a transient AV lock at boot shouldn't disable attachments for the whole
// process, only a genuine success populates `_cachedDir`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pyre/services/attachment_store.dart';

/// Minimal fake PathProviderPlatform that points app-docs at a temp dir so
/// the AttachmentStore's real Directory/File calls run against disk we can
/// sabotage — mirrors backup_attachments_test.dart's fixture.
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

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pyre_attach_boot_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test(
      'a FILE blocking the attachments dir does not throw out of warmUp(), '
      'and the failure is not cached forever (audit B1)', () async {
    // Pre-create the data root, then put a FILE exactly where the
    // `attachments` DIRECTORY needs to go — the boot-time collision this
    // fix guards against.
    final root = Directory('${tmp.path}/EmberChat');
    await root.create(recursive: true);
    final blocker = File('${root.path}/attachments');
    await blocker.writeAsString('not a directory');

    // THE BLOCKER: this used to throw an uncaught FileSystemException, and
    // main() awaits warmUp() before runApp() — no window, ever, on every
    // launch, until the user manually removed the offending file.
    await AttachmentStore.warmUp();

    // Degraded gracefully: attachment ops return null instead of throwing.
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final ref = await AttachmentStore.store(bytes);
    expect(ref, isNull);

    // Clear the obstruction — a transient failure must NOT be cached
    // forever; the very next call should succeed now that the collision is
    // gone (this is what "don't cache null" buys us).
    await blocker.delete();
    final ref2 = await AttachmentStore.store(bytes);
    expect(ref2, isNotNull);
    expect(AttachmentStore.isPyreUrl(ref2!), isTrue);
  });
}
