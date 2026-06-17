// Pyre — BotBooru web iframe widget (conditional export).
//
// On the web build (served by Pyre desktop over LAN), exposes the real
// HTMLIFrameElement-backed widget from botbooru_web_frame_web.dart.
// On native builds, exports the no-op stub so the import compiles without
// pulling in `package:web` / `dart:ui_web`.
//
// Usage in discover_screen.dart (web branch):
//   BotbooruWebFrame(onImport: _handleBbxImport)
//
// v2: the [onImport] callback receives (botbooruUrl, bbxOrigin).
//   [botbooruUrl] = canonical `https://botbooru.com/...` URL.
//   [bbxOrigin]   = bbx cross-origin endpoint, e.g. `http://host:bbxPort`.
//   The caller fetches the download bytes from bbxOrigin (CORS-safe).
export 'botbooru_web_frame_stub.dart'
    if (dart.library.js_interop) 'botbooru_web_frame_web.dart';
