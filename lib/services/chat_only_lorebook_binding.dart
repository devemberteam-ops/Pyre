// Pure diff-computation for the "Edit (this chat only)" character editor's
// lorebook-binding section.
//
// Audit (state-order, 1.2.1 batch D, finding #1): the injection engine
// (`collectBoundLorebooks`, lorebook_inject.dart) reads a character's
// lorebook BINDINGS live-first from the library character, falling back to
// the chat's frozen snapshot only when the library card has since been
// deleted. That's deliberate — bindings are live config, not frozen
// narrative content. But the per-chat character editor used to write binding
// edits straight into the frozen snapshot's `lorebookIds`, which the engine
// then ignored outright (the library character still exists, so the live
// read always won). The user's "for this chat only" binding edit silently
// did nothing.
//
// THE FIX: per-chat binding edits are expressed through the chat's own
// per-chat sets, which the engine already honours:
//   - `chat.attachedLorebookIds`            (per-chat ADDITIVE — always on)
//   - `chat.disabledInheritedLorebookIds`   (suppresses inherited bindings)
//
// This function is pure (no BuildContext / AppStore) so it's directly unit
// testable; the widget only supplies the live binding list + the user's
// edited list and this computes (and applies) the diff.

import '../models/models.dart';

/// Applies a per-chat-only lorebook binding edit onto [chat]'s per-chat
/// lorebook sets (mutates `chat.attachedLorebookIds` and
/// `chat.disabledInheritedLorebookIds` in place). Does NOT touch
/// `chat.characterSnapshots[...].lorebookIds` — the snapshot's binding list
/// is left exactly as it was; the engine ignores it for a still-live
/// character, so writing it would be pure noise (and worse, would look
/// self-consistent in a stale read).
///
/// [liveBindings] — the CURRENT effective source's `lorebookIds` (the LIVE
/// library character when it still exists, else the frozen snapshot — same
/// resolution `collectBoundLorebooks` uses for `lookupCharacter(cid) ??
/// chat.characterSnapshots[cid]`).
/// [editedList] — the list the user ended up with in the binding editor
/// (which should have been SEEDED from the effective per-chat state — live
/// bindings minus disabled, plus attached — so this diff only sees what
/// actually changed).
///
/// Diff rules:
///   - id in both live and edited            → NOT disabled (re-enabled if
///     it had been disabled before).
///   - id in live but NOT in edited           → added to
///     `disabledInheritedLorebookIds` (suppress the inherited binding).
///   - id in edited but NOT in live           → added to
///     `attachedLorebookIds` (a per-chat-only addition).
///   - id no longer in edited (regardless of live-ness) → removed from
///     `attachedLorebookIds` if it was there. `attachedLorebookIds` is
///     always-additive in the engine (never filtered by `disabled`), so a
///     removed id must be dropped from it directly, not merely disabled.
void applyChatOnlyBindingEdit(
  Chat chat,
  List<String> liveBindings,
  List<String> editedList,
) {
  final live = liveBindings.toSet();
  final edited = editedList.toSet();
  final attached = chat.attachedLorebookIds.toSet();
  final disabled = chat.disabledInheritedLorebookIds.toSet();

  // Live binding the user turned off → suppress via disabledInherited.
  for (final id in live.difference(edited)) {
    disabled.add(id);
  }
  // Live binding the user kept (or re-added) → make sure it's not
  // suppressed.
  for (final id in live.intersection(edited)) {
    disabled.remove(id);
  }
  // Non-live id the user added → per-chat attach.
  for (final id in edited.difference(live)) {
    attached.add(id);
  }
  // Any previously-attached id no longer in the edited list → drop the
  // attachment (attachedLorebookIds is always-additive, so leaving it there
  // would keep injecting regardless of `disabled`).
  attached.removeWhere((id) => !edited.contains(id));

  chat.attachedLorebookIds = attached.toList();
  chat.disabledInheritedLorebookIds = disabled.toList();
}
