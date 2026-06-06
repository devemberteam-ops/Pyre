// Audit 2026-06-04 (IMPORT batch):
//  - [import-1-01] / [import-1-09]: a shared content-sniffing parser so a
//    `.json` (or extension-less JSON) direct link routes to the JSON parser
//    instead of being unconditionally PNG-parsed.
//  - [library-01] / [import-1-02]: JSON card bytes must be decoded as UTF-8,
//    not Latin-1 (String.fromCharCodes), so accented/CJK/emoji text survives.
//  - [import-1-04]: a compressed iTXt `chara` chunk must be inflated, not
//    silently skipped (which surfaced as "not a Tavern Card").

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/png_parser.dart';

const _pngSig = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

// Big-endian uint32.
List<int> _u32(int v) => [
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

// Assemble a chunk: length(4) + type(4) + data + crc(4). CRC is left zero —
// the parser does not verify CRCs (it skips them), so any value works.
List<int> _chunk(String type, List<int> data) =>
    [..._u32(data.length), ...ascii.encode(type), ...data, 0, 0, 0, 0];

/// Build a PNG carrying `chara` in a single `tEXt` chunk (base64 JSON).
Uint8List _pngWithTextChara(Map<String, dynamic> card) {
  final b64 = base64Encode(utf8.encode(jsonEncode(card)));
  final textData = <int>[...ascii.encode('chara'), 0, ...ascii.encode(b64)];
  return Uint8List.fromList([
    ..._pngSig,
    ..._chunk('IHDR', List<int>.filled(13, 0)),
    ..._chunk('tEXt', textData),
    ..._chunk('IEND', const []),
  ]);
}

/// Build a PNG carrying `chara` in a COMPRESSED `iTXt` chunk.
/// iTXt layout: keyword \0 compressionFlag(1) compressionMethod(1) lang \0
/// translatedKeyword \0 text. With compressionFlag==1 the text is zlib-deflated.
Uint8List _pngWithCompressedItxtChara(Map<String, dynamic> card) {
  final b64 = base64Encode(utf8.encode(jsonEncode(card)));
  final deflated = const ZLibEncoder().encode(utf8.encode(b64));
  final itxtData = <int>[
    ...ascii.encode('chara'), 0, // keyword \0
    1, // compressionFlag = compressed
    0, // compressionMethod = zlib
    0, // language tag \0 (empty)
    0, // translated keyword \0 (empty)
    ...deflated,
  ];
  return Uint8List.fromList([
    ..._pngSig,
    ..._chunk('IHDR', List<int>.filled(13, 0)),
    ..._chunk('iTXt', itxtData),
    ..._chunk('IEND', const []),
  ]);
}

void main() {
  group('parseCharaCard content-sniff (import-1-01 / import-1-09)', () {
    test('PNG bytes route to the PNG parser', () {
      final png = _pngWithTextChara({'name': 'Vesna', 'description': 'd'});
      final card = parseCharaCard(png);
      expect(card.card['name'], 'Vesna');
      expect(card.imageBytes, isNotNull); // PNG path keeps the avatar bytes
    });

    test('raw JSON bytes (no PNG signature) route to the JSON parser', () {
      // Mirrors a catbox/pixeldrain/RisuRealm `.json` or `json-v2` link.
      final json = jsonEncode({'name': 'Ren', 'description': 'desc'});
      final bytes = Uint8List.fromList(utf8.encode(json));
      final card = parseCharaCard(bytes);
      expect(card.card['name'], 'Ren');
      expect(card.imageBytes, isNull); // JSON path has no embedded image
    });

    test('JSON with nested data wrapper unwraps', () {
      final json = jsonEncode({
        'spec': 'chara_card_v2',
        'data': {'name': 'Hina', 'description': 'd'},
      });
      final card = parseCharaCard(Uint8List.fromList(utf8.encode(json)));
      expect(card.card['name'], 'Hina');
    });
  });

  group('UTF-8 fidelity (library-01 / import-1-02)', () {
    test('parseCharaCardJson keeps accented/CJK/emoji intact', () {
      const name = 'Renée 美咲 🦊';
      const desc = 'café — naïve — 鈴 — 🌸';
      final json = jsonEncode({'name': name, 'description': desc});
      final card = parseCharaCardJson(json);
      expect(card.card['name'], name);
      expect(card.card['description'], desc);
    });

    test('parseCharaCard on UTF-8 JSON bytes keeps non-ASCII intact', () {
      const name = 'Renée 美咲 🦊';
      final bytes =
          Uint8List.fromList(utf8.encode(jsonEncode({'name': name})));
      final card = parseCharaCard(bytes);
      expect(card.card['name'], name);
    });

    test('regression: Latin-1 decode (String.fromCharCodes) WOULD mojibake', () {
      // Documents the old bug: decoding UTF-8 bytes as Latin-1 corrupts é.
      const name = 'Renée';
      final utf8Bytes = utf8.encode(name);
      final mojibake = String.fromCharCodes(utf8Bytes); // old behaviour
      expect(mojibake, isNot(name));
      expect(utf8.decode(utf8Bytes), name); // the fix
    });
  });

  group('compressed iTXt chara chunk (import-1-04)', () {
    test('inflates a zlib-compressed iTXt chara payload', () {
      final png = _pngWithCompressedItxtChara(
          {'name': 'Compressed Card', 'description': 'd'});
      final card = parseCharaCard(png);
      expect(card.card['name'], 'Compressed Card');
    });

    test('uncompressed iTXt still works (no regression)', () {
      final b64 = base64Encode(
          utf8.encode(jsonEncode({'name': 'PlainItxt', 'description': 'd'})));
      final itxtData = <int>[
        ...ascii.encode('chara'), 0,
        0, // compressionFlag = uncompressed
        0, // compressionMethod
        0, // lang \0
        0, // translated \0
        ...ascii.encode(b64),
      ];
      final png = Uint8List.fromList([
        ..._pngSig,
        ..._chunk('IHDR', List<int>.filled(13, 0)),
        ..._chunk('iTXt', itxtData),
        ..._chunk('IEND', const []),
      ]);
      final card = parseCharaCardPng(png);
      expect(card.card['name'], 'PlainItxt');
    });
  });
}
