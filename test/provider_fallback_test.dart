import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/provider_fallback.dart';

ApiProvider _p(String id) => ApiProvider(id: id, name: id);

void main() {
  final all = [_p('a'), _p('b'), _p('c')];

  group('buildFallbackChain', () {
    test('enabled: primary first, then rest in list order', () {
      final chain = buildFallbackChain(all: all, primaryId: 'b', enabled: true);
      expect(chain.map((p) => p.id).toList(), ['b', 'a', 'c']);
    });

    test('disabled: only primary', () {
      final chain = buildFallbackChain(all: all, primaryId: 'b', enabled: false);
      expect(chain.map((p) => p.id).toList(), ['b']);
    });

    test('no primary set, enabled: just list order', () {
      final chain = buildFallbackChain(all: all, primaryId: null, enabled: true);
      expect(chain.map((p) => p.id).toList(), ['a', 'b', 'c']);
    });

    test('primary id missing from list: falls to list order', () {
      final chain = buildFallbackChain(all: all, primaryId: 'zzz', enabled: true);
      expect(chain.map((p) => p.id).toList(), ['a', 'b', 'c']);
    });

    test('single provider: chain of one regardless of enabled', () {
      final one = [_p('a')];
      expect(buildFallbackChain(all: one, primaryId: 'a', enabled: true)
          .map((p) => p.id).toList(), ['a']);
      expect(buildFallbackChain(all: one, primaryId: 'a', enabled: false)
          .map((p) => p.id).toList(), ['a']);
    });
  });

  group('pickCleanAlternative', () {
    test('returns first candidate with a zero refusal record', () {
      final clean = pickCleanAlternative(
        candidates: [_p('a'), _p('b'), _p('c')],
        refusals: {'a': 2, 'b': 0},
        excludeId: 'a',
      );
      expect(clean?.id, 'b');
    });

    test('skips the excluded id even if clean', () {
      final clean = pickCleanAlternative(
        candidates: [_p('a'), _p('b')],
        refusals: {},
        excludeId: 'a',
      );
      expect(clean?.id, 'b');
    });

    test('returns null when every candidate has a refusal record', () {
      final clean = pickCleanAlternative(
        candidates: [_p('a'), _p('b')],
        refusals: {'a': 1, 'b': 3},
        excludeId: 'a',
      );
      expect(clean, isNull);
    });
  });

  // Web-send fix (2026-07-03): a paired WEB profile has no local providers by
  // design (the hub proxies with its OWN), but the send-path gates demand a
  // non-null provider — the synthetic hub-proxy provider satisfies them.
  group('effectiveActiveProvider (web hub-proxy fallback)', () {
    test('a resolved local provider always wins (any platform)', () {
      final local = _p('mine');
      expect(
          effectiveActiveProvider(local: local, isWeb: true, isPaired: true),
          same(local));
      expect(
          effectiveActiveProvider(
              local: local, isWeb: false, isPaired: false),
          same(local));
    });

    test('web + paired + no local → the synthetic hub proxy', () {
      final r =
          effectiveActiveProvider(local: null, isWeb: true, isPaired: true);
      expect(r, isNotNull);
      expect(r!.id, '__hub_proxy__');
      expect(r.name, 'PC (paired)');
    });

    test(
        'web UNPAIRED → null (the pairing screen is the fix, not a ghost '
        'provider)', () {
      expect(
          effectiveActiveProvider(local: null, isWeb: true, isPaired: false),
          isNull);
    });

    test('native → null, byte-identical to the old getter', () {
      expect(
          effectiveActiveProvider(local: null, isWeb: false, isPaired: true),
          isNull);
      expect(
          effectiveActiveProvider(local: null, isWeb: false, isPaired: false),
          isNull);
    });
  });
}
