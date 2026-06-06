// Mega-audit 2026-06-05 (H-4): unit tests for the PURE sync conflict
// detector + resolver. No AppStore / server needed — the divergence logic is
// the heart of "stop silently dropping one side", so it is locked in here.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/sync_conflict.dart';

SyncRecordRef _ref(String id, int mtime,
        {String kind = 'character', String name = '', bool deleted = false}) =>
    SyncRecordRef(kind: kind, id: id, mtime: mtime, name: name, deleted: deleted);

void main() {
  group('detectSyncConflicts', () {
    const since = 1000;

    test('empty inputs → no conflicts', () {
      expect(detectSyncConflicts(const [], const [], since), isEmpty);
      expect(detectSyncConflicts([_ref('a', 2000)], const [], since), isEmpty);
      expect(detectSyncConflicts(const [], [_ref('a', 2000)], since), isEmpty);
    });

    test('one-sided edit (only LOCAL changed) is NOT a conflict', () {
      // local edited after watermark, remote unchanged (at/below watermark).
      final local = [_ref('a', 2000)];
      final remote = [_ref('a', 500)];
      expect(detectSyncConflicts(local, remote, since), isEmpty);
    });

    test('one-sided edit (only REMOTE changed) is NOT a conflict', () {
      final local = [_ref('a', 500)];
      final remote = [_ref('a', 2000)];
      expect(detectSyncConflicts(local, remote, since), isEmpty);
    });

    test('both sides changed after watermark → conflict', () {
      final local = [_ref('a', 2000, name: 'Ren')];
      final remote = [_ref('a', 3000, name: 'Ren (peer)')];
      final conflicts = detectSyncConflicts(local, remote, since);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.id, 'a');
      expect(conflicts.single.kind, 'character');
      expect(conflicts.single.remoteIsNewer, isTrue);
      expect(conflicts.single.newerSideLabel, 'Other device');
    });

    test('both changed but remote older → still a conflict, local newer', () {
      final local = [_ref('a', 3000)];
      final remote = [_ref('a', 2000)];
      final conflicts = detectSyncConflicts(local, remote, since);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.remoteIsNewer, isFalse);
      expect(conflicts.single.newerSideLabel, 'This device');
    });

    test('record present on only one side is never a conflict', () {
      final local = [_ref('a', 2000), _ref('b', 2000)];
      final remote = [_ref('a', 2000)]; // no 'b' on the peer
      final conflicts = detectSyncConflicts(local, remote, since);
      // 'a' is the only shared id, and it conflicts; 'b' is one-sided.
      expect(conflicts.map((c) => c.id), ['a']);
    });

    test('edit-vs-tombstone where both moved past watermark → conflict', () {
      // local kept editing; remote deleted it — both after the watermark.
      final local = [_ref('a', 2000, deleted: false)];
      final remote = [_ref('a', 2500, deleted: true)];
      final conflicts = detectSyncConflicts(local, remote, since);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.remote.deleted, isTrue);
      expect(conflicts.single.local.deleted, isFalse);
    });

    test('tombstone-vs-edit where the DELETE predates the watermark → no '
        'conflict (one-sided)', () {
      final local = [_ref('a', 2000, deleted: false)];
      final remote = [_ref('a', 500, deleted: true)]; // old delete
      expect(detectSyncConflicts(local, remote, since), isEmpty);
    });

    test('exactly-at-watermark mtime is NOT "after" (strict >)', () {
      // since == 1000; a record at exactly 1000 has not changed since.
      final local = [_ref('a', 1000)];
      final remote = [_ref('a', 2000)];
      expect(detectSyncConflicts(local, remote, since), isEmpty);
    });

    test('multiple conflicts returned in stable local order', () {
      final local = [_ref('c', 2000), _ref('a', 2000), _ref('b', 2000)];
      final remote = [_ref('a', 2000), _ref('b', 2000), _ref('c', 2000)];
      final conflicts = detectSyncConflicts(local, remote, since);
      expect(conflicts.map((c) => c.id), ['c', 'a', 'b']);
    });
  });

  group('resolveConflictDecision', () {
    final remoteNewer = SyncConflict(
      kind: 'character',
      id: 'a',
      local: _ref('a', 2000),
      remote: _ref('a', 3000),
    );
    final localNewer = SyncConflict(
      kind: 'character',
      id: 'a',
      local: _ref('a', 3000),
      remote: _ref('a', 2000),
    );

    test('newestWins applies iff remote strictly newer', () {
      expect(
          resolveConflictDecision(remoteNewer, SyncConflictMode.newestWins),
          isTrue);
      expect(
          resolveConflictDecision(localNewer, SyncConflictMode.newestWins),
          isFalse);
    });

    test('newestWins tie keeps local (does not apply)', () {
      final tie = SyncConflict(
        kind: 'character',
        id: 'a',
        local: _ref('a', 2000),
        remote: _ref('a', 2000),
      );
      expect(resolveConflictDecision(tie, SyncConflictMode.newestWins), isFalse);
    });

    test('preferThisDevice never applies the peer record', () {
      expect(
          resolveConflictDecision(
              remoteNewer, SyncConflictMode.preferThisDevice),
          isFalse);
      expect(
          resolveConflictDecision(
              localNewer, SyncConflictMode.preferThisDevice),
          isFalse);
    });

    test('preferOtherDevice always applies the peer record', () {
      expect(
          resolveConflictDecision(
              remoteNewer, SyncConflictMode.preferOtherDevice),
          isTrue);
      expect(
          resolveConflictDecision(
              localNewer, SyncConflictMode.preferOtherDevice),
          isTrue);
    });

    test('ask: applies per the user choice; null choice → do NOT apply', () {
      expect(
          resolveConflictDecision(remoteNewer, SyncConflictMode.ask,
              askChoice: true),
          isTrue);
      expect(
          resolveConflictDecision(remoteNewer, SyncConflictMode.ask,
              askChoice: false),
          isFalse);
      expect(
          resolveConflictDecision(remoteNewer, SyncConflictMode.ask,
              askChoice: null),
          isFalse);
    });
  });

  group('SyncConflictMode persistence (UiPrefs)', () {
    test('default is newestWins and round-trips clean (omitted when default)',
        () {
      final p = UiPrefs();
      expect(p.syncConflictMode, SyncConflictMode.newestWins);
      // Default is omitted from JSON to keep blobs clean.
      expect(p.toJson().containsKey('syncConflictMode'), isFalse);
    });

    test('non-default persists + parses back', () {
      final p = UiPrefs(syncConflictMode: SyncConflictMode.preferOtherDevice);
      final j = p.toJson();
      expect(j['syncConflictMode'], 'preferOtherDevice');
      final back = UiPrefs.fromJson(j);
      expect(back.syncConflictMode, SyncConflictMode.preferOtherDevice);
    });

    test('unknown/legacy value falls back to newestWins', () {
      expect(parseSyncConflictMode('garbage'), SyncConflictMode.newestWins);
      expect(parseSyncConflictMode(null), SyncConflictMode.newestWins);
      expect(parseSyncConflictMode(42), SyncConflictMode.newestWins);
    });
  });
}
