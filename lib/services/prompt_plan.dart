// Pyre 1.2 (Motor refactor, Slice B) — the internal `PromptPlan` model that
// `buildChatPrompt` now assembles BEFORE projecting to the outgoing
// `List<ChatTurn>`.
//
// PURE — this file imports ONLY models.dart (for [PromptSegmentKind], defined
// in chat_prompt_builder.dart) + chat_api.dart (for [ChatTurn]). No AppStore,
// no package:flutter.
//
// THE CONTRACT: `PromptPlan.toChatTurns()` must reproduce, byte-for-byte,
// exactly what `buildChatPrompt` emitted before this refactor (proven by
// `test/prompt_golden_test.dart`, which stays green with ZERO golden
// regeneration). This file does not change WHAT is assembled — only HOW it is
// represented internally, so a later slice (D) can budget/trim the plan
// before projection without touching the assembly logic itself.
//
// THE LEADING SYSTEM TURN — the one subtle part: today's builder writes the
// system prompt / card-fallback / LTM recap / live-sheet / group-roster
// pieces into ONE `StringBuffer` (a mix of `buffer.write(x)` — no trailing
// newline — and `buffer.writeln(x)` — trailing '\n') and emits it as a SINGLE
// `ChatTurn('system', buffer.toString().trim())`. To reproduce that exactly,
// each contributing piece becomes a `PlanSegment` in the `leadingSystem` slot
// whose `content` is stored VERBATIM as it was written to the buffer, plus an
// `appendNewline` flag recording whether the original call was `writeln`
// (true) or `write` (false). `toChatTurns()` concatenates every
// `leadingSystem` segment's `content + (appendNewline ? '\n' : '')` in order
// and trims the result ONCE — identical to the old buffer's `.toString().trim()`.

import 'chat_api.dart' show ChatTurn;
import 'chat_prompt_builder.dart' show PromptSegmentKind;

/// Where a [PlanSegment] lands in the final turn sequence.
///
///  - [PlanSlot.leadingSystem]: joined with every other `leadingSystem`
///    segment into ONE leading `system` ChatTurn (see the file doc above).
///  - [PlanSlot.beforeHistoryTurn]: becomes its own turn placed BEFORE the
///    replayed chat history (modular preset role-split `beforeTurns`).
///  - [PlanSlot.historyTurn]: one replayed chat-history message (or a
///    depth-injected preset turn spliced into that history).
///  - [PlanSlot.roadmapTurn]: the story-roadmap system turn, placed after
///    history.
///  - [PlanSlot.postHistoryTurn]: the preset's post-history instructions
///    turn.
///  - [PlanSlot.afterHistoryTurn]: modular preset role-split `afterTurns`,
///    placed at the very end.
///  - [PlanSlot.guideTurn]: the one-shot Guide note, injected by
///    `injectGuide` AFTER every other turn is assembled (its position inside
///    the final sequence is decided by `injectGuide`, not by slot order here
///    — see [PromptPlan.toChatTurns]).
enum PlanSlot {
  leadingSystem,
  beforeHistoryTurn,
  historyTurn,
  roadmapTurn,
  postHistoryTurn,
  afterHistoryTurn,
  guideTurn,
}

/// One atomic contribution to the assembled prompt — the PromptPlan's unit.
///
/// [priority] / [droppable] are INERT this slice (Slice D wires a token
/// budget that reads them to decide what to trim under an over-budget chat).
/// They are populated now with sane defaults so D can build on this shape
/// without another pass over every call site:
///   - `droppable: false` (never-drop) for anything the Motor spec's D
///     section names as protected: the leading-system pieces (system prompt,
///     character, persona, LTM recap, live sheet, group roster — lore is the
///     one leading-system piece that IS droppable, see below), post-history,
///     the roadmap, the guide note, and — once history turns are individually
///     tagged in a later slice — the last user/assistant turn.
///   - `droppable: true` for ordinary history turns and lorebook-before
///     content (D's proposal explicitly trims "oldest history then
///     oldest/lowest-order lore" first).
/// [priority] is left at 0 for every segment this slice (no ordering signal
/// exists yet); D assigns real values when it builds the trim algorithm.
class PlanSegment {
  final String role; // 'system' | 'user' | 'assistant'
  final PlanSlot slot;
  final PromptSegmentKind kind;

  /// The content AS IT WAS WRITTEN to the original assembly (verbatim for
  /// `leadingSystem` segments — see [appendNewline]; already `fill()`-resolved
  /// and, for non-`leadingSystem` slots, already `.trim()`-ed exactly as the
  /// pre-refactor code trimmed each individual turn).
  final String content;

  /// ONLY meaningful for [PlanSlot.leadingSystem] segments: whether the
  /// original code wrote this piece via `buffer.writeln` (true, adds a
  /// trailing `\n`) or `buffer.write` (false, no trailing separator). Ignored
  /// for every other slot (those become their own discrete ChatTurn, with no
  /// join to reproduce).
  final bool appendNewline;

  final List<String>? imageDataUrls;
  final int priority;
  final bool droppable;
  final String? sourceLabel;
  final String id;

  const PlanSegment({
    required this.role,
    required this.slot,
    required this.kind,
    required this.content,
    this.appendNewline = false,
    this.imageDataUrls,
    this.priority = 0,
    this.droppable = false,
    this.sourceLabel,
    required this.id,
  });

  PlanSegment copyWith({String? content}) => PlanSegment(
        role: role,
        slot: slot,
        kind: kind,
        content: content ?? this.content,
        appendNewline: appendNewline,
        imageDataUrls: imageDataUrls,
        priority: priority,
        droppable: droppable,
        sourceLabel: sourceLabel,
        id: id,
      );
}

/// The internal source-of-truth `buildChatPrompt` assembles before projecting
/// to the outgoing `List<ChatTurn>`. See the file doc for the parity contract.
class PromptPlan {
  final List<PlanSegment> segments;

  const PromptPlan(this.segments);

  /// Project this plan to the exact `List<ChatTurn>` the pre-refactor
  /// `buildChatPrompt` returned (before the final name-fill pass, which the
  /// builder still applies afterwards — identical to before).
  ///
  /// Every [PlanSlot.leadingSystem] segment is joined (in list order) into
  /// ONE leading `system` turn using each segment's own [PlanSegment.
  /// appendNewline] flag, then `.trim()`-ed ONCE — reproducing the old single
  /// `StringBuffer`'s `.toString().trim()` byte-for-byte. Every other slot
  /// becomes its own turn, in list order.
  List<ChatTurn> toChatTurns() {
    final leadingBuffer = StringBuffer();
    var sawLeading = false;
    final turns = <ChatTurn>[];
    for (final s in segments) {
      if (s.slot == PlanSlot.leadingSystem) {
        sawLeading = true;
        leadingBuffer.write(s.content);
        if (s.appendNewline) leadingBuffer.write('\n');
        continue;
      }
      // Flush the leading system turn the first time we hit a non-leading
      // segment, so it always lands first (matches the old code, which built
      // the whole buffer before touching `turns`).
      if (sawLeading) {
        turns.add(ChatTurn('system', leadingBuffer.toString().trim()));
        sawLeading = false;
      }
      turns.add(ChatTurn(s.role, s.content, imageDataUrls: s.imageDataUrls));
    }
    if (sawLeading) {
      turns.add(ChatTurn('system', leadingBuffer.toString().trim()));
    }
    return turns;
  }
}
