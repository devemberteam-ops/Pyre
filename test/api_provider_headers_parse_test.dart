// Audit B3 (MAJOR): `headers: (j['headers'] as Map?)?.cast<String, String>()
// ?? {}` in ApiProvider.fromJson built a lazy CastMap — a non-String VALUE
// doesn't throw at decode time, it throws the first time something iterates
// the map (`_sanitiseHeaders` does exactly that on every send). A provider
// with one corrupted header value failed EVERY send with a confusing
// TypeError instead of a clean "bad header" message.
//
// Fix: eager-build the map, keeping only entries whose key AND value are
// Strings — same philosophy as `_jStringList`.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('Audit B3: ApiProvider.fromJson headers is eager + tolerant', () {
    test('a non-String header VALUE is dropped; parse + read never throws',
        () {
      final j = <String, dynamic>{
        'id': 'p1',
        'name': 'Test Provider',
        'headers': {'Authorization': 'ok', 'X-Bad': 123},
      };

      late ApiProvider p;
      expect(() {
        p = ApiProvider.fromJson(j);
        // Force a full iteration — this is exactly what `_sanitiseHeaders`
        // does on every send, and what used to throw with the lazy cast.
        for (final entry in p.headers.entries) {
          // ignore: unnecessary_statements
          entry.value.length;
        }
      }, returnsNormally);

      expect(p.headers, {'Authorization': 'ok'});
    });

    test('a non-String header KEY is dropped too', () {
      final j = <String, dynamic>{
        'id': 'p1',
        'name': 'Test Provider',
        'headers': <dynamic, dynamic>{'Authorization': 'ok', 42: 'bad-key'},
      };
      final p = ApiProvider.fromJson(j);
      expect(p.headers, {'Authorization': 'ok'});
    });

    test('an all-clean headers map passes through unchanged', () {
      final j = <String, dynamic>{
        'id': 'p1',
        'name': 'Test Provider',
        'headers': {'Authorization': 'Bearer sk', 'X-Org': 'ember'},
      };
      final p = ApiProvider.fromJson(j);
      expect(p.headers, {'Authorization': 'Bearer sk', 'X-Org': 'ember'});
    });

    test('a missing headers key defaults to empty (no throw)', () {
      final p =
          ApiProvider.fromJson(<String, dynamic>{'id': 'p1', 'name': 'N'});
      expect(p.headers, isEmpty);
    });

    test('a non-Map headers value (wrong type) defaults to empty', () {
      final p = ApiProvider.fromJson(
          <String, dynamic>{'id': 'p1', 'name': 'N', 'headers': 'nope'});
      expect(p.headers, isEmpty);
    });
  });
}
