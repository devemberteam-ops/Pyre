// Wave CY.18.211 (Prompt Observability — `inspect` harness): the ENTRYPOINT.
//
// ============================================================================
// RUN COMMAND (from the flutter_app/ package root):
//
//   C:\Users\Gui\flutter\bin\flutter.bat test tool/prompt_lab/prompt_lab.dart
//
// (POSIX: `flutter test tool/prompt_lab/prompt_lab.dart`.)
// ============================================================================
//
// WHY the test runner: the harness is written as `flutter_test` `test(...)`
// cases so it runs through `flutter test` (gives a clean pass/fail + isolate
// without needing a Flutter app). It loads the bundled example cards off disk
// via `dart:io` (NOT `rootBundle`), so it does NOT need Flutter test bindings
// — a plain `dart run` would also work — and it NEVER calls a model: it only
// assembles the prompt via the pure builders in `chat_prompt_builder.dart`.
//
// This file lives under `tool/` (not `test/`), so the default `flutter test`
// (which only globs `test/`) does NOT pick it up — it has to be invoked
// explicitly. That keeps the normal suite fast and free of generated-file
// side effects while still letting CI / contributors run the harness as a
// real, asserted test on demand.
//
// OUTPUT: `tool/prompt_lab/out/<id>.md` + `<id>.request.json` per scenario
// (gitignored). A summary table (id → ~tokens, segment/turn count) is printed.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

import 'report.dart';
import 'scenarios.dart';

void main() {
  // Build the example cards once for the whole run.
  final ex = ExampleCards.load();

  final summaries = <ReportSummary>[];

  group('prompt_lab inspect — chat scenarios', () {
    for (final sc in buildChatScenarios(ex)) {
      test(sc.id, () {
        final result = buildChatPromptResult(sc);
        final summary = writeChatReport(sc.id, sc.description, result);
        summaries.add(summary);

        // The report must be real: non-empty turns + at least one labeled
        // segment + a written markdown file with content.
        expect(result.turns, isNotEmpty,
            reason: '${sc.id}: assembled turns should not be empty');
        expect(result.segments, isNotEmpty,
            reason: '${sc.id}: should produce labeled segments');
        expect(summary.totalTokens, greaterThan(0),
            reason: '${sc.id}: total token estimate should be > 0');
      });
    }
  });

  group('prompt_lab inspect — creator scenarios', () {
    for (final sc in buildCreatorScenarios()) {
      test(sc.id, () {
        final summary = writeCreatorReport(sc.id, sc.description, sc.turns);
        summaries.add(summary);

        expect(sc.turns, isNotEmpty,
            reason: '${sc.id}: creator turns should not be empty');
        // A creator request is always at least a system turn.
        expect(sc.turns.first.role, 'system',
            reason: '${sc.id}: first turn should be the system/architect turn');
        expect(summary.totalTokens, greaterThan(0),
            reason: '${sc.id}: total token estimate should be > 0');
      });
    }
  });

  // Printed once after all scenarios run. Using tearDownAll keeps it after
  // the individual test lines so the table is easy to find in the output.
  tearDownAll(() {
    summaries.sort((a, b) => a.id.compareTo(b.id));
    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print('=== Prompt Lab — inspect summary ===');
    // ignore: avoid_print
    print('scenario                 ~tokens   segs/turns');
    // ignore: avoid_print
    print('------------------------ --------- ----------');
    for (final s in summaries) {
      final id = s.id.padRight(24);
      final tok = '~${s.totalTokens}'.padLeft(8);
      // ignore: avoid_print
      print('$id $tok   ${s.segmentOrTurnCount}');
    }
    // ignore: avoid_print
    print('Reports written to: $outDir/<id>.md + <id>.request.json');
  });
}

/// Tiny seam so the test body reads cleanly: assemble the chat scenario via
/// the pure builder. Kept here (not in scenarios.dart) so scenarios.dart
/// stays a pure fixture file.
ChatPromptResult buildChatPromptResult(ChatScenario sc) =>
    buildChatPrompt(sc.inputs);
