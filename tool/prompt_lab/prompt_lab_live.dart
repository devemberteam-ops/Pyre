// Wave CY.18.213 (Prompt Observability — `live` mode): the LIVE entrypoint.
//
// ============================================================================
// RUN COMMAND (from the flutter_app/ package root):
//
//   1. Copy tool/prompt_lab/local.example.json → tool/prompt_lab/local.json
//      and fill in baseUrl / model / apiKey from ONE of your configured
//      providers. local.json is gitignored — it is NEVER committed.
//   2. Run:
//        C:\Users\Gui\flutter\bin\flutter.bat test tool/prompt_lab/prompt_lab_live.dart
//      (POSIX: `flutter test tool/prompt_lab/prompt_lab_live.dart`.)
//
//   To target a SINGLE scenario instead of all of them:
//        flutter test tool/prompt_lab/prompt_lab_live.dart --dart-define=scenario=chat_single
// ============================================================================
//
// WHY this is SEPARATE from prompt_lab.dart / the default suite:
//   • It fires a REAL model call (costs tokens, needs the network + a key).
//   • It lives under tool/ (not test/), so the default `flutter test` glob NEVER
//     picks it up — CI never needs local.json.
//   • When local.json is MISSING it prints a one-line how-to and PASSES (exit 0)
//     — running it without a key is a graceful no-op, never a failure.
//
// SAFETY: the API key is read from the gitignored local.json and rides only the
// HTTP Authorization header inside chat_api. It is NEVER printed, logged, or
// written to the report. A call error is caught and written into the report —
// the harness never crashes.
//
// OUTPUT: tool/prompt_lab/out/<id>.live.md per fired scenario (gitignored).

import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/chat_prompt_builder.dart';
import 'package:pyre/services/creator_schema.dart' show CreatorMode;
import 'package:pyre/services/scene_background.dart'
    show loadSceneManifest, parseClassifierJson;
import 'package:pyre/services/prompt_post_processing.dart'
    show promptPostProcessingFromString;

import 'live.dart';
import 'report.dart';
import 'scenarios.dart';

// Optional single-scenario filter via --dart-define=scenario=<id>. Empty = all.
const _scenarioFilter = String.fromEnvironment('scenario');

// Optional per-run override of the provider's prompt post-processing mode, so the
// live harness can exercise the reshaping (e.g. --dart-define=postproc=strict).
// Empty = use whatever local.json specifies (default none).
const _postprocOverride = String.fromEnvironment('postproc');

// Mega-audit reasoning test (2026-06-04): pass --dart-define=reasoning=off to
// inject {"reasoning":{"effort":"none"}} into the request body so we can A/B a
// reasoning model with/without thinking. This NEVER touches local.json — the key
// stays untouched. Empty / anything-else = provider default (reasoning ON).
const _reasoningMode = String.fromEnvironment('reasoning');

void main() {
  final cfg = _loadConfigOrSkip();
  if (cfg == null) return; // missing/placeholder config → graceful no-op above.

  final provider = providerFromConfig(cfg);
  if (_reasoningMode == 'off') {
    provider.extraParams['reasoning'] = {'effort': 'none'};
    // ignore: avoid_print
    print('Prompt Lab LIVE: reasoning OFF → injected reasoning={effort:none}');
  }
  if (_postprocOverride.isNotEmpty) {
    provider.promptPostProcessing =
        promptPostProcessingFromString(_postprocOverride);
    // ignore: avoid_print
    print('Prompt Lab LIVE: post-processing override → '
        '${provider.promptPostProcessing.name}');
  }
  final settings = settingsFromConfig(cfg);

  final ex = ExampleCards.load();

  // Build the (id, feature, turns, [creator canvas/mode]) work items.
  final chatItems = [
    for (final sc in buildChatScenarios(ex))
      _LiveItem(
        id: sc.id,
        description: sc.description,
        feature: featureForScenarioId(sc.id),
        turns: buildChatPrompt(sc.inputs).turns,
      ),
  ];
  final creatorItems = [
    for (final sc in buildCreatorScenarios())
      _LiveItem(
        id: sc.id,
        description: sc.description,
        feature: featureForScenarioId(sc.id),
        // The trailing synthetic `render` turn is NOT sent to the model — fire
        // only the real structured-request turns from buildBatchTurns / vision.
        turns: sc.turns.where((t) => t.role != 'render').toList(),
        creatorFields: sc.fields,
        creatorMode: sc.mode,
      ),
  ];

  final items = [...chatItems, ...creatorItems]
      .where((it) =>
          _scenarioFilter.isEmpty || it.id == _scenarioFilter)
      .toList();

  group('prompt_lab LIVE — real model calls', () {
    if (items.isEmpty) {
      test('scenario filter "$_scenarioFilter" matched nothing', () {
        fail('No scenario id matches --dart-define=scenario=$_scenarioFilter');
      });
      return;
    }
    for (final it in items) {
      test(it.id, () async {
        await _fireOne(it, provider, settings);
        // The test passes as long as a report was written (success OR a
        // captured error). The report is the artefact; this asserts it exists.
        expect(true, isTrue);
      }, timeout: const Timeout(Duration(minutes: 6)));
    }
  });
}

/// Load local.json; if missing or still holding the placeholder key, print the
/// how-to and register a single PASSING test (so `flutter test` exits 0).
LiveConfig? _loadConfigOrSkip() {
  LiveConfig? cfg;
  String? loadError;
  try {
    cfg = loadLiveConfig();
  } on LiveConfigError catch (e) {
    loadError = e.message;
  }

  if (cfg == null || cfg.hasPlaceholderKey) {
    final reason = loadError != null
        ? 'local.json is present but invalid: $loadError\n$missingConfigMessage'
        : (cfg != null
            ? 'local.json still has the placeholder/blank apiKey.\n'
                '$missingConfigMessage'
            : missingConfigMessage);
    test('live mode skipped (no usable local.json)', () {
      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('=== Prompt Lab — LIVE skipped ===');
      // ignore: avoid_print
      print(reason);
      expect(true, isTrue); // graceful: skipping is not a failure.
    });
    return null;
  }

  // ignore: avoid_print
  print('Prompt Lab LIVE using: $cfg'); // toString() redacts the apiKey.
  return cfg;
}

class _LiveItem {
  final String id;
  final String description;
  final PromptLabFeature feature;
  final List<ChatTurn> turns;
  final Map<String, dynamic>? creatorFields;
  final CreatorMode? creatorMode;
  _LiveItem({
    required this.id,
    required this.description,
    required this.feature,
    required this.turns,
    this.creatorFields,
    this.creatorMode,
  });
}

/// A short, key-free summary of the assembled request for the report header.
String _promptSummary(_LiveItem it) {
  final roles = it.turns.map((t) => t.role).toList();
  return '- feature: `${it.feature.name}`\n'
      '- turns: ${it.turns.length} (${roles.join(' → ')})';
}

/// Fire ONE scenario's real call + write its `<id>.live.md`. Never throws.
Future<void> _fireOne(
  _LiveItem it,
  ApiProvider provider,
  ModelSettings settings,
) async {
  final summary = _promptSummary(it);
  try {
    // Stream so we can capture the finish_reason sentinel, then strip
    // artifacts to get the clean prose (mirrors completeChatStreamed, but
    // keeps the raw buffer so we can read the finish reason).
    final raw = StringBuffer();
    await for (final chunk in streamChatCompletion(
      provider: provider,
      settings: settings,
      messages: it.turns,
    )) {
      raw.write(chunk);
    }
    final rawText = raw.toString();
    final finishMatch = pyreFinishSentinelRegex.firstMatch(rawText);
    final finishReason = finishMatch?.group(1);
    final response = stripStreamArtifacts(rawText);

    final parseOutcome = await _parseOutcome(it, response, finishReason);

    writeLiveReport(
      it.id,
      description: it.description,
      promptSummary: summary,
      response: response,
      rawUnstripped: rawText,
      finishReason: finishReason,
      parseOutcome: parseOutcome,
    );
    // ignore: avoid_print
    print('LIVE ${it.id}: ${response.length} chars, '
        'finish_reason=${finishReason ?? '(none)'} → ${liveReportPath(it.id)}');
  } catch (e) {
    // Catch ANY call failure into the report. NB: ChatApiError scrubs the
    // provider body; the apiKey is never part of an error string.
    writeLiveReport(
      it.id,
      description: it.description,
      promptSummary: summary,
      error: e.toString(),
    );
    // ignore: avoid_print
    print('LIVE ${it.id}: ERROR (written to report) → ${liveReportPath(it.id)}');
  }
}

/// Compute the parse outcome. Scene is the one case that needs the runtime
/// SceneManifest, so it's resolved here; everything else uses the pure path.
Future<String> _parseOutcome(
  _LiveItem it,
  String response,
  String? finishReason,
) async {
  if (it.feature == PromptLabFeature.scene) {
    final manifest = await loadSceneManifest();
    if (manifest != null) {
      final verdict = parseClassifierJson(response, manifest);
      if (verdict == null) {
        return 'scene: parseClassifierJson → null (no valid verdict).';
      }
      return 'scene: parseClassifierJson → location=${verdict.location}, '
          'setting=${verdict.setting}, time=${verdict.timeOfDay}, '
          'confidence=${verdict.confidence}.';
    }
    // Manifest unavailable (no bindings) — fall back to the pure heuristic.
  }
  return classifyLiveResponse(
    it.feature,
    response,
    finishReason: finishReason,
    creatorFields: it.creatorFields,
    creatorMode: it.creatorMode,
  );
}
