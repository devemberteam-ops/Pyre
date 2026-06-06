// Wave CY.18.230 (Creator Structured Build, Task 6a): tests for the PURE
// orchestration pipeline `runStructuredBuild` — drives the per-batch model loop
// with a FAKE injected `call` so the loop, artifact strip, JSON parse, and
// bounded truncation-continuation are all exercised headless (no real LLM).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_api.dart' show ChatTurn;
import 'package:pyre/services/creator_build.dart';

// A trivial injected turn-builder: encodes the batch keys into a single user
// turn so the fake `call` can key its reply off `turns.last.content`. The
// accumulated `decided` map (carry-forward, FIX G #3) is encoded too so tests
// can assert it is wired.
List<ChatTurn> fakeBuild(List<String> keys, Map<String, dynamic> decided) =>
    [ChatTurn('user', 'REQ:${keys.join(",")} DECIDED:${decided.keys.join(",")}')];

void main() {
  group('runStructuredBuild', () {
    test('clean multi-batch → complete merged map', () async {
      final batches = [
        ['a', 'b'],
        ['c'],
      ];

      Future<String> call(List<ChatTurn> turns) async {
        // Key off the REQ: segment only — DECIDED: (carry-forward) may also
        // mention prior-batch keys, so a bare contains('a') would mis-match.
        final last = turns.last.content;
        if (last.contains('REQ:a,b')) {
          return '{"a":"x","b":"y"}';
        }
        return '{"c":"z"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'a': 'x', 'b': 'y', 'c': 'z'});
    });

    test('truncated then continued → complete after continuation', () async {
      final batches = [
        ['a', 'b'],
      ];

      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('Continue the JSON object')) {
          return 'ated value","b":"y"}';
        }
        return '{"a":"trunc';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'a': 'truncated value', 'b': 'y'});
    });

    // MEDIUM 8: on a truncation continuation, a poorly-behaved model re-opens
    // with a leading `{` instead of continuing mid-string. The stitched text
    // `{"a":"trunc{"a":"truncated value","b":"y"}` would corrupt the scan; the
    // seam guard strips the stray leading `{` so the object still parses.
    test('continuation that re-emits a leading { is de-corrupted at the seam',
        () async {
      final batches = [
        ['a', 'b'],
      ];

      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('Continue the JSON object')) {
          // The model wrongly re-opens the whole object.
          return '{"a":"truncated value","b":"y"}';
        }
        return '{"a":"trunc'; // truncated mid-string
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'a': 'truncated value', 'b': 'y'});
    });

    test('permanently unparseable batch → its keys absent, others intact',
        () async {
      final batches = [
        ['a'],
        ['b'],
      ];

      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('REQ:a')) {
          return 'I cannot do that.'; // no JSON → not truncated → no continuation
        }
        return '{"b":"ok"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'b': 'ok'});
      expect(result.containsKey('a'), isFalse);
    });

    test('continuation bound respected (never-completes → batch empty, ≤2 extra)',
        () async {
      final batches = [
        ['a'],
      ];

      var calls = 0;
      Future<String> call(List<ChatTurn> turns) async {
        calls++;
        return '{"a":"nev'; // always truncated, even for continuation turns
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result.isEmpty, isTrue);
      expect(result.containsKey('a'), isFalse);
      // A genuine truncation does NOT trigger a whole-batch retry (it would
      // just truncate again): 1 initial + at most 2 continuations.
      expect(calls, lessThanOrEqualTo(3));
    });

    test('EMPTY reply is retried at the batch level (reasoning-provider '
        'intermittent empty content) → recovers', () async {
      final batches = [
        ['a', 'b'],
      ];

      var calls = 0;
      Future<String> call(List<ChatTurn> turns) async {
        calls++;
        // First attempt returns an empty content channel (the DeepSeek
        // intermittent-empty case); the retry returns the real object.
        if (calls == 1) return '';
        return '{"a":"x","b":"y"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'a': 'x', 'b': 'y'});
      expect(calls, 2, reason: 'one empty + one successful retry');
    });

    test('permanently EMPTY batch → bounded retries then absent (no spin)',
        () async {
      final batches = [
        ['a'],
      ];

      var calls = 0;
      Future<String> call(List<ChatTurn> turns) async {
        calls++;
        return ''; // always empty
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result.isEmpty, isTrue);
      // Bounded by _kMaxBatchAttempts (3) — never an infinite loop.
      expect(calls, lessThanOrEqualTo(3));
    });

    test('FIX #2: a VALID object MISSING a requested key → the missing key is '
        're-requested and filled', () async {
      final batches = [
        ['a', 'b', 'c'],
      ];

      var calls = 0;
      Future<String> call(List<ChatTurn> turns) async {
        calls++;
        final last = turns.last.content;
        // The targeted re-request asks ONLY for the missing key(s) — here it
        // is the batch where 'c' is requested without 'a'/'b'.
        if (last.contains('REQ:c ')) {
          return '{"c":"third"}';
        }
        // First pass: a valid object that silently dropped 'c'.
        return '{"a":"first","b":"second"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'a': 'first', 'b': 'second', 'c': 'third'});
      // 1 initial + 1 targeted re-request = 2 calls (bounded, no loop).
      expect(calls, 2);
    });

    test('FIX #2: missing-key re-request is bounded to ONE (still-missing key '
        'after the re-request is left absent)', () async {
      final batches = [
        ['a', 'b'],
      ];

      var calls = 0;
      Future<String> call(List<ChatTurn> turns) async {
        calls++;
        // Always drops 'b', even on the re-request.
        return '{"a":"x"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'a': 'x'});
      expect(result.containsKey('b'), isFalse);
      // 1 initial + exactly 1 re-request (the budget) — never loops.
      expect(calls, 2);
    });

    test('FIX #3: decidedSoFar is empty for batch 1 and carries the prior '
        "batch's fields for batch 2", () async {
      final batches = [
        ['a'],
        ['b'],
      ];

      final decidedSeen = <String, List<String>>{};
      List<ChatTurn> spyBuild(
          List<String> keys, Map<String, dynamic> decided) {
        decidedSeen[keys.join(',')] = decided.keys.toList();
        return fakeBuild(keys, decided);
      }

      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('REQ:a')) return '{"a":"x"}';
        return '{"b":"y"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: spyBuild,
      );

      expect(result, {'a': 'x', 'b': 'y'});
      // Batch 1 saw no decided facts; batch 2 saw batch 1's 'a'.
      expect(decidedSeen['a'], isEmpty);
      expect(decidedSeen['b'], contains('a'));
    });
  });
}
