// chara_card_v2 PNG parser (Dart port of js/png.js).
// Reads tEXt / iTXt chunks, decodes the "chara" or "ccv3" key (base64 JSON),
// and returns the embedded Tavern Card.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

/// Wave CY.18.43: surface diagnostics for `parseCharaCardPng` failures.
/// Pre-Wave the base64 fallback was completely silent: if the `chara`
/// value couldn't be base64-decoded, we treated it as plain JSON and
/// let `jsonDecode` blow up downstream with a generic "not a JSON
/// object" error. Now the importer can read [PngParserErrors.log] to
/// tell the user "base64 decode failed, falling back to raw text"
/// (informational) vs "base64 succeeded but JSON parse failed" (real
/// corruption — the embedded payload is broken).
class PngParserErrors {
  PngParserErrors._();
  static final List<String> log = [];
  static const int _max = 20;

  static void record(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[PngParser] $msg');
    log.insert(0, msg);
    if (log.length > _max) {
      log.removeRange(_max, log.length);
    }
  }

  static void clear() => log.clear();
}

const _pngSig = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

class PngChunk {
  final String type;
  final Uint8List data;
  PngChunk(this.type, this.data);
}

class CharaCard {
  final Map<String, dynamic> card; // unwrapped card (parsed.data ?? parsed)
  final Map<String, dynamic> raw; // top-level JSON
  final Uint8List? imageBytes; // original PNG bytes (for avatar)

  CharaCard({required this.card, required this.raw, this.imageBytes});

  String? get avatarDataUrl {
    if (imageBytes == null) return null;
    return 'data:image/png;base64,${base64Encode(imageBytes!)}';
  }
}

int _readUint32(Uint8List bytes, int off) =>
    ((bytes[off] << 24) |
            (bytes[off + 1] << 16) |
            (bytes[off + 2] << 8) |
            bytes[off + 3]) &
        0xFFFFFFFF;

String _chunkType(Uint8List bytes, int off) =>
    String.fromCharCodes(bytes.sublist(off, off + 4));

String _ascii(Uint8List bytes) => String.fromCharCodes(bytes);

int _findNull(Uint8List bytes, int start) {
  for (var i = start; i < bytes.length; i++) {
    if (bytes[i] == 0) return i;
  }
  return -1;
}

List<PngChunk> parsePngChunks(Uint8List bytes) {
  if (bytes.length < 8) throw const FormatException('Not a PNG (too short)');
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngSig[i]) {
      throw const FormatException('Not a PNG (bad signature)');
    }
  }
  final chunks = <PngChunk>[];
  var off = 8;
  while (off < bytes.length) {
    if (off + 8 > bytes.length) break;
    final len = _readUint32(bytes, off);
    final type = _chunkType(bytes, off + 4);
    final dataStart = off + 8;
    final dataEnd = dataStart + len;
    if (dataEnd + 4 > bytes.length) break;
    final data = Uint8List.sublistView(bytes, dataStart, dataEnd);
    chunks.add(PngChunk(type, data));
    if (type == 'IEND') break;
    off = dataEnd + 4; // skip CRC
  }
  return chunks;
}

Map<String, String> extractTextEntries(List<PngChunk> chunks) {
  final out = <String, String>{};
  for (final c in chunks) {
    if (c.type == 'tEXt') {
      final nullIdx = _findNull(c.data, 0);
      if (nullIdx < 0) continue;
      final key = _ascii(Uint8List.sublistView(c.data, 0, nullIdx));
      final val = _ascii(Uint8List.sublistView(c.data, nullIdx + 1));
      out[key] = val;
    } else if (c.type == 'iTXt') {
      // keyword \0 compressionFlag(1) compressionMethod(1) lang \0 trans \0 text
      final nullIdx = _findNull(c.data, 0);
      if (nullIdx < 0) continue;
      final key = _ascii(Uint8List.sublistView(c.data, 0, nullIdx));
      final compressionFlag = c.data[nullIdx + 1];
      final langNull = _findNull(c.data, nullIdx + 3);
      if (langNull < 0) continue;
      final transNull = _findNull(c.data, langNull + 1);
      if (transNull < 0) continue;
      final textBytes = Uint8List.sublistView(c.data, transNull + 1);
      if (compressionFlag == 0) {
        try {
          out[key] = utf8.decode(textBytes);
        } catch (_) {
          out[key] = _ascii(textBytes);
        }
      }
      // compressed iTXt skipped (would require zlib inflate)
    }
  }
  return out;
}

CharaCard parseCharaCardPng(Uint8List bytes) {
  final chunks = parsePngChunks(bytes);
  final entries = extractTextEntries(chunks);

  String? cardJsonStr;
  // Wave CY.18.43: track whether we hit the plain-JSON fallback path.
  // When the base64 decode fails AND the subsequent JSON parse also
  // fails, we want to tell the user "this PNG had a chara chunk that
  // wasn't valid base64 AND wasn't valid raw JSON either" — much more
  // diagnostic than the previous generic "chara payload is not a JSON
  // object" message that left the user guessing whether the issue was
  // the base64 layer or the JSON layer.
  var usedBase64Fallback = false;
  String? base64FailureMessage;
  final tryKeys = ['chara', 'ccv3'];
  for (final k in tryKeys) {
    final v = entries[k];
    if (v == null) continue;
    try {
      cardJsonStr = utf8.decode(base64Decode(v));
    } catch (e) {
      // base64Decode threw — either the value wasn't base64 at all
      // (some exporters embed raw JSON in the tEXt chunk) or it was
      // base64-encoded garbage. Try the raw-JSON fallback and capture
      // the failure reason so we can include it if downstream parse
      // also fails.
      usedBase64Fallback = true;
      base64FailureMessage = e.toString();
      cardJsonStr = v;
    }
    break;
  }

  if (cardJsonStr == null || cardJsonStr.isEmpty) {
    throw const FormatException(
      'No "chara" metadata found in PNG (not a Tavern Card?)',
    );
  }

  final dynamic parsed;
  try {
    parsed = jsonDecode(cardJsonStr);
  } catch (e) {
    // Wave CY.18.43: more useful error than the bare jsonDecode
    // exception. Tells the user which layer failed and how — they
    // can immediately tell "the PNG was corrupted" vs "the PNG was
    // valid but the embedded JSON was malformed".
    if (usedBase64Fallback) {
      PngParserErrors.record('PNG chara base64', base64FailureMessage ?? '');
      PngParserErrors.record('PNG chara raw-JSON fallback', e);
      throw FormatException(
        'PNG metadata could not be decoded. Base64 layer failed '
        '(${base64FailureMessage ?? "unknown"}) and the raw-text '
        'fallback is not valid JSON either: $e',
      );
    }
    PngParserErrors.record('PNG chara JSON parse', e);
    throw FormatException(
      'PNG metadata base64-decoded but the result is not valid JSON: $e',
    );
  }
  if (parsed is! Map<String, dynamic>) {
    throw const FormatException('chara payload is not a JSON object');
  }
  final inner = parsed['data'];
  final card = (inner is Map<String, dynamic>) ? inner : parsed;
  return CharaCard(card: card, raw: parsed, imageBytes: bytes);
}

CharaCard parseCharaCardJson(String text) {
  final parsed = jsonDecode(text);
  if (parsed is! Map<String, dynamic>) {
    throw const FormatException('Not a JSON object');
  }
  final inner = parsed['data'];
  final card = (inner is Map<String, dynamic>) ? inner : parsed;
  return CharaCard(card: card, raw: parsed, imageBytes: null);
}
