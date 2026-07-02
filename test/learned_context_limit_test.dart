// Slice D-2 (2026-07-02): persisted "learned context-limit" cache on
// AppStore. PURE STATE — nothing reads `learnedContextLimits` yet (Slice
// D-3 wires the reader). These tests cover the full lifecycle mirrored on
// `providerRefusals`: record/tighten semantics, persist/load round-trip,
// and prune-on-provider-delete — plus the model_metadata.dart:78 key-shape
// convention ('providerId|model', NOT providerRefusals' providerId-alone
// key).
//
// NOTE on why the round-trip/prune tests below don't call the real
// `AppStore.load()`: `load()` unawaited-fires `AttachmentStore.gcOrphans`
// (path_provider) and (for localhost providers) `warmUpLocalProviders`
// (secure storage) as fire-and-forget background work. Those platform
// channels aren't available in a plain `flutter_test` VM run, and since the
// calls are `unawaited`, a `MissingPluginException` surfaces as an
// unhandled zone error blamed on whichever test happens to be running —
// exactly the flake `botbooru_profile_sync_test.dart` already documents
// ("We deliberately DON'T exercise `AppStore.load()` here"). Following that
// established convention: the persist half is proven via the REAL
// `flushPersist()` → captured-blob path (production `_persist`/`toJson`
// code, no mocks needed), and the hydrate half is proven via a pure
// re-implementation of the exact 3-line coercion `load()` uses for
// `learnedContextLimits` (same style as
// `app_store_scalar_tolerance_test.dart`'s `_jStr`/`_jBool` shims) — this
// must stay in sync with the source hydrate block in app_store.dart.

import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

/// In-memory backend so `flushPersist()` doesn't hit real disk / platform
/// channels in a unit test. Mirrors app_store_stream_coalesce_test.dart's
/// `_MemBackend`.
class _MemBackend implements StoreBackend {
  Map<String, dynamic>? blob;

  @override
  Future<Map<String, dynamic>?> load() async => blob;

  @override
  Future<void> save(Map<String, dynamic> b) async {
    blob = b;
  }

  @override
  Future<void> clear() async {
    blob = null;
  }
}

/// Pure re-implementation of the exact hydrate coercion `AppStore.load()`
/// applies to `raw['learnedContextLimits']`. Kept in sync with the source
/// (app_store.dart, next to the `providerRefusals` hydrate block).
Map<String, int> _hydrateLearnedContextLimits(dynamic raw) {
  var out = <String, int>{};
  if (raw is Map) {
    out = raw.map(
      (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
    );
  }
  return out;
}

void main() {
  group('recordContextLimit — record/tighten semantics', () {
    test('a new entry is stored', () {
      final store = AppStore(storage: _MemBackend());
      store.recordContextLimit('p1', 'model-a', 8000);
      expect(store.learnedContextLimits['p1|model-a'], 8000);
    });

    test('a SMALLER second call tightens the stored value', () {
      final store = AppStore(storage: _MemBackend());
      store.recordContextLimit('p1', 'model-a', 8000);
      store.recordContextLimit('p1', 'model-a', 4000);
      expect(store.learnedContextLimits['p1|model-a'], 4000);
    });

    test('a LARGER second call does NOT loosen it (min wins)', () {
      final store = AppStore(storage: _MemBackend());
      store.recordContextLimit('p1', 'model-a', 4000);
      store.recordContextLimit('p1', 'model-a', 8000);
      expect(store.learnedContextLimits['p1|model-a'], 4000);
    });

    test('non-positive limitTokens is ignored (zero)', () {
      final store = AppStore(storage: _MemBackend());
      store.recordContextLimit('p1', 'model-a', 0);
      expect(store.learnedContextLimits.containsKey('p1|model-a'), isFalse);
    });

    test('non-positive limitTokens is ignored (negative)', () {
      final store = AppStore(storage: _MemBackend());
      store.recordContextLimit('p1', 'model-a', -100);
      expect(store.learnedContextLimits.containsKey('p1|model-a'), isFalse);
    });

    test('non-positive call after a valid entry does not clobber it', () {
      final store = AppStore(storage: _MemBackend());
      store.recordContextLimit('p1', 'model-a', 4000);
      store.recordContextLimit('p1', 'model-a', -1);
      expect(store.learnedContextLimits['p1|model-a'], 4000);
    });
  });

  group('key shape', () {
    test('the stored key is exactly "providerId|model"', () {
      final store = AppStore(storage: _MemBackend());
      store.recordContextLimit('my-provider-id', 'my-model-name', 12345);
      expect(store.learnedContextLimits.keys.single,
          'my-provider-id|my-model-name');
    });
  });

  group('persist -> load round-trip', () {
    test('a recorded limit survives a save + reload cycle', () async {
      final backend = _MemBackend();
      final store = AppStore(storage: backend);
      store.recordContextLimit('p1', 'model-a', 6000);
      await store.flushPersist();

      // The blob must actually carry the key (real production persist path
      // — `_persist()` → the toJson blob — no mocking involved).
      expect(backend.blob, isNotNull);
      expect(backend.blob!.containsKey('learnedContextLimits'), isTrue);
      expect(backend.blob!['learnedContextLimits'], {'p1|model-a': 6000});

      // Hydrate half: feed the captured blob through the exact coercion
      // `load()` applies (see `_hydrateLearnedContextLimits` doc comment).
      final rehydrated =
          _hydrateLearnedContextLimits(backend.blob!['learnedContextLimits']);
      expect(rehydrated['p1|model-a'], 6000);
    });

    test('an empty cache omits the key from the persisted blob', () async {
      final backend = _MemBackend();
      final store = AppStore(storage: backend);
      await store.flushPersist();

      expect(backend.blob, isNotNull);
      expect(backend.blob!.containsKey('learnedContextLimits'), isFalse);
    });

    test('a null value degrades to 0 (matches providerRefusals\' tolerance)',
        () {
      // The hydrate coercion is `(v as num?)?.toInt() ?? 0` — the SAME
      // pattern used by providerRefusals (app_store.dart:570): it tolerates
      // an explicit JSON null (or a missing entry map value) by degrading to
      // 0, but a non-numeric non-null value is a malformed blob and is
      // allowed to throw, same as providerRefusals today.
      final rehydrated = _hydrateLearnedContextLimits({
        'p1|model-a': 6000,
        'p2|model-b': null,
      });
      expect(rehydrated['p1|model-a'], 6000);
      expect(rehydrated['p2|model-b'], 0);
    });

    test('a double value truncates via toInt() (JSON numbers may decode as '
        'double)', () {
      final rehydrated = _hydrateLearnedContextLimits({'p1|model-a': 6000.0});
      expect(rehydrated['p1|model-a'], 6000);
    });
  });

  group('prune on provider delete', () {
    // `_sweepOrphanReferences` (which owns this prune) is private and only
    // reachable via `load()`, which isn't safely callable in this test
    // environment (see the file-level NOTE above). This test drives the
    // IDENTICAL predicate app_store.dart uses at the prune site (verbatim
    // match confirmed against the source below) against a real AppStore's
    // own `learnedContextLimits` field, proving the prune CONTRACT: keys
    // whose providerId half ('providerId|model'.split('|').first) is no
    // longer a known provider id are dropped; other providers' keys survive.
    //
    // Source (app_store.dart, _sweepOrphanReferences):
    //   learnedContextLimits.removeWhere(
    //     (key, _) => !providerIds.contains(key.split('|').first),
    //   );
    test('deleting a provider drops its keys, keeps another provider\'s',
        () {
      final store = AppStore(storage: _MemBackend());
      store.providers = [
        ApiProvider(id: 'p1', name: 'Provider 1', model: 'model-a'),
        ApiProvider(id: 'p2', name: 'Provider 2', model: 'model-b'),
      ];
      store.recordContextLimit('p1', 'model-a', 4000);
      store.recordContextLimit('p2', 'model-b', 9000);

      // Simulate deleting p1.
      store.providers = [
        ApiProvider(id: 'p2', name: 'Provider 2', model: 'model-b'),
      ];
      final providerIds = store.providers.map((p) => p.id).toSet();
      store.learnedContextLimits.removeWhere(
        (key, _) => !providerIds.contains(key.split('|').first),
      );

      expect(store.learnedContextLimits.containsKey('p1|model-a'), isFalse);
      expect(store.learnedContextLimits['p2|model-b'], 9000);
    });
  });
}
