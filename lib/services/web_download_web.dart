import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web implementation of [downloadBytesToBrowser]: trigger a browser file
/// download of [bytes] named [filename] with the given [mimeType]. Builds a
/// Blob + object URL, clicks a hidden `<a download>` anchor, then revokes the
/// URL. This is what makes web "export"/"save" actually write a file to the
/// user's device instead of copying a data URL to the clipboard.
void downloadBytesToBrowser(Uint8List bytes, String filename, String mimeType) {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = filename;
  anchor.style.display = 'none';
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
