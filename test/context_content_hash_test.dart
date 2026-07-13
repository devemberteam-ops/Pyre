@TestOn('vm')
library;

// Context-loss fix (audit round 12/14) — INTEGRATION: findValidCheckpoints
// (memory) and activeLiveSheetSnapshot (Live Sheet) now honour the content
// fingerprint, so an in-place edit / Continue of a COVERED message drops the
// stale recap/state, while edits after the anchor / to a non-selected variant
// don't, and legacy (contentHash-less) snapshots stay valid (back-compat).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_fingerprint.dart';
import 'package:pyre/services/live_sheet.dart'
    show
        activeLiveSheetSnapshot,
        reanchorSnapshotToLatest,
        seedInitialSnapshot;
import 'package:pyre/services/memory.dart' show findValidCheckpoints;

Message _m(String id, List<String> variants, {int sel = 0}) =>
    Message(id: id, kind: MessageKind.char, variants: variants, selectedVariant: sel);

Chat _chat(List<Message> msgs,
        {List<MemoryCheckpoint>? cps, List<LiveSheetSnapshot>? snaps}) =>
    Chat(
      id: 'c',
      characterIds: ['x'],
      messages: msgs,
      memoryCheckpoints: cps ?? [],
      liveSheetSnapshots: snaps ?? [],
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('memory findValidCheckpoints honours contentHash', () {
    final orig = [_m('a', ['hi']), _m('b', ['there']), _m('c', ['now'])];
    // A checkpoint covering messages 0..1, fingerprinted from `orig`.
    MemoryCheckpoint cpOver1() => MemoryCheckpoint(
          id: 'cp',
          summary: 's',
          anchorMessageIdx: 1,
          pathHash: computePathHash(orig, 1),
          contentHash: computeContentHash(orig, 1),
        );

    test('valid when the covered content is unchanged', () {
      expect(findValidCheckpoints(_chat(orig, cps: [cpOver1()])).map((c) => c.id),
          ['cp']);
    });

    test('editing a COVERED message drops it (stale recap)', () {
      final edited = [_m('a', ['hi']), _m('b', ['there — EDITED']), _m('c', ['now'])];
      expect(findValidCheckpoints(_chat(edited, cps: [cpOver1()])), isEmpty);
    });

    test('editing a message AFTER the anchor keeps it valid', () {
      final afterEdit = [_m('a', ['hi']), _m('b', ['there']), _m('c', ['CHANGED'])];
      expect(
          findValidCheckpoints(_chat(afterEdit, cps: [cpOver1()])).map((c) => c.id),
          ['cp']);
    });

    test('a swipe (variant switch) still invalidates via pathHash', () {
      final multi = [_m('a', ['hi']), _m('b', ['v0', 'v1'], sel: 0)];
      final cp = MemoryCheckpoint(
          id: 'cp',
          summary: 's',
          anchorMessageIdx: 1,
          pathHash: computePathHash(multi, 1),
          contentHash: computeContentHash(multi, 1));
      final swiped = [_m('a', ['hi']), _m('b', ['v0', 'v1'], sel: 1)];
      expect(findValidCheckpoints(_chat(swiped, cps: [cp])), isEmpty);
    });

    test('legacy checkpoint (empty contentHash) stays valid after an edit', () {
      final legacy = MemoryCheckpoint(
          id: 'legacy', summary: 's', anchorMessageIdx: 1,
          pathHash: '', contentHash: '');
      final edited = [_m('a', ['hi — edited']), _m('b', ['whatever'])];
      expect(findValidCheckpoints(_chat(edited, cps: [legacy])).map((c) => c.id),
          ['legacy']);
    });
  });

  group('LiveSheet activeLiveSheetSnapshot honours contentHash', () {
    final orig = [_m('a', ['hi']), _m('b', ['there'])];
    LiveSheetSnapshot snapAtB() => LiveSheetSnapshot(
          id: 's1',
          anchorMessageId: 'b',
          pathHash: computePathHash(orig, 1),
          contentHash: computeContentHash(orig, 1),
        );

    test('valid when covered content is unchanged', () {
      expect(activeLiveSheetSnapshot(_chat(orig, snaps: [snapAtB()]))?.id, 's1');
    });

    test('editing a covered message drops the stale state', () {
      final edited = [_m('a', ['hi']), _m('b', ['there — EDITED'])];
      expect(activeLiveSheetSnapshot(_chat(edited, snaps: [snapAtB()])), isNull);
    });

    test('legacy snapshot (empty contentHash) stays valid after an edit', () {
      final legacy = LiveSheetSnapshot(
          id: 'leg', anchorMessageId: 'b', pathHash: '', contentHash: '');
      final edited = [_m('a', ['hi']), _m('b', ['there — EDITED'])];
      expect(activeLiveSheetSnapshot(_chat(edited, snaps: [legacy]))?.id, 'leg');
    });
  });

  group('Live Sheet seed + re-anchor fingerprint the content (Codex review)', () {
    test('editing the greeting after the initial SEED invalidates it', () {
      final seed = seedInitialSnapshot(_chat([_m('greeting', ['Hi there!'])]), []);
      // Same chat unedited → seed valid.
      expect(activeLiveSheetSnapshot(_chat([_m('greeting', ['Hi there!'])],
              snaps: [seed]))?.id,
          seed.id);
      // Greeting edited in place (same id) → seed's content hash no longer
      // matches → dropped (was always-valid before this fix).
      expect(
          activeLiveSheetSnapshot(
              _chat([_m('greeting', ['Hi there! — EDITED'])], snaps: [seed])),
          isNull);
    });

    test('reanchorSnapshotToLatest recomputes contentHash at the new anchor', () {
      final msgs = [_m('a', ['x']), _m('b', ['y']), _m('c', ['z'])];
      final snap = LiveSheetSnapshot(
          id: 's', anchorMessageId: 'a', pathHash: 'old', contentHash: 'old');
      reanchorSnapshotToLatest(_chat(msgs), snap);
      expect(snap.anchorMessageId, 'c');
      expect(snap.pathHash, computePathHash(msgs, 2));
      expect(snap.contentHash, computeContentHash(msgs, 2));
    });
  });

  group('JSON round-trip (byte-clean back-compat)', () {
    test('MemoryCheckpoint carries contentHash; legacy → empty; empty omitted', () {
      final cp = MemoryCheckpoint(
          id: 'cp', summary: 's', anchorMessageIdx: 1,
          pathHash: 'p', contentHash: 'ch');
      expect(MemoryCheckpoint.fromJson(cp.toJson()).contentHash, 'ch');

      final legacyJson = {
        'id': 'x', 'summary': 's', 'anchorMessageIdx': 0,
        'pathHash': 'p', 'createdAt': 0, 'mtime': 0,
      };
      expect(MemoryCheckpoint.fromJson(legacyJson).contentHash, '');

      // A checkpoint with no contentHash serialises WITHOUT the key (byte-clean).
      final bare = MemoryCheckpoint(
          id: 'x', summary: 's', anchorMessageIdx: 0, pathHash: 'p');
      expect(bare.toJson().containsKey('contentHash'), isFalse);
    });

    test('LiveSheetSnapshot carries contentHash; empty omitted', () {
      final s = LiveSheetSnapshot(
          id: 's', anchorMessageId: 'a', pathHash: 'p', contentHash: 'ch');
      expect(LiveSheetSnapshot.fromJson(s.toJson()).contentHash, 'ch');
      final bare = LiveSheetSnapshot(id: 's', anchorMessageId: 'a', pathHash: 'p');
      expect(bare.toJson().containsKey('contentHash'), isFalse);
    });
  });
}
