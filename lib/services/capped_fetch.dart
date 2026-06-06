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

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Default body cap for a downloaded chara-card (OOM guard). A real card is
/// far smaller; mirrors the 25 MB caps the import paths used inline before
/// this util existed.
const int kDefaultMaxFetchBytes = 25 * 1024 * 1024; // 25 MB

/// Mega-audit 2026-06-05 (M-2): timeouts so a stalled host fails fast
/// instead of hanging the import spinner forever.
///
/// * [kFetchConnectTimeout] bounds the wait for the response HEADERS
///   (`client.send` completing). A host that accepts the TCP connection but
///   never sends a status line is the classic "spinner spins forever" case.
/// * [kFetchOverallTimeout] bounds the WHOLE operation (connect + streaming
///   the body) so a host that drip-feeds bytes can't keep us alive
///   indefinitely. It's longer than the connect timeout to allow a genuine
///   (large, slow) card to finish downloading.
const Duration kFetchConnectTimeout = Duration(seconds: 30);
const Duration kFetchOverallTimeout = Duration(seconds: 60);

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
/// * A connect timeout ([kFetchConnectTimeout]) bounds the wait for response
///   headers and an overall timeout ([kFetchOverallTimeout]) bounds the full
///   fetch, so a stalled/slow host throws a [TimeoutException] instead of
///   hanging forever (M-2).
///
/// [client] is injectable for tests (a never-completing client proves the
/// timeout fires); production passes nothing and a fresh client is created
/// and closed in `finally`. [connectTimeout] / [overallTimeout] are also
/// injectable so a test can prove the timeout fires in milliseconds instead
/// of waiting the production 30s/60s.
///
/// Returns an [http.Response] so callers reuse `statusCode` / `bodyBytes`
/// exactly as with `http.get`. The client is always closed in `finally`.
Future<http.Response> fetchCappedNoRedirect(
  Uri target, {
  int maxBytes = kDefaultMaxFetchBytes,
  http.Client? client,
  Duration connectTimeout = kFetchConnectTimeout,
  Duration overallTimeout = kFetchOverallTimeout,
}) async {
  final ownClient = client == null;
  final c = client ?? http.Client();
  try {
    return await _doFetch(c, target, maxBytes, connectTimeout)
        .timeout(overallTimeout);
  } finally {
    if (ownClient) c.close();
  }
}

Future<http.Response> _doFetch(http.Client client, Uri target, int maxBytes,
    Duration connectTimeout) async {
  final request = http.Request('GET', target)..followRedirects = false;
  // Connect/headers timeout: a host that accepts the socket but never
  // replies must not stall us up to the overall ceiling.
  final streamed = await client.send(request).timeout(connectTimeout);
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
}
