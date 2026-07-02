// Live Sheet — pure functions + LLM orchestration (Wave CY.18.171-172).

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../models/models.dart';
import 'chat_api.dart';
import 'memory.dart' show computePathHash;

// ---------------------------------------------------------------------------
// LS-2 fix: service-level in-flight lock (mirrors memory.dart's C1 /
// `_checkpointInFlight`).
// ---------------------------------------------------------------------------

/// Per-chat in-flight lock for the Live Sheet update/seed pipeline.
///
/// Keyed by chat id. A value of `true` means a [generateLiveSheetUpdate] or
/// [seedLiveSheetEntity] call is currently in progress for that chat.
///
/// This is the **service-level** guard for the same class of bug memory.dart's
/// C1 fixed: before this, `chat_screen.dart`'s `_liveSheetUpdating` and
/// `live_sheet_screen.dart`'s `_updating` were two INDEPENDENT widget-local
/// latches that can't see each other — a background auto-update (chat_screen)
/// and a manual "Update state now" (live_sheet_screen) could both read the
/// same base snapshot and apply two divergent deltas concurrently.
///
/// Both call sites now honour the sentinel return value: a null return while
/// the lock is held is indistinguishable from "no change" to the immediate
/// caller by design (mirrors memory.dart) — use [isLiveSheetInFlight] to tell
/// "already running" apart from "LLM error / no change" when that matters.
final Map<String, bool> _liveSheetInFlight = {};

/// Returns true while a [generateLiveSheetUpdate] or [seedLiveSheetEntity]
/// call is in progress for [chatId].
bool isLiveSheetInFlight(String chatId) => _liveSheetInFlight[chatId] == true;

/// TEST SEAM — forcibly marks [chatId] as in-flight or clears it. Only used in
/// unit tests to verify the LS-2 concurrent-call guard without spinning up a
/// real LLM call.
@visibleForTesting
void setLiveSheetInFlightForTest(String chatId, {required bool inFlight}) {
  if (inFlight) {
    _liveSheetInFlight[chatId] = true;
  } else {
    _liveSheetInFlight.remove(chatId);
  }
}

/// TEST SEAM — clears ALL in-flight state. Call in setUp/tearDown so lock
/// state from one test never leaks into the next.
@visibleForTesting
void clearAllLiveSheetInFlightForTest() => _liveSheetInFlight.clear();

// ---------------------------------------------------------------------------
// Wave CY.18.218: narrator/scenario card detection
// ---------------------------------------------------------------------------

/// True when [c]'s description signals a NARRATOR / scenario card (an
/// omniscient narrator with no body), rather than a bodied character.
///
/// Scenarios ARE characters in Pyre (there is no explicit scenario flag), so
/// this is a description heuristic. Such cards must NOT be seeded into the
/// Live Sheet as a physical entity — doing so makes the model hallucinate a
/// body for the narrator (live-test 2026-05-31).
///
/// Detection is case-insensitive and matches any of the robust markers a
/// narrator card's description uses: the `<Narrator>` XML section, the phrase
/// "is not a character", or "omniscient narrator".
bool isNarratorCard(Character c) {
  final d = c.description.toLowerCase();
  if (d.isEmpty) return false;
  return d.contains('<narrator>') ||
      d.contains('is not a character') ||
      d.contains('omniscient narrator');
}

// ---------------------------------------------------------------------------
// TASK 6: LiveSheetDelta + parseLiveSheetDelta
// ---------------------------------------------------------------------------

class LiveSheetDeltaOp {
  final String entityName;
  final LiveSheetSection section;
  final String text;
  final bool isAdd;
  LiveSheetDeltaOp(this.entityName, this.section, this.text, this.isAdd);
}

class LiveSheetDelta {
  final bool noChange;
  final List<LiveSheetDeltaOp> ops;
  LiveSheetDelta(this.noChange, this.ops);
}

final RegExp _lsStripLead = RegExp(r'^[\s>*#`\-•]*');
final RegExp _lsEntityLine =
    RegExp(r'ENTITY\s*:\s*(.+?)\s*$', caseSensitive: false);
final RegExp _lsOpLine = RegExp(r'^\s*([+\-~])\s*(.+?)\s*:\s*(.+)\s*$');

LiveSheetDelta parseLiveSheetDelta(String raw) {
  final ops = <LiveSheetDeltaOp>[];
  var sawNoChange = false;
  String? current;

  for (final lineRaw in raw.split('\n')) {
    final line = lineRaw.trim();
    if (line.isEmpty) continue;

    // Check for NO_CHANGE (strip all non-alpha/underscore before comparing)
    final bare = line.replaceAll(RegExp(r'[^A-Za-z]'), '').toUpperCase();
    if (bare == 'NOCHANGE') {
      sawNoChange = true;
      continue;
    }

    // Strip leading markdown noise + asterisks to detect ENTITY lines
    final cleaned =
        line.replaceFirst(_lsStripLead, '').replaceAll('*', '').trim();
    final em = _lsEntityLine.firstMatch(cleaned);
    if (em != null) {
      current = em.group(1)!.trim();
      continue;
    }

    // Parse op lines against the raw line (preserves +/- sign position)
    final om = _lsOpLine.firstMatch(line);
    if (om == null || current == null) continue;

    final sign = om.group(1)!;
    // Strip markdown bold asterisks from the section label
    final sectionRaw = om.group(2)!.replaceAll('*', '').trim();
    final text = om.group(3)!.trim();

    final section = liveSheetSectionFromLabel(sectionRaw);
    if (section == null || text.isEmpty) continue;

    ops.add(LiveSheetDeltaOp(current, section, text, sign != '-'));
  }

  return LiveSheetDelta(sawNoChange && ops.isEmpty, ops);
}

// ---------------------------------------------------------------------------
// TASK 7: applyLiveSheetDelta (lock-respecting, no auto-create)
// ---------------------------------------------------------------------------

String _lsNorm(String s) => s.trim().toLowerCase();

/// Strips a single trailing parenthetical (e.g. `" (the user / {{user}})"`)
/// from an entity name a model may have echoed back decorated.
final RegExp _lsTrailingParen = RegExp(r'\s*\(.*\)\s*$');

/// Tokens/markers that unambiguously refer to the user entity even when the
/// model invents/aliases a name instead of echoing the stored one.
const Set<String> _lsUserAliases = {'you', '{{user}}', 'user', 'the user'};

/// Resolves the existing entity an op targets, or null if none matches (null →
/// the caller's auto-create-or-skip path). Wave CY.18.244. Order, stable:
///   1. exact normalized-name match against an existing entity;
///   2. same match after stripping a trailing parenthetical from the op name;
///   3. user-intent fallback: if the (stripped) op name equals an existing
///      user-kind entity's name, OR is a known user alias / contains
///      "the user" / "{{user}}", map to the existing user-kind entity;
///   4. (handled by the caller) auto-create as NPC.
LiveSheetEntity? _resolveOpEntity(
    List<LiveSheetEntity> entities, LiveSheetDeltaOp op) {
  // 1. exact normalized-name match
  final target = _lsNorm(op.entityName);
  for (final e in entities) {
    if (_lsNorm(e.name) == target) return e;
  }

  // 2. strip a trailing parenthetical, retry exact match
  final stripped = _lsNorm(op.entityName.replaceFirst(_lsTrailingParen, ''));
  if (stripped != target) {
    for (final e in entities) {
      if (_lsNorm(e.name) == stripped) return e;
    }
  }

  // 3. user-intent fallback → map to the existing user-kind entity (if any)
  final user = entities
      .where((e) => e.kind == LiveSheetEntityKind.user)
      .cast<LiveSheetEntity?>()
      .firstWhere((_) => true, orElse: () => null);
  if (user != null) {
    if (_lsNorm(user.name) == stripped ||
        _lsUserAliases.contains(stripped) ||
        _lsUserAliases.contains(target) ||
        target.contains('the user') ||
        target.contains('{{user}}')) {
      return user;
    }
  }

  // 4. no match — caller decides (auto-create on add, skip on remove)
  return null;
}

LiveSheetSnapshot applyLiveSheetDelta({
  required LiveSheetSnapshot prev,
  required LiveSheetDelta delta,
  required String anchorMessageId,
  required String pathHash,
}) {
  final next = prev.clone()
    ..id = newId('lss')
    ..anchorMessageId = anchorMessageId
    ..pathHash = pathHash
    ..createdAt = DateTime.now().millisecondsSinceEpoch
    ..mtime = DateTime.now().millisecondsSinceEpoch;

  for (final op in delta.ops) {
    // Wave CY.18.244: resilient resolve (exact → strip-paren → user-intent)
    // so a decorated/aliased name maps to the existing entity (esp. the user)
    // instead of duplicating it.
    var entity = _resolveOpEntity(next.entities, op);
    if (entity == null) {
      // Wave CY.18.219: auto-create an entity for an ADD op naming a
      // character not yet tracked (a newly-prominent NPC). A `-`/remove op for
      // an unknown entity is still a no-op (nothing to remove).
      if (!op.isAdd) continue;
      // Audit 2026-06-04 (Low): store the paren-stripped name so a later bare
      // reference ("Bob") resolves to this entity (via _resolveOpEntity step 2)
      // instead of auto-creating a second "Bob" when the first op arrived
      // decorated ("Bob (the guard)").
      final newName =
          op.entityName.replaceFirst(_lsTrailingParen, '').trim();
      entity = LiveSheetEntity(
        id: newId('lse'),
        name: newName.isEmpty ? op.entityName : newName,
        kind: LiveSheetEntityKind.npc,
      );
      next.entities.add(entity);
    }

    final list = entity.sections[op.section]!;
    if (op.isAdd) {
      // Dedup by normalized text
      if (!list.any((f) => _lsNorm(f.text) == _lsNorm(op.text))) {
        list.add(LiveSheetFact(text: op.text));
      }
    } else {
      // Remove only unlocked matching facts
      list.removeWhere(
          (f) => !f.locked && _lsNorm(f.text) == _lsNorm(op.text));
    }
  }

  return next;
}

// ---------------------------------------------------------------------------
// TASK 8: activeLiveSheetSnapshot (branch-aware, ID→index)
// ---------------------------------------------------------------------------

int _lsAnchorIdx(Chat chat, LiveSheetSnapshot s) =>
    chat.messages.indexWhere((m) => m.id == s.anchorMessageId);

LiveSheetSnapshot? activeLiveSheetSnapshot(Chat chat) {
  if (chat.liveSheetSnapshots.isEmpty) return null;

  LiveSheetSnapshot? best;
  int bestIdx = -1;

  for (final s in chat.liveSheetSnapshots) {
    final idx = _lsAnchorIdx(chat, s);
    if (idx < 0) continue;

    // Empty pathHash = legacy/manual sentinel → always valid
    if (s.pathHash.isNotEmpty &&
        s.pathHash != computePathHash(chat.messages, idx)) {
      continue;
    }

    // `>=` so that when two snapshots share an anchor index the LATER-appended
    // one wins. Relies on liveSheetSnapshots being append-only (seeder + updates
    // always add to the end) — do not insert snapshots mid-list.
    if (idx >= bestIdx) {
      bestIdx = idx;
      best = s;
    }
  }

  return best;
}

/// Cap on how many Live Sheet snapshots we retain per chat. Each snapshot is a
/// deep clone of the full tracked state; on a long chat the append-only list
/// accumulates dozens of full-state blobs that serialize on every persist,
/// sync and backup. Bound it going forward: keep the most-recent [_kMaxSnapshots]
/// (by append order) so the cost stays flat.
const int _kMaxSnapshots = 40;

/// Appends [snap] to the chat's snapshot list and prunes it back to
/// [_kMaxSnapshots], oldest-first. CAP LOGIC, deliberately conservative:
///   • snapshots are append-only (seeder + updates always add to the end), so
///     the OLDEST entries sit at the FRONT — drop from there;
///   • [activeLiveSheetSnapshot] picks the highest-in-range anchor (newest
///     valid), so dropping the oldest never strands the active selection in the
///     common forward-chat case; AND
///   • as a belt-and-suspenders guard against branching (where the active
///     anchor can be an EARLIER message), we resolve the active snapshot
///     AFTER appending and NEVER drop it — if removing the oldest would remove
///     the active one, we skip it and remove the next-oldest instead.
/// Net: the list never exceeds [_kMaxSnapshots] unless the active snapshot is
/// older than every one of the most-recent N (extremely unlikely), in which
/// case we keep it plus the newest N-1 — correctness over the hard cap.
void appendLiveSheetSnapshot(Chat chat, LiveSheetSnapshot snap) {
  chat.liveSheetSnapshots.add(snap);
  if (chat.liveSheetSnapshots.length <= _kMaxSnapshots) return;

  final active = activeLiveSheetSnapshot(chat);
  // Remove oldest-first until at the cap, skipping the active snapshot.
  var i = 0;
  while (chat.liveSheetSnapshots.length > _kMaxSnapshots &&
      i < chat.liveSheetSnapshots.length) {
    final candidate = chat.liveSheetSnapshots[i];
    if (active != null && candidate.id == active.id) {
      i++; // never drop the active one — try the next oldest
      continue;
    }
    chat.liveSheetSnapshots.removeAt(i);
    // do not advance i — the next element shifts into this slot
  }
}

// ---------------------------------------------------------------------------
// TASK 9: turnsSinceActiveSnapshot + shouldUpdateLiveSheet
// ---------------------------------------------------------------------------

int turnsSinceActiveSnapshot(Chat chat) {
  final active = activeLiveSheetSnapshot(chat);
  final anchorIdx = active == null ? -1 : _lsAnchorIdx(chat, active);
  var count = 0;
  for (var i = anchorIdx + 1; i < chat.messages.length; i++) {
    if (chat.messages[i].kind == MessageKind.char) count++;
  }
  return count;
}

bool shouldUpdateLiveSheet(Chat chat, LiveSheetSettings settings) {
  if (!chat.liveSheetEnabled) return false;
  if (settings.autoEvery <= 0) return false;
  if (activeLiveSheetSnapshot(chat) == null) return false;
  return turnsSinceActiveSnapshot(chat) >= settings.autoEvery;
}

/// Wave CY.18.245: true iff there is an active snapshot AND at least one
/// message exists AFTER its anchor — i.e. [generateLiveSheetUpdate] would have
/// something to diff. Mirrors the exact guards in that function (`cutoffIdx`
/// vs `anchorIdx`) so the UI's branch matches what the engine would actually
/// do. When this is false, a manual "Update state now" has no new messages to
/// summarize and should populate from existing history instead.
bool liveSheetHasNewMessages(Chat chat) {
  final active = activeLiveSheetSnapshot(chat);
  if (active == null) return false;
  final cutoffIdx = chat.messages.length - 1;
  if (cutoffIdx < 0) return false;
  final anchorIdx =
      chat.messages.indexWhere((m) => m.id == active.anchorMessageId);
  return cutoffIdx > anchorIdx;
}

// ---------------------------------------------------------------------------
// TASK 10: buildLiveSheetBlock
// ---------------------------------------------------------------------------

const _kLiveSheetHeader =
    '--- Current state (authoritative; this overrides the character sheet wherever '
    'they conflict; everything else in the sheet still applies) ---';
const _kLiveSheetFooter = '--- end current state ---';

String buildLiveSheetBlock(Chat chat) {
  if (!chat.liveSheetEnabled) return '';
  final active = activeLiveSheetSnapshot(chat);
  if (active == null) return '';

  final buf = StringBuffer();
  var rendered = 0;

  for (final e in active.entities) {
    if (!e.hasAnyFact) continue;

    final header = e.kind == LiveSheetEntityKind.user
        ? '[${e.name}] (you)'
        : '[${e.name}]';

    final lines = <String>[];
    for (final s in LiveSheetSection.values) {
      final facts = e.sections[s]!;
      if (facts.isEmpty) continue;
      lines.add('- ${s.label}: ${facts.map((f) => f.text).join('; ')}');
    }
    if (lines.isEmpty) continue;

    buf.writeln(header);
    for (final l in lines) {
      buf.writeln(l);
    }
    rendered++;
  }

  if (rendered == 0) return '';
  return '$_kLiveSheetHeader\n${buf.toString().trimRight()}\n$_kLiveSheetFooter';
}

// ---------------------------------------------------------------------------
// TASK 11: parseSeedSheet
// ---------------------------------------------------------------------------

Map<LiveSheetSection, List<LiveSheetFact>> parseSeedSheet(String raw) {
  final out = {for (final s in LiveSheetSection.values) s: <LiveSheetFact>[]};

  for (final lineRaw in raw.split('\n')) {
    final line = lineRaw.trim();
    if (line.isEmpty) continue;

    final m = RegExp(r'^\s*[-*]?\s*(.+?)\s*:\s*(.+)\s*$').firstMatch(line);
    if (m == null) continue;

    final section =
        liveSheetSectionFromLabel(m.group(1)!.replaceAll('*', '').trim());
    final text = m.group(2)!.trim();

    if (section == null || text.isEmpty) continue;
    if (text.toLowerCase() == 'none' || text == '-') continue;

    // Dedup by normalized text (mirrors the add-dedup in applyLiveSheetDelta)
    if (out[section]!.any((f) => _lsNorm(f.text) == _lsNorm(text))) continue;
    out[section]!.add(LiveSheetFact(text: text));
  }

  return out;
}

// ---------------------------------------------------------------------------
// L1/L2 fix (2026-06-15): mergeSeedSections — lock-preserving seed merge
// ---------------------------------------------------------------------------

/// Merges [seeded] facts (from an LLM seed call via [parseSeedSheet]) into
/// [existing] entity sections, PRESERVING every locked fact.
///
/// Per-section semantics:
///   • Locked facts from [existing] are always kept, regardless of [seeded].
///   • Unlocked facts from [existing] are DISCARDED (the seed is a fresh
///     state description of the entity, so old unlocked facts are stale).
///   • Facts from [seeded] are appended AFTER the kept locked facts, but
///     only if they aren't already present by normalized text (dedup against
///     both locked survivors and each other).
///
/// Returns a fresh section map — neither input is mutated.
Map<LiveSheetSection, List<LiveSheetFact>> mergeSeedSections({
  required Map<LiveSheetSection, List<LiveSheetFact>> existing,
  required Map<LiveSheetSection, List<LiveSheetFact>> seeded,
}) {
  final result = <LiveSheetSection, List<LiveSheetFact>>{};
  for (final s in LiveSheetSection.values) {
    final existingFacts = existing[s] ?? [];
    final seededFacts = seeded[s] ?? [];

    // Keep every locked fact from existing (in order).
    final kept = existingFacts.where((f) => f.locked).map((f) => f.clone()).toList();

    // Build a dedup set from the locked survivors.
    final seen = {for (final f in kept) _lsNorm(f.text)};

    // Append seeded facts that aren't already represented.
    for (final f in seededFacts) {
      final norm = _lsNorm(f.text);
      if (!seen.contains(norm)) {
        seen.add(norm);
        // Seeded facts are unlocked by definition — the user can lock them
        // afterwards if they want to protect them from future deltas.
        kept.add(LiveSheetFact(text: f.text, locked: false));
      }
    }

    result[s] = kept;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Wave CY.18.172: error log + settings floor + orchestration helpers
// ---------------------------------------------------------------------------

/// In-memory error log for Live Sheet LLM failures (mirrors MemoryErrors).
/// Capped at 20 entries, newest first. Cleared by the UI via [clear].
class LiveSheetErrors {
  LiveSheetErrors._();
  static final List<String> log = [];
  static const int _max = 20;

  static void record(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[LiveSheet] $msg');
    log.insert(0, msg);
    if (log.length > _max) log.removeRange(_max, log.length);
  }

  static void clear() => log.clear();
}

/// Floor the maxTokens cap at 1024 for Live Sheet LLM calls — mirrors
/// _recapSettings in memory.dart. Never lowers a higher user value.
ModelSettings _liveSheetSettings(ModelSettings base) {
  if (base.maxTokens >= 1024) return base;
  return ModelSettings.fromJson(base.toJson())..maxTokens = 1024;
}

// ---------------------------------------------------------------------------
// TASK 13: buildUpdateBody (PURE)
// ---------------------------------------------------------------------------

/// Serializes the current snapshot state (with [LOCKED] tags) plus every
/// message since the anchor into a single body string for the update prompt.
String buildUpdateBody({required Chat chat, required LiveSheetSnapshot active}) {
  final buf = StringBuffer();
  buf.writeln('## Tracked entities and their CURRENT state:');
  for (final e in active.entities) {
    // Wave CY.18.244: keep the ENTITY label a BARE name so the model echoes it
    // verbatim in its delta ops. The "this is the user" hint is a SEPARATE
    // annotation line — folding it into the name decorated the user entity and
    // caused the update pass to mis-match (no exact-name hit) → duplicate the
    // user as a brand-new NPC.
    buf.writeln('ENTITY: ${e.name}');
    if (e.kind == LiveSheetEntityKind.user) {
      buf.writeln(
          '  (this entity is the user / {{user}} — when reporting changes for them, use the exact name "${e.name}")');
    }
    for (final s in LiveSheetSection.values) {
      final facts = e.sections[s]!;
      if (facts.isEmpty) continue;
      for (final f in facts) {
        buf.writeln('  ${s.label}: ${f.text}${f.locked ? '  [LOCKED]' : ''}');
      }
    }
  }
  buf.writeln();
  buf.writeln('## Most recent messages (report only significant, durable changes since the state above):');
  final anchorIdx = chat.messages.indexWhere((m) => m.id == active.anchorMessageId);
  for (var i = anchorIdx + 1; i < chat.messages.length; i++) {
    final m = chat.messages[i];
    final role = switch (m.kind) {
      MessageKind.user => 'User',
      MessageKind.char => 'Character',
      MessageKind.ooc => 'OOC',
      MessageKind.scene => 'Scene',
      MessageKind.system => 'System',
    };
    // chat-core-1-01: strip `<think>…</think>` from assistant bodies so model
    // reasoning never feeds the Live Sheet update source. Stored text keeps the
    // reasoning (per-message toggle); only character turns carry it.
    final text =
        m.kind == MessageKind.char ? stripStreamArtifacts(m.text) : m.text;
    buf.writeln('$role: $text');
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// TASK 14a: generateLiveSheetUpdate (orchestration)
// ---------------------------------------------------------------------------

/// Runs the LLM update pass for the current chat's active Live Sheet snapshot.
/// Returns the new snapshot if the LLM produced any ops, null otherwise (this
/// includes the LS-2 in-flight-lock sentinel — see [isLiveSheetInFlight] to
/// distinguish "already running" from "no change" / "LLM error").
/// Mirrors generateCheckpoint in memory.dart.
Future<LiveSheetSnapshot?> generateLiveSheetUpdate({
  required Chat chat,
  required ApiProvider provider,
  required ModelSettings settings,
  LiveSheetSettings? liveSheetSettings,
}) async {
  // LS-2: service-level per-chat lock. Both the auto path (chat_screen) and
  // the manual path (live_sheet_screen) call this function; their separate
  // per-widget `_liveSheetUpdating` / `_updating` latches can't see each
  // other. Acquiring here prevents a concurrent call from a DIFFERENT screen
  // from reading the same base snapshot and applying a divergent delta.
  if (_liveSheetInFlight[chat.id] == true) {
    return null;
  }
  _liveSheetInFlight[chat.id] = true;
  try {
    return await _generateLiveSheetUpdateBody(
      chat: chat,
      provider: provider,
      settings: settings,
      liveSheetSettings: liveSheetSettings,
    );
  } finally {
    _liveSheetInFlight.remove(chat.id);
  }
}

/// Internal body of [generateLiveSheetUpdate] — called only while the
/// per-chat lock is held.
Future<LiveSheetSnapshot?> _generateLiveSheetUpdateBody({
  required Chat chat,
  required ApiProvider provider,
  required ModelSettings settings,
  LiveSheetSettings? liveSheetSettings,
}) async {
  if (provider.baseUrl.isEmpty) return null;
  final active = activeLiveSheetSnapshot(chat);
  if (active == null) return null;
  final cutoffIdx = chat.messages.length - 1;
  if (cutoffIdx < 0) return null;
  final anchorIdx = chat.messages.indexWhere((m) => m.id == active.anchorMessageId);
  if (cutoffIdx <= anchorIdx) return null;
  // LS-1 (C2 race): snapshot the anchor message's ID + the cutoff message's ID
  // NOW — before the await — from the same message state buildUpdateBody reads
  // from. Re-indexing `chat.messages[cutoffIdx]` AFTER the await (the old code)
  // reused a stale index against a possibly-mutated list: if the user
  // edits/deletes/regenerates/branches during the 10-30s LLM call, that index
  // can throw (list shrank) or silently bind the new snapshot to the WRONG
  // anchor/pathHash (list changed shape but stayed long enough).
  final cutoffMessageId = chat.messages[cutoffIdx].id;
  final activeSnapshotId = active.id;
  final ls = liveSheetSettings ?? LiveSheetSettings();
  final turns = <ChatTurn>[
    ChatTurn('system', ls.updatePrompt),
    ChatTurn('user', buildUpdateBody(chat: chat, active: active)),
  ];
  try {
    final out = await completeChatStreamed(
      provider: provider,
      settings: _liveSheetSettings(settings),
      messages: turns,
      debugTag: 'livesheet', // Wave CY.18.214 diagnostics tag
      // LS-3: a reasoning-only model (the owner's Venice/Qwen daily driver)
      // emits its whole answer in the `<think>` channel; without this the
      // stripped visible content comes back empty and the update silently
      // fails ("LLM returned empty response"). Mirrors memory.dart's
      // _completeRecapSanitized. Live Sheet ops are internal state (never
      // shown verbatim), so a delta recovered from the reasoning channel is
      // still safe to parse.
      allowReasoningFallback: true,
    );
    // Distinguish a provider-returns-empty error from a clean NO_CHANGE
    // cycle (mirrors generateCheckpoint / seedLiveSheetEntity) so the
    // failure surfaces in the log instead of looking like "no change".
    if (out.trim().isEmpty) {
      LiveSheetErrors.record('generateLiveSheetUpdate', 'LLM returned empty response');
      return null;
    }
    final delta = parseLiveSheetDelta(out);
    if (delta.noChange || delta.ops.isEmpty) return null;
    // LS-1 (C2 race): re-resolve by id against the CURRENT message/snapshot
    // state rather than trusting the pre-await index/object. Bail (discard
    // the result) if the branch changed underneath us — applying it would
    // bind a delta computed from the old body to the wrong anchor/pathHash.
    final currentActive = activeLiveSheetSnapshot(chat);
    if (currentActive == null || currentActive.id != activeSnapshotId) {
      LiveSheetErrors.record('generateLiveSheetUpdate',
          'active snapshot changed during the update — discarding stale result');
      return null;
    }
    final newCutoffIdx =
        chat.messages.indexWhere((m) => m.id == cutoffMessageId);
    if (newCutoffIdx < 0) {
      LiveSheetErrors.record('generateLiveSheetUpdate',
          'anchor message removed during the update — discarding stale result');
      return null;
    }
    return applyLiveSheetDelta(
      prev: currentActive,
      delta: delta,
      anchorMessageId: cutoffMessageId,
      pathHash: computePathHash(chat.messages, newCutoffIdx),
    );
  } catch (e) {
    LiveSheetErrors.record('generateLiveSheetUpdate', e);
    return null;
  }
}

// ---------------------------------------------------------------------------
// TASK 14b: seedLiveSheetEntity (orchestration)
// ---------------------------------------------------------------------------

/// Asks the LLM to fill initial sheet sections for a single entity using
/// its card description + the current conversation. Returns null on failure
/// (this includes the LS-2 in-flight-lock sentinel when a
/// [generateLiveSheetUpdate] or another [seedLiveSheetEntity] call for the
/// same chat is already running — see [isLiveSheetInFlight]).
Future<Map<LiveSheetSection, List<LiveSheetFact>>?> seedLiveSheetEntity({
  required Chat chat,
  required String entityName,
  required LiveSheetEntityKind kind,
  String? cardDescription,
  required ApiProvider provider,
  required ModelSettings settings,
  LiveSheetSettings? liveSheetSettings,
}) async {
  // LS-2: service-level per-chat lock (same guard as generateLiveSheetUpdate).
  // Seeding mutates/replaces the same chat's active-snapshot entities, so a
  // seed running concurrently with an auto/manual update (or another seed)
  // for the same chat is exactly the C1-shaped hazard memory.dart fixed.
  if (_liveSheetInFlight[chat.id] == true) {
    return null;
  }
  _liveSheetInFlight[chat.id] = true;
  try {
    return await _seedLiveSheetEntityBody(
      chat: chat,
      entityName: entityName,
      kind: kind,
      cardDescription: cardDescription,
      provider: provider,
      settings: settings,
      liveSheetSettings: liveSheetSettings,
    );
  } finally {
    _liveSheetInFlight.remove(chat.id);
  }
}

/// Internal body of [seedLiveSheetEntity] — called only while the per-chat
/// lock is held.
Future<Map<LiveSheetSection, List<LiveSheetFact>>?> _seedLiveSheetEntityBody({
  required Chat chat,
  required String entityName,
  required LiveSheetEntityKind kind,
  String? cardDescription,
  required ApiProvider provider,
  required ModelSettings settings,
  LiveSheetSettings? liveSheetSettings,
}) async {
  if (provider.baseUrl.isEmpty) return null;
  final ls = liveSheetSettings ?? LiveSheetSettings();
  final body = StringBuffer();
  body.writeln('Entity to sheet: $entityName${kind == LiveSheetEntityKind.user ? ' (the user / {{user}})' : ''}');
  if (cardDescription != null && cardDescription.trim().isNotEmpty) {
    body.writeln('\n## Their description:\n${cardDescription.trim()}');
  }
  body.writeln('\n## Conversation so far:');
  for (final m in chat.messages) {
    final role = switch (m.kind) {
      MessageKind.user => 'User',
      MessageKind.char => 'Character',
      MessageKind.ooc => 'OOC',
      MessageKind.scene => 'Scene',
      MessageKind.system => 'System',
    };
    // chat-core-1-01: strip `<think>…</think>` from assistant bodies (see
    // buildUpdateBody). Stored text is untouched; only char turns carry it.
    final text =
        m.kind == MessageKind.char ? stripStreamArtifacts(m.text) : m.text;
    body.writeln('$role: $text');
  }
  final turns = <ChatTurn>[
    ChatTurn('system', ls.seedPrompt),
    ChatTurn('user', body.toString()),
  ];
  try {
    final out = await completeChatStreamed(
      provider: provider,
      settings: _liveSheetSettings(settings),
      messages: turns,
      debugTag: 'livesheet', // Wave CY.18.214 diagnostics tag
      // LS-3: see generateLiveSheetUpdate — a reasoning-only model answers
      // entirely in the `<think>` channel, and without this flag the visible
      // content strips to empty, logging "empty seed" and silently failing
      // the sheet fill. Mirrors memory.dart's _completeRecapSanitized.
      allowReasoningFallback: true,
    );
    if (out.trim().isEmpty) {
      LiveSheetErrors.record('seedLiveSheetEntity', 'empty seed');
      return null;
    }
    return parseSeedSheet(out);
  } catch (e) {
    LiveSheetErrors.record('seedLiveSheetEntity', e);
    return null;
  }
}

// ---------------------------------------------------------------------------
// TASK 14c: seedInitialSnapshot (PURE)
// ---------------------------------------------------------------------------

/// Creates an empty snapshot anchored at the head of the message list with
/// the given entities pre-registered (all sections empty). Intended as the
/// starting point before the first LLM seed pass.
LiveSheetSnapshot seedInitialSnapshot(Chat chat, List<LiveSheetEntity> entities) {
  final idx = chat.messages.length - 1;
  final anchorId = idx >= 0 ? chat.messages[idx].id : '';
  return LiveSheetSnapshot(
    id: newId('lss'),
    anchorMessageId: anchorId,
    pathHash: idx >= 0 ? computePathHash(chat.messages, idx) : '',
    entities: entities,
  );
}

/// C-3: build the default Live Sheet entity list for a chat — the persona (as
/// the `user` entity, falling back to "You" when there's no persona) plus every
/// real (non-narrator) character in the chat as a `char` entity. Pure: mirrors
/// the entity construction the Live Sheet screen used to do inline, so the
/// chat-creation seed and the screen produce identical entities.
List<LiveSheetEntity> buildLiveSheetEntities({
  required String? personaName,
  required Iterable<Character> characters,
}) {
  return <LiveSheetEntity>[
    LiveSheetEntity(
      id: newId('lse'),
      name: (personaName != null && personaName.trim().isNotEmpty)
          ? personaName
          : 'You',
      kind: LiveSheetEntityKind.user,
    ),
    for (final ch in characters)
      // A narrator/scenario card has no body — seeding it as a physical entity
      // makes the model hallucinate one. Skip it; persona + real NPCs seed.
      if (!isNarratorCard(ch))
        LiveSheetEntity(
          id: newId('lse'),
          name: ch.name,
          kind: LiveSheetEntityKind.char,
        ),
  ];
}

/// C-3 (default-ON Live Sheet was inert on new chats): ensure an initial Live
/// Sheet snapshot exists when the chat has Live Sheet enabled. Idempotent —
/// no-op when disabled or when an active snapshot already exists (so callers
/// can fire it freely on chat creation, on the first turn, or when the Live
/// Sheet screen opens, without ever double-seeding). Returns true iff a fresh
/// snapshot was appended.
///
/// Without this, `Chat.liveSheetEnabled` defaulting to true had no effect:
/// nothing seeded a snapshot, so `shouldUpdateLiveSheet` stayed false and
/// `buildLiveSheetBlock` returned '' forever — the default-ON flag never
/// started tracking or injecting.
bool ensureLiveSheetSeed({
  required Chat chat,
  required String? personaName,
  required Iterable<Character> characters,
}) {
  if (!chat.liveSheetEnabled) return false;
  if (activeLiveSheetSnapshot(chat) != null) return false;
  final entities = buildLiveSheetEntities(
    personaName: personaName,
    characters: characters,
  );
  final snapshot = seedInitialSnapshot(chat, entities);
  chat.liveSheetSnapshots.add(snapshot);
  return true;
}

/// Re-anchors [snapshot] in place to the LATEST message, recomputing its
/// `pathHash` with the same helper [applyLiveSheetDelta] uses. Used after a
/// MANUAL empty-sheet seed (the "Update state now → empty sheet" path), which
/// folds the WHOLE conversation into the snapshot's facts but, unlike the auto
/// update, never creates a fresh re-anchored snapshot. Without this the anchor
/// stays pinned at enable-time, so the next auto-update would re-feed messages
/// already folded into the seed (double-counting). No-op on an empty chat.
void reanchorSnapshotToLatest(Chat chat, LiveSheetSnapshot snapshot) {
  final idx = chat.messages.length - 1;
  if (idx < 0) return;
  snapshot.anchorMessageId = chat.messages[idx].id;
  snapshot.pathHash = computePathHash(chat.messages, idx);
}
