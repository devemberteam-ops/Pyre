// H-10 — off-isolate state encode + write-ordering guard.
//
// The whole-library `jsonEncode` used to run synchronously on the UI
// isolate inside `JsonStorage.save`, dropping frames on every persist as
// the library grew. The fix moves the encode behind `compute()` (off the
// UI isolate on native, inline on web). Because `compute` adds an await
// between snapshotting the data and writing it to disk, `save()` now also
// claims a monotonic sequence number and drops its disk write if a NEWER
// save started while it was encoding — so a stale encode result can never
// clobber a newer write ("latest wins", no interleaving / corruption).
//
// These tests assert:
//   1. The off-isolate `encodeStateBlob` is byte-for-byte identical to the
//      previous synchronous `jsonEncode(data)`, for a representative blob.
//   2. The full `save()` path (encode → atomic write) lands exactly that
//      same bytes on disk and reloads cleanly.
//   3. Two overlapping `save()` calls leave ONLY the latest snapshot on
//      disk — the ordering guard prevents a stale encode from winning.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pyre/dev_flavor.dart';
import 'package:pyre/services/storage.dart';

/// Minimal fake PathProviderPlatform that points app-docs at a temp dir so
/// `JsonStorage` writes real files we can read back and assert on.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
  @override
  Future<String?> getTemporaryPath() async => docsPath;
}

/// A representative app-state blob: nested maps, lists of maps, strings
/// with unicode + frank adult text, ints, doubles, bools, nulls (omitted)
/// — the same shape AppStore._persistOnce assembles from `toJson()`.
Map<String, dynamic> _representativeBlob() => <String, dynamic>{
      'schemaVersion': 42,
      'activeProviderId': 'prov-1',
      'providers': [
        {
          'id': 'prov-1',
          'name': 'Venice',
          'baseUrl': 'https://api.venice.ai',
          'model': 'qwen-3.6-plus-uncensored',
          'temperature': 0.85,
          'extraParams': {'reasoning': true, 'top_k': 40},
        },
        {
          'id': 'prov-2',
          'name': 'Localhost',
          'baseUrl': 'http://127.0.0.1:1234',
          'model': null,
          'warmUpOnLaunch': false,
        },
      ],
      'characters': [
        {
          'id': 'ren',
          'name': 'Ren Brennan',
          'description': 'A 21yo isekai\'d femboy NEET — frank, charged, '
              'unambiguously adult. Unicode: café ✦ 日本語 — — em-dash.',
          'tags': ['isekai', 'femboy', 'adult'],
          'alternateGreetings': ['*He slouches.*', '"Back again?"'],
          'lorebookIds': ['example-world-vael'],
        },
      ],
      'personas': [],
      'folders': [
        {'id': 'f1', 'name': 'Favorites', 'order': 0}
      ],
      'modelSettings': {'temperature': 0.7, 'maxTokens': 4096, 'topP': 1.0},
      'seenOnboarding': true,
      'exampleContentSeeded': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  // JsonStorage writes under <app-docs>/<pyreDataDirName()>/, not directly
  // in the app-docs dir — mirror that here so we read the real file.
  File stateFile() => File('${tmp.path}/${pyreDataDirName()}/$stateFileName');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pyre_storage_h10_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('H-10 off-isolate encode', () {
    test('encodeStateBlob output is identical to synchronous jsonEncode',
        () async {
      final blob = _representativeBlob();
      // The off-isolate path (compute → encodeStateBlob) must produce the
      // EXACT same string the old synchronous call did.
      final viaCompute = encodeStateBlob(blob);
      final viaSync = jsonEncode(blob);
      expect(viaCompute, equals(viaSync));
      // And it must round-trip back to the same structure.
      expect(jsonDecode(viaCompute), equals(blob));
    });

    test('save() writes exactly the encoded bytes and reloads cleanly',
        () async {
      final storage = JsonStorage();
      final blob = _representativeBlob();
      await storage.save(blob);

      // The bytes on disk match the synchronous encode (no drift from the
      // compute hop).
      final onDisk = await stateFile().readAsString();
      expect(onDisk, equals(jsonEncode(blob)));

      // And the loader reads it back to the original structure.
      final loaded = await storage.load();
      expect(loaded, equals(blob));
    });
  });

  group('H-10 write-ordering guard', () {
    test('overlapping saves: only the latest snapshot survives', () async {
      final storage = JsonStorage();
      final older = _representativeBlob()..['marker'] = 'OLDER';
      final newer = _representativeBlob()..['marker'] = 'NEWER';

      // Fire two saves WITHOUT awaiting between them so their encode hops
      // overlap. `save(newer)` claims a higher sequence number, so whichever
      // encode finishes first, the stale (older) write must be dropped.
      final f1 = storage.save(older);
      final f2 = storage.save(newer);
      await Future.wait([f1, f2]);

      final onDisk = await stateFile().readAsString();
      final decoded = jsonDecode(onDisk) as Map<String, dynamic>;
      expect(decoded['marker'], equals('NEWER'),
          reason: 'the latest save must win; a stale encode must not '
              'overwrite newer bytes');

      // Reloads cleanly (not interleaved / corrupted).
      final loaded = await storage.load();
      expect(loaded, equals(newer));
    });

    test('sequential saves each land (guard never drops a non-overlapping '
        'write)', () async {
      final storage = JsonStorage();
      final a = _representativeBlob()..['marker'] = 'A';
      final b = _representativeBlob()..['marker'] = 'B';

      // Awaited end-to-end (the AppStore._persistOnce contract): both must
      // complete their disk write; the second overwrites the first.
      await storage.save(a);
      final afterA = await storage.load();
      expect(afterA!['marker'], equals('A'));

      await storage.save(b);
      final afterB = await storage.load();
      expect(afterB!['marker'], equals('B'));
    });
  });
}
