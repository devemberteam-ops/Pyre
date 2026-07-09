// Audit B2 (BLOCKER): `charSelectedTags: (raw['charSelectedTags'] as
// List?)?.cast<String>() ?? []` in AppStore.load() built a lazy CastList
// view — a corrupted element (non-String) doesn't throw at decode time, it
// throws the FIRST time something iterates/reads the list. `charSelectedTags`
// backs the Characters-tab tag chips row, read on every `_applyFiltersAndSort`
// rebuild, so a single bad element bricked the main library screen
// permanently (every rebuild re-threw).
//
// Fix: eager-filter via the same `_jStringList` philosophy models.dart
// already established (`v.whereType<String>().toList()`), dropping
// non-String elements at decode time instead of deferring the throw.
//
// NOTE on why this doesn't call the real `AppStore.load()`: `load()`
// unawaited-fires `AttachmentStore.gcOrphans` (path_provider) and (for
// localhost providers) `warmUpLocalProviders` (secure storage) as
// fire-and-forget background work, which isn't safe in a plain
// `flutter_test` VM run — see learned_context_limit_test.dart's file-level
// note for the established precedent. Following that convention: this test
// drives a pure re-implementation of the exact hydrate coercion `load()`
// uses for `charSelectedTags` (kept in sync with the source line in
// app_store.dart), proving the no-throw + eager-filter contract directly.

import 'package:flutter_test/flutter_test.dart';

/// Pure re-implementation of the exact hydrate coercion `AppStore.load()`
/// applies to `raw['charSelectedTags']` (app_store.dart, `_jStringList` +
/// its call site). Kept in sync with the source.
List<String> _jStringList(dynamic v) =>
    v is List ? v.whereType<String>().toList() : <String>[];

List<String> _hydrateCharSelectedTags(Map<String, dynamic> raw) =>
    _jStringList(raw['charSelectedTags']);

void main() {
  group('Audit B2: charSelectedTags hydrate is eager + tolerant', () {
    test(
        'a corrupted element (int, null) is dropped; the loaded field never '
        'throws on read', () {
      final raw = <String, dynamic>{
        'charSelectedTags': ['ok', 42, null, 'also-ok'],
      };

      // THE BLOCKER: with the old lazy `.cast<String>()` this list "loads"
      // fine but throws TypeError the moment anything reads element [1].
      List<String>? tags;
      expect(() {
        tags = _hydrateCharSelectedTags(raw);
        // Force a read of every element — this is what used to throw.
        for (final t in tags!) {
          // ignore: unnecessary_statements
          t.length;
        }
      }, returnsNormally);

      expect(tags, ['ok', 'also-ok']);
    });

    test('a fully-clean list passes through unchanged', () {
      final raw = <String, dynamic>{
        'charSelectedTags': ['romance', 'sci-fi'],
      };
      expect(_hydrateCharSelectedTags(raw), ['romance', 'sci-fi']);
    });

    test('a missing key defaults to empty (no throw)', () {
      expect(_hydrateCharSelectedTags(<String, dynamic>{}), <String>[]);
    });

    test('a non-List value (wrong type) defaults to empty (no throw)', () {
      expect(
        _hydrateCharSelectedTags(<String, dynamic>{'charSelectedTags': 'x'}),
        <String>[],
      );
    });

    test('all-corrupted list degrades to empty, not a throw', () {
      expect(
        _hydrateCharSelectedTags(
            <String, dynamic>{'charSelectedTags': [1, 2, null, true]}),
        <String>[],
      );
    });
  });
}
