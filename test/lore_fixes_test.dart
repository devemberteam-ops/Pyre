@TestOn('vm')
library;

// Lore family fixes (2026-07-13, Codex-confirmed audit findings, slice A):
//   #1 order semantics — ASCENDING (higher order = later in the block =
//      closer to history = more attention; ST insertion-order convention).
//   #2 constant × probability — a constant entry with useProbability rolls
//      like any other; constant WITHOUT useProbability never consults the
//      roller (seeded fixtures unchanged).
//   #4 macro fill — {{user}}/{{char}} resolve in both the scanned window
//      text and entry keys via the caller-supplied fillMacros.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_inject.dart';

LoreEntry _entry(
  String id, {
  List<String>? keys,
  bool constant = false,
  int order = 0,
  bool useProbability = false,
  int probability = 100,
}) =>
    LoreEntry(
      id: id,
      keys: keys ?? const [],
      content: 'content-$id',
      constant: constant,
      order: order,
      useProbability: useProbability,
      probability: probability,
    );

Lorebook _book(List<LoreEntry> entries) =>
    Lorebook(id: 'b', name: 'Book', entries: entries);

Message _msg(String text) =>
    Message(id: 'm-$text'.hashCode.toString(), kind: MessageKind.user, variants: [text]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fix #1 — order is ASCENDING (higher = later = nearer history)', () {
    test('higher-order entry lands LAST in hits', () {
      final scan = scanLorebookHits(
        [
          _book([
            _entry('low', constant: true, order: 1),
            _entry('high', constant: true, order: 10),
            _entry('mid', constant: true, order: 5),
          ])
        ],
        [_msg('hello')],
      );
      expect(scan.hits.map((e) => e.id).toList(), ['low', 'mid', 'high'],
          reason: 'ST semantics: the most important entry sits closest to '
              'the chat history (end of the block)');
    });

    test('equal orders keep stable scan order (H-9 determinism preserved)', () {
      final scan = scanLorebookHits(
        [
          _book([
            _entry('a', constant: true),
            _entry('b', constant: true),
            _entry('c', constant: true),
          ])
        ],
        [_msg('hello')],
      );
      expect(scan.hits.map((e) => e.id).toList(), ['a', 'b', 'c']);
    });
  });

  group('fix #2 — constant honours its own probability', () {
    test('constant + probability 0 never fires', () {
      final scan = scanLorebookHits(
        [
          _book([
            _entry('never',
                constant: true, useProbability: true, probability: 0)
          ])
        ],
        [_msg('hello')],
      );
      expect(scan.hits, isEmpty);
    });

    test('constant + probability 100 always fires (no roll consumed)', () {
      final scan = scanLorebookHits(
        [
          _book([
            _entry('always',
                constant: true, useProbability: true, probability: 100)
          ])
        ],
        [_msg('hello')],
      );
      expect(scan.hits.map((e) => e.id), ['always']);
    });

    test('constant + partial probability follows the seeded roll', () {
      // Compute what the first roll of THIS seed will be, then assert the
      // scan's decision is coherent with it — deterministic without pinning
      // a magic number.
      final expectedRoll = Random(42).nextInt(100);
      final scan = scanLorebookHits(
        [
          _book([
            _entry('maybe',
                constant: true, useProbability: true, probability: 50)
          ])
        ],
        [_msg('hello')],
        rng: Random(42),
      );
      expect(scan.hits.isNotEmpty, expectedRoll < 50,
          reason: 'fired iff roll($expectedRoll) < 50');
    });

    test('constant WITHOUT useProbability never consumes a roll '
        '(seeded sequences — golden fixtures — unchanged)', () {
      // A plain constant entry followed by a probability entry: the
      // probability entry must see the SAME first roll it would see alone.
      final aloneRoll = Random(7).nextInt(100);
      final scan = scanLorebookHits(
        [
          _book([
            _entry('plain-constant', constant: true),
            _entry('prob',
                keys: ['hello'], useProbability: true, probability: 50),
          ])
        ],
        [_msg('hello there')],
        rng: Random(7),
      );
      final probFired = scan.hits.any((e) => e.id == 'prob');
      expect(probFired, aloneRoll < 50,
          reason: 'the constant entry must not have consumed a roll');
    });
  });

  group('fix #4 — {{user}}/{{char}} resolve in keys and window text', () {
    String fill(String s) => s
        .replaceAll('{{user}}', 'Kuru')
        .replaceAll('{{char}}', 'Sera');

    test('a {{user}} key matches the persona name in chat text', () {
      final books = [
        _book([
          _entry('e', keys: ['{{user}}'])
        ])
      ];
      final withFill = scanLorebookHits(books, [_msg('Kuru waves hello')],
          fillMacros: fill);
      expect(withFill.hits.map((e) => e.id), ['e']);
      // Without the filler the key stays literal `{{user}}` → no match
      // (the pre-fix behaviour, kept for callers that pass nothing).
      final withoutFill = scanLorebookHits(books, [_msg('Kuru waves hello')]);
      expect(withoutFill.hits, isEmpty);
    });

    test('a plain key matches a message that names the char via macro', () {
      final books = [
        _book([
          _entry('e', keys: ['Sera'])
        ])
      ];
      final scan = scanLorebookHits(
          books, [_msg('I look at {{char}} and smile')],
          fillMacros: fill);
      expect(scan.hits.map((e) => e.id), ['e']);
    });
  });

  group('fix #3 (minimal) — the scan sees the prompt\'s view of a message', () {
    test('effectiveTextOf null excludes the message from the window', () {
      final books = [
        _book([
          _entry('e', keys: ['secret'])
        ])
      ];
      final hidden = _msg('the secret word');
      final scan = scanLorebookHits(
        books,
        [hidden, _msg('plain talk')],
        effectiveTextOf: (m) => m.id == hidden.id ? null : m.text,
      );
      expect(scan.hits, isEmpty,
          reason: 'an excluded message (in-flight slot / hidden greeting) '
              'must not feed the keyword window');
    });

    test('effectiveTextOf can strip reasoning so <think> text never fires',
        () {
      final books = [
        _book([
          _entry('e', keys: ['dragon'])
        ])
      ];
      final scan = scanLorebookHits(
        books,
        [_msg('<think>maybe a dragon?</think>Just a shadow.')],
        effectiveTextOf: (m) =>
            m.text.replaceAll(RegExp(r'<think>.*?</think>'), ''),
      );
      expect(scan.hits, isEmpty,
          reason: 'chain-of-thought is never sent to the model — keys must '
              'not fire on it');
    });
  });

  group('fix #5 — per-entry character filter (ST parity)', () {
    LoreEntry filtered(String id,
            {List<String>? names, bool exclude = false}) =>
        LoreEntry(
          id: id,
          keys: const [],
          content: 'c',
          constant: true,
          characterFilterNames: names ?? const [],
          characterFilterExclude: exclude,
        );

    test('inclusive filter fires only when the character is in the scene', () {
      final books = [
        _book([filtered('only-sera', names: ['Sera'])])
      ];
      final withSera = scanLorebookHits(books, [_msg('hi')],
          sceneCharacterNames: ['Sera', 'Ren']);
      expect(withSera.hits.map((e) => e.id), ['only-sera']);
      final withoutSera = scanLorebookHits(books, [_msg('hi')],
          sceneCharacterNames: ['Ren']);
      expect(withoutSera.hits, isEmpty);
    });

    test('exclude inverts; matching is case-insensitive', () {
      final books = [
        _book([filtered('not-sera', names: ['sera'], exclude: true)])
      ];
      expect(
          scanLorebookHits(books, [_msg('hi')],
              sceneCharacterNames: ['SERA']).hits,
          isEmpty,
          reason: 'excluded name present (case-folded) → suppressed');
      expect(
          scanLorebookHits(books, [_msg('hi')],
              sceneCharacterNames: ['Ren']).hits.length,
          1);
    });

    test('empty filter fires for everyone; no scene names = fail-open', () {
      final books = [
        _book([
          filtered('open'),
          filtered('gated', names: ['Sera']),
        ])
      ];
      expect(
          scanLorebookHits(books, [_msg('hi')],
              sceneCharacterNames: ['Ren']).hits.map((e) => e.id),
          ['open']);
      // Older callers that pass no scene names must not lose entries.
      expect(scanLorebookHits(books, [_msg('hi')]).hits.length, 2);
    });

    test('filter fields round-trip JSON and omit at defaults', () {
      final e = filtered('e', names: ['Sera'], exclude: true);
      final back = LoreEntry.fromJson(e.toJson());
      expect(back.characterFilterNames, ['Sera']);
      expect(back.characterFilterExclude, isTrue);
      final plainJson = filtered('p').toJson();
      expect(plainJson.containsKey('characterFilterNames'), isFalse);
      expect(plainJson.containsKey('characterFilterExclude'), isFalse,
          reason: 'existing books round-trip byte-identical');
    });
  });
}
