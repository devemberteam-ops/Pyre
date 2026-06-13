// Pyre 1.1.3: trigger a REAL browser "Save as" file download on the web build.
//
// Web has no filesystem, so exports used to dump a `data:` / JSON string to the
// clipboard with a "paste into an editor" message — you couldn't actually save
// a file. This helper builds a Blob + a hidden `<a download>` and clicks it, so
// the browser downloads a real file. On native it's a no-op (callers write to
// disk there instead) via the conditional export below.
//
// `downloadBytesToBrowser(bytes, filename, mimeType)`.
export 'web_download_stub.dart'
    if (dart.library.js_interop) 'web_download_web.dart';
