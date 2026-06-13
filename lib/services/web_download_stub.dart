import 'dart:typed_data';

/// Native stub for [downloadBytesToBrowser]. There is no browser to download
/// into on native targets, and callers reach this only on non-web builds (where
/// a real file write is used instead), so it is intentionally a no-op.
void downloadBytesToBrowser(Uint8List bytes, String filename, String mimeType) {
  // no-op on native
}
