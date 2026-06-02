// Wave CY.18.230 (Creator Structured Build, Task 6a): the PURE orchestration
// pipeline that REPLACES the fragile `<<SHEET>>`-marker cascade. PURE Dart — NO
// Flutter UI — so it is unit-testable headless (mirrors creator_render.dart /
// creator_json.dart / creator_build_prompts.dart's pure-fn pattern).
//
// `runStructuredBuild` drives the fixed, deterministic structured build: for
// each batch of field keys it asks the model (via the injected `call`) to return
// that batch as a single JSON object, strips stream artifacts at the seam,
// extracts the JSON object, and merges the parsed fields into one accumulated
// map. There is NO completeness loop — completeness is guaranteed by the batch
// maps (every required field lives in exactly one batch); the renderer skips
// empties and a soft missingRequired note surfaces any absent fields later.
//
// The model `call` and the per-batch `buildTurns` are INJECTED as function
// parameters, so the whole pipeline is fully fake-testable headless: the caller
// bakes the mode into the `buildTurns` closure (e.g. buildBatchTurns(mode:…))
// and passes `batchesFor(mode)` as `batches`, while `call` is a closure over the
// real `completeChatStreamed(extraBody: response_format)`. The plan sketch
// listed a `mode` parameter, but with `batches` + `buildTurns` both injected a
// `mode` would be UNUSED in this pure pipeline — so it is OMITTED to keep the
// function honest (the mode is fully captured by the injected closures).
//
// Truncation is handled by a BOUNDED JSON-continuation: at most 2 extra `call`s
// per batch, stopping early if the model makes no progress (empty chunk), so the
// loop always terminates. A batch that never yields parseable JSON simply leaves
// its keys absent (best-effort).

import 'chat_api.dart' show ChatTurn, stripStreamArtifacts;
import 'creator_build_prompts.dart' show buildContinuationTurns;
import 'creator_json.dart' show extractJsonObject, looksTruncatedJson;

/// Maximum number of EXTRA continuation calls per batch when a response was
/// truncated (on top of the 1 initial call). Bounds the loop so it terminates.
const int _kMaxContinuations = 2;

/// Maximum attempts per batch when a reply comes back EMPTY or unparseable
/// (and NOT merely truncated). Reasoning providers (e.g. DeepSeek-v4-pro)
/// intermittently return an empty content channel — a fresh attempt recovers
/// it. Bounded so the loop always terminates. (A genuine truncation does NOT
/// trigger a whole-batch retry — retrying would just truncate again; the
/// continuation loop handles that case instead.)
const int _kMaxBatchAttempts = 3;

/// Per-batch budget for targeted re-requests of keys that were silently
/// dropped from an otherwise-valid JSON object (FIX #2). Exactly ONE — a
/// missing key gets one focused second chance, then is left absent. Bounds the
/// loop so it can never spin.
const int _kMissingKeyReRequests = 1;

/// True when a parsed field value is absent or empty (string/list/map). Used to
/// detect keys that a valid-but-PARTIAL JSON object silently dropped.
bool _isEmpty(dynamic v) {
  if (v == null) return true;
  if (v is String) return v.trim().isEmpty;
  if (v is List) return v.isEmpty;
  if (v is Map) return v.isEmpty;
  return false;
}

/// Run the fixed, deterministic structured build: for each batch of field keys,
/// ask the model (via [call]) to return that batch as a JSON object, then merge
/// the parsed fields into one accumulated map. There is NO completeness loop —
/// completeness is guaranteed by the batch maps (every required field is in
/// exactly one batch). Best-effort: a batch that never yields parseable JSON
/// simply leaves its keys absent (the renderer skips empties + a soft
/// missingRequired note surfaces them later).
///
/// [batches]    — the per-mode batch groupings (each inner list = one batch's keys).
/// [buildTurns] — builds the request turns for a batch's keys, given the facts
///                DECIDED SO FAR (FIX #3 carry-forward: everything parsed from
///                earlier batches, empty for the first). A closure over
///                buildBatchTurns(mode:…, transcript:…, priorFields:…).
///                Injected for testability.
/// [call]       — runs the model on a turn list and returns the full reply text
///                (e.g. a closure over completeChatStreamed(extraBody: response_format)).
///                Injected for testability.
Future<Map<String, dynamic>> runStructuredBuild({
  required List<List<String>> batches,
  required Future<String> Function(List<ChatTurn> turns) call,
  required List<ChatTurn> Function(
          List<String> batchKeys, Map<String, dynamic> decidedSoFar)
      buildTurns,
  Duration retryDelay = Duration.zero,
}) async {
  final fields = <String, dynamic>{};
  for (final batchKeys in batches) {
    // FIX #3 carry-forward: every batch sees the facts decided by earlier
    // batches so it can stay consistent with them. A copy so the closure can't
    // mutate the live accumulator mid-batch.
    final decidedSoFar = Map<String, dynamic>.from(fields);
    final turns = buildTurns(batchKeys, decidedSoFar);
    final parsed = await _runBatch(turns, call, retryDelay);
    if (parsed != null) fields.addAll(parsed); // merge; absent on permanent fail

    // FIX #2 re-request missing: a valid-but-PARTIAL object can silently drop
    // requested keys (the real Clothing/Intimate Details/General Appearance
    // bug). After merging, compute the requested keys STILL empty/absent and do
    // ONE targeted re-request for just those — bounded, never loops.
    if (parsed != null) {
      final missing = batchKeys.where((k) => _isEmpty(fields[k])).toList();
      if (missing.isNotEmpty) {
        for (var r = 0; r < _kMissingKeyReRequests; r++) {
          final reTurns = buildTurns(missing, Map<String, dynamic>.from(fields));
          final reParsed = await _runBatch(reTurns, call, retryDelay);
          if (reParsed != null) {
            // Only fill keys still missing — never clobber a present value.
            for (final entry in reParsed.entries) {
              if (_isEmpty(fields[entry.key]) && !_isEmpty(entry.value)) {
                fields[entry.key] = entry.value;
              }
            }
          }
          // Stop early once everything's filled.
          if (batchKeys.every((k) => !_isEmpty(fields[k]))) break;
        }
      }
    }
  }
  return fields;
}

/// Run ONE batch request: strip artifacts, parse the JSON object, and handle a
/// bounded truncation-continuation + an empty/garbage whole-batch retry.
/// Returns the parsed object, or null on permanent failure.
Future<Map<String, dynamic>?> _runBatch(
  List<ChatTurn> turns,
  Future<String> Function(List<ChatTurn> turns) call,
  Duration retryDelay,
) async {
  Map<String, dynamic>? parsed;
  // Outer retry: an EMPTY / unparseable (non-truncated) reply gets a fresh
  // attempt — reasoning providers intermittently return empty content (often
  // a transient rate-limit). [retryDelay] backs off between attempts so a
  // throttle can recover; it defaults to zero (tests stay instant).
  for (var attempt = 0; attempt < _kMaxBatchAttempts; attempt++) {
    if (attempt > 0 && retryDelay > Duration.zero) {
      await Future.delayed(retryDelay);
    }
    var raw = stripStreamArtifacts(await call(turns)); // strip <think>/sentinels
    parsed = extractJsonObject(raw);
    // Bounded JSON-continuation on truncation: at most _kMaxContinuations
    // extra calls within this attempt.
    var tries = 0;
    while (parsed == null &&
        looksTruncatedJson(raw) &&
        tries < _kMaxContinuations) {
      tries++;
      final contTurns = buildContinuationTurns(priorTurns: turns, partial: raw);
      final more = stripStreamArtifacts(await call(contTurns));
      if (more.isEmpty) break; // no progress → stop the continuation
      raw += more; // concat the partial + continuation
      parsed = extractJsonObject(raw); // re-parse the stitched text
    }
    if (parsed != null) return parsed; // got a valid object → done
    // A genuine truncation we couldn't complete won't improve on retry
    // (it would just truncate again) → stop. Only an empty/garbage reply
    // (nothing to continue) is worth a fresh whole-batch attempt.
    if (looksTruncatedJson(raw)) break;
  }
  return parsed;
}
