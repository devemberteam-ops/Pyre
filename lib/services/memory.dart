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

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/models.dart';
import 'chat_api.dart';

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
  if (!chat.memoryEnabled) return false;
  // Global kill-switch — autoEvery == 0 means "never auto-summarise".
  if (memorySettings != null && memorySettings.autoEvery == 0) return false;
  final threshold = memorySettings != null && memorySettings.autoEvery > 0
      ? memorySettings.autoEvery
      : _summarizeThreshold;
  final valid = findValidCheckpoints(chat);
  final lastAnchor = valid.isEmpty ? -1 : valid.last.anchorMessageIdx;
  // Count only DURABLE turns (assistant prose) past the anchor — not user / ooc
  // / scene / system messages. A run of impersonations or OOC chatter with no
  // new character reply must NOT trip the summariser (it would checkpoint over
  // nothing new to narrate). Mirrors the Live Sheet trigger
  // (turnsSinceActiveSnapshot), which deliberately counts MessageKind.char only.
  var newMessages = 0;
  for (var i = lastAnchor + 1; i < chat.messages.length; i++) {
    if (chat.messages[i].kind == MessageKind.char) newMessages++;
  }
  return newMessages >= threshold;
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
    body.writeln('$role: ${m.text}');
  }
  return body.toString();
}

/// System prompt used by the summariser. Honours
/// [MemorySettings.summaryPrompt] when provided (with `{{words}}`
/// substitution); otherwise falls back to a sensible default tuned for
/// the new checkpoint paradigm.
String _resolveSystemPrompt({
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
      'message. RETELL what happened — never continue it. Every sentence '
      'you write must describe something that is already in the '
      'conversation above, nothing more. ';
  if (memorySettings != null &&
      memorySettings.summaryPrompt.trim().isNotEmpty) {
    // Soft cap: convert memoryLimit (lines, loosely "words") into a
    // word budget the template can interpolate.
    final words =
        (memorySettings.memoryLimit.clamp(50, 5000) ~/ 1).toString();
    // Wave CY.18.209: ALWAYS prepend the anti-continuation framing, even
    // when the user supplies their own template — the recap-not-continuation
    // discipline is non-negotiable regardless of the editable summary text.
    return '$antiContinuationBlock'
        '${memorySettings.summaryPrompt.replaceAll('{{words}}', words)}';
  }
  return hasPriorContext
      ? '$antiContinuationBlock'
          'You are the NARRATOR of an unfolding roleplay, keeping a '
          'running STORY of it across entries that read as one '
          'continuous tale — not a log, not a status report. You are '
          'given the story so far, then the exact point where it '
          'currently ends; write the NEXT part of the story recap, '
          'continuing seamlessly from that handoff in the same '
          'third-person, PAST-tense narrative voice — the next page of '
          'the same recap, never a fresh summary. Open with a connective '
          'beat ("From there", "In the days that followed", "Soon '
          'after", "Meanwhile") rather than re-introducing anyone. TELL '
          'it as a story: what the characters did, how things shifted '
          'between them, what it cost or meant, the texture of the '
          'moment — NOT a dry, minute-by-minute description and NOT a '
          'list of events. Cover ONLY the new events given below; do '
          'NOT repeat, rephrase or re-summarise anything already in the '
          'story so far, and do NOT restart or re-introduce people and '
          'places already named. Close on whatever is still unresolved '
          'so the next part has a thread to pick up. Stay concrete — '
          'real names, real places, real events from the conversation; '
          'invent nothing. Keep it to ONE focused paragraph — roughly '
          '150–300 words, vivid but economical, never padded or run '
          'long (a recap, not the scene replayed). Prose only: no '
          'headers, no bullet points, no commentary.'
      : '$antiContinuationBlock'
          'You are the NARRATOR of an unfolding roleplay, beginning a '
          'running STORY recap of it. This is the OPENING recap entry — '
          'write it like the first page of a story, in flowing '
          'third-person, PAST-tense prose. Establish who the characters '
          'are, where they are and the situation that sets things in '
          'motion, then carry it through the first real beats: what the '
          'characters did, what shifted between them, what is left '
          'hanging. TELL it as a story with shape and stakes — NOT a '
          'minute-by-minute description and NOT a list of events strung '
          'together with "then… then… then". This opening sets the '
          'narrative VOICE for every entry that follows (each continues '
          'directly from where the last ended), so make it vivid and '
          'leave a clear thread unresolved on the final line. Stay '
          'concrete — use the real names, places and events from the '
          'conversation below, and invent nothing that is not there. Do '
          'NOT borrow names or settings from this instruction. Keep it '
          'to ONE focused paragraph — roughly 150–300 words, vivid but '
          'economical, never padded or run long (a recap, not the scene '
          'replayed). Prose only: no headers, no bullet points, no '
          'commentary.';
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

/// Generate a fresh checkpoint covering everything between the last
/// valid anchor (exclusive) and the cutoff (inclusive). Returns null
/// when there's nothing to summarise or the LLM call fails.
Future<MemoryCheckpoint?> generateCheckpoint({
  required Chat chat,
  required ApiProvider provider,
  required ModelSettings settings,
  MemorySettings? memorySettings,
}) async {
  if (provider.baseUrl.isEmpty) return null;
  final valid = findValidCheckpoints(chat);
  final lastAnchor = valid.isEmpty ? -1 : valid.last.anchorMessageIdx;
  // Cover everything up to the latest message. No keep-recent buffer:
  // the user's mental model is "every N messages, drop a checkpoint
  // covering those N", and that's exactly what we do. Subsequent live
  // chat replay starts past the new anchor and grows back from zero
  // as the user keeps chatting.
  final cutoff = chat.messages.length - 1;
  if (cutoff <= lastAnchor) return null;

  final priorCapped = valid.length > kMaxCheckpointsInPrompt
      ? valid.sublist(valid.length - kMaxCheckpointsInPrompt)
      : valid;

  final body = _buildSummariserBody(
    chat: chat,
    startExclusive: lastAnchor,
    endInclusive: cutoff,
    priorContext: priorCapped,
  );
  final systemPrompt = _resolveSystemPrompt(
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
    final firstChunk = await completeChatStreamed(
      provider: provider,
      settings: _recapSettings(settings),
      messages: turns,
      debugTag: 'ltm', // Wave CY.18.214 diagnostics tag
    );
    if (firstChunk.trim().isEmpty) {
      // Wave CY.18.42: empty summary from a successful LLM call is
      // surfaced too — the user can re-trigger with a different
      // provider/preset rather than silently losing the checkpoint.
      MemoryErrors.record(
        'generateCheckpoint',
        'LLM returned empty summary',
      );
      return null;
    }

    // Wave CY.18.189: bounded auto-continue for truncated recaps.
    // completeChatStreamed already strips <think>/reasoning (Wave 160),
    // so each chunk is clean. We keep the loop small (≤ _kRecapMaxContinuations)
    // and always-terminating (empty-chunk break + cap).
    var accumulated = firstChunk.trim();
    final continuationTurns = List<ChatTurn>.from(turns);
    for (var i = 0; i < _kRecapMaxContinuations; i++) {
      if (recapLooksComplete(accumulated)) break;
      // Append accumulated recap as assistant turn and ask to continue.
      continuationTurns.add(ChatTurn('assistant', accumulated));
      continuationTurns.add(ChatTurn('user', _kRecapContinuePrompt));
      final chunk = await completeChatStreamed(
        provider: provider,
        settings: _recapSettings(settings),
        messages: continuationTurns,
        debugTag: 'ltm', // Wave CY.18.214 diagnostics tag
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
  final systemPrompt = _resolveSystemPrompt(
    hasPriorContext: priorCapped.isNotEmpty,
    memorySettings: memorySettings,
  );

  final turns = <ChatTurn>[
    ChatTurn('system', systemPrompt),
    ChatTurn('user', body),
  ];

  try {
    // Wave CY.18.160: streaming transport (see generateCheckpoint).
    final out = await completeChatStreamed(
      provider: provider,
      settings: _recapSettings(settings),
      messages: turns,
      debugTag: 'ltm', // Wave CY.18.214 diagnostics tag
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
/// the SAME chapter (see _resolveSystemPrompt), so the runtime recap
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
int firstUncoveredIndex(Chat chat) {
  final valid = findValidCheckpoints(chat);
  if (valid.isEmpty) return 0;
  return valid.last.anchorMessageIdx + 1;
}
