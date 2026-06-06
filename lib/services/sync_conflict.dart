// Mega-audit 2026-06-05 (H-4): sync conflict detection + resolution.
//
// The LAN sync model is whole-record last-writer-wins (LWW): on a /pull the
// engine replaces a local record with an incoming one iff `incoming.mtime >
// local.mtime`. That is correct for a one-sided edit (only one device touched
// the record) but SILENTLY drops one side when BOTH devices edited the same
// record since the last successful sync — a genuine divergence. The owner asked
// for (a) an opt-in setting choosing which side prevails, and (b) a warning
// shown BEFORE applying anything when a real conflict is detected.
//
// This module is PURE (no AppStore, no I/O, no Flutter) so the detection +
// decision logic is unit-testable in isolation. The sync engine wires it in:
// it builds [SyncRecordRef]s for the local + incoming records, calls
// [detectSyncConflicts] with the last-sync watermark, then for each incoming
// record consults [resolveConflictDecision] to decide whether to apply it.
//
// IMPORTANT: per-record resolution for a Chat still replaces the WHOLE chat
// (its entire message array) — there is no per-message merge here. The win in
// this wave is that the resolution is USER-CHOSEN and WARNED, not silent.
// Per-message (and per-lorebook-entry) merge is a deeper future enhancement.

import '../models/models.dart';

/// A minimal, transport-agnostic view of one synced record: enough to detect a
/// conflict (id + mtime) and to describe it to the user (kind + name). Built
/// for both the LOCAL copy and the INCOMING (peer) copy of the same id.
class SyncRecordRef {
  /// Collection kind, singular — `character`, `persona`, `chat`, `preset`,
  /// `lorebook`, `regexRule`, `folder`, `creatorPreset`, `provider`.
  final String kind;
  final String id;
  final int mtime;

  /// Human-friendly label for the warning dialog (e.g. the character's name,
  /// the chat title). Best-effort; never used in the conflict decision itself.
  final String name;

  /// True when this side is a deletion (tombstone) rather than a live edit.
  /// A delete-vs-edit divergence is still a conflict the user should see.
  final bool deleted;

  const SyncRecordRef({
    required this.kind,
    required this.id,
    required this.mtime,
    this.name = '',
    this.deleted = false,
  });
}

/// One detected conflict: the SAME id changed on BOTH sides since the last
/// successful sync. Carries both refs so the UI can show type + name + which
/// side is newer.
class SyncConflict {
  final String kind;
  final String id;
  final SyncRecordRef local;
  final SyncRecordRef remote;

  const SyncConflict({
    required this.kind,
    required this.id,
    required this.local,
    required this.remote,
  });

  /// True when the REMOTE (peer) copy has the newer mtime. Ties resolve to
  /// "local is newer-or-equal" (false), matching the engine's `>=`-skips LWW.
  bool get remoteIsNewer => remote.mtime > local.mtime;

  /// A short, user-readable description of which side is newer, for the dialog.
  String get newerSideLabel => remoteIsNewer ? 'Other device' : 'This device';
}

/// PURE conflict detector. Given the LOCAL records, the INCOMING (remote)
/// records, and the watermark [lastSyncAt] (the `since` the engine pulled
/// with), return the records where BOTH sides changed since the watermark —
/// i.e. `local.mtime > lastSyncAt AND remote.mtime > lastSyncAt` for the same
/// id. That is genuine divergence; a normal one-sided edit (only one side past
/// the watermark) is NOT a conflict and is excluded.
///
/// Notes:
///   * A record present on only one side is never a conflict (the other side
///     has nothing to diverge from).
///   * Delete-vs-edit IS surfaced: a tombstone whose mtime is past the
///     watermark on one side and a live edit past the watermark on the other
///     both qualify (both `mtime > lastSyncAt`). The [SyncRecordRef.deleted]
///     flag lets the UI phrase it as "deleted on one device".
///   * Order of the returned list follows the iteration of [local] (stable for
///     a given input), so the dialog ordering is deterministic.
List<SyncConflict> detectSyncConflicts(
  List<SyncRecordRef> local,
  List<SyncRecordRef> remote,
  int lastSyncAt,
) {
  if (local.isEmpty || remote.isEmpty) return const [];
  // Index remote by id for O(1) pairing. Last-one-wins on duplicate ids in the
  // (malformed) input, which is harmless for detection.
  final remoteById = <String, SyncRecordRef>{};
  for (final r in remote) {
    remoteById[r.id] = r;
  }
  final out = <SyncConflict>[];
  for (final l in local) {
    final r = remoteById[l.id];
    if (r == null) continue; // one-sided: only local has it.
    // Both must have changed strictly AFTER the watermark to be a conflict.
    if (l.mtime > lastSyncAt && r.mtime > lastSyncAt) {
      out.add(SyncConflict(kind: l.kind, id: l.id, local: l, remote: r));
    }
  }
  return out;
}

/// The decision for applying ONE incoming record that is in conflict, under a
/// given [mode]. Returns true to APPLY the incoming (peer) record, false to
/// KEEP the local one. Only ever consulted for records that [detectSyncConflicts]
/// flagged — non-conflicting records always merge by normal LWW upstream.
///
///   * [SyncConflictMode.newestWins]      → apply iff the peer is strictly
///                                           newer (`>` — ties keep local, same
///                                           as the engine's `>=`-skips LWW).
///   * [SyncConflictMode.preferThisDevice]→ never apply (local always wins).
///   * [SyncConflictMode.preferOtherDevice]→ always apply (peer always wins).
///   * [SyncConflictMode.ask]             → resolved by the user's per-pull
///                                           choice, passed in via [askChoice]
///                                           (true = take other device). When
///                                           [askChoice] is null (no decision
///                                           yet / dialog dismissed) we DO NOT
///                                           apply — the caller aborts the apply
///                                           rather than silently LWW-ing.
bool resolveConflictDecision(
  SyncConflict conflict,
  SyncConflictMode mode, {
  bool? askChoice,
}) {
  switch (mode) {
    case SyncConflictMode.newestWins:
      return conflict.remote.mtime > conflict.local.mtime;
    case SyncConflictMode.preferThisDevice:
      return false;
    case SyncConflictMode.preferOtherDevice:
      return true;
    case SyncConflictMode.ask:
      // No user decision available ⇒ don't apply (caller aborts).
      return askChoice ?? false;
  }
}
