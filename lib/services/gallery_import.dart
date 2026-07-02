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

import 'package:http/http.dart' as http;

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

/// Result of [downloadGalleryImagesWithStats]: the stored `pyre://attachment/…`
/// refs, plus how many of the REQUESTED urls were never even attempted
/// because a cap ([kMaxGalleryImages] / [kMaxGalleryAggregateBytes]) was
/// already hit when the loop reached them. Audit fix #2: the caps used to
/// truncate silently — this makes the truncation visible so a caller can
/// tell the user e.g. "Imported 12 of 20 gallery images (size cap reached)".
class GalleryDownloadResult {
  /// The `pyre://attachment/…` refs successfully stored, in order.
  final List<String> refs;

  /// Count of input urls that were never attempted because the count cap
  /// ([kMaxGalleryImages]) or the aggregate byte cap
  /// ([kMaxGalleryAggregateBytes]) was already reached. Does NOT include
  /// urls that were attempted and skipped for other reasons (bad host,
  /// fetch failure, non-image response) — those are silent best-effort
  /// skips unrelated to the caps.
  final int skippedForCap;

  const GalleryDownloadResult(this.refs, this.skippedForCap);
}

/// Download + store each gallery image, returning the refs gathered plus a
/// cap-truncation count. Best-effort: a failed / oversized / non-image entry
/// is skipped (logged) and does NOT count toward [GalleryDownloadResult
/// .skippedForCap] — only urls left untried once a cap is hit are counted.
/// Downloading stops once [kMaxGalleryImages] is reached or the aggregate
/// exceeds [kMaxGalleryAggregateBytes]. Returns an empty result on web
/// (AttachmentStore is a no-op there) or when nothing could be gathered.
///
/// [client] is injectable for tests (mirrors [fetchCappedNoRedirect]'s own
/// injectable client); production passes nothing and each fetch creates +
/// closes its own client as before.
Future<GalleryDownloadResult> downloadGalleryImagesWithStats(
  List<String> urls, {
  http.Client? client,
}) async {
  final refs = <String>[];
  var aggregate = 0;
  for (var i = 0; i < urls.length; i++) {
    if (refs.length >= kMaxGalleryImages ||
        aggregate >= kMaxGalleryAggregateBytes) {
      // A cap is already hit — every remaining url (this one included) is
      // left untried. Count them all and stop.
      return GalleryDownloadResult(refs, urls.length - i);
    }
    final url = urls[i];
    try {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !kBotbooruGalleryHosts.contains(uri.host.toLowerCase())) {
        continue;
      }
      final resp = await fetchCappedNoRedirect(
        uri,
        maxBytes: kMaxGalleryImageBytes,
        client: client,
      );
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
  return GalleryDownloadResult(refs, 0);
}

/// Legacy entry point kept for existing callers ([main.dart]'s bookmarklet
/// handoff, `characters_screen.dart`'s file-import paths) that only ever
/// pass an empty `urls` list today and don't need the cap-visibility stats —
/// returns just the refs from [downloadGalleryImagesWithStats].
Future<List<String>> downloadGalleryImages(
  List<String> urls, {
  http.Client? client,
}) async {
  final result = await downloadGalleryImagesWithStats(urls, client: client);
  return result.refs;
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
