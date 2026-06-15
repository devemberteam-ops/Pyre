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

    // H4: when a batch truncates mid-string and the model resumes correctly,
    // the resumed continuation text might contain a parseable JSON-object
    // FRAGMENT (e.g. a count or status object embedded in prose). The old seam
    // guard ran extractJsonObject over the WHOLE continuation chunk — greedy,
    // returns the FIRST balanced `{…}` anywhere — and would grab that inner
    // fragment as if the model had re-emitted the whole batch object. This
    // discards the real partial+continuation stitch and injects garbage.
    // The fix: only activate the re-emit path when `more` starts with `{`,
    // i.e. the model opened a fresh object — NOT when it resumed a string.
    test(
        'H4: a {…} fragment inside a resumed continuation is NOT treated as '
        'a standalone re-emit (seam guard only fires on leading {)',
        () async {
      final batches = [
        ['a', 'b'],
      ];

      // On continuation, the model produces a chunk that contains a valid
      // parseable JSON fragment {"count":42} embedded in the resumed text,
      // but the chunk does NOT start with `{`.
      // Old code: extractJsonObject finds {"count":42} → result = {"count":42}
      //           (wrong keys — 'a' and 'b' are lost, garbage injected)
      // New code: `more` starts with `v`, not `{` → standalone = null
      //           → stitch occurs → stitched text parsed for 'a'/'b'.
      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('Continue the JSON object')) {
          // Continuation does NOT start with `{` — it's resuming mid-string.
          // But it contains a standalone parseable fragment {"count":42}.
          // The batch expects keys 'a' and 'b'; "count" is a garbage key.
          return 'value_end","b":"ok"}';
        }
        return '{"a":"value_'; // truncated mid-string
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      // The seam guard must NOT have grabbed a garbage fragment — the result
      // must contain the batch keys, not an unrelated key.
      // (The stitched text {"a":"value_value_end","b":"ok"} parses correctly.)
      expect(result.containsKey('count'), isFalse,
          reason: 'H4: "count" is a garbage injected fragment, must not appear');
      expect(result['a'], 'value_value_end',
          reason: 'H4: mid-string stitch must produce the real value');
      expect(result['b'], 'ok',
          reason: 'H4: second key must survive the mid-string continuation');
    });

    // Verify the INNER-FRAGMENT scenario: the old code would grab {"count":42}
    // embedded in the continuation text. We use a continuation that contains
    // a clean parseable fragment but does NOT start with `{`.
    test(
        'H4 regression: continuation with embedded {…} fragment but not '
        'starting with { — stitch succeeds, fragment is NOT taken as the batch',
        () async {
      final batches = [
        ['status'],
      ];

      // Continuation returns text starting with a word, but containing
      // {"inner":"val"} — extractJsonObject(more) would return {"inner":"val"}
      // with the old guard. The fix skips it (doesn't start with `{`) and
      // stitches instead.
      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('Continue the JSON object')) {
          // Old seam guard would extract {"inner":"val"} (wrong key).
          // New guard: starts with 'c' → stitch → full parse.
          return 'complete"}';
        }
        return '{"status":"in'; // truncated mid-string
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      // After stitch: {"status":"incomplete"} — the correct batch key.
      expect(result['status'], 'incomplete',
          reason: 'H4: stitched result must have the batch key, not a fragment');
      expect(result.containsKey('inner'), isFalse,
          reason: 'H4: inner fragment key must NOT be present');
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

    test('continuation that re-emits a full object after an outside-string '
        'truncation is recovered', () async {
      final batches = [
        ['a', 'b'],
      ];

      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('Continue the JSON object')) {
          // The model wrongly restarts from the beginning instead of resuming
          // after the trailing comma.
          return '{"a":"x","b":"y"}';
        }
        return '{"a":"x",'; // truncated outside a string
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      expect(result, {'a': 'x', 'b': 'y'});
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

    // H5: a later batch that echoes an earlier batch's key as EMPTY must NOT
    // overwrite the good value the earlier batch produced.
    test('H5: cross-batch empty clobber is suppressed — later empty does NOT '
        'overwrite earlier good value', () async {
      // Batch 1 fills 'a' with a good value.
      // Batch 2 is for 'b' but the model also echoes 'a' as empty (over-emit).
      // The good 'a' must survive.
      final batches = [
        ['a'],
        ['b'],
      ];

      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('REQ:a')) return '{"a":"good value"}';
        // Batch 2: model over-emits 'a' empty alongside 'b'.
        return '{"a":"","b":"second"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      // 'a' must keep its good value; 'b' is filled normally.
      expect(result['a'], 'good value',
          reason: 'empty over-emit from a later batch must NOT clobber '
              'the good value produced by an earlier batch');
      expect(result['b'], 'second');
    });

    // H5 variant: a later batch with a NON-EMPTY value for an earlier key DOES
    // overwrite (a better value should always win).
    test('H5: cross-batch NON-empty overwrite IS allowed (better value wins)',
        () async {
      final batches = [
        ['a'],
        ['b'],
      ];

      Future<String> call(List<ChatTurn> turns) async {
        final last = turns.last.content;
        if (last.contains('REQ:a')) return '{"a":"first"}';
        // Batch 2 echoes 'a' with a non-empty value — this is a genuine
        // update (model corrected itself).
        return '{"a":"corrected","b":"second"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
      );

      // Non-empty overwrite is allowed.
      expect(result['a'], 'corrected');
      expect(result['b'], 'second');
    });

    // H2: cancellation token stops the build between batches.
    test('H2: cancelled token — build stops after current batch, returns '
        'accumulated fields (no more LLM calls)', () async {
      // 3 batches. Cancel after batch 1 completes.
      final batches = [
        ['a'],
        ['b'],
        ['c'],
      ];

      var calls = 0;
      final token = BuildCancelToken();

      Future<String> call(List<ChatTurn> turns) async {
        calls++;
        final last = turns.last.content;
        if (last.contains('REQ:a')) {
          // After batch 1 finishes, cancel the build.
          token.cancel();
          return '{"a":"first"}';
        }
        if (last.contains('REQ:b')) return '{"b":"second"}';
        return '{"c":"third"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
        cancelToken: token,
      );

      // Batch 1 completed — 'a' is present.
      expect(result['a'], 'first',
          reason: 'H2: completed batch must be in the result');
      // Batches 2 and 3 were skipped — 'b' and 'c' absent.
      expect(result.containsKey('b'), isFalse,
          reason: 'H2: cancelled build must not run batch 2');
      expect(result.containsKey('c'), isFalse,
          reason: 'H2: cancelled build must not run batch 3');
      // Only 1 LLM call (batch 1 only — the cancel check fires before batch 2).
      expect(calls, 1,
          reason: 'H2: only the first batch call must have fired');
    });

    test('H2: token already cancelled before build starts → no batches run',
        () async {
      final batches = [
        ['a'],
        ['b'],
      ];

      var calls = 0;
      final token = BuildCancelToken();
      token.cancel(); // cancel before we even start

      Future<String> call(List<ChatTurn> turns) async {
        calls++;
        return '{"a":"x","b":"y"}';
      }

      final result = await runStructuredBuild(
        batches: batches,
        call: call,
        buildTurns: fakeBuild,
        cancelToken: token,
      );

      expect(result.isEmpty, isTrue,
          reason: 'H2: pre-cancelled token → empty result, no work done');
      expect(calls, 0, reason: 'H2: no LLM calls when already cancelled');
    });

    test('H2: no token = normal build (backward compat)', () async {
      // Omitting cancelToken must work exactly as before (no regression).
      final result = await runStructuredBuild(
        batches: [
          ['a', 'b']
        ],
        call: (turns) async => '{"a":"x","b":"y"}',
        buildTurns: fakeBuild,
        // no cancelToken
      );
      expect(result, {'a': 'x', 'b': 'y'});
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
