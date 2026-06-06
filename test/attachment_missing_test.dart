import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/attachment_refs.dart';

// SYNC W7 (attachment volume): a pushing client must upload ONLY the blobs the
// server is MISSING, so each image transfers at most once and we never re-send
// gigabytes of images the peer already holds. This pins the pure set-difference
// the negotiation is built on.
void main() {
  group('attachmentHashesMissing', () {
    test('returns only the hashes the server lacks', () {
      final missing = attachmentHashesMissing(
        ['aaa', 'bbb', 'ccc'],
        {'bbb'},
      );
      expect(missing, {'aaa', 'ccc'});
    });

    test('server has everything → nothing to upload', () {
      expect(
        attachmentHashesMissing(['a', 'b'], {'a', 'b'}),
        isEmpty,
      );
    });

    test('server has nothing → all are missing', () {
      expect(
        attachmentHashesMissing(['a', 'b'], <String>{}),
        {'a', 'b'},
      );
    });

    test('dedupes repeated requested hashes', () {
      expect(
        attachmentHashesMissing(['a', 'a', 'b'], <String>{}),
        {'a', 'b'},
      );
    });

    test('drops blank / path-unsafe hashes (no traversal)', () {
      final missing = attachmentHashesMissing(
        ['', '   ', 'ok', '../etc', 'a/b'],
        <String>{},
      );
      expect(missing, {'ok'});
    });
  });
}
