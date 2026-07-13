@TestOn('vm')
library;

// Context-loss fix (audit round 12/14) — the pure fingerprint core, tested
// before it's wired into memory + Live Sheet. contentHash must change on a
// covered-message edit / Continue, and must NOT change on an edit after the
// anchor or to a non-selected variant.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_fingerprint.dart';

Message _m(String id, List<String> variants,
        {int sel = 0, MessageKind kind = MessageKind.char}) =>
    Message(id: id, kind: kind, variants: variants, selectedVariant: sel);

void main() {
  group('computeContentHash', () {
    final base = [
      _m('a', ['hello']),
      _m('b', ['world']),
    ];

    test('editing a COVERED message invalidates', () {
      final edited = [
        _m('a', ['hello']),
        _m('b', ['world — edited']),
      ];
      expect(computeContentHash(base, 1),
          isNot(computeContentHash(edited, 1)));
    });

    test('Continue (appending to the selected variant text) invalidates', () {
      final continued = [
        _m('a', ['hello']),
        _m('b', ['world and then some more']),
      ];
      expect(computeContentHash(base, 1),
          isNot(computeContentHash(continued, 1)));
    });

    test('an edit AFTER the anchor does NOT invalidate the covered prefix', () {
      final afterEdit = [
        _m('a', ['hello']),
        _m('b', ['world — changed']),
      ];
      // Hash up to index 0 ('a' only) is unchanged though 'b' differs.
      expect(computeContentHash(base, 0), computeContentHash(afterEdit, 0));
    });

    test('changing a NON-selected variant does NOT invalidate', () {
      final baseMulti = [
        _m('a', ['hello']),
        _m('b', ['world', 'alt'], sel: 0),
      ];
      final altChanged = [
        _m('a', ['hello']),
        _m('b', ['world', 'DIFFERENT alt'], sel: 0),
      ];
      expect(computeContentHash(baseMulti, 1),
          computeContentHash(altChanged, 1));
    });

    test('switching the selected variant DOES change the content hash', () {
      final baseMulti = [
        _m('a', ['hello']),
        _m('b', ['world', 'alt'], sel: 0),
      ];
      final selAlt = [
        _m('a', ['hello']),
        _m('b', ['world', 'alt'], sel: 1),
      ];
      expect(computeContentHash(baseMulti, 1),
          isNot(computeContentHash(selAlt, 1)));
    });

    test('empty / negative index → the __empty__ sentinel', () {
      expect(computeContentHash(const [], 0), '__empty__');
      expect(computeContentHash(base, -1), '__empty__');
    });
  });

  group('computeContentHashesAtAnchors (single-pass) equals per-anchor', () {
    final msgs = [
      _m('a', ['x']),
      _m('b', ['y']),
      _m('c', ['z']),
    ];
    test('each anchor matches the standalone computeContentHash', () {
      final multi = computeContentHashesAtAnchors(msgs, {0, 1, 2});
      expect(multi[0], computeContentHash(msgs, 0));
      expect(multi[1], computeContentHash(msgs, 1));
      expect(multi[2], computeContentHash(msgs, 2));
    });
    test('out-of-range anchors map to the sentinel', () {
      final multi = computeContentHashesAtAnchors(msgs, {5, -1});
      expect(multi[5], '__empty__');
      expect(multi[-1], '__empty__');
    });
  });

  group('computePathHash (moved, still branch-only)', () {
    test('captures the variant path; empty → sentinel', () {
      final msgs = [
        _m('a', ['x']),
        _m('b', ['y', 'y2'], sel: 1),
      ];
      expect(computePathHash(msgs, 1), contains('b:1'));
      expect(computePathHash(const [], 0), '__empty__');
    });
  });
}
