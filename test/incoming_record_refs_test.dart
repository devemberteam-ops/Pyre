// SYNC pull-side reconcile: which attachment blobs must be fetched for a
// freshly-applied character/persona record.
//
// Bug this guards: the non-destructive recrop preserves the UNCROPPED original
// in `avatarOriginal` (a `pyre://attachment/<hash>` ref). The record FIELD
// syncs (it rides toJson) and the PUSH side ships the blob
// (collectReferencedAttachmentHashes includes it), but the PULL side's
// reconcile used to note only `avatar` + `gallery` — so a device that PULLED a
// recropped card downloaded the crop but NOT the original's bytes, and tapping
// the avatar to see the whole image rendered broken. `incomingRecordAttachmentRefs`
// is the pure helper the engine now uses; it MUST include avatarOriginal.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/attachment_refs.dart';
import 'package:pyre/services/attachment_store.dart';

void main() {
  String url(String h) => '${AttachmentStore.urlPrefix}$h';

  group('incomingRecordAttachmentRefs', () {
    test('includes avatar, avatarOriginal, and every gallery ref', () {
      final refs = incomingRecordAttachmentRefs(
        avatar: url('CROP'),
        avatarOriginal: url('FULL'),
        gallery: [url('G1'), url('G2')],
      );
      expect(refs, {url('CROP'), url('FULL'), url('G1'), url('G2')});
    });

    test('REGRESSION: avatarOriginal is reconciled (the recrop bug)', () {
      final refs = incomingRecordAttachmentRefs(
        avatar: url('CROP'),
        avatarOriginal: url('FULL'),
      );
      // Without the original the pulled recrop renders broken on tap.
      expect(refs.contains(url('FULL')), isTrue);
    });

    test('null original adds nothing extra', () {
      final refs = incomingRecordAttachmentRefs(avatar: url('ONLY'));
      expect(refs, {url('ONLY')});
    });

    test('non-pyre URLs (inline data:, http) and nulls are ignored', () {
      final refs = incomingRecordAttachmentRefs(
        avatar: 'data:image/png;base64,AAAA',
        avatarOriginal: null,
        gallery: ['http://example.com/x.png', ''],
      );
      expect(refs, isEmpty);
    });

    test('de-dupes a ref shared between fields', () {
      final refs = incomingRecordAttachmentRefs(
        avatar: url('SAME'),
        avatarOriginal: url('SAME'),
      );
      expect(refs, {url('SAME')});
    });
  });
}
