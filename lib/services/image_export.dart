import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
      // Web has no filesystem; fall back to clipboard with a data URL,
      // matching the character-card export's web branch.
      final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
      await Clipboard.setData(ClipboardData(text: dataUrl));
      messenger.showSnackBar(
        const SnackBar(
            content: Text(
                'Web: copied image as a data URL to clipboard. Paste into an image editor or save as a file.')),
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
