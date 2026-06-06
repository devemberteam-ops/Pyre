// Mega-audit 2026-06-05 — verified data-completeness fixes B-1 + B-2.
//
// B-1 (BLOCKER): the Pyre-native backup export serialised characters /
// personas via `.toJson()`, which emits `avatar` / `gallery` as
// `pyre://attachment/<hash>` REF strings only. The actual bytes live in
// `attachments/<sha256>.bin` and were NEVER packed into the backup, so a
// restore on a fresh install / second device resolved every ref to a
// missing file → blank avatars + empty galleries. The fix embeds a
// top-level `attachments: { "<hash>": "<base64>" }` map on export and
// re-creates the `.bin` files from it on import. These tests assert the
// full round-trip survives even after the on-disk store is wiped.
//
// B-2 (BLOCKER) / H-6 (HIGH): card import stored the avatar as an inline
// `data:` URL and `addCharacter` never externalised it, so imported
// avatars stayed inline base64 forever (re-encoded on every save, copied
// into all rolling backups). The fix externalises at import time, mirroring
// the persona ST path. These tests assert an imported card's avatar becomes
// a `pyre://attachment/...` ref whose bytes resolve.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/backup_restore_screen.dart';
import 'package:pyre/services/attachment_store.dart';
import 'package:pyre/services/card_import.dart';
import 'package:pyre/services/png_parser.dart';

/// Minimal fake PathProviderPlatform that points app-docs at a temp dir so
/// the AttachmentStore writes real `.bin` files we can inspect / wipe.
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
    tmp = await Directory.systemTemp.createTemp('pyre_backup_attach_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// Wipe every `.bin` / `.mime` under the attachment dir to simulate a
  /// fresh install / second device that has the JSON blob but none of the
  /// content-addressed blobs.
  Future<void> wipeAttachmentDir() async {
    final dir = Directory('${tmp.path}/EmberChat/attachments');
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
  }

  group('B-1 backup attachments round-trip', () {
    test(
        'export embeds attachment bytes; import recreates them after a wipe',
        () async {
      // 1. Store some avatar bytes → get a pyre:// ref.
      final bytes = Uint8List.fromList(
          List<int>.generate(512, (i) => (i * 7 + 3) % 256));
      final ref = await AttachmentStore.store(bytes, mime: 'image/png');
      expect(ref, isNotNull);
      expect(AttachmentStore.isPyreUrl(ref!), isTrue);
      // Bytes are on disk before export.
      expect(await AttachmentStore.readBytes(ref), isNotNull);

      // 2. Build a backup blob for a character that references it.
      final blob = <String, dynamic>{
        'schemaVersion': 1,
        'characters': [
          Character(id: 'c1', name: 'Avatar Owner', avatar: ref).toJson(),
        ],
      };

      // 3. Embed attachments into the blob (the export-side fix).
      await embedBackupAttachments(blob);

      // The blob must now carry the bytes under a top-level map keyed by hash.
      final attachments = blob['attachments'];
      expect(attachments, isA<Map>());
      final hash = ref.substring(AttachmentStore.urlPrefix.length);
      expect((attachments as Map).containsKey(hash), isTrue);
      expect(base64Decode(attachments[hash] as String), bytes);

      // 4. Simulate transfer to a fresh device: serialise → deserialise →
      //    WIPE the on-disk store so the ref no longer resolves.
      final wire = jsonDecode(jsonEncode(blob)) as Map<String, dynamic>;
      await wipeAttachmentDir();
      expect(await AttachmentStore.readBytes(ref), isNull,
          reason: 'precondition: store wiped, ref must not resolve');

      // 5. Restore the embedded attachments (the import-side fix).
      await restoreBackupAttachments(wire);

      // The bytes are back and the original ref resolves again.
      final restored = await AttachmentStore.readBytes(ref);
      expect(restored, isNotNull);
      expect(restored, bytes);
    });

    test('a backup with no attachments map restores without crashing',
        () async {
      // Backwards compatibility: an old backup has no `attachments` key.
      await restoreBackupAttachments(<String, dynamic>{
        'characters': <dynamic>[],
      });
      // No throw == pass.
    });

    test('embed dedupes a hash shared by two records', () async {
      final bytes = Uint8List.fromList(
          List<int>.generate(64, (i) => (i * 11) % 256));
      final ref = await AttachmentStore.store(bytes, mime: 'image/png');
      final hash = ref!.substring(AttachmentStore.urlPrefix.length);

      final blob = <String, dynamic>{
        'characters': [
          Character(id: 'c1', name: 'A', avatar: ref).toJson(),
        ],
        'personas': [
          Persona(id: 'p1', name: 'B', avatar: ref, gallery: [ref]).toJson(),
        ],
      };
      await embedBackupAttachments(blob);
      final attachments = blob['attachments'] as Map;
      // Shared hash appears exactly once.
      expect(attachments.keys.where((k) => k == hash).length, 1);
    });
  });

  group('B-2 card import externalizes inline avatar', () {
    test('externalizeCharacterImages turns an inline data: avatar into a ref',
        () async {
      final bytes = Uint8List.fromList(
          List<int>.generate(256, (i) => (i * 5 + 1) % 256));
      final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
      final c = Character(id: 'c1', name: 'Imported', avatar: dataUrl);
      expect(c.avatar!.startsWith('data:'), isTrue);

      await externalizeCharacterImages(c);

      // Avatar is now a pyre:// ref (not a data URL) and its bytes resolve.
      expect(AttachmentStore.isPyreUrl(c.avatar!), isTrue,
          reason: 'inline avatar must be externalised to a pyre:// ref');
      expect(await AttachmentStore.readBytes(c.avatar!), bytes);
    });

    test('externalizeCharacterImages also externalizes inline gallery entries',
        () async {
      final b1 = Uint8List.fromList(List<int>.generate(48, (i) => i % 256));
      final b2 = Uint8List.fromList(
          List<int>.generate(48, (i) => (i + 100) % 256));
      final c = Character(
        id: 'c1',
        name: 'G',
        gallery: [
          'data:image/png;base64,${base64Encode(b1)}',
          'data:image/png;base64,${base64Encode(b2)}',
        ],
      );

      await externalizeCharacterImages(c);

      expect(c.gallery.every(AttachmentStore.isPyreUrl), isTrue);
      expect(await AttachmentStore.readBytes(c.gallery[0]), b1);
      expect(await AttachmentStore.readBytes(c.gallery[1]), b2);
    });

    test('already-externalised refs are left untouched (idempotent)',
        () async {
      final bytes =
          Uint8List.fromList(List<int>.generate(32, (i) => (i * 3) % 256));
      final ref = await AttachmentStore.store(bytes, mime: 'image/png');
      final c = Character(id: 'c1', name: 'R', avatar: ref);
      await externalizeCharacterImages(c);
      expect(c.avatar, ref); // unchanged
    });

    test('a chara_card import builds + externalises an inline avatar',
        () async {
      // Mirror the real import surface: characterFromCharaCard sets the
      // avatar from the card's imageBytes as an inline data URL, then the
      // externalise step turns it into a pyre:// ref. This is the path a
      // user's BotBooru / chub import takes.
      final avatarBytes = Uint8List.fromList(
          List<int>.generate(200, (i) => (i * 13 + 7) % 256));
      final card = CharaCard(
        card: {'name': 'PngCard', 'description': 'hi'},
        raw: {'spec': 'chara_card_v2'},
        imageBytes: avatarBytes,
      );
      final c = characterFromCharaCard(card);
      // characterFromCharaCard sets an inline data: avatar from the card.
      expect(c.avatar, isNotNull);
      expect(c.avatar!.startsWith('data:'), isTrue);

      await externalizeCharacterImages(c);
      expect(AttachmentStore.isPyreUrl(c.avatar!), isTrue);
      expect(await AttachmentStore.readBytes(c.avatar!), avatarBytes);
    });
  });
}
