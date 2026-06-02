// Wave CY.18.141: pure helper for the FRONTEND gallery route.
//
// Per the BotBooru site owner's request ("don't go around sharing our API,
// use our frontend"), Pyre no longer calls BotBooru's JSON API. Instead, the
// gallery is read from the page's RENDERED DOM inside Pyre's embedded Discover
// webview (Wave 142 wires that up): the webview reads the `img` srcs out of
// `#post-mini-gallery` — which BotBooru's own frontend JS already populated —
// and hands them here to be turned into clean, host-gated full-res image URLs
// for `downloadGalleryImages`.
//
// This function is the SECURITY BOUNDARY for that read: it only emits URLs on
// an allowed host. A relative `/mini-gallery/{id}/...` src implicitly belongs
// to botbooru.com; an absolute src on a non-allowed host (e.g.
// `https://evil.test/...` or a lookalike `botbooru.com.attacker.io`) is
// REJECTED. Pure: no I/O, never throws.

/// Resolve the raw `img.src` values read from a BotBooru character page's
/// rendered mini-gallery DOM (`#post-mini-gallery img`) into absolute,
/// host-gated, full-resolution image URLs.
///
/// The DOM srcs look like `/mini-gallery/{id}/preview/480` (relative) or an
/// absolute `https://botbooru.com/mini-gallery/{id}/preview/480`. We extract
/// the numeric gallery id and rebuild the canonical full-res URL
/// `https://botbooru.com/mini-gallery/{id}` (dropping any `/preview/{size}`
/// tail), host-gate against [allowedHosts], and dedupe preserving first-seen
/// order.
///
/// Returns `[]` for empty / no-id / all-off-host input — never throws.
List<String> resolveBotbooruGalleryDomUrls(
  List<String> domSrcs, {
  required Set<String> allowedHosts,
}) {
  final allowed = allowedHosts.map((h) => h.toLowerCase()).toSet();
  final out = <String>[];
  final seen = <String>{};
  final re = RegExp(r'/mini-gallery/(\d+)', caseSensitive: false);
  for (final src in domSrcs) {
    if (src.isEmpty) continue;
    // Host-gate absolute refs (relative refs belong to the botbooru host).
    if (src.startsWith('http://') || src.startsWith('https://')) {
      final u = Uri.tryParse(src);
      if (u == null || !allowed.contains(u.host.toLowerCase())) continue;
    }
    final m = re.firstMatch(src);
    final id = m?.group(1);
    if (id == null || id.isEmpty) continue;
    if (!seen.add(id)) continue;
    out.add('https://botbooru.com/mini-gallery/$id');
  }
  return out;
}
