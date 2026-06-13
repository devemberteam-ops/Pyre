import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart' as http;

/// Web: the default `BrowserClient` (XHR) buffers the whole response body, which
/// breaks SSE token streaming. `FetchClient` uses the Fetch API and exposes the
/// response as a `ReadableStream`, so `client.send(...).stream` yields chunks as
/// they arrive — restoring token-by-token streaming on web.
///
/// `RequestMode.cors` works whether the paired server is same-origin (the page
/// is served by it) or a different LAN host (the server already sets CORS
/// headers for the web client).
http.Client makeStreamingClient() => FetchClient(mode: RequestMode.cors);
