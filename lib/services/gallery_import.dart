// Wave CY.18.131 / Wave CY.18.141: BotBooru mini-gallery DOWNLOADER.
//
// Wave 141: Pyre no longer DISCOVERS the gallery by calling BotBooru's backend
// (the site owner asked us not to hit their API — "don't share our API, use
// our frontend"). The list of gallery image URLs is now produced by reading
// the rendered page DOM inside Pyre's Discover webview (Wave 142) +
// `resolveBotbooruGalleryDomUrls`. This file just DOWNLOADS that already
// host-gated list into the content-addressed AttachmentStore; the resulting
// `pyre://attachment/<hash>` refs go on `Character.gallery` / `Persona.gallery`.
//
// Hardening (best-effort — a failure NEVER blocks the normal card import):
//   * every image is RE-host-locked to botbooru.com / www.botbooru.com here
//     too (defence in depth — the URL list is already host-gated upstream);
//   * fetched via the shared `fetchCappedNoRedirect` (no-redirect + size-cap);
//   * magic-byte validated (PNG / JPEG / WEBP / GIF) before storing, so a
//     non-image response can't be saved as a "gallery image";
//   * caps: ≤12 images, ≤4 MB each, stop at ≤24 MB aggregate.

import 'dart:typed_data';

import 'capped_fetch.dart';
import 'card_import.dart' show CardImportErrors;
import 'attachment_store.dart';

/// Hosts a gallery page / image is allowed to live on. Mirrors the resolver's
/// exact-host botbooru set so a lookalike (`botbooru.com.attacker.io`) is
/// rejected.
const Set<String> kBotbooruGalleryHosts = {'botbooru.com', 'www.botbooru.com'};

/// Max number of gallery images imported from one card.
const int kMaxGalleryImages = 12;

/// Per-image body cap (OOM guard; a WebP thumbnail is far smaller).
const int kMaxGalleryImageBytes = 4 * 1024 * 1024; // 4 MB

/// Aggregate cap across the whole gallery — stop downloading once the gathered
/// bytes exceed this.
const int kMaxGalleryAggregateBytes = 24 * 1024 * 1024; // 24 MB

/// Download + store each gallery image, returning the `pyre://attachment/…`
/// refs gathered (in order). Best-effort: a failed / oversized / non-image
/// entry is skipped (logged), and downloading stops once
/// [kMaxGalleryImages] is reached or the aggregate exceeds
/// [kMaxGalleryAggregateBytes]. Returns `[]` on web (AttachmentStore is a
/// no-op there) or when nothing could be gathered.
Future<List<String>> downloadGalleryImages(List<String> urls) async {
  final refs = <String>[];
  var aggregate = 0;
  for (final url in urls) {
    if (refs.length >= kMaxGalleryImages) break;
    if (aggregate >= kMaxGalleryAggregateBytes) break;
    try {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !kBotbooruGalleryHosts.contains(uri.host.toLowerCase())) {
        continue;
      }
      final resp =
          await fetchCappedNoRedirect(uri, maxBytes: kMaxGalleryImageBytes);
      if (resp.statusCode >= 400) continue;
      final bytes = resp.bodyBytes;
      final mime = _imageMime(bytes);
      if (mime == null) continue; // not a real image — skip
      aggregate += bytes.length;
      final ref = await AttachmentStore.store(bytes, mime: mime);
      if (ref != null) refs.add(ref);
    } catch (e) {
      CardImportErrors.record('downloadGalleryImages', e);
      // skip this one, keep going
    }
  }
  return refs;
}

/// Sniff the leading bytes for a supported raster image format. Returns the
/// mime type or null when the bytes are not a PNG / JPEG / WEBP / GIF.
String? _imageMime(Uint8List b) {
  if (b.length < 12) return null;
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  // JPEG: FF D8 FF
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  // GIF: "GIF87a" / "GIF89a"
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return 'image/gif';
  }
  // WEBP: "RIFF" .... "WEBP"
  if (b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}
