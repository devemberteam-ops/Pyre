// Wave CY.18.212 (Prompt Observability — golden snapshots): the REGRESSION
// NET that makes prompt changes reviewable in a PR.
//
// For each of the 6 prompt-lab scenarios (2 chat + 4 Creator) this test:
//   1. re-assembles the prompt LIVE via the pure builders in
//      `chat_prompt_builder.dart` (driven by the shared fixtures in
//      `tool/prompt_lab/scenarios.dart`),
//   2. serializes it to a STABLE text form (`goldenTextForChat` /
//      `goldenTextForCreator` in `tool/prompt_lab/report.dart` — no token
//      counts, no timestamps, no `{{random:}}` churn), and
//   3. compares it to the committed golden in `test/goldens/prompt_lab/<id>.txt`.
//
// On mismatch the test FAILS with the exact regen command. When a prompt
// change is INTENTIONAL, set `PYRE_UPDATE_GOLDENS=1` and the test REWRITES the
// golden instead of asserting:
//
//   PYRE_UPDATE_GOLDENS=1 flutter test test/prompt_lab_golden_test.dart
//
// (PowerShell: `$env:PYRE_UPDATE_GOLDENS=1; flutter test test/prompt_lab_golden_test.dart`)
//
// This test runs in the DEFAULT `flutter test` suite (it lives under `test/`),
// so it is the always-on guard. It reads the example cards off disk via the
// fixtures' own `dart:io` loader (no test-asset bundle / no Flutter bindings),
// matching `chat_prompt_builder_test.dart` / `example_seed_test.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

import '../tool/prompt_lab/report.dart';
import '../tool/prompt_lab/scenarios.dart';

/// Directory holding the committed goldens (relative to the package root,
/// which is the cwd under `flutter test`).
const _goldenDir = 'test/goldens/prompt_lab';

/// Honour the regen flag from the environment. `flutter test` forwards the
/// process environment to the test isolate, so `PYRE_UPDATE_GOLDENS=1` (any
/// non-empty, non-"0"/"false" value) flips this on.
bool get _updateGoldens {
  final v = Platform.environment['PYRE_UPDATE_GOLDENS']?.trim().toLowerCase();
  return v != null && v.isNotEmpty && v != '0' && v != 'false';
}

File _goldenFile(String id) => File('$_goldenDir/$id.txt');

void main() {
  // Build the example cards + scenarios once for the whole run (binding-free
  // disk reads via the fixtures).
  final ex = ExampleCards.load();

  /// Re-derive the (id → golden text) pairs LIVE. Chat scenarios go through
  /// `buildChatPrompt`; Creator scenarios use their eagerly-built turns.
  final entries = <MapEntry<String, String>>[
    for (final sc in buildChatScenarios(ex))
      MapEntry(sc.id, goldenTextForChat(buildChatPrompt(sc.inputs))),
    for (final sc in buildCreatorScenarios())
      MapEntry(sc.id, goldenTextForCreator(sc.turns)),
  ];

  // Regen path: rewrite every golden, then a single pass-through assert so the
  // run still reports green. Done in setUpAll so it happens before the
  // per-scenario tests read the (now-fresh) files.
  setUpAll(() {
    if (!_updateGoldens) return;
    Directory(_goldenDir).createSync(recursive: true);
    for (final e in entries) {
      _goldenFile(e.key).writeAsStringSync(e.value);
    }
    // ignore: avoid_print
    print('PYRE_UPDATE_GOLDENS set — rewrote ${entries.length} goldens in '
        '$_goldenDir/');
  });

  group('prompt_lab goldens', () {
    for (final e in entries) {
      final id = e.key;
      final actual = e.value;
      test(id, () {
        final file = _goldenFile(id);

        if (_updateGoldens) {
          // setUpAll already wrote it — just confirm round-trip + non-empty.
          expect(file.existsSync(), isTrue,
              reason: 'golden $id should exist after regen');
          expect(file.readAsStringSync(), actual);
          return;
        }

        expect(
          file.existsSync(),
          isTrue,
          reason:
              'Missing golden for "$id" ($_goldenDir/$id.txt). Generate it '
              'with: PYRE_UPDATE_GOLDENS=1 flutter test '
              'test/prompt_lab_golden_test.dart',
        );

        final golden = file.readAsStringSync();
        expect(
          actual,
          golden,
          reason: 'Prompt assembly changed for "$id". If intentional, '
              'regenerate with: PYRE_UPDATE_GOLDENS=1 flutter test '
              'test/prompt_lab_golden_test.dart',
        );
      });
    }
  });

  // Sanity: the registry must produce exactly the 6 expected scenario ids, so
  // a dropped/renamed scenario is caught here (not silently un-golden-ed).
  // Wave CY.18.233: the old marker-cascade edit + review-pass scenarios were
  // removed when the structured-JSON build replaced them.
  test('all 6 scenarios are covered', () {
    final ids = entries.map((e) => e.key).toSet();
    expect(ids, {
      'chat_single',
      'chat_group',
      'creator_character',
      'creator_scenario',
      'creator_persona',
      'creator_vision',
    });
    expect(entries.length, 6);
  });
}
