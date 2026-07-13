// Deterministic fingerprints over a chat's message list, shared by the memory
// (checkpoint recap) and Live Sheet services so their branch/content validity
// can NEVER drift apart.
//
// TWO orthogonal fingerprints (audit round 12/14 CRITICAL context-loss fix):
//   - pathHash    — WHICH branch (the sequence of selectedVariant choices).
//   - contentHash — WHAT the covered messages SAY (their text/kind/visibility).
//
// A snapshot (memory checkpoint / Live Sheet) is valid only if BOTH match the
// current chat. pathHash alone missed in-place edits + Continue (same message
// id, same selected variant → same pathHash) so a stale recap/state kept being
// injected as truth. contentHash closes that: editing the covered text changes
// the hash → the stale snapshot is dropped and regenerated.
//
// BACK-COMPAT: a snapshot persisted before this fix has an EMPTY contentHash and
// is treated as content-valid (never invalidated on upgrade — see the callers).
// We deliberately do NOT strip <think> / apply effective-history here: the
// fingerprint represents the PERSISTED covered state, not a prompt projection,
// so it invalidates conservatively on any real edit.

import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' show sha256;

import '../models/models.dart';

/// Deterministic branch fingerprint over the messages from index 0 up to and
/// including [upToIdx]. Encodes the SEQUENCE of variant choices that landed us
/// on this branch — two branches share a prefix iff they share the same path
/// through the variant tree up to that point. (Moved here from memory.dart in
/// the round-12/14 fix; memory.dart re-exports it so existing imports hold.)
String computePathHash(List<Message> messages, int upToIdx) {
  // Hard-guard against the empty-messages collision with the legacy "no-path"
  // sentinel (Wave CY.18.24). An empty chat / upToIdx < 0 used to return "" —
  // indistinguishable from the migration sentinel (pathHash == "" = always
  // valid). Return a deterministic non-empty value so the sentinel stays unique.
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

/// Canonical per-message fingerprint fed into the content hash. Length-prefixed
/// fields (not raw concatenation) so no two distinct messages can collide via a
/// delimiter in their text. Covers exactly what a covered-message edit can
/// change: id, kind, the SELECTED variant index + its raw text, and the
/// greeting-variant binding (a visibility flag). Editing a NON-selected variant
/// doesn't touch `text`/`selectedVariant`, so it correctly doesn't invalidate.
String _msgFingerprint(Message m) {
  final id = m.id;
  final text = m.text; // selected variant's raw text
  return 'i${id.length}:$id'
      '|k:${m.kind.name}'
      '|v:${m.selectedVariant}'
      '|g:${m.greetingVariant ?? -1}'
      '|t${text.length}:$text';
}

/// One step of the chained content hash: `h_i = sha256(h_{i-1} ␞ msgFp_i)`.
/// A chain (not a hash of one big concatenation) is what lets
/// [computeContentHashesAtAnchors] emit every prefix hash in a single pass.
String _chain(String running, String msgFingerprint) =>
    sha256.convert(utf8.encode('$running\x1e$msgFingerprint')).toString();

/// Content fingerprint of the covered prefix `0..upToIdx` (inclusive). Changes
/// iff the text/kind/selected-variant/visibility of any covered message changes
/// (incl. Continue, which rewrites the selected variant's text). Equal to
/// [computeContentHashesAtAnchors] evaluated at the same in-range anchor.
String computeContentHash(List<Message> messages, int upToIdx) {
  if (upToIdx < 0 || messages.isEmpty) return '__empty__';
  final last = upToIdx.clamp(0, messages.length - 1);
  var running = '';
  for (var i = 0; i <= last; i++) {
    running = _chain(running, _msgFingerprint(messages[i]));
  }
  return running;
}

/// Content hashes at many anchors in ONE pass (avoids the O(N×K) re-hash of
/// `0..anchor` per checkpoint that [computeContentHash] called K times would
/// cost). Walks `0..maxAnchor` once, snapshotting the running chain at each
/// requested in-range anchor. Anchors out of range map to the `__empty__`
/// sentinel (callers already skip out-of-range anchors before validating).
Map<int, String> computeContentHashesAtAnchors(
    List<Message> messages, Iterable<int> anchors) {
  final out = <int, String>{};
  final wanted = anchors.toSet();
  if (wanted.isEmpty) return out;
  final inRange = <int>{};
  for (final a in wanted) {
    if (a >= 0 && a < messages.length) {
      inRange.add(a);
    } else {
      out[a] = '__empty__';
    }
  }
  if (inRange.isEmpty) return out;
  final maxA = inRange.reduce((a, b) => a > b ? a : b);
  var running = '';
  for (var i = 0; i <= maxA; i++) {
    running = _chain(running, _msgFingerprint(messages[i]));
    if (inRange.contains(i)) out[i] = running;
  }
  return out;
}
