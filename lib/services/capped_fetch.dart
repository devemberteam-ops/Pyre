// Wave CY.18.131: shared no-redirect, size-capped HTTP fetch.
//
// Several import paths (typed URL dialog, bookmarklet `?import=`, Discover
// bridge) GET a remote card after their own host/SSRF gate has run. They all
// need the SAME hardening: redirects DISABLED (a 3xx could bounce an
// allowlisted host to an arbitrary, e.g. internal, address — defeating the
// host check the caller already did) and the body CAPPED (an unbounded
// response is an OOM vector). This util centralises that guard so the new
// gallery importer reuses the exact same protection instead of hand-rolling
// `http.get`.

import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Default body cap for a downloaded chara-card (OOM guard). A real card is
/// far smaller; mirrors the 25 MB caps the import paths used inline before
/// this util existed.
const int kDefaultMaxFetchBytes = 25 * 1024 * 1024; // 25 MB

/// GET [target] with auto-redirects DISABLED and the body capped at
/// [maxBytes].
///
/// * A 3xx response is surfaced as a thrown error rather than followed — a
///   redirect would let a host bounce us to an arbitrary (e.g. internal)
///   address, defeating any host-allowlist / public-host check the caller
///   already ran (limited SSRF defence-in-depth).
/// * The declared `Content-Length` is rejected up front when it exceeds
///   [maxBytes]; the streamed body is also capped chunk-by-chunk so a
///   lying/absent length can't OOM us.
///
/// Returns an [http.Response] so callers reuse `statusCode` / `bodyBytes`
/// exactly as with `http.get`. The client is always closed in `finally`.
Future<http.Response> fetchCappedNoRedirect(
  Uri target, {
  int maxBytes = kDefaultMaxFetchBytes,
}) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', target)..followRedirects = false;
    final streamed = await client.send(request);
    if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
      throw "Couldn't import — the link redirected to another address.";
    }
    final declared = streamed.contentLength;
    if (declared != null && declared > maxBytes) {
      throw "Couldn't import — file is too large.";
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw "Couldn't import — file is too large.";
      }
    }
    return http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
    );
  } finally {
    client.close();
  }
}
