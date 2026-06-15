// Wave CY.18.XX (Lorebook Creator, Wave 1 foundation): pure orchestration for
// building a single LoreEntry from a [[BUILD_ENTRY]] trigger.
//
// PURE Dart — NO Flutter imports — unit-testable headless (the model `call`
// is injected, so the whole pipeline runs with a fake in tests).
//
// Flow:
//   1. Build the turn list (system + conversation history, caller-supplied).
//   2. ONE model call via `call`.
//   3. Strip reasoning channel (<think>…</think>) and recover JSON from it
//      when the normal content channel carries none (HIGH 5 / extractJsonAfterReasoning).
//   4. extractJsonObject on the result.
//   5. If the JSON looks truncated, make ONE bounded continuation call and
//      re-extract from the concatenated result.
//   6. Map to LoreEntry via entryJsonToLoreEntry.
//   7. Return null on any unrecoverable failure (best-effort, never throws).
//
// Bounded: max 1 continuation → always terminates.

import 'chat_api.dart' show ChatTurn;
import 'creator_json.dart'
    show extractJsonAfterReasoning, looksTruncatedJson;
import 'lorebook_entry_schema.dart' show entryJsonToLoreEntry;
import '../models/models.dart' show LoreEntry;

// ── Public API ────────────────────────────────────────────────────────────────

/// Build a single [LoreEntry] from a completed architect conversation.
///
/// [turns] is the full conversation up to (and including) the architect's
/// last message that contained the [[BUILD_ENTRY]] marker (or a synthesised
/// build-trigger turn). The caller is responsible for stripping the marker
/// text from the display and for constructing the right turn list; this
/// function only cares about extracting the JSON object from the model's
/// current reply.
///
/// [call] is an injected `Future<String> Function(List<ChatTurn>)` that
/// issues a single LLM request and returns the plain-text content channel
/// response (reasoning already stripped by the provider layer, OR still
/// wrapped in `<think>…</think>` — both are handled here).
///
/// Returns the parsed [LoreEntry], or null if no parseable JSON object could
/// be recovered after the bounded continuation.
Future<LoreEntry?> draftLoreEntry({
  required List<ChatTurn> turns,
  required Future<String> Function(List<ChatTurn>) call,
}) async {
  // ── Initial call ──────────────────────────────────────────────────────────
  final String raw;
  try {
    raw = await call(turns);
  } catch (_) {
    return null; // network / provider error — caller can surface it
  }

  // ── Attempt 1: extract JSON from the initial reply ─────────────────────
  final Map<String, dynamic>? parsed = _extractFromRaw(raw);
  if (parsed != null) return entryJsonToLoreEntry(parsed);

  // ── Truncation check: bounded continuation (max 1) ─────────────────────
  if (!looksTruncatedJson(raw)) {
    // Not truncated — just unparseable (garbage, refusal, etc.). Give up.
    return null;
  }

  // Build continuation turns: append the partial as an assistant turn +
  // a user turn asking the model to resume exactly where it left off.
  final continuationTurns = [
    ...turns,
    ChatTurn(_kAssistant, raw),
    ChatTurn(_kUser, _kContinuationPrompt),
  ];

  final String continuationRaw;
  try {
    continuationRaw = await call(continuationTurns);
  } catch (_) {
    return null;
  }

  // Stitch the partial + continuation and re-extract.
  final stitched = '$raw$continuationRaw';
  final Map<String, dynamic>? stitchedParsed = _extractFromRaw(stitched);
  if (stitchedParsed != null) return entryJsonToLoreEntry(stitchedParsed);

  // Try the continuation chunk alone (in case the model re-emitted the full
  // object rather than resuming mid-stream — common with some providers).
  final Map<String, dynamic>? continuationOnly = _extractFromRaw(continuationRaw);
  if (continuationOnly != null) return entryJsonToLoreEntry(continuationOnly);

  // Nothing parseable after one continuation → best-effort null.
  return null;
}

// ── Internal ──────────────────────────────────────────────────────────────────

/// OpenAI-style role constants. Kept private — callers use ChatTurn directly.
const String _kAssistant = 'assistant';
const String _kUser = 'user';

/// The continuation prompt sent after a truncated partial JSON. Mirrors the
/// pattern used by the character Creator's continuation loop.
const String _kContinuationPrompt =
    'Continue EXACTLY where you left off — resume the JSON mid-token if needed. '
    'Do NOT repeat what you already wrote, add preamble, or start over.';

/// Try to extract a JSON object from [raw], handling both reasoning-model
/// replies (with `<think>…</think>`) and plain-content replies. Returns null
/// when nothing parseable is found.
///
/// Strategy (HIGH 5 / extractJsonAfterReasoning):
///   1. Look for an object AFTER the last `</think>` tag (the model's post-
///      reasoning answer, the one we want).
///   2. Fall back to scanning the whole buffer (handles models that put the
///      JSON inside the reasoning channel, or non-reasoning models).
Map<String, dynamic>? _extractFromRaw(String raw) {
  return extractJsonAfterReasoning(raw);
}
