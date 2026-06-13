// Pyre 1.1.3: a streaming-capable `http.Client` for SSE.
//
// The native default client (IOClient) already streams response bodies, so
// token-by-token SSE works on desktop/mobile. The WEB default client
// (BrowserClient, backed by XMLHttpRequest) BUFFERS the entire response body and
// only emits it once at the end — so the LAN-proxy chat stream never actually
// streamed on web (the whole reply popped in at once). The web impl below uses
// the Fetch API (response ReadableStream) via `fetch_client`, which delivers
// chunks incrementally.
//
// `makeStreamingClient()` → an `http.Client` suitable for `client.send()` SSE.
export 'streaming_http_client_stub.dart'
    if (dart.library.js_interop) 'streaming_http_client_web.dart';
