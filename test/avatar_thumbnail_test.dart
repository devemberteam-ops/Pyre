// BATCH P2-ui (J): the list-row avatar thumbnail wrapper.
//
// `thumbnailProvider` wraps a base ImageProvider in a ResizeImage sized to
// the painted diameter × devicePixelRatio so a full-res card avatar decodes
// straight to the ~44px circle instead of its intrinsic ~1024×1536 texture
// (the many-cards OOM driver). These tests pin the size math + the no-op
// edges.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/widgets/avatar.dart';

void main() {
  // A trivial concrete provider to wrap — its bytes never get decoded here,
  // we only assert the wrapping policy.
  final base = NetworkImage('https://example.com/a.png');

  group('thumbnailProvider', () {
    test('null base returns null (nothing to wrap)', () {
      expect(
        thumbnailProvider(null, diameter: 44, devicePixelRatio: 2),
        isNull,
      );
    });

    test('wraps in a ResizeImage at diameter × devicePixelRatio', () {
      final p = thumbnailProvider(base, diameter: 44, devicePixelRatio: 2);
      expect(p, isA<ResizeImage>());
      final r = p as ResizeImage;
      // 44 * 2 = 88 physical px, square.
      expect(r.width, 88);
      expect(r.height, 88);
      expect(r.imageProvider, same(base));
    });

    test('uses fit policy so a portrait is NOT squished into a square', () {
      // Root cause of "the auto-face-frame did nothing": the default
      // ResizeImagePolicy.exact, with BOTH width and height set, behaves like
      // BoxFit.fill (per Flutter's docs) — it decodes a tall portrait straight
      // into a SQUARE, distorting it at decode time. The AvatarBubble cover-crop
      // + kAvatarFaceAlignment then paints a square into a square circle with
      // zero overflow, so the alignment is a no-op and the squished image shows
      // unchanged. ResizeImagePolicy.fit preserves the source aspect ratio
      // (decoding within the px box), giving the cover-crop real vertical
      // overflow to bias toward the face.
      final r = thumbnailProvider(base, diameter: 44, devicePixelRatio: 2)
          as ResizeImage;
      expect(r.policy, ResizeImagePolicy.fit);
    });

    test('rounds the physical-pixel target', () {
      final p = thumbnailProvider(base, diameter: 22, devicePixelRatio: 2.625)
          as ResizeImage;
      // 22 * 2.625 = 57.75 → round → 58
      expect(p.width, 58);
      expect(p.height, 58);
    });

    test('clamps a non-positive devicePixelRatio to 1.0 (no 0-px decode)', () {
      final p =
          thumbnailProvider(base, diameter: 44, devicePixelRatio: 0)
              as ResizeImage;
      expect(p.width, 44);
      expect(p.height, 44);
    });

    test('a degenerate 0 diameter falls back to the un-resized base', () {
      // resizeIfNeeded with a 0 target would be meaningless; the helper
      // returns the base provider unchanged rather than a 0-px ResizeImage.
      final p = thumbnailProvider(base, diameter: 0, devicePixelRatio: 2);
      expect(p, same(base));
    });
  });
}
