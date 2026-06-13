// Pyre 1.1 (Prompt Manager) — pure preset assembly.
//
// A [Preset] is either FLAT (its `mainPrompt` + `postHistoryInstructions`
// fields, every preset before 1.1) or MODULAR (a list of toggleable
// [PromptBlock]s). This module turns either shape into the two text slots the
// chat prompt builder consumes: the system prompt sent BEFORE the chat history
// and the post-history instructions sent AFTER it.
//
// THE INVARIANT: a preset with NO blocks must assemble to its raw
// `mainPrompt` / `postHistoryInstructions` BYTE-IDENTICALLY. The whole feature
// is additive and rides on this — the prompt-lab golden suite is the backstop.
//
// Role + depth ARE honoured (Prompt Manager Core): a block with role 'user' or
// 'assistant' becomes a separate chat TURN (not flattened to system text), and
// a block with an explicit `depth` is injected into the history at that depth.
// Only `role:'system'`, no-depth blocks join the text slots. The byte-identical
// invariant still holds for the common all-system / flat case.

import '../models/models.dart';

/// What a preset contributes to the chat prompt: two TEXT slots (system /
/// post-history, for `role:'system'` no-depth blocks) plus role-split + depth
/// TURNS.
class AssembledPreset {
  /// System prompt sent BEFORE the chat history.
  final String systemPrompt;

  /// Instructions appended AFTER the chat history (jailbreak / reminder /
  /// prefill).
  final String postHistory;

  /// `role:'user'/'assistant'` no-depth blocks placed BEFORE history, in order.
  final List<({String role, String content})> beforeTurns;

  /// `role:'user'/'assistant'` no-depth blocks placed AFTER history, in order.
  final List<({String role, String content})> afterTurns;

  /// Blocks with an explicit `depth` — injected as a turn `depth` messages from
  /// the END of the chat history (any role). In list order.
  final List<({int depth, String role, String content})> depthTurns;

  const AssembledPreset({
    required this.systemPrompt,
    required this.postHistory,
    this.beforeTurns = const [],
    this.afterTurns = const [],
    this.depthTurns = const [],
  });
}

/// Resolve [p] into its system-prompt / post-history text slots.
///
/// Flat preset (no blocks) → returns `(p.mainPrompt, p.postHistoryInstructions)`
/// EXACTLY (byte-identical, including empty strings).
///
/// Modular preset → enabled `beforeHistory` blocks' `content` joined in LIST
/// ORDER by `'\n\n'` form the system prompt; enabled `afterHistory` blocks the
/// post-history. Disabled blocks are excluded. Empty-content blocks are skipped
/// so they never produce a stray `'\n\n\n\n'` gap. An empty result is the empty
/// string.
AssembledPreset assemblePreset(Preset p) {
  if (p.promptBlocks.isEmpty) {
    // FLAT PATH — byte-identical to pre-1.1. Do NOT trim/normalise.
    return AssembledPreset(
      systemPrompt: p.mainPrompt,
      postHistory: p.postHistoryInstructions,
    );
  }

  // MODULAR PATH. Classify each enabled, non-empty block by role + depth.
  final before = <String>[];
  final after = <String>[];
  final beforeTurns = <({String role, String content})>[];
  final afterTurns = <({String role, String content})>[];
  final depthTurns = <({int depth, String role, String content})>[];
  for (final b in p.promptBlocks) {
    if (!b.enabled) continue;
    // Skip empty content so we never join "" and create a double gap.
    if (b.content.isEmpty) continue;
    final role = _normRole(b.role);
    // Depth overrides position: an explicit depth makes it an in-chat turn.
    if (b.depth != null) {
      depthTurns.add((depth: b.depth!, role: role, content: b.content));
      continue;
    }
    final isSystem = role == 'system';
    switch (b.position) {
      case PromptBlockPosition.beforeHistory:
        if (isSystem) {
          before.add(b.content);
        } else {
          beforeTurns.add((role: role, content: b.content));
        }
        break;
      case PromptBlockPosition.afterHistory:
        if (isSystem) {
          after.add(b.content);
        } else {
          afterTurns.add((role: role, content: b.content));
        }
        break;
    }
  }
  return AssembledPreset(
    systemPrompt: before.join('\n\n'),
    postHistory: after.join('\n\n'),
    beforeTurns: beforeTurns,
    afterTurns: afterTurns,
    depthTurns: depthTurns,
  );
}

/// Normalise a block role to `'system' | 'user' | 'assistant'`. Anything else
/// (empty / unknown / legacy) → `'system'` so it safely flattens to text.
String _normRole(String role) {
  final r = role.toLowerCase();
  return (r == 'user' || r == 'assistant') ? r : 'system';
}

/// H-8: does this preset support the in-chat "Quick edit system prompt"
/// affordance?
///
/// That quick-edit writes [Preset.mainPrompt], but [assemblePreset] IGNORES
/// `mainPrompt` for MODULAR presets (it assembles from `promptBlocks`). So for
/// a modular preset the quick-edit is a silent no-op — the user edits, sees a
/// "Saved" toast, and the next message is byte-identical. Gate the affordance
/// on this predicate: it is supported ONLY for FLAT presets (no blocks), where
/// `mainPrompt` is the value actually sent. Modular presets are edited in the
/// Presets screen (block editor).
bool presetSupportsMainPromptQuickEdit(Preset p) => p.promptBlocks.isEmpty;
