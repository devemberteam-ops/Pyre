// Downscale large images before they hit a vision API.
//
// A 5MB phone photo would otherwise spend ~3-10s uploading and get
// billed by image-tile count regardless of how much the model
// actually looks at. Vision APIs (Anthropic, OpenAI, Venice, etc.)
// internally rescale anything bigger than ~768-1024px on the long
// edge — so a 4032×3024 phone photo and a 1280×960 downscaled copy
// produce essentially the same model output, just one is 20× smaller
// to upload.
//
// All heavy work happens in a background isolate via compute() so
// the chip-appears latency on the main thread stays in single-digit
// milliseconds.

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Resize [bytes] to fit within [maxDim]×[maxDim] pixels (longest
/// edge), re-encoding as JPEG at [quality]. If the image is already
/// smaller than [maxDim] OR the input is below [minBytes], returns
/// the original bytes unchanged. If decoding fails (unsupported
/// format, corrupt file), also returns the original — callers can
/// decide whether to send anyway.
Future<Uint8List> downscaleIfNeeded(
  Uint8List bytes, {
  int maxDim = 1280,
  int quality = 85,
  int minBytes = 256 * 1024,
}) async {
  if (bytes.length < minBytes) return bytes;
  // compute() runs the function in a separate isolate, copying the
  // payload across. The copy adds ~50-200ms for a few MB but it's
  // worth it to keep the UI thread free.
  return compute(
    _doDownscale,
    _DownscaleArgs(bytes: bytes, maxDim: maxDim, quality: quality),
  );
}

class _DownscaleArgs {
  final Uint8List bytes;
  final int maxDim;
  final int quality;
  const _DownscaleArgs({
    required this.bytes,
    required this.maxDim,
    required this.quality,
  });
}

/// Isolate entrypoint. Must be a top-level (or static) function for
/// compute() to call.
Uint8List _doDownscale(_DownscaleArgs args) {
  final decoded = img.decodeImage(args.bytes);
  if (decoded == null) return args.bytes;
  if (decoded.width <= args.maxDim && decoded.height <= args.maxDim) {
    // Already small. No need to re-encode (which could BLOAT a small
    // PNG into a bigger JPEG). Return original.
    return args.bytes;
  }
  // Resize the long edge to maxDim, preserve aspect via the OTHER
  // axis being null (image package computes it).
  final resized = img.copyResize(
    decoded,
    width: decoded.width >= decoded.height ? args.maxDim : null,
    height: decoded.height > decoded.width ? args.maxDim : null,
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(img.encodeJpg(resized, quality: args.quality));
}
