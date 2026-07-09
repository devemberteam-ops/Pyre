@TestOn('vm')
library;

// Batch E audit Fix 1 — oracle audit: test/sync_data_correctness_test.dart
// exercised LOCAL REIMPLEMENTATIONS (`keepLocalBumpMtime`, `reapBoundary`) of
// the S-BUG1 / S-BUG3 fix logic. The REAL logic is private in
// lib/services/sync_engine.dart: `_keepLocalMtime` (used by every `force ==
// false` conflict branch in the `apply*` closures) and the tombstone-reap
// `mtime <= effective` boundary inside `applyTombstones()`. Neither was ever
// exercised by an actual SyncEngine tick — the suite would have stayed green
// even if the real fixes were reverted.
//
// This file drives the REAL `SyncEngine._tick()` (via the public
// `forceTick()`) end to end: a real AppStore, a real (paired) LanClient, and
// a `package:http/testing.dart` `MockClient` that fakes ONLY the HTTP
// boundary (the /pair, /pull, /push endpoints) — never the merge logic
// itself. `SyncEngine` is otherwise a singleton wired for app lifecycle
// (WidgetsBinding observer, a 30s periodic Timer, a delayed auto-tick on
// install); `debugInstallForTest` (a tiny @visibleForTesting seam added
// alongside this test) points the engine at a fresh store and resets its
// per-tick cursors WITHOUT any of that lifecycle wiring, so a unit test can
// call `forceTick()` directly and inspect the real merge result.
//
// Revert-validation performed by hand while writing this suite (see the
// commit message / PR notes): temporarily changing the two `mtime <=
// effective` occurrences for the `character` tombstone-reap arm back to the
// pre-fix `mtime < effective` made
// "tombstone mtime EQUAL to record mtime reaps the record (<=)" FAIL, while
// "tombstone mtime OLDER than record mtime does NOT reap" kept passing — i.e.
// this suite bites a revert of S-BUG3. The change was reverted immediately
// after confirming the failure; sync_engine.dart is unmodified except for
// the additive `debugInstallForTest` seam.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lan_client.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/services/sync_engine.dart';
import 'package:pyre/state/app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory AppStore backend — no disk I/O, keeps the test hermetic. Same
/// shape as test/tombstone_resurrection_test.dart's `_MemoryBackend`.
class _MemoryBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

/// Fakes the flutter_secure_storage MethodChannel with an in-memory store so
/// LanClient.pair()'s bearer write (routed through SecureKeys on native)
/// works without an OS keystore, unavailable in `flutter test`'s VM. Mirrors
/// test/backup_import_key_hydration_test.dart's helper of the same shape.
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
        store[args['key'] as String] = args['value'] as String;
        return null;
      case 'read':
        return store[args['key'] as String];
      case 'delete':
        store.remove(args['key'] as String);
        return null;
      case 'deleteAll':
        store.clear();
        return null;
      case 'containsKey':
        return store.containsKey(args['key'] as String);
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

/// A minimal fake LAN peer answering /pair, /pull, /push the way
/// PyreServer's real endpoints do (shape-wise), so SyncEngine's REAL
/// `_tick()` runs completely unmodified. This fakes ONLY the HTTP boundary
/// — [pullBody] is supplied by each test and read fresh on every /pull so
/// the canned payload can be swapped between ticks.
MockClient _fakePeer({
  required String deviceId,
  required Map<String, dynamic> Function() pullBody,
}) {
  return MockClient((request) async {
    if (request.method == 'POST' && request.url.path == '/pair') {
      return http.Response(
        jsonEncode({'bearerToken': 'test-bearer', 'deviceId': deviceId}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'GET' && request.url.path == '/pull') {
      return http.Response(jsonEncode(pullBody()), 200,
          headers: {'content-type': 'application/json'});
    }
    if (request.method == 'POST' && request.url.path == '/push') {
      return http.Response(
          jsonEncode({'accepted': 0, 'rejected': <dynamic>[]}), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('not found', 404);
  });
}

/// Pairs the REAL [LanClient.instance] against [peer] (a genuine /pair round
/// trip through the faked HTTP boundary) and installs [store] on the REAL
/// [SyncEngine.instance] via the test-only seam — no WidgetsBinding
/// observer / periodic Timer, see `debugInstallForTest`'s doc.
Future<void> _pairAndInstall(MockClient peer, AppStore store) async {
  SyncEngine.instance.debugInstallForTest(store);
  final err = await LanClient.instance
      .pair(host: '127.0.0.1', port: 9999, pairingToken: 'test-token');
  expect(err, isNull, reason: 'fake /pair must succeed: $err');
  expect(LanClient.instance.isPaired, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorageChannel fakeSecureStorage;
  var deviceCounter = 0;

  setUp(() {
    fakeSecureStorage = _FakeSecureStorageChannel();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await LanClient.instance.disconnect();
    fakeSecureStorage.dispose();
  });

  group('S-BUG1 (real _tick / _keepLocalMtime): keep-local conflict', () {
    test(
        'character: local content survives a genuine conflict, mtime bumped '
        'to the REAL formula max(now, serverTime+1)', () async {
      final store = AppStore(storage: _MemoryBackend());
      // preferThisDevice ⇒ every genuine conflict resolves to "keep local"
      // (force == false), which is the branch S-BUG1 fixed.
      store.setSyncConflictMode(SyncConflictMode.preferThisDevice);
      store.characters.add(Character(
        id: 'c1',
        name: 'Local Name',
        description: 'local desc',
        mtime: 1500,
      ));

      final incoming = Character(
        id: 'c1',
        name: 'Remote Name',
        description: 'remote desc',
        mtime: 2000, // newer than local — a plain LWW would overwrite.
      );
      // Far-future serverTime makes `_keepLocalMtime`'s `now > serverTime+1`
      // branch deterministically false, so the bump is exactly
      // `serverTime + 1` — pins the assertion to the REAL formula, not just
      // "greater than something".
      final serverTime = DateTime.now().millisecondsSinceEpoch + 10000000;
      final peer = _fakePeer(
        deviceId: 'dev-${deviceCounter++}',
        pullBody: () => {
          'serverTime': serverTime,
          'updates': {
            'characters': [incoming.toJson()],
          },
        },
      );

      await http.runWithClient(() async {
        await _pairAndInstall(peer, store);
        await SyncEngine.instance.forceTick();
      }, () => peer);

      final result = store.characters.firstWhere((c) => c.id == 'c1');
      expect(result.name, 'Local Name',
          reason: 'keep-local must not be overwritten by the incoming peer '
              'record, even though the peer is nominally newer');
      expect(result.description, 'local desc');
      expect(result.mtime, serverTime + 1,
          reason: 'must equal the REAL SyncEngine._keepLocalMtime formula '
              '(max(now, serverTime+1)), read via the store — not a local '
              'reimplementation of the formula');
    });

    test(
        'chat: local content survives a genuine conflict, mtime bumped to '
        'the REAL formula max(now, serverTime+1)', () async {
      final store = AppStore(storage: _MemoryBackend());
      store.setSyncConflictMode(SyncConflictMode.preferThisDevice);
      store.chats.add(Chat(
        id: 'ch1',
        characterIds: const [],
        title: 'Local Title',
        mtime: 1500,
      ));

      final incoming = Chat(
        id: 'ch1',
        characterIds: const [],
        title: 'Remote Title',
        mtime: 2000,
      );
      final serverTime = DateTime.now().millisecondsSinceEpoch + 10000000;
      final peer = _fakePeer(
        deviceId: 'dev-${deviceCounter++}',
        pullBody: () => {
          'serverTime': serverTime,
          'updates': {
            'chats': [incoming.toJson()],
          },
        },
      );

      await http.runWithClient(() async {
        await _pairAndInstall(peer, store);
        await SyncEngine.instance.forceTick();
      }, () => peer);

      final result = store.chats.firstWhere((c) => c.id == 'ch1');
      expect(result.title, 'Local Title',
          reason: 'keep-local must not be overwritten by the incoming peer '
              'record');
      expect(result.mtime, serverTime + 1,
          reason: 'must equal the REAL SyncEngine._keepLocalMtime formula, '
              'read via the store');
    });
  });

  group('S-BUG3 (real _tick / applyTombstones): reap boundary', () {
    test('tombstone mtime EQUAL to record mtime reaps the record (<=)',
        () async {
      final store = AppStore(storage: _MemoryBackend());
      store.characters.add(Character(id: 'g1', name: 'Ghost', mtime: 5000));

      final peer = _fakePeer(
        deviceId: 'dev-${deviceCounter++}',
        pullBody: () => {
          'serverTime': 6000,
          'updates': <String, dynamic>{},
          'tombstones': {'character:g1': 5000}, // == record mtime
        },
      );

      await http.runWithClient(() async {
        await _pairAndInstall(peer, store);
        await SyncEngine.instance.forceTick();
      }, () => peer);

      expect(store.characters.any((c) => c.id == 'g1'), isFalse,
          reason: 'the real applyTombstones() reap boundary is `<=` — an '
              'equal-mtime tombstone must reap the record');
    });

    test('tombstone mtime OLDER than record mtime does NOT reap', () async {
      final store = AppStore(storage: _MemoryBackend());
      store.characters.add(Character(id: 'g2', name: 'Alive', mtime: 5000));

      final peer = _fakePeer(
        deviceId: 'dev-${deviceCounter++}',
        pullBody: () => {
          'serverTime': 6000,
          'updates': <String, dynamic>{},
          'tombstones': {'character:g2': 3000}, // older than record mtime
        },
      );

      await http.runWithClient(() async {
        await _pairAndInstall(peer, store);
        await SyncEngine.instance.forceTick();
      }, () => peer);

      expect(store.characters.any((c) => c.id == 'g2'), isTrue,
          reason: 'a tombstone strictly older than the live record must not '
              'reap it');
    });
  });
}
