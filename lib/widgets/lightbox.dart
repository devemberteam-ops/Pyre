import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/attachment_store.dart';

/// Tap-to-dismiss fullscreen image viewer with pinch-zoom + pan.
class Lightbox extends StatelessWidget {
  final String? dataUrl;
  final String? heroTag;
  final String fallback;
  const Lightbox({
    super.key,
    required this.dataUrl,
    required this.fallback,
    this.heroTag,
  });

  ImageProvider? _decode() => resolveImage(dataUrl);

  /// Resolve any avatar/gallery image reference to an [ImageProvider],
  /// or null when it can't be shown (empty, web pyre://, missing blob,
  /// un-decodable). This is the SINGLE source of truth for `pyre://` /
  /// `data:` / `http` / raw-base64 fullscreen rendering — `GalleryStrip`
  /// (swipeable viewer) reuses it so there's no second decoder to drift.
  static ImageProvider? resolveImage(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('data:')) {
      final comma = url.indexOf(',');
      if (comma > 0) {
        try {
          return MemoryImage(
              Uint8List.fromList(base64Decode(url.substring(comma + 1))));
        } catch (_) {}
      }
      return null;
    }
    if (url.startsWith('http')) return NetworkImage(url);
    // Wave CY.18.129: content-addressed attachment ref. Gallery images
    // (and any pyre:// avatar) resolve through the same sync dir cache
    // the avatar widget uses (`AttachmentStore.fileForSync` → FileImage).
    // Returns null before warmUp / when the backing file is missing →
    // the fallback letter renders, matching AvatarBubble.
    if (AttachmentStore.isPyreUrl(url)) {
      if (kIsWeb) {
        // Wave CY.18.255 (FIX 3): web has no local fs, so resolve the blob
        // over HTTP from the paired desktop server's bearer-protected
        // `GET /attachments/<hash>` endpoint. NetworkImage carries the auth
        // header and (unlike resolveImage's other branches) works
        // asynchronously inside the ImageProvider, so the sync API stays
        // intact. Returns null when not paired → fallback letter renders.
        final req = AttachmentStore.webAttachmentRequest(url);
        if (req != null) return NetworkImage(req.url, headers: req.headers);
        return null;
      }
      final f = AttachmentStore.fileForSync(url);
      if (f != null) return FileImage(f);
      return null;
    }
    // Wave CY.18.44: tolerate raw base64 without a `data:` prefix.
    // Some legacy chub.ai exports + hand-edited backups carry the avatar
    // as just the base64 payload (no scheme), which made the lightbox
    // fall through to "?" placeholder while the small list-card view
    // (which decodes raw base64 via AvatarBubble) showed the image
    // fine. The mismatch confused users into thinking their cards had
    // broken avatars when only this one view path was bailing out.
    // Sniff the value as base64 and decode if it parses.
    try {
      // Strip stray whitespace/newlines that line-wrapped exports leak.
      final cleaned = url.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.length >= 16) {
        return MemoryImage(Uint8List.fromList(base64Decode(cleaned)));
      }
    } catch (_) {
      // Not valid base64 either — fall through to null and let the
      // fallback letter render.
    }
    return null;
  }

  /// Wrap the `Image` with an `errorBuilder` so a `FileImage` whose
  /// backing attachment file is missing (synced-record-without-bytes,
  /// or a deleted blob) renders a broken-image glyph instead of a red
  /// framework error box. Mirrors the broken-image fallback the avatar
  /// + gallery-thumb paths use.
  static Widget imageWidget(ImageProvider img) => Image(
        image: img,
        errorBuilder: (_, _, _) => const Center(
          child: Icon(Icons.broken_image_outlined,
              color: Colors.white54, size: 72),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final img = _decode();
    final content = img == null
        ? Center(
            child: Text(
              fallback.isNotEmpty
                  ? fallback.characters.first.toUpperCase()
                  : '?',
              style:
                  const TextStyle(color: Colors.white, fontSize: 96),
            ),
          )
        : InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: heroTag != null
                  ? Hero(tag: heroTag!, child: imageWidget(img))
                  : imageWidget(img),
            ),
          );
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.96),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: content,
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static void show(BuildContext context,
      {required String? dataUrl, required String fallback, String? heroTag}) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          Lightbox(dataUrl: dataUrl, fallback: fallback, heroTag: heroTag),
    ));
  }
}
