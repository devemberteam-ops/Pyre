// Wave CY.18.127: tests for the gallery model field + the unified
// referenced-attachment collector that the GC (LAN server start AND the
// once-per-launch local sweep) uses to decide which `.bin` blobs are live.
//
// Two concerns:
//   1. `Character.gallery` / `Persona.gallery` survive a JSON round-trip,
//      and an absent `gallery` key parses to `[]` (never null, never throws).
//   2. `collectReferencedAttachmentHashes` unions every char avatar+gallery,
//      every persona avatar+gallery, and the chat-bg ref — DEDUPED (a hash
//      shared by a char gallery AND a persona avatar appears exactly once).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/attachment_refs.dart';
import 'package:pyre/services/attachment_store.dart';
import 'package:pyre/services/gallery_scrape.dart';
import 'package:pyre/state/app_store.dart';

void main() {
  group('gallery model round-trip', () {
    test('Character.gallery survives fromJson(toJson())', () {
      final c = Character(
        id: 'c1',
        name: 'Test',
        gallery: ['pyre://attachment/aa', 'pyre://attachment/bb'],
      );
      final restored = Character.fromJson(c.toJson());
      expect(restored.gallery, ['pyre://attachment/aa', 'pyre://attachment/bb']);
    });

    test('Persona.gallery survives fromJson(toJson())', () {
      final p = Persona(
        id: 'p1',
        name: 'You',
        gallery: ['pyre://attachment/aa', 'pyre://attachment/bb'],
      );
      final restored = Persona.fromJson(p.toJson());
      expect(restored.gallery, ['pyre://attachment/aa', 'pyre://attachment/bb']);
    });

    test('absent gallery key parses to [] (Character)', () {
      final restored = Character.fromJson({'id': 'c1', 'name': 'Test'});
      expect(restored.gallery, isEmpty);
    });

    test('absent gallery key parses to [] (Persona)', () {
      final restored = Persona.fromJson({'id': 'p1', 'name': 'You'});
      expect(restored.gallery, isEmpty);
    });

    test('default constructor gallery is [] (both)', () {
      expect(Character(id: 'c1', name: 'T').gallery, isEmpty);
      expect(Persona(id: 'p1', name: 'You').gallery, isEmpty);
    });
  });

  group('collectReferencedAttachmentHashes', () {
    String url(String h) => '${AttachmentStore.urlPrefix}$h';

    test('unions char avatar+gallery + persona avatar+gallery, deduped', () {
      final s = AppStore();
      // 1 char: avatar H1, gallery [H2, H3].
      s.characters.add(Character(
        id: 'c1',
        name: 'C',
        avatar: url('H1'),
        gallery: [url('H2'), url('H3')],
      ));
      // 1 persona: avatar H3 (shared with the char gallery), gallery [H4].
      s.personas.add(Persona(
        id: 'p1',
        name: 'P',
        avatar: url('H3'),
        gallery: [url('H4')],
      ));

      final refs = collectReferencedAttachmentHashes(s);
      expect(refs, {'H1', 'H2', 'H3', 'H4'});
      // H3 (char gallery + persona avatar) collapses to a single entry.
      expect(refs.length, 4);
    });

    test('non-pyre / null urls are ignored', () {
      final s = AppStore();
      s.characters.add(Character(
        id: 'c1',
        name: 'C',
        avatar: 'data:image/png;base64,AAAA', // legacy inline, not a ref
        gallery: [url('H2'), 'not-a-pyre-url'],
      ));
      s.personas.add(Persona(id: 'p1', name: 'P')); // null avatar, empty gallery

      final refs = collectReferencedAttachmentHashes(s);
      expect(refs, {'H2'});
    });

    test('includes the custom chat-background ref', () {
      final s = AppStore();
      s.chatSettings.customBackgroundDataUrl = url('BG');
      final refs = collectReferencedAttachmentHashes(s);
      expect(refs, contains('BG'));
    });
  });

  group('buildPersonaFromCharacter gallery copy', () {
    test('copies the gallery refs as an independent list', () {
      final c = Character(
        id: 'c1',
        name: 'C',
        gallery: ['pyre://attachment/H2', 'pyre://attachment/H3'],
      );

      final p = buildPersonaFromCharacter(c);

      // Same ref strings carried over (pointers only, no byte copy).
      expect(p.gallery, ['pyre://attachment/H2', 'pyre://attachment/H3']);

      // Independent copy: not the same list instance, and mutating one
      // side never touches the other.
      expect(identical(p.gallery, c.gallery), isFalse);
      p.gallery.add('pyre://attachment/H4');
      expect(c.gallery, ['pyre://attachment/H2', 'pyre://attachment/H3']);
      c.gallery.removeAt(0);
      expect(
        p.gallery,
        ['pyre://attachment/H2', 'pyre://attachment/H3', 'pyre://attachment/H4'],
      );
    });
  });

  group('resolveBotbooruGalleryDomUrls', () {
    const allowed = {'botbooru.com', 'www.botbooru.com'};

    test('relative preview srcs → ordered, deduped full-res URLs', () {
      // The DOM `img.src` values BotBooru's frontend renders into
      // #post-mini-gallery (relative, with a /preview/{size} tail).
      final urls = resolveBotbooruGalleryDomUrls(const [
        '/mini-gallery/2679/preview/480',
        '/mini-gallery/2680/preview/480',
        '/mini-gallery/2681/preview/480',
        '/mini-gallery/2680/preview/480', // dup
      ], allowedHosts: allowed);
      expect(urls, [
        'https://botbooru.com/mini-gallery/2679',
        'https://botbooru.com/mini-gallery/2680',
        'https://botbooru.com/mini-gallery/2681',
      ]);
    });

    test('absolute srcs on an allowed host are accepted + normalised', () {
      final urls = resolveBotbooruGalleryDomUrls(const [
        'https://botbooru.com/mini-gallery/100/preview/480',
        'https://www.botbooru.com/mini-gallery/200',
      ], allowedHosts: allowed);
      expect(urls, [
        'https://botbooru.com/mini-gallery/100',
        'https://botbooru.com/mini-gallery/200',
      ]);
    });

    test('off-host absolute srcs are REJECTED (security boundary)', () {
      final urls = resolveBotbooruGalleryDomUrls(const [
        'https://evil.test/x.webp',
        'https://evil.test/mini-gallery/9/preview/480',
        'https://botbooru.com.attacker.io/mini-gallery/7',
        '/mini-gallery/42/preview/480', // relative → allowed host
      ], allowedHosts: allowed);
      expect(urls, ['https://botbooru.com/mini-gallery/42']);
    });

    test('garbage / no-id / empty srcs → [] (never throws)', () {
      expect(resolveBotbooruGalleryDomUrls(const [], allowedHosts: allowed),
          isEmpty);
      expect(
        resolveBotbooruGalleryDomUrls(
            const ['', '/avatar/123.png', 'not a url'],
            allowedHosts: allowed),
        isEmpty,
      );
    });
  });

  group('hashFromPyreUrl', () {
    test('extracts the hash from a pyre:// url', () {
      expect(hashFromPyreUrl('${AttachmentStore.urlPrefix}abc'), 'abc');
    });

    test('returns null for null / non-pyre input', () {
      expect(hashFromPyreUrl(null), isNull);
      expect(hashFromPyreUrl('data:image/png;base64,AAAA'), isNull);
      expect(hashFromPyreUrl('https://example.com/x.png'), isNull);
    });
  });
}
