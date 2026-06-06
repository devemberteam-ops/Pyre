import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/attachment_store.dart';
import '../theme.dart';
import 'lightbox.dart';

/// BATCH P2-ui (J): wrap a list-row avatar [ImageProvider] in a
/// [ResizeImage] so Flutter decodes the source straight to the displayed
/// thumbnail size instead of its intrinsic (card-sized, ~1024×1536) pixel
/// dimensions.
///
/// Card avatars are stored full-res. Without this, a single 44px-circle
/// avatar decodes to a ~6 MB RGBA texture; at 100+ rows that is the OOM
/// driver. Decoding to `diameter × devicePixelRatio` cuts each texture to
/// ~30 KB (~200× less) and makes the image-cache key size-specific so
/// same-size rows dedupe.
///
/// `null` provider → `null` (nothing to wrap). The fullscreen lightbox
/// deliberately keeps the un-resized provider (it shows ONE image at full
/// quality on demand), so this is only applied to the in-row thumbnail.
ImageProvider? thumbnailProvider(
  ImageProvider? base, {
  required double diameter,
  required double devicePixelRatio,
}) {
  if (base == null) return null;
  // Target the painted size in physical pixels. Clamp the DPR to a sane
  // floor so a bogus 0 ratio can't ask for a 0-px decode.
  final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
  final px = (diameter * dpr).round();
  if (px <= 0) return base;
  // CRITICAL: use `ResizeImagePolicy.fit`, NOT the default `exact`.
  //
  // With BOTH width and height set, `exact` behaves like `BoxFit.fill` (per
  // Flutter's own docs) — it decodes a tall portrait STRAIGHT INTO A SQUARE,
  // distorting it at decode time. That squished square is then painted into the
  // square avatar circle with zero overflow, so the `BoxFit.cover` +
  // [kAvatarFaceAlignment] face-framing is a complete no-op (nothing to crop).
  //
  // `fit` preserves the source aspect ratio (decoding within the px×px box, so
  // a 1024×1536 portrait decodes to ~px-wide × taller), giving the cover-crop
  // real vertical overflow to bias toward the face. Memory stays bounded (both
  // dimensions are still ≤ px), so the OOM-avoidance intent is preserved.
  return ResizeImage(base, width: px, height: px, policy: ResizeImagePolicy.fit);
}

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

/// Estimated face position for the circular thumbnail crop. Character-card art
/// is overwhelmingly head-and-shoulders or full-body PORTRAIT (taller than
/// wide), where the face sits in the upper third. `BoxFit.cover` defaults to
/// CENTER, which crops to the torso and cuts the face off — the "whole image
/// squished in a tiny circle looks horrible" complaint. Biasing the crop window
/// upward frames the face automatically, no manual recrop needed. Y = -1 is the
/// very top, 0 is center; -0.5 lands on the upper third without clipping the
/// top of the head for square art.
const Alignment kAvatarFaceAlignment = Alignment(0.0, -0.5);

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

  /// Non-destructive Recrop: when provided, the fullscreen lightbox opens THIS
  /// image (the uncropped original) instead of the displayed thumbnail
  /// [dataUrl]. Callers that have the owning character/persona pass
  /// `avatarOriginal ?? avatar` so tapping the circle shows the WHOLE picture,
  /// not the face-cropped thumbnail. Null → the lightbox falls back to
  /// [dataUrl] (unchanged behaviour for call sites without the full record).
  final String? fullImageUrl;

  const AvatarBubble({
    super.key,
    required this.dataUrl,
    required this.fallback,
    this.radius = 22,
    this.tappableLightbox = false,
    this.fullImageUrl,
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
    // BATCH P2-ui (J): decode the row thumbnail at the painted size, not the
    // source's intrinsic (card) resolution. The fullscreen lightbox below
    // still opens from the original full-res `dataUrl`, so quality on tap is
    // unaffected.
    final thumb = thumbnailProvider(
      image,
      diameter: radius * 2,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0,
    );
    // When there's an image, render it through a DecorationImage so we can
    // bias the cover-crop toward the face ([kAvatarFaceAlignment]) — CircleAvatar
    // only does center-cover, which cuts faces off on portrait art. Fall back to
    // the coloured initial circle when there's no image.
    final Widget avatar = image == null
        ? CircleAvatar(
            radius: radius,
            backgroundColor: EmberColors.bgElevated,
            child: Text(
              initial,
              style: TextStyle(
                color: EmberColors.textHigh,
                fontWeight: FontWeight.w600,
                fontSize: radius * 0.7,
              ),
            ),
          )
        : Container(
            width: radius * 2,
            height: radius * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: EmberColors.bgElevated,
              image: DecorationImage(
                image: thumb!,
                fit: BoxFit.cover,
                alignment: kAvatarFaceAlignment,
              ),
            ),
          );
    if (!tappableLightbox || image == null) return avatar;
    // Non-destructive Recrop: open the uncropped original in the lightbox when
    // the caller supplied one (`fullImageUrl`), else the displayed thumbnail.
    final lightboxUrl = fullImageUrl ?? dataUrl;
    return GestureDetector(
      onTap: () =>
          Lightbox.show(context, dataUrl: lightboxUrl, fallback: fallback),
      child: avatar,
    );
  }
}
