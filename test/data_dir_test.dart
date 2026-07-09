// Tests for the PYRE_DATA_DIR override seam (1.2.1 item #6).
//
// `resolveDataParentPath` is the PURE decision (override vs documents dir,
// incl. the cmd.exe quote quirk). `dataRootFor` is the resilient root
// resolver: it must NEVER throw for a bad override — a broken env var must
// degrade to the default location, not brick app boot (audit finding,
// 1.2.1). `pyreDataParent()` / `pyreDataRoot()` are thin wrappers over
// these two (Platform.environment + path_provider only).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/data_dir.dart';

void main() {
  group('resolveDataParentPath', () {
    test('env null returns the documents path unchanged', () {
      expect(resolveDataParentPath(null, '/docs'), '/docs');
    });

    test('env blank (whitespace only) returns the documents path', () {
      expect(resolveDataParentPath('   ', '/docs'), '/docs');
    });

    test('env set wins over the documents path', () {
      expect(
        resolveDataParentPath('/home/u/PyreData', '/docs'),
        '/home/u/PyreData',
      );
    });

    test('env with surrounding whitespace is trimmed', () {
      expect(resolveDataParentPath('  /data  ', '/docs'), '/data');
    });

    // Audit fix (1.2.1): cmd.exe does NOT strip quotes from
    // `set PYRE_DATA_DIR="C:\Sync\Pyre"` — the literal quotes reach the
    // process env and `"` is an illegal NTFS filename char. Strip them.
    test('surrounding double quotes are stripped (cmd.exe quirk)', () {
      expect(
        resolveDataParentPath('"C:\\Sync\\Pyre"', '/docs'),
        'C:\\Sync\\Pyre',
      );
    });

    test('surrounding single quotes are stripped', () {
      expect(
        resolveDataParentPath("'/home/u/sync'", '/docs'),
        '/home/u/sync',
      );
    });

    test('quotes + whitespace combined are stripped', () {
      expect(
        resolveDataParentPath('  "C:\\Data"  ', '/docs'),
        'C:\\Data',
      );
    });

    test('a value that is ONLY quotes is treated as unset', () {
      expect(resolveDataParentPath('""', '/docs'), '/docs');
    });
  });

  group('dataRootFor (resilient root resolution)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('pyre_data_dir_test');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('no override → root under the documents path', () async {
      final docs = '${tmp.path}${Platform.pathSeparator}docs';
      await Directory(docs).create(recursive: true);
      final root = await dataRootFor(null, docs);
      expect(root.path, startsWith(docs));
      expect(await root.exists(), isTrue);
    });

    test('valid override → root under the override, created', () async {
      final docs = '${tmp.path}${Platform.pathSeparator}docs';
      final override = '${tmp.path}${Platform.pathSeparator}sync';
      await Directory(docs).create(recursive: true);
      // Override dir does NOT pre-exist — first run must create it.
      final root = await dataRootFor(override, docs);
      expect(root.path, startsWith(override));
      expect(await root.exists(), isTrue);
    });

    // THE BLOCKER (audit finding): an unusable override used to throw an
    // uncaught FileSystemException out of main() before runApp — the app
    // never opened a window again until the user hand-fixed the OS env var.
    // A bad override must FALL BACK to the documents path, never throw.
    test('override pointing under an existing FILE → falls back, no throw',
        () async {
      final docs = '${tmp.path}${Platform.pathSeparator}docs';
      await Directory(docs).create(recursive: true);
      // Create a FILE, then use a path UNDER it as the override parent —
      // create(recursive:true) cannot succeed through a file on any OS.
      final blocker = File('${tmp.path}${Platform.pathSeparator}notadir');
      await blocker.writeAsString('x');
      final override =
          '${blocker.path}${Platform.pathSeparator}deeper';
      final root = await dataRootFor(override, docs);
      expect(root.path, startsWith(docs));
      expect(await root.exists(), isTrue);
    });
  });
}
