// Friendly HTTP failure messages for the community-card download paths.
//
// Pyre fetches PNG bytes directly (outside the WebView) from a small set
// of community marketplaces (botbooru.com, chub.ai, etc.). Each one has
// its own throttles and quirks, and a bare `HTTP 429` is opaque to a
// non-technical user — they think the app is broken.
//
// Botbooru's `/download/png/{id}` route in particular is rate-limited
// to a couple of requests per minute per client after a scraping
// incident. A user who taps Download on a few cards in quick succession
// WILL trip it. Surfacing a "rate-limiting you, try again in N seconds"
// message keeps it from looking like a bug.

import 'package:http/http.dart' as http;

/// Returns a user-friendly one-line message describing why [r] failed.
/// Pass [host] (e.g. via [friendlyHostName]) to identify the upstream;
/// falls back to "the server" if omitted.
String describeHttpFailure(http.Response r, {String? host}) {
  final h = host ?? 'the server';
  switch (r.statusCode) {
    case 429:
      // Retry-After can be either delta-seconds (integer) or an HTTP-date.
      // We only parse the seconds form on purpose — Dart's HTTP-date
      // parser lives in dart:io and importing that breaks Flutter Web
      // builds. The seconds form is what nginx / cloudflare emit by
      // default for rate-limit responses anyway.
      final retry = int.tryParse((r.headers['retry-after'] ?? '').trim());
      if (retry != null && retry > 0) {
        return '$h is rate-limiting downloads. Try again in ${retry}s.';
      }
      return '$h is rate-limiting downloads. Wait a moment and try again.';
    case 503:
      return '$h is temporarily overloaded. Try again in a minute.';
    case 404:
      return 'Card not found on $h (404). The link may have been removed.';
    case 403:
      return '$h refused the request (403). The card may be private.';
    default:
      return 'HTTP ${r.statusCode} from $h.';
  }
}

/// Best-effort short label for a host, used as the `host:` argument to
/// [describeHttpFailure]. Falls back to the raw hostname when no alias
/// matches so the message is still informative.
String friendlyHostName(Uri uri) {
  final h = uri.host.toLowerCase();
  if (h.endsWith('botbooru.com')) return 'Botbooru';
  if (h.endsWith('chub.ai') || h.endsWith('chub.io')) return 'Chub';
  if (h.endsWith('charhub.io') || h.endsWith('characterhub.org')) {
    return 'CharacterHub';
  }
  return uri.host;
}
