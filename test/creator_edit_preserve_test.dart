// Audit 2026-06-05: the Creator's "Edit with AI" save rebuilds the Character
// from the chara_card_v2 canvas, which only carries the `data` block. The
// extra `gallery` images, the `favorite` star, and the top-level
// `talkativeness` never round-trip through the canvas, so a naive
// rebuild-then-save silently WIPED a BotBooru card's gallery, un-starred a
// favourited card, and dropped talkativeness.
//
// `restoreCanvasDroppedExtras` copies those three fields back from the
// original onto the freshly-rebuilt card, mirroring the persona edit path
// (which already restored gallery + favorite from `existing`).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/card_import.dart';

void main() {
  // A fresh-from-canvas rebuild: gallery [], favorite false, talkativeness
  // null — exactly the empty defaults `_commitSave` holds in `c` after
  // `characterFromCharaCard`, because the canvas never carried them.
  Character rebuilt() => Character(
        id: 'fresh',
        name: 'Ren',
        description: 'edited by the AI',
      );

  // The stored original the user is editing: a BotBooru-imported, favourited
  // card with a populated gallery and a talkativeness value.
  Character original() => Character(
        id: 'orig',
        name: 'Ren',
        gallery: const ['pyre://attachment/g1', 'pyre://attachment/g2'],
        favorite: true,
        talkativeness: 0.8,
      );

  group('restoreCanvasDroppedExtras — overwrite (keepFavorite: true)', () {
    test('restores gallery, favorite, and talkativeness from the original',
        () {
      final c = restoreCanvasDroppedExtras(rebuilt(), original(),
          keepFavorite: true);
      expect(c.gallery, ['pyre://attachment/g1', 'pyre://attachment/g2']);
      expect(c.favorite, isTrue);
      expect(c.talkativeness, 0.8);
    });

    test('gallery is an independent copy (mutating one never bleeds back)', () {
      final orig = original();
      final c =
          restoreCanvasDroppedExtras(rebuilt(), orig, keepFavorite: true);
      expect(identical(c.gallery, orig.gallery), isFalse);
      c.gallery.add('pyre://attachment/g3');
      expect(orig.gallery, ['pyre://attachment/g1', 'pyre://attachment/g2']);
    });

    test('a null talkativeness on the original round-trips as null', () {
      final orig = original()..talkativeness = null;
      final c =
          restoreCanvasDroppedExtras(rebuilt(), orig, keepFavorite: true);
      expect(c.talkativeness, isNull);
    });
  });

  group('restoreCanvasDroppedExtras — save-as-copy (keepFavorite: false)', () {
    test(
        'restores gallery + talkativeness but NOT favorite (a fresh copy '
        'starts unstarred)', () {
      final c = restoreCanvasDroppedExtras(rebuilt(), original(),
          keepFavorite: false);
      expect(c.gallery, ['pyre://attachment/g1', 'pyre://attachment/g2']);
      expect(c.talkativeness, 0.8);
      // The copy is its own new record — it does NOT inherit the star.
      expect(c.favorite, isFalse);
    });
  });
}
