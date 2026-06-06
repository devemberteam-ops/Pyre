// Long-term memory: branch-aware checkpoint chain.
//
// Wave CY.18: replaces the single-summary string with a list of
// [MemoryCheckpoint]s tagged by the BRANCH they were taken on. Each
// checkpoint covers a fixed slice of conversation; multiple checkpoints
// concatenated together form the running recap. When the user re-rolls
// or branches off a past message, checkpoints whose anchor sits at or
// past the divergence point become INVALID for the new branch — their
// pathHash no longer prefixes the current branch's path — but they
// remain on disk so the original branch keeps its memory intact when
// the user navigates back via the chat tree.
//
// Lifecycle:
//   - shouldSummarize(chat) — true once the chat has accumulated enough
//     uncovered messages past the last VALID checkpoint for the current
//     branch.
//   - generateCheckpoint(chat, ...) — runs the LLM with the last valid
//     checkpoints as context + the delta since the last anchor; returns
//     a fresh MemoryCheckpoint with a pathHash fingerprinting the
//     current branch up to its new anchor.
//   - regenerateCheckpoint(chat, target, ...) — re-runs the same delta
//     range as `target` but with a fresh LLM call. Used by the "Retry"
//     button on each checkpoint in the Memory screen.
//   - findValidCheckpoints(chat) — returns the checkpoints whose
//     pathHash matches the current branch's prefix (or empty-hash
//     legacy sentinels), sorted by anchor index. This is what the
//     chat builder injects into the system prompt and what the UI
//     shows as anchor dividers in the message list.
//
// pathHash semantics: deterministic concatenation of
//   `<message.id>:<selectedVariant>|`
// for each message from index 0 up to (and inclusive of) the anchor.
// Two branches share a hash prefix iff they share the same sequence of
// variant choices. The empty string is a sentinel for legacy migrated
// checkpoints and is always treated as valid.

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../models/models.dart';
import 'chat_api.dart';
import 'llm_debug_log.dart';

/// Wave CY.18.42: in-memory error log for memory-system failures.
/// Pre-Wave the LLM-summariser calls swallowed every error with
/// `catch (_)` and returned null — which the UI rendered as "no
/// checkpoint produced", indistinguishable from "nothing to
/// summarise". Now every failure is recorded so the Memory screen
/// (or a snackbar) can surface "auto-summarise failed: <provider
/// 401 / timeout / parse-error>", and the user can fix the root
/// cause instead of wondering why memory stopped advancing.
///
/// Capped at 20 entries (newest first). Cleared by the UI after
/// the user has acknowledged via [clear].
class MemoryErrors {
  MemoryErrors._();
  static final List<String> log = [];
  static const int _max = 20;

  static void record(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[Memory] $msg');
    log.insert(0, msg);
    if (log.length > _max) {
      log.removeRange(_max, log.length);
    }
  }

  static void clear() => log.clear();
}

/// Minimum uncovered messages past the last valid anchor before the
/// auto-summariser fires. Used as the fallback when no
/// [MemorySettings.autoEvery] is provided. The trigger is honest:
/// "every N messages" really means every N messages — when N new
/// messages have accumulated past the last checkpoint, the next
/// checkpoint folds ALL of them in (cutoff = length - 1) and the
/// anchor advances to that point. No silent "keep N recent verbatim"
/// buffer that would push the real fire to N+buffer.
const int _summarizeThreshold = 20;

/// Cap on how many valid checkpoints we feed back into the LLM as
/// context when generating a fresh one, and how many we inject into
/// the chat's system prompt. Keeps prompt size bounded on long chats.
const int kMaxCheckpointsInPrompt = 5;

/// Cap on how many checkpoints we RETAIN per chat. Each is a full narrative
/// summary blob; the append-only chain grows without bound on long chats and
/// serializes on every persist, sync and backup. Bound it going forward: keep
/// the most-recent [_kMaxRetainedCheckpoints] (by append order) — far more than
/// the [kMaxCheckpointsInPrompt] / [kRecapCharBudget] the runtime ever reads,
/// so the visible recap is unaffected; we only shed ancient history blobs.
const int _kMaxRetainedCheckpoints = 60;

/// Wave CY.18.220: soft character budget for the recap block injected into the
/// chat system prompt every turn. Recaps are narrative (~600-750 words ≈
/// ~4000 chars each); with several checkpoints the standing cost grows large.
/// We keep the NEWEST checkpoint(s) whole and trim the OLDEST first (oldest
/// content is established backstory that later messages already reinforce).
/// Generous enough that a single big recap always survives intact (the newest
/// checkpoint is never cut, even if it alone exceeds the budget).
const int kRecapCharBudget = 9000;

/// How many of the most-recent checkpoints are ALWAYS kept whole, regardless
/// of the budget. The latest turn-to-turn continuity matters most.
const int _kRecapAlwaysWholeNewest = 2;

/// Maximum number of EXTRA continuation calls after the first recap
/// response. Each call appends the accumulated text as an assistant
/// turn and asks the model to continue the recap — used when the
/// response looks truncated (does not end in sentence-final
/// punctuation). Kept deliberately small (≤2) so the loop always
/// terminates quickly and never spams the provider.
const int _kRecapMaxContinuations = 2;

/// Prompt appended as a user turn to continue a truncated recap.
/// Explicit "recap, not roleplay" framing mirrors the system prompt's
/// anti-continuation block so a model that re-reads the turn history
/// stays on task.
const String _kRecapContinuePrompt =
    'Continue the recap from where you left off. '
    'Do not repeat anything, no preamble, and keep summarising — '
    'do not start writing new story.';

/// Deterministic branch fingerprint over the messages from index 0 up
/// to and including [upToIdx]. The fingerprint encodes the SEQUENCE of
/// variant choices that landed us on this branch — two branches share
/// a prefix iff they share the same path through the variant tree up
/// to that point.
String computePathHash(List<Message> messages, int upToIdx) {
  // Wave CY.18.24: hard-guard against the empty-messages collision
  // with the legacy "no-path" sentinel. An empty chat or an upToIdx
  // < 0 used to return `""` — indistinguishable from the migration
  // sentinel applied to pre-Wave-CY.18 chats where every checkpoint
  // had `pathHash = ""` (always-valid). Callers can't tell those
  // apart. Return a deterministic non-empty value for the empty
  // case so the sentinel meaning stays unique.
  if (upToIdx < 0 || messages.isEmpty) return '__empty__';
  final last = upToIdx.clamp(0, messages.length - 1);
  final buf = StringBuffer();
  for (var i = 0; i <= last; i++) {
    final m = messages[i];
    buf.write(m.id);
    buf.write(':');
    buf.write(m.selectedVariant);
    buf.write('|');
  }
  return buf.toString();
}

/// Returns the checkpoints valid for the chat's CURRENT branch, sorted
/// by anchor index ascending. A checkpoint is valid iff:
///   - its anchor index is still in range (`< messages.length`), AND
///   - its pathHash equals the current branch's hash at that anchor
///     OR its pathHash is the empty-string legacy sentinel.
List<MemoryCheckpoint> findValidCheckpoints(Chat chat) {
  if (chat.memoryCheckpoints.isEmpty) return const [];
  final valid = <MemoryCheckpoint>[];
  for (final c in chat.memoryCheckpoints) {
    if (c.anchorMessageIdx >= chat.messages.length) continue;
    if (c.pathHash.isEmpty) {
      // Legacy migrated checkpoint — treat as always valid.
      valid.add(c);
      continue;
    }
    final branchPrefix =
        computePathHash(chat.messages, c.anchorMessageIdx);
    if (c.pathHash == branchPrefix) valid.add(c);
  }
  valid.sort((a, b) => a.anchorMessageIdx.compareTo(b.anchorMessageIdx));
  return valid;
}

/// Whether the auto-summariser should fire for this chat right now.
///
/// Honours [MemorySettings.autoEvery] when provided — a value of 0
/// globally disables auto-summarisation across all chats (the user
/// can still hit "Summarise now" manually). Otherwise the threshold
/// defaults to [_summarizeThreshold].
///
/// The trigger compares the count of NEW messages (those past the
/// last valid checkpoint anchor) directly against the threshold —
/// no off-by-buffer arithmetic. With autoEvery=20, the first fire
/// lands exactly at message #20 and every subsequent fire lands
/// 20 messages after the previous anchor.
bool shouldSummarize(Chat chat, {MemorySettings? memorySettings}) {
  return summarizeDecision(chat, memorySettings: memorySettings).shouldSummarize;
}

/// Diagnostic companion to [shouldSummarize]: returns the SAME boolean
/// verdict alongside the intermediate numbers that drove it, so a silent
/// non-firing auto-summariser can be diagnosed from the export-only log.
///
/// IMPORTANT: this is the single source of truth — [shouldSummarize] now
/// delegates here and reads back `.shouldSummarize`, so the boolean result
/// is byte-identical to the prior inline logic. The extra fields are pure
/// observability; computing them changes nothing.
class SummarizeDecision {
  /// True iff the auto-summariser should fire now (== [shouldSummarize]).
  final bool shouldSummarize;

  /// Anchor index of the last VALID checkpoint for the current branch, or
  /// -1 when there is none.
  final int lastAnchor;

  /// Count of NEW durable (assistant `MessageKind.char`) turns past the
  /// last anchor — the quantity compared against [threshold].
  final int newCharMsgs;

  /// The effective fire threshold (resolved from `autoEvery` or the
  /// `_summarizeThreshold` default).
  final int threshold;

  /// Number of valid checkpoints for the current branch.
  final int validCount;

  /// Total messages in the chat (all kinds).
  final int totalMessages;

  const SummarizeDecision({
    required this.shouldSummarize,
    required this.lastAnchor,
    required this.newCharMsgs,
    required this.threshold,
    required this.validCount,
    required this.totalMessages,
  });
}

/// Computes the auto-summarise verdict AND the numbers behind it. The
/// boolean logic is identical to the historical inline body of
/// [shouldSummarize]; this just also surfaces the intermediates.
SummarizeDecision summarizeDecision(Chat chat,
    {MemorySettings? memorySettings}) {
  final valid = findValidCheckpoints(chat);
  final lastAnchor = valid.isEmpty ? -1 : valid.last.anchorMessageIdx;
  final threshold = memorySettings != null && memorySettings.autoEvery > 0
      ? memorySettings.autoEvery
      : _summarizeThreshold;
  // Count only DURABLE turns (assistant prose) past the anchor — not user / ooc
  // / scene / system messages. A run of impersonations or OOC chatter with no
  // new character reply must NOT trip the summariser (it would checkpoint over
  // nothing new to narrate). Mirrors the Live Sheet trigger
  // (turnsSinceActiveSnapshot), which deliberately counts MessageKind.char only.
  var newMessages = 0;
  for (var i = lastAnchor + 1; i < chat.messages.length; i++) {
    if (chat.messages[i].kind == MessageKind.char) newMessages++;
  }
  // Preserve the exact short-circuits of the original boolean: memory off
  // OR autoEvery==0 kill-switch ⇒ false, regardless of the counts.
  final bool fire;
  if (!chat.memoryEnabled) {
    fire = false;
  } else if (memorySettings != null && memorySettings.autoEvery == 0) {
    fire = false;
  } else {
    fire = newMessages >= threshold;
  }
  return SummarizeDecision(
    shouldSummarize: fire,
    lastAnchor: lastAnchor,
    newCharMsgs: newMessages,
    threshold: threshold,
    validCount: valid.length,
    totalMessages: chat.messages.length,
  );
}

/// Builds the LLM prompt body for a checkpoint covering messages
/// `(startExclusive, endInclusive]`, optionally with [priorContext]
/// summaries prepended as "story so far". Used both by
/// [generateCheckpoint] (forward) and [regenerateCheckpoint] (retry).
///
/// Wave CY.18.2: the body is structured so the LLM writes each new
/// checkpoint as the NEXT PARAGRAPH of an ongoing narrative — not a
/// standalone synopsis. Older checkpoints concatenate into a "Story
/// so far" block that establishes voice/tone/facts, the most recent
/// one is quoted again as "where the recap left off" so the model
/// has an explicit handoff line to continue from, then the new turns
/// are listed as the raw events to fold in. Reading every checkpoint
/// in sequence should read as one continuous chapter.
String _buildSummariserBody({
  required Chat chat,
  required int startExclusive,
  required int endInclusive,
  required List<MemoryCheckpoint> priorContext,
}) {
  final body = StringBuffer();
  if (priorContext.isNotEmpty) {
    // Concatenate everything BUT the last checkpoint as the established
    // canon. The last one gets called out separately as the handoff
    // line so the model knows exactly where to pick up.
    final tailIdx = priorContext.length - 1;
    if (tailIdx > 0) {
      body.writeln(
          '## Story so far (already-told narrative — for context, do NOT retell):');
      for (var i = 0; i < tailIdx; i++) {
        body.writeln(priorContext[i].summary.trim());
        body.writeln();
      }
    }
    body.writeln(
        '## The recap currently ends here — your NEW paragraph must continue directly from this point, in the same voice, without repeating any of it:');
    body.writeln(priorContext[tailIdx].summary.trim());
    body.writeln();
    body.writeln(
        '## What happens next in the conversation — tell THIS as the next part of the story, continuing straight from above (do not retell what came before):');
  } else {
    body.writeln(
        '## What happens in the conversation below — tell it as the opening of the story:');
  }
  for (var i = startExclusive + 1; i <= endInclusive; i++) {
    if (i < 0 || i >= chat.messages.length) continue;
    final m = chat.messages[i];
    final role = switch (m.kind) {
      MessageKind.user => 'User',
      MessageKind.char => 'Character',
      MessageKind.ooc => 'OOC',
      MessageKind.scene => 'Scene',
      MessageKind.system => 'System',
    };
    // chat-core-1-01: assistant bodies can carry `<think>…</think>` reasoning
    // (kept in the STORED text for the per-message toggle). Strip it from the
    // summariser's SOURCE so chain-of-thought never feeds the recap. Only
    // character turns carry reasoning; other roles pass through verbatim.
    final text =
        m.kind == MessageKind.char ? stripStreamArtifacts(m.text) : m.text;
    body.writeln('$role: $text');
  }
  return body.toString();
}

/// memory test seam: exposes [_buildSummariserBody] so the summariser source
/// assembly (incl. the chat-core-1-01 `<think>` strip) is unit-testable.
@visibleForTesting
String buildSummariserBodyForTest({
  required Chat chat,
  required int startExclusive,
  required int endInclusive,
  required List<MemoryCheckpoint> priorContext,
}) =>
    _buildSummariserBody(
      chat: chat,
      startExclusive: startExclusive,
      endInclusive: endInclusive,
      priorContext: priorContext,
    );

/// System prompt used by the summariser. Honours
/// [MemorySettings.summaryPrompt] when provided (with `{{words}}`
/// substitution); otherwise falls back to a sensible default tuned for
/// the new checkpoint paradigm.
@visibleForTesting
String resolveSystemPrompt({
  required bool hasPriorContext,
  required MemorySettings? memorySettings,
}) {
  // Wave CY.18.2: emphasise narrative CONTINUITY across checkpoints —
  // reading them in order should produce one unbroken chapter, each
  // entry picking up exactly where the previous ended.
  // Wave CY.18.162: both prompts push STORYTELLING over narrative voice
  // rather than a dry event log.
  // Wave CY.18.189: both prompts now lead with an EXPLICIT, PROMINENT
  // anti-continuation block. The Wave-162 narrative framing caused some
  // models (especially when fired right after a character turn) to
  // CONTINUE the roleplay instead of recapping it. The fix keeps the
  // past-tense narrative VOICE but makes the TASK unambiguously a recap
  // of events that ALREADY happened — never an extension of the story.
  // Wave CY.18.209: the block is now defined ABOVE the custom-summaryPrompt
  // branch and prepended in BOTH paths. Previously it only reached the
  // default (empty-summaryPrompt) path, so any user with a persisted
  // `summaryPrompt` (most users, incl. the owner) never got the
  // anti-continuation discipline and the "LTM continues the story" bug
  // persisted. The block is a generic recap-not-continuation instruction
  // compatible with any summary template.
  const antiContinuationBlock =
      'IMPORTANT — YOUR TASK IS A MEMORY RECAP, NOT A STORY CONTINUATION. '
      'You are SUMMARISING events that have ALREADY happened so they can '
      'be stored as long-term memory. Do NOT advance the plot. Do NOT '
      'invent new events. Do NOT write any action, dialogue, or outcome '
      'that has not already occurred in the messages provided. Do NOT '
      'continue the scene or add anything that comes after the last '
      'message. RETELL what happened in the PAST tense — never continue '
      'it. Within those limits, write it as flowing narrative prose (a '
      '"story so far"), not a bulleted log and not a flat list of '
      'events. ';
  // Soft cap: convert memoryLimit (lines, loosely "words") into a word
  // budget the template can interpolate via `{{words}}`.
  final words =
      ((memorySettings?.memoryLimit ?? 1000).clamp(50, 5000) ~/ 1).toString();
  // Wave CY.18.270: the rich narrative-arc framing now lives in ONE place —
  // MemorySettings._defaultPrompt — which already covers BOTH the
  // "Story so far" handoff case and the opening-arc case in prose, and is
  // PAST-tense throughout. Use the user's custom template when they supplied
  // one (a non-empty summaryPrompt), otherwise fall back to that same default
  // arc framing. This removes the prior DEAD, divergent narrative branch (the
  // user's persisted summaryPrompt always defaulted to the non-empty
  // _defaultPrompt, so the old hasPriorContext branches below were never
  // reached) and keeps a single source of truth for the arc framing.
  // `hasPriorContext` is left as a documented param: the actual WITH/WITHOUT
  // prior-context split is handled by the prompt body itself (it inspects the
  // "Story so far" block the user-turn builder includes), not by branching
  // here — so both code paths now yield the same coherent arc framing.
  final body = (memorySettings != null &&
          memorySettings.summaryPrompt.trim().isNotEmpty)
      ? memorySettings.summaryPrompt
      : MemorySettings().summaryPrompt; // == _defaultPrompt arc framing
  // Wave CY.18.209: ALWAYS prepend the anti-continuation framing — the
  // recap-not-continuation discipline is non-negotiable regardless of the
  // editable summary text.
  return '$antiContinuationBlock${body.replaceAll('{{words}}', words)}';
}

/// Returns true when [text] appears to end on a complete sentence, i.e.
/// the trimmed text's last non-whitespace character is sentence-final
/// punctuation (`.`, `!`, `?`, `…`) or a closing quotation mark
/// (`"`, `'`, `』`, `」`, `"`) that immediately follows such punctuation.
///
/// Used by [generateCheckpoint] to detect truncated output: if the
/// recap does NOT look complete we run a bounded continuation loop
/// (Wave CY.18.189).
///
/// Conservative by design: only marks text as complete when it CLEARLY
/// ends on a sentence boundary. A false-negative (looks truncated but
/// was actually complete) wastes one extra LLM call; a false-positive
/// (looks complete but was actually cut off) silently loses context.
/// The former is the lesser evil, hence the conservative check.
bool recapLooksComplete(String text) {
  final trimmed = text.trimRight();
  if (trimmed.isEmpty) return false;
  final last = trimmed[trimmed.length - 1];
  // Direct sentence-final punctuation.
  if (last == '.' || last == '!' || last == '?' || last == '…') return true;
  // Closing quote immediately after sentence-final punctuation, e.g. `."`.
  if (last == '"' ||
      last == "'" ||
      last == '」' || // 』
      last == '』' || // 」
      last == '”') {
    // "  (right double quotation mark)
    // Look at the character before the closing quote.
    if (trimmed.length >= 2) {
      final beforeQuote = trimmed[trimmed.length - 2];
      return beforeQuote == '.' ||
          beforeQuote == '!' ||
          beforeQuote == '?' ||
          beforeQuote == '…';
    }
  }
  return false;
}

/// Leading-line markers a reasoning model uses for its META-REASONING /
/// planning preamble (anchored to the START of a line, word-boundary aware so
/// a narrative line that merely SHARES a prefix word — e.g. "Letting go…",
/// "Sounds drifted…" — is never mistaken for a plan line). These are the
/// "thinking out loud" lines that precede the actual recap when a reasoning
/// model dumps its `<think>` channel as the answer.
final RegExp _kRecapPlanLine = RegExp(
  r'''^\s*(?:[-*>#•]\s*)?(?:'''
  // first-person planning: I should/need/will/must/'ll/'m/am/have to/want
  r"i(?:'ll|'m| am| should| need| will| must| have to| want| can| could| think| guess| see| have| now)\b"
  r'|'
  // task framing
  r'my (?:task|job|goal)\b|the user\b|user (?:wants|asks|is asking)\b|we (?:need|should|must)\b'
  r'|'
  // discourse openers used to start reasoning
  r"let me\b|let'?s\b|okay\b|ok\b|alright\b|so,|now,|first,|next,|then,|hmm\b|wait\b|actually,|right,|well,"
  r')',
  caseSensitive: false,
);

/// Wave: strip a reasoning model's META-REASONING preamble from a recovered
/// LTM recap before it is stored. ONLY used on the empty-visible-content
/// fallback path (when [recoverReasoningFromRaw] returned the raw `<think>`
/// channel verbatim) — visible content still wins untouched.
///
/// Mirrors [stripVisionReasoningPreamble] (image_describe.dart): drop any
/// `<think>…</think>` blocks, then drop the LEADING contiguous run of planning
/// lines ("The user wants…/I should…/Let me…/Wait…") and keep the narrative
/// recap tail. Conservative: stops at the first non-plan (narrative) line, and
/// NEVER nukes the text to empty — if every line looks like reasoning it
/// returns the think-stripped text (a thin recap beats none). Pure + tested.
String stripRecapReasoningPreamble(String raw) {
  // 1. Drop any <think>…</think> reasoning blocks first.
  final withoutThink = raw.replaceAll(
    RegExp(r'<think>.*?</think>', dotAll: true, caseSensitive: false),
    '',
  );

  // 2. Drop a LEADING contiguous run of plan/meta lines. Blank lines inside
  //    the leading run are skipped (still part of the preamble); we stop at the
  //    first non-blank line that does NOT look like a plan line — that is where
  //    the narrative recap begins.
  final lines = withoutThink.split('\n');
  var start = 0;
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (t.isEmpty) {
      start = i + 1;
      continue;
    }
    if (_kRecapPlanLine.hasMatch(t)) {
      start = i + 1;
      continue;
    }
    break; // first narrative line — keep from here on
  }

  final kept = lines.sublist(start).join('\n').trim();
  if (kept.isNotEmpty) return kept;
  // Everything looked like reasoning — never return nothing.
  final fallback = withoutThink.trim();
  return fallback.isNotEmpty ? fallback : raw.trim();
}

/// Wave CY.18.164: the summariser sends NO preset, so `_samplingPayload`
/// falls through to the GLOBAL `modelSettings.maxTokens` (default 1024) —
/// which can be lower than the RP preset's cap. The storytelling recap
/// (Wave CY.18.162) is wordier than the old terse one and was getting cut
/// mid-sentence. The prompt now bounds itself to ~150–300 words (fits well
/// under 1024), and this floors the cap so a too-low USER setting can't
/// truncate a compliant recap either. Never LOWERS a higher user value.
ModelSettings _recapSettings(ModelSettings base) {
  if (base.maxTokens >= 1024) return base;
  return ModelSettings.fromJson(base.toJson())..maxTokens = 1024;
}

/// Runs one recap LLM call via [completeChatStreamed] with the reasoning
/// fallback ON, but cleans the result of META-REASONING preamble ONLY when the
/// answer actually came from that fallback (visible content wins, untouched).
///
/// HOW it isolates the fallback path without a second call: it captures the raw
/// stream via `rawSink`. If [stripStreamArtifacts] of the raw is non-empty, the
/// returned text IS the visible content — return it verbatim. If it is empty,
/// the return value was recovered from the `<think>` channel
/// ([recoverReasoningFromRaw]) — a reasoning-only model (Venice's uncensored
/// Qwen) dumping its whole recap (planning lines and all) — so run
/// [stripRecapReasoningPreamble] to drop the "The user wants…/I should…/wait…"
/// scaffolding before it is stored as the checkpoint.
Future<String> _completeRecapSanitized({
  required ApiProvider provider,
  required ModelSettings settings,
  required List<ChatTurn> messages,
}) async {
  final rawSink = StringBuffer();
  final result = await completeChatStreamed(
    provider: provider,
    settings: settings,
    messages: messages,
    debugTag: 'ltm', // Wave CY.18.214 diagnostics tag
    // Wave CY.18.270: a reasoning-only model (Venice's uncensored Qwen) emits
    // its whole recap in the `<think>` channel; stripping it left '' → "empty
    // reply" → no checkpoint. The recap is internal context (never shown
    // verbatim), so a cleaned-up "thinky" recap beats none.
    allowReasoningFallback: true,
    rawSink: rawSink,
  );
  // Visible content present ⇒ the result is the visible content; leave it alone.
  if (stripStreamArtifacts(rawSink.toString()).isNotEmpty) return result;
  // Empty visible content ⇒ result came from the reasoning fallback; clean it.
  return stripRecapReasoningPreamble(result);
}

/// Generate a fresh checkpoint covering everything between the last
/// valid anchor (exclusive) and the cutoff (inclusive). Returns null
/// when there's nothing to summarise or the LLM call fails.
Future<MemoryCheckpoint?> generateCheckpoint({
  required Chat chat,
  required ApiProvider provider,
  required ModelSettings settings,
  MemorySettings? memorySettings,
}) async {
  if (provider.baseUrl.isEmpty) {
    // Wave CY.18.270: was a silent `return null` — record it so the failure
    // is visible (the chat-screen SnackBar reads MemoryErrors) instead of the
    // summariser appearing to do nothing when no provider URL is configured.
    MemoryErrors.record('generateCheckpoint', 'provider has no base URL');
    return null;
  }
  final valid = findValidCheckpoints(chat);
  final lastAnchor = valid.isEmpty ? -1 : valid.last.anchorMessageIdx;
  // Cover everything up to the latest message. No keep-recent buffer:
  // the user's mental model is "every N messages, drop a checkpoint
  // covering those N", and that's exactly what we do. Subsequent live
  // chat replay starts past the new anchor and grows back from zero
  // as the user keeps chatting.
  final cutoff = chat.messages.length - 1;
  if (cutoff <= lastAnchor) {
    // SILENT export-only breadcrumb (Wave CY.18.214 channel). This early
    // return otherwise records NOTHING — making a stuck "nothing to cover"
    // case invisible. No behaviour change: the return is identical.
    unawaited(LlmDebugLog.instance
        .trace('ltm.gen: skipped cutoff<=lastAnchor (cutoff=$cutoff '
            'lastAnchor=$lastAnchor)'));
    return null;
  }

  final priorCapped = valid.length > kMaxCheckpointsInPrompt
      ? valid.sublist(valid.length - kMaxCheckpointsInPrompt)
      : valid;

  final body = _buildSummariserBody(
    chat: chat,
    startExclusive: lastAnchor,
    endInclusive: cutoff,
    priorContext: priorCapped,
  );
  final systemPrompt = resolveSystemPrompt(
    hasPriorContext: priorCapped.isNotEmpty,
    memorySettings: memorySettings,
  );

  final turns = <ChatTurn>[
    ChatTurn('system', systemPrompt),
    ChatTurn('user', body),
  ];

  try {
    // Wave CY.18.160: use the STREAMING transport (same as the live chat),
    // not the one-shot completeChat — some providers (Chub/Soji) return
    // nothing usable on `stream:false`, which silently broke the
    // auto-summariser while the chat itself worked.
    //
    // Wave CY.18.268: ONE automatic retry on an empty/errored first call.
    // A transient provider blip (network hiccup, a momentary refusal or an
    // empty body) used to fail the whole summarise — the chat path has
    // retry/fallback but this one didn't, so a single glitch surfaced the
    // generic "couldn't summarise" toast. Retry once (short backoff) so a
    // momentary blip self-heals; only give up if BOTH attempts come back
    // empty or throw.
    var firstChunk = '';
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      try {
        firstChunk = (await _completeRecapSanitized(
          provider: provider,
          settings: _recapSettings(settings),
          messages: turns,
        ))
            .trim();
        if (firstChunk.isNotEmpty) break;
        lastErr = 'empty reply';
      } catch (e) {
        lastErr = e;
      }
    }
    if (firstChunk.isEmpty) {
      // Wave CY.18.42 / 268: both the call and its retry came back empty or
      // errored — surface it so the user can re-trigger rather than
      // silently losing the checkpoint.
      MemoryErrors.record(
        'generateCheckpoint',
        'LLM returned no summary after retry: $lastErr',
      );
      return null;
    }

    // Wave CY.18.189: bounded auto-continue for truncated recaps.
    // completeChatStreamed already strips <think>/reasoning (Wave 160),
    // so each chunk is clean. We keep the loop small (≤ _kRecapMaxContinuations)
    // and always-terminating (empty-chunk break + cap).
    var accumulated = firstChunk;
    final continuationTurns = List<ChatTurn>.from(turns);
    for (var i = 0; i < _kRecapMaxContinuations; i++) {
      if (recapLooksComplete(accumulated)) break;
      // Append accumulated recap as assistant turn and ask to continue.
      continuationTurns.add(ChatTurn('assistant', accumulated));
      continuationTurns.add(ChatTurn('user', _kRecapContinuePrompt));
      final chunk = await _completeRecapSanitized(
        provider: provider,
        settings: _recapSettings(settings),
        messages: continuationTurns,
      );
      final trimmedChunk = chunk.trim();
      if (trimmedChunk.isEmpty) break; // provider returned nothing — stop
      accumulated = '$accumulated $trimmedChunk';
    }

    final summary = accumulated.trim();
    return MemoryCheckpoint(
      id: newId('mc'),
      summary: summary,
      anchorMessageIdx: cutoff,
      pathHash: computePathHash(chat.messages, cutoff),
    );
  } catch (e) {
    MemoryErrors.record('generateCheckpoint', e);
    return null;
  }
}

/// Re-runs the LLM call for an existing checkpoint, keeping its anchor
/// and pathHash but replacing its summary. Used by the per-checkpoint
/// "Retry" button. Returns the new checkpoint object — the caller
/// swaps it into `chat.memoryCheckpoints` (preserving order).
Future<MemoryCheckpoint?> regenerateCheckpoint({
  required Chat chat,
  required MemoryCheckpoint target,
  required ApiProvider provider,
  required ModelSettings settings,
  MemorySettings? memorySettings,
}) async {
  if (provider.baseUrl.isEmpty) return null;
  final valid = findValidCheckpoints(chat);
  final idx = valid.indexWhere((c) => c.id == target.id);
  if (idx < 0) return null;

  final priorContext = idx == 0 ? <MemoryCheckpoint>[] : valid.sublist(0, idx);
  final priorCapped = priorContext.length > kMaxCheckpointsInPrompt
      ? priorContext.sublist(priorContext.length - kMaxCheckpointsInPrompt)
      : priorContext;

  final prevAnchor = idx == 0 ? -1 : valid[idx - 1].anchorMessageIdx;
  final cutoff = target.anchorMessageIdx;
  if (cutoff <= prevAnchor) return null;

  final body = _buildSummariserBody(
    chat: chat,
    startExclusive: prevAnchor,
    endInclusive: cutoff,
    priorContext: priorCapped,
  );
  final systemPrompt = resolveSystemPrompt(
    hasPriorContext: priorCapped.isNotEmpty,
    memorySettings: memorySettings,
  );

  final turns = <ChatTurn>[
    ChatTurn('system', systemPrompt),
    ChatTurn('user', body),
  ];

  try {
    // Wave CY.18.160: streaming transport (see generateCheckpoint).
    final out = await _completeRecapSanitized(
      provider: provider,
      settings: _recapSettings(settings),
      messages: turns,
    );
    final summary = out.trim();
    if (summary.isEmpty) {
      MemoryErrors.record(
        'regenerateCheckpoint',
        'LLM returned empty summary',
      );
      return null;
    }
    return MemoryCheckpoint(
      id: target.id,
      summary: summary,
      anchorMessageIdx: target.anchorMessageIdx,
      pathHash: target.pathHash,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  } catch (e) {
    MemoryErrors.record('regenerateCheckpoint', e);
    return null;
  }
}

/// Append a freshly-generated checkpoint to the chat's memory chain, then
/// prune to [_kMaxRetainedCheckpoints] oldest-first. Checkpoints are
/// append-only, so the OLDEST sit at the FRONT; dropping from there can never
/// strand the recent valid set the runtime reads (the cap is an order of
/// magnitude larger than [kMaxCheckpointsInPrompt]).
void applyCheckpoint(Chat chat, MemoryCheckpoint c) {
  chat.memoryCheckpoints.add(c);
  if (chat.memoryCheckpoints.length > _kMaxRetainedCheckpoints) {
    chat.memoryCheckpoints.removeRange(
        0, chat.memoryCheckpoints.length - _kMaxRetainedCheckpoints);
  }
}

/// Swap an existing checkpoint with its regenerated copy, preserving
/// ordering. Returns true if the swap happened.
bool replaceCheckpoint(Chat chat, MemoryCheckpoint replacement) {
  final idx =
      chat.memoryCheckpoints.indexWhere((c) => c.id == replacement.id);
  if (idx < 0) return false;
  chat.memoryCheckpoints[idx] = replacement;
  return true;
}

/// Delete a single checkpoint by id. Returns true if removed.
bool deleteCheckpoint(Chat chat, String checkpointId) {
  final before = chat.memoryCheckpoints.length;
  chat.memoryCheckpoints.removeWhere((c) => c.id == checkpointId);
  return chat.memoryCheckpoints.length < before;
}

/// Wipe every checkpoint — both valid and stale-from-other-branches.
void wipeAllCheckpoints(Chat chat) {
  chat.memoryCheckpoints.clear();
}

/// Concatenate the valid checkpoints (capped at [kMaxCheckpointsInPrompt]
/// most recent) into the recap block injected into the chat's system
/// prompt. Returns an empty string when memory is disabled or no
/// checkpoints are valid for the current branch.
///
/// Wave CY.18.2: checkpoints are written as consecutive paragraphs of
/// the SAME chapter (see resolveSystemPrompt), so the runtime recap
/// concatenates them as pure prose separated by blank lines — no
/// "Checkpoint X of Y" labels would only fight the model's continuity
/// when reading the recap as the established story.
String buildRecapBlock(Chat chat) {
  if (!chat.memoryEnabled) return '';
  final valid = findValidCheckpoints(chat);
  if (valid.isEmpty) return '';
  final capped = valid.length > kMaxCheckpointsInPrompt
      ? valid.sublist(valid.length - kMaxCheckpointsInPrompt)
      : valid;
  return recencyBoundedRecap(
    [for (final c in capped) c.summary],
    charBudget: kRecapCharBudget,
    alwaysWholeNewest: _kRecapAlwaysWholeNewest,
  );
}

/// PURE. Joins checkpoint [summaries] (oldest-first, chronological) into the
/// recap block, applying a RECENCY-BIASED character budget: the newest
/// checkpoints are kept WHOLE and the OLDEST are dropped first when the total
/// would exceed [charBudget]. The most-recent [alwaysWholeNewest] checkpoints
/// are NEVER dropped even if they alone blow the budget — the latest
/// continuity is the most important to preserve verbatim.
///
/// Returns the joined block (paragraphs separated by a blank line), trimmed.
/// Wave CY.18.220.
String recencyBoundedRecap(
  List<String> summaries, {
  required int charBudget,
  int alwaysWholeNewest = 1,
}) {
  // Trim + drop empties, preserving chronological order.
  final items = [
    for (final s in summaries)
      if (s.trim().isNotEmpty) s.trim()
  ];
  if (items.isEmpty) return '';

  final protect = alwaysWholeNewest < 1 ? 1 : alwaysWholeNewest;
  // Walk from NEWEST → OLDEST, keeping checkpoints until adding the next
  // (older) one would exceed the budget. The newest [protect] are always kept.
  final keptReversed = <String>[];
  var total = 0;
  const sep = 2; // the '\n\n' joiner between paragraphs
  for (var i = items.length - 1; i >= 0; i--) {
    final addLen = items[i].length + (keptReversed.isEmpty ? 0 : sep);
    final mustKeep = (items.length - 1 - i) < protect;
    if (!mustKeep && total + addLen > charBudget) {
      // Adding this older checkpoint would overflow — stop; everything older
      // is dropped (oldest-first trimming).
      break;
    }
    keptReversed.add(items[i]);
    total += addLen;
  }
  final kept = keptReversed.reversed.toList();
  return kept.join('\n\n').trim();
}

/// The index AFTER the last covered message — equivalent to the legacy
/// `chat.memoryAnchor`. Used by the chat turn builder to decide where
/// the replay window starts.
///
/// memory-livesheet-script-scene-01: when memory is OFF the recap is
/// suppressed ([buildRecapBlock] returns ''), so honouring a stale anchor here
/// would hide all pre-anchor messages — they'd be NEITHER summarised NOR
/// replayed, silently dropping context. With memory disabled we clamp to 0 so
/// the full history replays. (Gating here means every consumer — the chat
/// builder AND the token-breakdown panel — stays consistent with the recap.)
int firstUncoveredIndex(Chat chat) {
  if (!chat.memoryEnabled) return 0;
  final valid = findValidCheckpoints(chat);
  if (valid.isEmpty) return 0;
  return valid.last.anchorMessageIdx + 1;
}
