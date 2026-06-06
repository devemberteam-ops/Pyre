// Marketplace URL resolvers — map a community card page URL to a direct
// PNG / JSON download endpoint.
//
// botbooru.com:
//   /post/{id}, /character/{id}      → /download/png/{id}
//   raw filename                     → /images/preview/640/{filename}
//
// chub.ai:
//   /characters/{author}/{slug}      → avatars.chub.io CDN PNG (GET).
//     The HTML prototype's resolvers.js is the source of truth — we mirror
//     it exactly: take whatever follows /characters/ in the page URL and
//     stick it into the CDN path.
//
// The web prototype's resolvers.js is the source of truth — this is a
// straight port for the Flutter native side, which can call these without
// a CORS proxy.

import 'dart:typed_data';

/// What a resolved URL actually downloads. The vast majority of community
/// links resolve to a CHARACTER (chara_card_v2 PNG / JSON). BotBooru also
/// publishes standalone LOREBOOKs (`/lorebook/{id}` → a bare
/// `character_book` JSON), which take a completely different import path —
/// `tryParseLorebookJson` + `store.addLorebook`, not the PNG/card parser.
/// The discriminator lets a single resolver feed both flows; everything
/// existing keeps the `character` default so the PNG path is untouched.
enum ResolvedKind { character, lorebook }

class ResolvedCard {
  /// The URL to GET for the bytes (PNG card, or lorebook JSON).
  final Uri pngUrl;
  final String source; // 'botbooru' | 'chub' | 'risurealm' | 'direct'
  /// Whether [pngUrl] downloads a character card or a standalone lorebook.
  /// Defaults to [ResolvedKind.character] so every existing call site (and
  /// the PNG flow) behaves exactly as before.
  final ResolvedKind kind;
  /// Optional pre-fetched PNG bytes — used when the resolver had to
  /// fetch the data itself (currently unused; reserved for future
  /// endpoints that require POST/auth).
  final Uint8List? bytes;
  ResolvedCard(
    this.pngUrl,
    this.source, {
    this.kind = ResolvedKind.character,
    this.bytes,
  });
}

/// File-hosting services people routinely use to share a bare
/// chara_card_v2 PNG / JSON. These are added to every card-download
/// allowlist so a direct link from them passes the trusted-host check
/// the same way botbooru/chub CDNs do. Hosts here are general-purpose
/// (anyone can upload), so this is NOT a statement of trust in the
/// *content* — the import confirm dialog + strict card parse still
/// gate what actually gets saved. Exact-host matches only (no
/// `contains`), so a lookalike like `catbox.moe.evil.com` is rejected.
const Set<String> kCardFileHostAllowlist = {
  'files.catbox.moe',
  'catbox.moe',
  'www.catbox.moe',
  'pixeldrain.com',
  'www.pixeldrain.com',
  // pixeldrain serves direct file bytes from this host (api.pixeldrain.com
  // /api/file/{id}); include it so a direct-file link resolves.
  'api.pixeldrain.com',
};

/// Exact-host set for BotBooru. Used both by [resolveCommunityUrl] and by
/// [isBotbooruLorebookUrl] so a lookalike (`evilbotbooru.com`,
/// `botbooru.com.attacker.io`) is never treated as BotBooru.
const Set<String> _botbooruHosts = {'botbooru.com', 'www.botbooru.com'};

/// Frontend-only lorebook rework: detect a BotBooru LOREBOOK URL so the
/// paste-by-URL import path can REFUSE to fetch it from the app and instead
/// tell the user to open it in Discover and tap "Download JSON".
///
/// The owner's hard rule is that the app must NOT call BotBooru's API
/// directly — and the lorebook download endpoint
/// (`/api/lorebooks/{id}/download.json`) is bot-gated (403 to the app's
/// cookie-less client), so it only works inside the logged-in webview. This
/// gate catches BOTH the human-facing `/lorebook/{id}` page and the raw
/// `/api/lorebooks/{id}/download.json` API URL on an EXACT BotBooru host (a
/// lookalike returns false). Pure, no I/O.
bool isBotbooruLorebookUrl(String input) {
  final cleaned = input.trim();
  if (cleaned.isEmpty) return false;
  final uri = Uri.tryParse(cleaned);
  if (uri == null) return false;
  if (!_botbooruHosts.contains(uri.host.toLowerCase())) return false;
  final segments = uri.pathSegments;
  // `/lorebook/{id}` page.
  if (segments.length >= 2 && segments[0] == 'lorebook') return true;
  // `/api/lorebooks/{id}/download.json` API URL.
  if (segments.length >= 4 &&
      segments[0] == 'api' &&
      segments[1] == 'lorebooks' &&
      segments[3] == 'download.json') {
    return true;
  }
  return false;
}

Future<ResolvedCard?> resolveCommunityUrl(String input) async {
  final cleaned = input.trim();
  if (cleaned.isEmpty) return null;
  final uri = Uri.tryParse(cleaned);
  if (uri == null) return null;

  // Frontend-only lorebook rework: BotBooru LOREBOOK page URLs are NO LONGER
  // mapped to an `/api/lorebooks/.../download.json` fetch target. The app must
  // never call BotBooru's API; the lorebook bytes are captured by the embedded
  // webview's authenticated JS hook (which posts the JSON TEXT to native), so
  // the resolver/fetch path is not involved for lorebooks at all. A pasted
  // `/lorebook/{id}` page therefore resolves to null here, and Discover's
  // paste-URL handler detects it via [isBotbooruLorebookUrl] and shows a hint.
  const botbooruHosts = _botbooruHosts;

  // Already a direct card link — a .png (chara_card_v2 embedded in PNG
  // metadata) OR a .json (raw chara_card JSON, the form catbox/pixeldrain
  // and many exporters hand out). Both resolve to a plain GET; the
  // importer picks the parser by extension. Source stays 'direct' so the
  // fetch side knows to run the allowlist / public-host SSRF gate.
  final lowerPath = uri.path.toLowerCase();
  if (lowerPath.endsWith('.png') || lowerPath.endsWith('.json')) {
    return ResolvedCard(uri, 'direct');
  }

  // Botbooru post/character page.
  // Wave CY: was `host.contains('botbooru')` which lets
  // `evilbotbooru.com` and `botbooru.com.attacker.io` through. Use an
  // exact-host set so a hostile lookalike can't drive the resolver.
  // (Reuses the `botbooruHosts` set declared for the lorebook branch above.)
  if (botbooruHosts.contains(uri.host.toLowerCase())) {
    final segments = uri.pathSegments;
    // Wave CY.18.149: the URL is ALREADY a direct download link
    // (`/download/png/{id}`). The Windows Discover webview's JS hook posts
    // exactly this when the user clicks "Download PNG", so we MUST tag it
    // `source: 'botbooru'` — otherwise it falls through to `null` and the
    // gallery gate in _importFromUrl (`resolved?.source == 'botbooru'`)
    // silently drops the mini-gallery even though the card still imports via
    // the trusted-host direct fetch. This was the real cause of "Download PNG
    // didn't bring the gallery" — the srcs arrived fine, the gate threw them
    // away. Keep `pngUrl == uri` (it's the final download URL already).
    if (segments.length >= 3 &&
        segments[0] == 'download' &&
        segments[1] == 'png') {
      return ResolvedCard(uri, 'botbooru');
    }
    String? id;
    for (var i = 0; i < segments.length - 1; i++) {
      if (segments[i] == 'post' || segments[i] == 'character') {
        id = segments[i + 1];
        break;
      }
    }
    if (id != null) {
      final png = Uri.parse('https://botbooru.com/download/png/$id');
      return ResolvedCard(png, 'botbooru');
    }
  }

  // Chub.ai character page → avatars.chub.io CDN PNG.
  // Wave CT.1: dropped the api.chub.ai POST path — it was a misread of
  // chub's API and never returned the bytes we expected. The CDN path
  // mirrors the HTML prototype's resolveChub and is a plain GET.
  // Wave CY: exact-host set instead of `contains(...)`.
  const chubPageHosts = {
    'chub.ai',
    'www.chub.ai',
    'characterhub.org',
    'www.characterhub.org',
  };
  if (chubPageHosts.contains(uri.host.toLowerCase())) {
    final segments = uri.pathSegments;
    final ci = segments.indexOf('characters');
    if (ci >= 0 && ci + 1 < segments.length) {
      // Keep every segment after /characters/ (covers `/author/slug` AND
      // the rarer `/author-slug-hash` single-segment form).
      final path = segments
          .sublist(ci + 1)
          .map(Uri.encodeComponent)
          .join('/')
          .replaceAll(RegExp(r'/+$'), '');
      if (path.isNotEmpty) {
        // Note: the HTML prototype references `avatars.chub.io` but that
        // host has no DNS record on real devices — the prototype runs
        // behind a CORS proxy that rewrites the request. The actual CDN
        // is `avatars.charhub.io` (vestige of the pre-rebrand
        // "characterhub" name), which is also the host already on the
        // app's download allowlist.
        final png = Uri.parse(
            'https://avatars.charhub.io/avatars/$path/chara_card_v2.png');
        return ResolvedCard(png, 'chub');
      }
    }
  }

  // RisuRealm character page → the download API's chara_card_v2 PNG.
  //   /character/{id}  →  /api/v1/download/png-v2/{id}
  // The download endpoint returns the same PNG-embedded chara_card_v2 the
  // importer already parses (`parseCharaCardPng`); `json-v2` is the same
  // card as JSON. `charx-v3` is a zip and unsupported — never resolved to.
  // Exact-host set (no `contains`) so a lookalike like
  // `realm.risuai.net.evil.com` is rejected.
  const risurealmHosts = {'realm.risuai.net', 'www.realm.risuai.net'};
  if (risurealmHosts.contains(uri.host.toLowerCase())) {
    final segments = uri.pathSegments;
    // Pasted API URL (`/api/v1/download/png-v2/{id}` or `.../json-v2/...`):
    // pass it straight through. It never matched the .png/.json direct
    // suffix above (the id has no extension), so tag it 'risurealm' and let
    // the allowlist fetch handle it.
    final di = segments.indexOf('download');
    if (di >= 0 && di + 1 < segments.length) {
      return ResolvedCard(uri, 'risurealm');
    }
    // Character page: take the segment after 'character' as the id.
    String? id;
    for (var i = 0; i < segments.length - 1; i++) {
      if (segments[i] == 'character') {
        id = segments[i + 1];
        break;
      }
    }
    if (id != null && id.isNotEmpty) {
      // Native-first: plain endpoint, no query params. (On a WEB build a
      // cross-origin fetch *might* need the API's `?cors=` param — out of
      // scope here; the native APK/EXE is the target, so we don't add it.)
      final png = Uri.parse(
          'https://realm.risuai.net/api/v1/download/png-v2/$id');
      return ResolvedCard(png, 'risurealm');
    }
  }

  return null;
}

/// SSRF guard for the "paste ANY direct link" import path.
///
/// When the user pastes a direct PNG/JSON link from a host that ISN'T on
/// the curated download allowlist, we still want to let them import — but
/// only from a *public* internet host. Returning false here blocks the
/// fetch, so a pasted (or attacker-supplied) link can't make the app GET
/// `http://localhost:…`, a LAN/router address, a cloud metadata endpoint
/// reachable over a private range, etc. (server-side request forgery).
///
/// Pure function: no I/O, no DNS. It rejects [host] when it is a known
/// non-routable name or parses as a loopback / private / link-local IP
/// literal. Anything else (a normal DNS hostname, a public IPv4/IPv6) is
/// treated as public. NOTE: this is a literal-IP + name check only; it
/// does NOT resolve DNS, so a hostname that *resolves* to a private IP is
/// not caught here — pair it with the no-redirect fetch (a 3xx to an
/// internal address is already refused) for defence in depth.
///
/// Strips an IPv6 bracket wrapper (`[::1]`) and any zone id (`%eth0`)
/// before matching. Comparison is case-insensitive.
bool isPublicHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  // Strip IPv6 brackets if present: `[::1]` -> `::1`.
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  // Strip an IPv6 zone id (`fe80::1%eth0`).
  final pct = h.indexOf('%');
  if (pct >= 0) h = h.substring(0, pct);
  if (h.isEmpty) return false;

  // Non-routable / loopback hostnames.
  if (h == 'localhost' ||
      h == 'localhost.localdomain' ||
      h.endsWith('.localhost')) {
    return false;
  }

  // IPv4 literal?
  final v4 = _parseIPv4(h);
  if (v4 != null) return _isPublicIPv4(v4);

  // IPv6 literal?
  if (h.contains(':')) {
    final v6 = _parseIPv6(h);
    if (v6 != null) return _isPublicIPv6(v6);
    // Looks like IPv6 (has a colon) but didn't parse — refuse rather
    // than treat an unparseable address as public.
    return false;
  }

  // A normal DNS hostname — treated as public.
  return true;
}

/// Mega-audit 2026-06-05 (H-7): SSRF gate for provider Browse / Test /
/// warm-up requests.
///
/// Unlike the import paths, the provider endpoints (`/v1/models` Browse,
/// "Test connection", the launch-time warm-up POST) issue a raw HTTP
/// request straight to `provider.baseUrl`. A SYNCED or IMPORTED provider
/// record could point that URL at an internal host — and the launch-time
/// warm-up fires UNATTENDED — so a malicious peer/record could make the
/// app probe `http://192.168.x.x/…`, a cloud metadata endpoint, etc.
///
/// Pure decision: should we be allowed to issue an outbound request to the
/// host of [baseUrl]?
///   * [isLocalhostKind] = true  → the EXPLICIT localhost provider kind
///     (LM Studio / Ollama). The user deliberately created it to talk to a
///     local server, so loopback/private targets are EXPECTED and allowed.
///   * Otherwise (External / proxy kind) the host must be public:
///     a private/loopback/link-local target is refused (returns false).
///
/// Reuses [isPublicHost] (literal-IP + non-routable-name check, no DNS) so
/// there is exactly ONE SSRF classifier in the codebase. An unparseable /
/// empty URL is refused (returns false) for the non-localhost kind.
bool isProviderHostAllowed(String baseUrl, {required bool isLocalhostKind}) {
  // The explicit localhost kind is allowed to reach private/loopback
  // targets — that's its whole purpose (LM Studio/Ollama on this machine
  // or the LAN). We don't second-guess a kind the user picked themselves.
  if (isLocalhostKind) return true;
  Uri u;
  try {
    u = Uri.parse(baseUrl.trim());
  } catch (_) {
    return false;
  }
  final host = u.host;
  if (host.isEmpty) return false;
  return isPublicHost(host);
}

/// Parse a dotted-quad IPv4 literal into its four octets, or null if [s]
/// is not a well-formed IPv4 address (rejects leading-zero ambiguity,
/// octets > 255, wrong segment count).
List<int>? _parseIPv4(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return null;
    for (final c in p.codeUnits) {
      if (c < 0x30 || c > 0x39) return null; // not a digit
    }
    final n = int.parse(p);
    if (n > 255) return null;
    octets.add(n);
  }
  return octets;
}

/// RFC1918 / loopback / link-local / unspecified ranges are NOT public.
bool _isPublicIPv4(List<int> o) {
  final a = o[0], b = o[1];
  if (a == 0) return false; // 0.0.0.0/8 ("this network", incl. 0.0.0.0)
  if (a == 127) return false; // 127.0.0.0/8 loopback
  if (a == 10) return false; // 10.0.0.0/8 private
  if (a == 172 && b >= 16 && b <= 31) return false; // 172.16.0.0/12 private
  if (a == 192 && b == 168) return false; // 192.168.0.0/16 private
  if (a == 169 && b == 254) return false; // 169.254.0.0/16 link-local
  return true;
}

/// Parse an IPv6 literal (incl. `::` compression and embedded IPv4 tail)
/// into 16 bytes, or null if malformed. Deliberately small — enough to
/// classify the address, not a full validator.
List<int>? _parseIPv6(String s) {
  if (!s.contains(':')) return null;
  // Split off an embedded IPv4 tail (e.g. `::ffff:192.168.0.1`).
  List<int>? tail4;
  var work = s;
  final lastColon = work.lastIndexOf(':');
  final maybeV4 = work.substring(lastColon + 1);
  if (maybeV4.contains('.')) {
    tail4 = _parseIPv4(maybeV4);
    if (tail4 == null) return null;
    work = work.substring(0, lastColon + 1); // keep trailing ':'
  }

  final hasCompression = work.contains('::');
  // '::' must appear at most once.
  if (work.indexOf('::') != work.lastIndexOf('::')) return null;

  final groups = <int>[];
  if (hasCompression) {
    final halves = work.split('::');
    if (halves.length != 2) return null;
    final left = halves[0].isEmpty
        ? <String>[]
        : halves[0].split(':').where((e) => e.isNotEmpty).toList();
    final right = halves[1].isEmpty
        ? <String>[]
        : halves[1].split(':').where((e) => e.isNotEmpty).toList();
    final leftWords = <int>[];
    for (final g in left) {
      final w = _hexWord(g);
      if (w == null) return null;
      leftWords.add(w);
    }
    final rightWords = <int>[];
    for (final g in right) {
      final w = _hexWord(g);
      if (w == null) return null;
      rightWords.add(w);
    }
    final tailWords = (tail4 != null) ? 2 : 0;
    final present = leftWords.length + rightWords.length + tailWords;
    if (present > 8) return null;
    final zeros = 8 - present;
    groups
      ..addAll(leftWords)
      ..addAll(List<int>.filled(zeros, 0))
      ..addAll(rightWords);
  } else {
    final segs = work.split(':').where((e) => e.isNotEmpty).toList();
    for (final g in segs) {
      final w = _hexWord(g);
      if (w == null) return null;
      groups.add(w);
    }
    final tailWords = (tail4 != null) ? 2 : 0;
    if (groups.length + tailWords != 8) return null;
  }

  final bytes = <int>[];
  for (final w in groups) {
    bytes
      ..add((w >> 8) & 0xff)
      ..add(w & 0xff);
  }
  if (tail4 != null) bytes.addAll(tail4);
  if (bytes.length != 16) return null;
  return bytes;
}

/// Parse a single IPv6 hextet (1–4 hex digits) into a 16-bit word.
int? _hexWord(String g) {
  if (g.isEmpty || g.length > 4) return null;
  var v = 0;
  for (final c in g.codeUnits) {
    int d;
    if (c >= 0x30 && c <= 0x39) {
      d = c - 0x30;
    } else if (c >= 0x61 && c <= 0x66) {
      d = c - 0x61 + 10;
    } else if (c >= 0x41 && c <= 0x46) {
      d = c - 0x41 + 10;
    } else {
      return null;
    }
    v = (v << 4) | d;
  }
  return v;
}

/// Loopback (`::1`), unspecified (`::`), ULA (`fc00::/7`), and link-local
/// (`fe80::/10`) IPv6 ranges are NOT public. An IPv4-mapped address
/// (`::ffff:a.b.c.d`) is classified by its embedded IPv4.
bool _isPublicIPv6(List<int> b) {
  // Unspecified `::` (all zero).
  if (b.every((x) => x == 0)) return false;
  // Loopback `::1`.
  var loop = true;
  for (var i = 0; i < 15; i++) {
    if (b[i] != 0) {
      loop = false;
      break;
    }
  }
  if (loop && b[15] == 1) return false;
  // IPv4-mapped `::ffff:0:0/96` — judge by the embedded IPv4.
  final mappedPrefixZero =
      b.sublist(0, 10).every((x) => x == 0);
  if (mappedPrefixZero && b[10] == 0xff && b[11] == 0xff) {
    return _isPublicIPv4(b.sublist(12, 16));
  }
  // ULA fc00::/7 — first 7 bits are 1111110.
  if ((b[0] & 0xfe) == 0xfc) return false;
  // Link-local fe80::/10 — first 10 bits are 1111111010.
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false;
  return true;
}
