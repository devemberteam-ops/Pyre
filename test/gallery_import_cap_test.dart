// Audit fix #2: the gallery importer silently caps at 12 images / 24MB
// (`kMaxGalleryImages` / `kMaxGalleryAggregateBytes`) with no signal to the
// user about how many images were left out. `downloadGalleryImagesWithStats`
// exposes a `skippedForCap` count — the number of REQUESTED urls that were
// never even attempted because a cap was already hit — so the Discover
// import flow can tell the user "Imported N of M gallery images (size cap
// reached)" instead of quietly truncating.
//
// `downloadGalleryImages` (the pre-existing, still-used-elsewhere entry
// point) is a thin wrapper that discards the stats — its behavior/signature
// is unchanged for `main.dart` / `characters_screen.dart` callers.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pyre/services/gallery_import.dart';

/// A 1x1 PNG's magic bytes + padding, long enough to pass the `_imageMime`
/// sniff (needs >= 12 bytes) without needing a real valid PNG stream.
Uint8List _fakePngBytes([int extra = 8]) => Uint8List.fromList([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      ...List.filled(extra, 0),
    ]);

/// Minimal fake PathProviderPlatform (mirrors backup_attachments_test.dart)
/// so `AttachmentStore.store` — called internally by the importer for every
/// downloaded image — can write real `.bin` files instead of throwing on a
/// missing platform channel.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.docsPath);
  final String docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
  @override
  Future<String?> getTemporaryPath() async => docsPath;
  @override
  Future<String?> getApplicationSupportPath() async => docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('pyre_gallery_cap_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('downloadGalleryImagesWithStats: cap visibility', () {
    test('all urls fit under both caps → 0 skipped', () async {
      final client = MockClient((req) async {
        return http.Response.bytes(_fakePngBytes(), 200);
      });
      final urls = List.generate(
        5,
        (i) => 'https://botbooru.com/mini-gallery/$i',
      );
      final result = await downloadGalleryImagesWithStats(urls, client: client);
      expect(result.refs.length, 5);
      expect(result.skippedForCap, 0);
    });

    test('more than kMaxGalleryImages urls → excess counted as skippedForCap',
        () async {
      final client = MockClient((req) async {
        return http.Response.bytes(_fakePngBytes(), 200);
      });
      // Request more than the cap (12) — e.g. 20 total.
      final urls = List.generate(
        20,
        (i) => 'https://botbooru.com/mini-gallery/$i',
      );
      final result = await downloadGalleryImagesWithStats(urls, client: client);
      expect(result.refs.length, kMaxGalleryImages);
      expect(result.skippedForCap, 20 - kMaxGalleryImages);
    });

    test('aggregate byte cap reached → remaining urls counted as skipped',
        () async {
      // Each image stays UNDER the per-image cap (kMaxGalleryImageBytes,
      // 4MB) so every fetch individually succeeds, but 8 of them (~28MB)
      // exceed the 24MB aggregate cap before the 12-image count cap would
      // ever trip — isolating the aggregate-cap code path.
      final chunkSize = (kMaxGalleryImageBytes * 0.9).ceil();
      final client = MockClient((req) async {
        return http.Response.bytes(_fakePngBytes(chunkSize), 200);
      });
      final urls = List.generate(
        8,
        (i) => 'https://botbooru.com/mini-gallery/$i',
      );
      final result = await downloadGalleryImagesWithStats(urls, client: client);
      expect(result.refs.length, lessThan(8));
      expect(result.skippedForCap, 8 - result.refs.length);
      expect(result.skippedForCap, greaterThan(0));
    });

    test('non-cap skips (bad host / non-image) are NOT counted as cap skips',
        () async {
      final client = MockClient((req) async {
        return http.Response.bytes(_fakePngBytes(), 200);
      });
      final urls = [
        'https://evil.test/x.png', // off-host — rejected, not a cap skip
        'https://botbooru.com/mini-gallery/1',
      ];
      final result = await downloadGalleryImagesWithStats(urls, client: client);
      expect(result.refs.length, 1);
      expect(result.skippedForCap, 0);
    });

    test('downloadGalleryImages (legacy wrapper) still returns just the refs',
        () async {
      final client = MockClient((req) async {
        return http.Response.bytes(_fakePngBytes(), 200);
      });
      final urls = List.generate(
        15,
        (i) => 'https://botbooru.com/mini-gallery/$i',
      );
      final refs = await downloadGalleryImages(urls, client: client);
      expect(refs.length, kMaxGalleryImages);
    });

    test('empty input → empty refs, 0 skipped', () async {
      final result = await downloadGalleryImagesWithStats(const []);
      expect(result.refs, isEmpty);
      expect(result.skippedForCap, 0);
    });
  });
}
