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
// MVP simplification (documented): a block's `role` is preserved on the model
// for import fidelity / display, but assembly here treats ALL enabled blocks
// as TEXT and joins them into the system / post-history slots. It does NOT yet
// inject user/assistant-role blocks as separate chat turns, nor honour ST
// in-chat depth injection. This covers the dominant "toggle system modules"
// case; per-turn roles are a future enhancement.

import '../models/models.dart';

/// The two assembled text slots a preset contributes to the chat prompt.
class AssembledPreset {
  /// System prompt sent BEFORE the chat history.
  final String systemPrompt;

  /// Instructions appended AFTER the chat history (jailbreak / reminder /
  /// prefill).
  final String postHistory;

  const AssembledPreset({
    required this.systemPrompt,
    required this.postHistory,
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

  // MODULAR PATH. `role` is intentionally NOT consulted here (see file header).
  final before = <String>[];
  final after = <String>[];
  for (final b in p.promptBlocks) {
    if (!b.enabled) continue;
    // Skip empty content so we never join "" and create a double gap.
    if (b.content.isEmpty) continue;
    switch (b.position) {
      case PromptBlockPosition.beforeHistory:
        before.add(b.content);
        break;
      case PromptBlockPosition.afterHistory:
        after.add(b.content);
        break;
    }
  }
  return AssembledPreset(
    systemPrompt: before.join('\n\n'),
    postHistory: after.join('\n\n'),
  );
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
