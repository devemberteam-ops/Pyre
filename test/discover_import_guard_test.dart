// M-1: the Discover import handler set a `_busy` flag but never CHECKED it, so
// a double-tap (or a click-hook firing alongside the blob-hook) could stack two
// concurrent imports of the same card → a DUPLICATE character. The re-entrancy
// gate is extracted as the pure `canStartDiscoverImport(busy)` so the
// "second concurrent call is a no-op" guard is unit-testable (the handler
// itself drives a webview that can't be widget-tested).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/screens/discover_screen.dart';

void main() {
  group('M-1: Discover import re-entrancy gate', () {
    test('idle (not busy) → a new import may start', () {
      expect(canStartDiscoverImport(false), isTrue);
    });

    test('busy (import in flight) → a second call is rejected (no-op)', () {
      expect(canStartDiscoverImport(true), isFalse);
    });

    test('simulated double-tap: only the first call proceeds', () {
      // First tap: idle → allowed; the handler would then set busy=true.
      var busy = false;
      final firstAllowed = canStartDiscoverImport(busy);
      expect(firstAllowed, isTrue);
      if (firstAllowed) busy = true; // handler flips the flag

      // Second tap arrives before the first finished → must be a no-op.
      expect(canStartDiscoverImport(busy), isFalse);
    });
  });

  group('Wave CY.18.260: parseCardBytesPayload', () {
    // The SOH (U+0001) delimiter the webview hook + native split on. Built via
    // charCode so the byte is exact regardless of editor encoding.
    final soh = String.fromCharCode(1);
    // Tiny "PNG" stand-in — the helper does NOT validate PNG magic (that's the
    // importer's job); it only base64-decodes + size-caps.
    final fakeBytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
    final b64 = base64Encode(fakeBytes);

    test('base64 only (no gallery) → bytes, empty gallery', () {
      final p = parseCardBytesPayload(b64);
      expect(p, isNotNull);
      expect(p!.bytes, fakeBytes);
      expect(p.galleryDomSrcs, isEmpty);
    });

    test('base64 + SOH + gallery JSON → bytes + gallery list', () {
      final gallery = ['/mini-gallery/1/preview/480', '/mini-gallery/2'];
      final p = parseCardBytesPayload('$b64$soh${jsonEncode(gallery)}');
      expect(p, isNotNull);
      expect(p!.bytes, fakeBytes);
      expect(p.galleryDomSrcs, gallery);
    });

    test('SOH present but empty gallery JSON → bytes + empty gallery', () {
      final p = parseCardBytesPayload('$b64$soh');
      expect(p, isNotNull);
      expect(p!.bytes, fakeBytes);
      expect(p.galleryDomSrcs, isEmpty);
    });

    test('malformed gallery JSON degrades to empty (still imports the card)',
        () {
      final p = parseCardBytesPayload('$b64${soh}not valid json [');
      expect(p, isNotNull);
      expect(p!.bytes, fakeBytes);
      expect(p.galleryDomSrcs, isEmpty);
    });

    test('gallery JSON that is not a list → empty gallery', () {
      final p = parseCardBytesPayload('$b64$soh{"a":1}');
      expect(p, isNotNull);
      expect(p!.galleryDomSrcs, isEmpty);
    });

    test('gallery list with non-string entries keeps only strings', () {
      final p = parseCardBytesPayload('$b64$soh${jsonEncode([
            'a',
            1,
            'b',
            null
          ])}');
      expect(p, isNotNull);
      expect(p!.galleryDomSrcs, ['a', 'b']);
    });

    test('empty base64 → null (rejected)', () {
      expect(parseCardBytesPayload(''), isNull);
      expect(parseCardBytesPayload('$soh[]'), isNull);
    });

    test('non-base64 garbage → null (rejected, never throws)', () {
      // A '!' is not a valid base64 char.
      expect(parseCardBytesPayload('!!!not base64!!!'), isNull);
    });

    test('decoded bytes over the 25 MB cap → null (rejected)', () {
      // 26 MB of zero bytes → base64 → must be rejected by the size cap.
      final big = Uint8List(26 * 1024 * 1024);
      expect(parseCardBytesPayload(base64Encode(big)), isNull);
    });
  });
}
