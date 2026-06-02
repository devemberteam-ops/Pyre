import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/attachment_store.dart';
import '../theme.dart';
import 'lightbox.dart';

/// Circular avatar that handles three cases:
///  - `dataUrl == null` → coloured circle with the first character of `fallback`
///  - `dataUrl` is a `data:image/...;base64,...` URI → decoded MemoryImage
///  - `dataUrl` is a regular http(s) URL → NetworkImage
///
/// Pass [tappableLightbox] = true to open the image fullscreen on tap.
///
/// Wave CY.4: caches the decoded `MemoryImage` per `dataUrl` so streaming
/// chunks (which rebuild the chat tree multiple times per second) don't
/// produce a fresh ImageProvider object on every frame. Without this
/// cache the avatars visibly flicker as messages stream in — Flutter
/// sees a new identity each rebuild and reloads the texture. The cache
/// is bounded so swapping between many characters doesn't pin every
/// avatar in memory forever; once we exceed the cap we drop everything
/// and the next paint pays a single decode each.
final Map<String, MemoryImage> _avatarDecodeCache = <String, MemoryImage>{};
const int _avatarCacheMax = 64;

MemoryImage? _decodeAvatar(String dataUrl) {
  final cached = _avatarDecodeCache[dataUrl];
  if (cached != null) return cached;
  if (_avatarDecodeCache.containsKey(dataUrl)) {
    // Cached failure — don't keep retrying a broken URL.
    return null;
  }
  final comma = dataUrl.indexOf(',');
  if (comma <= 0) {
    _avatarDecodeCache[dataUrl] = MemoryImage(Uint8List(0));
    _avatarDecodeCache.remove(dataUrl);
    return null;
  }
  try {
    final bytes = Uint8List.fromList(base64Decode(dataUrl.substring(comma + 1)));
    if (_avatarDecodeCache.length >= _avatarCacheMax) {
      _avatarDecodeCache.clear();
    }
    final img = MemoryImage(bytes);
    _avatarDecodeCache[dataUrl] = img;
    return img;
  } catch (_) {
    return null;
  }
}

class AvatarBubble extends StatelessWidget {
  final String? dataUrl;
  final String fallback;
  final double radius;
  final bool tappableLightbox;

  const AvatarBubble({
    super.key,
    required this.dataUrl,
    required this.fallback,
    this.radius = 22,
    this.tappableLightbox = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        fallback.isNotEmpty ? fallback.characters.first.toUpperCase() : '?';
    ImageProvider? image;
    final url = dataUrl;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('data:')) {
        image = _decodeAvatar(url);
      } else if (url.startsWith('http')) {
        image = NetworkImage(url);
      } else if (AttachmentStore.isPyreUrl(url) && !kIsWeb) {
        // Wave CY.18.64: content-addressed attachment. Sync resolve
        // via the warmed-up dir cache (see main.dart's startup). If
        // warmUp hasn't completed yet OR the backing file is missing
        // (record synced from another device before bytes arrived),
        // `fileForSync` returns null and we render the initial-letter
        // fallback for now — next rebuild after the file lands will
        // show the image.
        final f = AttachmentStore.fileForSync(url);
        if (f != null) {
          image = FileImage(f);
        }
      }
    }
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: EmberColors.bgElevated,
      backgroundImage: image,
      child: image == null
          ? Text(
              initial,
              style: TextStyle(
                color: EmberColors.textHigh,
                fontWeight: FontWeight.w600,
                fontSize: radius * 0.7,
              ),
            )
          : null,
    );
    if (!tappableLightbox || image == null) return avatar;
    return GestureDetector(
      onTap: () => Lightbox.show(context, dataUrl: dataUrl, fallback: fallback),
      child: avatar,
    );
  }
}
