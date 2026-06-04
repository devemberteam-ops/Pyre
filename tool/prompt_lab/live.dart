// Wave CY.18.213 (Prompt Observability — `live` mode): the LIVE-CALL plumbing
// for the prompt-lab harness.
//
// This file holds everything the live entrypoint (`prompt_lab_live.dart`) needs
// that is ALSO unit-testable WITHOUT a network or a real `local.json`:
//
//   • [LiveConfig] + [parseLiveConfig] — parse a `local.json`-shaped string into
//     a typed config; throws [LiveConfigError] on anything malformed.
//   • [loadLiveConfig] — read `tool/prompt_lab/local.json` off disk and parse
//     it, returning `null` when the file is MISSING (the graceful opt-in path)
//     and re-throwing [LiveConfigError] only when a present file is invalid.
//   • [providerFromConfig] / [settingsFromConfig] — build the `chat_api` inputs.
//   • [PromptLabFeature] + [featureForScenarioId] — which parser interprets the
//     model's reply for a given scenario.
//   • [classifyLiveResponse] — PURE: given a feature + the raw response text
//     (+ optional finish_reason), produce a human-readable "parse outcome" line
//     for the report. Tested on CANNED responses (no model).
//
// SAFETY (load-bearing): the API key NEVER appears in any string this module
// produces — not in the parse outcome, not in [LiveConfig.toString], not in any
// log. The key only ever rides the HTTP `Authorization` header inside `chat_api`.

import 'dart:convert';
import 'dart:io';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/memory.dart' show recapLooksComplete;
import 'package:pyre/services/live_sheet.dart' show parseLiveSheetDelta;
import 'package:pyre/services/creator_render.dart'
    show renderCard, missingRequired;
import 'package:pyre/services/creator_schema.dart' show CreatorMode;

/// Path to the gitignored live-mode config, relative to the package root.
const localConfigPath = 'tool/prompt_lab/local.json';

/// Path to the committed example the user copies from.
const exampleConfigPath = 'tool/prompt_lab/local.example.json';

/// One-line, copy-pasteable instruction printed when [loadLiveConfig] finds no
/// `local.json`. Shared so the entrypoint + tests assert the SAME message.
const missingConfigMessage =
    'Live mode is off: create $localConfigPath from $exampleConfigPath '
    '(fill in baseUrl/model/apiKey from one of your configured providers). '
    'It is gitignored and never committed.';

/// Raised when a PRESENT `local.json` (or an inline string) can't be parsed
/// into a usable config. A MISSING file is NOT an error (see [loadLiveConfig]).
class LiveConfigError implements Exception {
  final String message;
  const LiveConfigError(this.message);
  @override
  String toString() => 'LiveConfigError: $message';
}

/// Typed view of `local.json`. Holds the API key but DELIBERATELY excludes it
/// from [toString] so it can never leak into a debug print of the config.
class LiveConfig {
  final String baseUrl;
  final String model;
  final String apiKey;
  final Map<String, dynamic> extraParams;
  final ProviderKind kind;

  const LiveConfig({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    this.extraParams = const {},
    this.kind = ProviderKind.external_,
  });

  /// True when the file still carries the example placeholder (the user copied
  /// it but didn't fill the key). Treated as "not configured" so we don't fire
  /// a doomed call with a literal placeholder bearer token.
  bool get hasPlaceholderKey => apiKey == 'PUT-YOUR-KEY-HERE' || apiKey.isEmpty;

  /// NEVER includes the apiKey. Safe to print.
  @override
  String toString() =>
      'LiveConfig(baseUrl: $baseUrl, model: $model, kind: ${kind.name}, '
      'extraParams: ${extraParams.keys.toList()}, apiKey: <redacted>)';
}

ProviderKind _kindFromString(Object? raw) {
  switch (raw) {
    case 'localhost':
      return ProviderKind.localhost;
    case 'proxy':
      return ProviderKind.proxy;
    default:
      return ProviderKind.external_;
  }
}

/// PURE parse of a `local.json`-shaped JSON string. Ignores any `//`-prefixed
/// comment keys (the example file documents itself with them). Throws
/// [LiveConfigError] on invalid JSON or a missing/blank `baseUrl`/`model`.
LiveConfig parseLiveConfig(String jsonText) {
  Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } catch (e) {
    throw LiveConfigError('not valid JSON ($e)');
  }
  if (decoded is! Map) {
    throw const LiveConfigError('top level must be a JSON object');
  }
  final m = decoded.cast<String, dynamic>();

  final baseUrl = (m['baseUrl'] as String?)?.trim() ?? '';
  final model = (m['model'] as String?)?.trim() ?? '';
  if (baseUrl.isEmpty) {
    throw const LiveConfigError('"baseUrl" is required (and must be non-empty)');
  }
  if (model.isEmpty) {
    throw const LiveConfigError('"model" is required (and must be non-empty)');
  }

  final extra = m['extraParams'];
  final Map<String, dynamic> extraParams =
      extra is Map ? extra.cast<String, dynamic>() : const {};

  return LiveConfig(
    baseUrl: baseUrl,
    model: model,
    apiKey: (m['apiKey'] as String?) ?? '',
    extraParams: extraParams,
    kind: _kindFromString(m['kind']),
  );
}

/// Read + parse `tool/prompt_lab/local.json`.
///
///   • file missing            → returns `null` (the graceful opt-in path).
///   • file present but invalid → throws [LiveConfigError] (so the entrypoint
///     can report it instead of firing a doomed call).
LiveConfig? loadLiveConfig({String path = localConfigPath}) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return parseLiveConfig(file.readAsStringSync());
}

/// Build the `chat_api` provider from a [LiveConfig]. Synthetic id/name — this
/// provider is never persisted; it exists only for the duration of the call.
ApiProvider providerFromConfig(LiveConfig cfg) => ApiProvider(
      id: 'prompt-lab-live',
      name: 'Prompt Lab (live)',
      kind: cfg.kind,
      baseUrl: cfg.baseUrl,
      apiKey: cfg.apiKey,
      model: cfg.model,
      extraParams: Map<String, dynamic>.from(cfg.extraParams),
    );

/// Default sampling for live calls. The harness observes assembly + parsing,
/// not output tuning — but the app default `maxTokens` (1024) is too tight for
/// REASONING models (Qwen 3.x, etc.): they spend the whole budget in the
/// reasoning channel and return 0 chars of prose with finish_reason=length.
/// We give a generous headroom so reasoning can finish AND a real reply lands,
/// which is what the live test needs to observe. (Test-harness only — never
/// ships; the app uses the user's own preset/settings token limits.)
ModelSettings settingsFromConfig(LiveConfig cfg) =>
    ModelSettings(maxTokens: 4000);

// ---------------------------------------------------------------------------
// Feature classification + parse outcome (PURE — the unit-tested core)
// ---------------------------------------------------------------------------

/// Which Pyre feature a scenario exercises — selects the parser that interprets
/// the model's reply in the live report.
enum PromptLabFeature {
  /// Free chat / group chat. No structured parse — the reply IS the output.
  chat,

  /// Creator structured build: expect a single JSON object for the batch.
  /// "Complete" is gauged by the deterministic renderer — a non-empty rendered
  /// Description over the fixture field map + `missingRequired` being empty.
  creator,

  /// Creator vision: image-analysis reply. No structured parse; raw only.
  vision,

  /// Long-term memory recap: judged by `recapLooksComplete`.
  ltm,

  /// Live Sheet delta: judged by `parseLiveSheetDelta`.
  liveSheet,

  /// Scene classifier: judged by `parseClassifierJson` (handled in the
  /// entrypoint, which holds the SceneManifest — see [classifyLiveResponse]).
  scene,
}

/// Map a scenario id (the stable ids in `scenarios.dart`) to its feature.
/// Defaults to [PromptLabFeature.chat] for anything unrecognised so a new
/// chat-shaped scenario "just works" without a code change here.
PromptLabFeature featureForScenarioId(String id) {
  if (id == 'creator_vision') return PromptLabFeature.vision;
  if (id.startsWith('creator_')) return PromptLabFeature.creator;
  if (id.startsWith('ltm')) return PromptLabFeature.ltm;
  if (id.startsWith('livesheet') || id.startsWith('live_sheet')) {
    return PromptLabFeature.liveSheet;
  }
  if (id.startsWith('scene')) return PromptLabFeature.scene;
  return PromptLabFeature.chat; // chat_single, chat_group, …
}

/// PURE: produce the human-readable "parse outcome" line(s) for a live reply.
///
/// [feature]      — which parser to run.
/// [response]     — the RAW model reply (already stripped of Pyre sentinels by
///                  the caller; the apiKey is NEVER part of this).
/// [finishReason] — the captured finish_reason ('stop' | 'length' | …) or null.
/// [creatorFields] — for [PromptLabFeature.creator], the fixture field map the
///                  structured build renders, so the deterministic renderer has
///                  something to judge. Optional; when null only the JSON-object
///                  shape of the reply is reported.
/// [creatorMode]  — the Creator mode for `renderCard` / `missingRequired`.
///
/// Note: [PromptLabFeature.scene] returns a placeholder here because the real
/// `parseClassifierJson` needs a `SceneManifest`; the entrypoint runs that and
/// can override this line. The pure function still classifies the OTHER cases
/// so they're unit-testable without any Flutter binding.
String classifyLiveResponse(
  PromptLabFeature feature,
  String response, {
  String? finishReason,
  Map<String, dynamic>? creatorFields,
  CreatorMode? creatorMode,
}) {
  final trimmed = response.trim();
  final empty = trimmed.isEmpty;

  switch (feature) {
    case PromptLabFeature.chat:
      if (empty) return 'chat: EMPTY reply (no content returned).';
      final truncated = finishReason == 'length';
      return 'chat: non-empty reply (${trimmed.length} chars)'
          '${truncated ? ' — finish_reason=length (truncated by max_tokens)' : ''}.';

    case PromptLabFeature.vision:
      if (empty) return 'vision: EMPTY reply (no profile returned).';
      return 'vision: non-empty profile (${trimmed.length} chars). No '
          'structured parse — review the raw text for reasoning leaks/truncation.';

    case PromptLabFeature.creator:
      // Structured build: the reply should be ONE JSON object for the batch.
      final looksLikeJsonObject =
          trimmed.startsWith('{') && trimmed.contains('}');
      final parts = <String>[
        'creator: reply ${empty ? 'is EMPTY' : (looksLikeJsonObject ? 'looks like a JSON object' : 'is NOT a bare JSON object')}',
      ];
      if (creatorFields != null && creatorMode != null) {
        // The deterministic renderer is the completeness signal for the
        // structured build: a non-empty rendered Description + no missing
        // required fields over the fixture field map.
        final rendered = renderCard(creatorFields, creatorMode);
        final descNonEmpty =
            (rendered['description'] as String? ?? '').trim().isNotEmpty;
        final missing = missingRequired(creatorFields, creatorMode);
        final complete = descNonEmpty && missing.isEmpty;
        parts.add('renderCard(${creatorMode.name}) over the fixture fields → '
            'Description ${descNonEmpty ? 'non-empty' : 'EMPTY'}, '
            'missingRequired=${missing.isEmpty ? 'none' : missing.join('/')} '
            '→ complete=$complete');
      }
      if (finishReason == 'length') {
        parts.add('finish_reason=length (the JSON was likely truncated)');
      }
      return '${parts.join('; ')}.';

    case PromptLabFeature.ltm:
      if (empty) return 'ltm: EMPTY recap (nothing to judge).';
      final complete = recapLooksComplete(response);
      return 'ltm: recapLooksComplete = $complete'
          '${finishReason == 'length' ? ' — finish_reason=length (truncated)' : ''} '
          '(${trimmed.length} chars).';

    case PromptLabFeature.liveSheet:
      if (empty) return 'liveSheet: EMPTY reply (no delta).';
      final delta = parseLiveSheetDelta(response);
      if (delta.noChange) return 'liveSheet: parsed NO_CHANGE.';
      return 'liveSheet: parsed ${delta.ops.length} delta op(s).';

    case PromptLabFeature.scene:
      // The real classify needs a SceneManifest (loaded in the entrypoint).
      // This branch is a fallback for the pure path / tests.
      if (empty) return 'scene: EMPTY reply (no JSON to classify).';
      final looksLikeJson =
          trimmed.contains('{') && trimmed.contains('}');
      return 'scene: reply ${looksLikeJson ? 'contains' : 'has NO'} a JSON '
          'object (full classify runs in the entrypoint with the manifest).';
  }
}
