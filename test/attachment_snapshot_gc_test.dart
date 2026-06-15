// Bug 5 regression: collectReferencedAttachmentHashes did not iterate
// chat.characterSnapshots, so when a library character was deleted (or in a
// group chat where snapshots are frozen), its avatar/avatarOriginal/gallery
// blobs dropped out of the referenced set and gcOrphans deleted those .bin
// files — permanently breaking the snapshot's avatar display.
//
// Fix: the function now also iterates every chat's characterSnapshots values
// and adds their avatar + avatarOriginal + gallery hashes, mirroring exactly
// how it handles live `characters`.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/attachment_refs.dart';
import 'package:pyre/services/attachment_store.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

// ── Minimal in-memory StoreBackend so we can create an AppStore without disk.

class _NullBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {}
  @override
  Future<void> clear() async {}
}

// ── Helpers ──────────────────────────────────────────────────────────────────

String _url(String hash) => '${AttachmentStore.urlPrefix}$hash';

/// Build an AppStore whose only attachment references live inside a
/// chat.characterSnapshot. The library character list is EMPTY (simulating
/// deletion after a snapshot was frozen).
///
/// Pattern mirrors state_actions_test.dart: no load() call, state injected
/// directly so there are no I/O or ChangeNotifier side-effects.
AppStore _storeWithSnapshotOnly({
  required String avatarHash,
  String? avatarOriginalHash,
  List<String> galleryHashes = const [],
}) {
  final store = AppStore(storage: _NullBackend());

  final snap = Character(
    id: newId('snap'),
    name: 'Deleted Character',
    avatar: _url(avatarHash),
    avatarOriginal:
        avatarOriginalHash != null ? _url(avatarOriginalHash) : null,
    gallery: galleryHashes.map(_url).toList(),
  );

  final chat = Chat(
    id: newId('chat'),
    characterIds: [snap.id],
    characterSnapshots: {snap.id: snap},
  );
  store.chats.add(chat);
  // library characters stays EMPTY — simulating a post-deletion state.

  return store;
}

void main() {
  group('Bug 5: characterSnapshot refs are protected from GC', () {
    test(
        'avatar hash referenced only via snapshot is included in the referenced set',
        () {
      const avatarHash = 'abc123avatarhash';
      final store = _storeWithSnapshotOnly(avatarHash: avatarHash);

      final refs = collectReferencedAttachmentHashes(store);
      expect(refs.contains(avatarHash), isTrue,
          reason: 'snapshot avatar must survive GC');
    });

    test('avatarOriginal hash via snapshot is included', () {
      const avatarHash = 'croppedHash';
      const originalHash = 'fullSizeHash';
      final store = _storeWithSnapshotOnly(
        avatarHash: avatarHash,
        avatarOriginalHash: originalHash,
      );

      final refs = collectReferencedAttachmentHashes(store);
      expect(refs.contains(avatarHash), isTrue);
      expect(refs.contains(originalHash), isTrue,
          reason: 'snapshot avatarOriginal must survive GC');
    });

    test('gallery hashes via snapshot are included', () {
      final store = _storeWithSnapshotOnly(
        avatarHash: 'avatarHash',
        avatarOriginalHash: null,
        galleryHashes: ['g1', 'g2', 'g3'],
      );

      final refs = collectReferencedAttachmentHashes(store);
      expect(refs.contains('g1'), isTrue);
      expect(refs.contains('g2'), isTrue);
      expect(refs.contains('g3'), isTrue);
    });

    test(
        'a hash referenced by snapshot but NOT the live library is still retained',
        () {
      // This is the exact failure scenario from Bug 5: library character was
      // deleted, snapshot is the only remaining reference.
      const orphanCandidate = 'wouldBeGCdWithoutFix';
      final store = _storeWithSnapshotOnly(avatarHash: orphanCandidate);
      // Confirm the live characters list is empty.
      expect(store.characters, isEmpty);

      final refs = collectReferencedAttachmentHashes(store);
      expect(refs.contains(orphanCandidate), isTrue,
          reason: 'without the fix this hash would be missing and the blob '
              'would be deleted by gcOrphans, breaking the snapshot avatar');
    });

    test('snapshots across multiple chats are all included', () {
      final store = AppStore(storage: _NullBackend());

      final snap1 =
          Character(id: newId('s'), name: 'A', avatar: _url('hash1'));
      final snap2 =
          Character(id: newId('s'), name: 'B', avatar: _url('hash2'));

      store.chats.addAll([
        Chat(
          id: newId('c'),
          characterIds: [snap1.id],
          characterSnapshots: {snap1.id: snap1},
        ),
        Chat(
          id: newId('c'),
          characterIds: [snap2.id],
          characterSnapshots: {snap2.id: snap2},
        ),
      ]);

      final refs = collectReferencedAttachmentHashes(store);
      expect(refs.contains('hash1'), isTrue);
      expect(refs.contains('hash2'), isTrue);
    });

    test('non-pyre URLs in snapshots are ignored (no spurious hashes)', () {
      final store = AppStore(storage: _NullBackend());

      // Snapshot with a legacy inline data: avatar.
      final snap = Character(
        id: newId('s'),
        name: 'Legacy',
        avatar: 'data:image/png;base64,AAAA',
      );
      store.chats.add(Chat(
        id: newId('c'),
        characterIds: [snap.id],
        characterSnapshots: {snap.id: snap},
      ));

      final refs = collectReferencedAttachmentHashes(store);
      // No hash should have been extracted from the data: URL.
      expect(refs.where((h) => h.contains('AAAA')), isEmpty);
    });
  });
}
