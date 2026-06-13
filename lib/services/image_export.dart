import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'web_download.dart';

/// Wave CY.18.250: shared "write image bytes to PyreExports + offer Share"
/// helper. Mirrors `_exportCharacterAsPng`'s native write-to-PyreExports +
/// OS Share sheet + snackbar, with the same `kIsWeb` clipboard fallback.
///
/// Used by the gallery-image download (lightbox/strip), the card export's
/// gallery files, and the persona PNG export — so the destination + share
/// mechanism stay identical to the long-standing character-card export.
///
/// [filename] must already include the `.png` extension.
/// [shareSubject] is the OS share sheet's subject line.
Future<void> saveImageBytesToExports(
  BuildContext context,
  Uint8List bytes,
  String filename, {
  String? shareSubject,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (kIsWeb) {
      // Web has no filesystem — trigger a real browser download instead of the
      // old data-URL→clipboard fallback (which couldn't actually save a file).
      downloadBytesToBrowser(bytes, filename, 'image/png');
      messenger.showSnackBar(
        SnackBar(content: Text('Downloading $filename')),
      );
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/PyreExports');
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final file = File('${outDir.path}/$filename');
    await file.writeAsBytes(bytes);
    // Drop any lingering banner first — opening the OS share sheet pauses
    // a live SnackBar's dismiss timer, so it would otherwise stick around.
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Saved — ${file.uri.pathSegments.last}'),
        action: SnackBarAction(
          label: 'Share',
          onPressed: () async {
            try {
              await Share.shareXFiles(
                [XFile(file.path, mimeType: 'image/png')],
                subject: shareSubject,
              );
            } catch (e) {
              messenger.showSnackBar(
                SnackBar(content: Text('Share failed: $e')),
              );
            }
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Save failed: $e')),
    );
  }
}
