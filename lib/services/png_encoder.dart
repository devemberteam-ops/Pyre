// chara_card_v2 PNG ENCODER — inverse of png_parser.dart.
//
// Takes the avatar's PNG bytes plus a Character, returns a new PNG with
// the character's data embedded in a `chara` tEXt chunk. Compatible with
// SillyTavern, RisuAI, Chub.ai, JanitorAI, AiMaker, Tavo, and every other
// frontend that consumes chara_card_v2 PNGs.
//
// We don't re-encode the image itself — we copy every existing PNG chunk
// verbatim (preserving exact pixel data, gamma, ICC profiles, etc.) and
// only insert one new tEXt chunk before IEND. Any existing `chara` / `ccv3`
// chunks are stripped first so we don't end up with two competing payloads.

import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';
import 'png_parser.dart';

/// Build the chara_card_v2 JSON payload from a [Character].
///
/// Includes every field the spec defines. Optional fields (talkativeness,
/// depth_prompt) are wrapped inside `extensions` per the spec, alongside
/// any opaque extensions blob the user round-tripped from another tool.
Map<String, dynamic> buildCharaCardV2Json(Character c, {Lorebook? lorebook}) {
  // Compose the extensions blob. Start from whatever opaque dict the user
  // already had (preserved through import), then layer Pyre-managed
  // entries (depth_prompt) on top.
  final extensions = <String, dynamic>{...c.extensions};
  if (c.depthPrompt.trim().isNotEmpty) {
    extensions['depth_prompt'] = <String, dynamic>{
      'prompt': c.depthPrompt,
      'depth': c.depthPromptDepth,
    };
  }
  // chara_card_v2 has no first-class `tagline`, so Pyre's one-line
  // tagline would be dropped on export. Stash it under a Pyre
  // namespace inside `extensions` so it round-trips (Pyre reads it
  // back on import; other tools ignore the unknown namespace).
  final tagline = c.tagline?.trim() ?? '';
  if (tagline.isNotEmpty) {
    final existing = extensions['pyre'];
    final pyre = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    pyre['tagline'] = tagline;
    extensions['pyre'] = pyre;
  }
  final data = <String, dynamic>{
    'name': c.name,
    'description': c.description,
    'personality': c.personality,
    'scenario': c.scenario,
    'first_mes': c.firstMes,
    'mes_example': c.mesExample,
    'system_prompt': c.systemPrompt,
    'post_history_instructions': c.postHistoryInstructions,
    'alternate_greetings': c.alternateGreetings,
    'tags': c.tags,
    'creator': c.creator,
    'character_version': c.characterVersion,
    'creator_notes': c.creatorNotes,
    if (c.talkativeness != null) 'talkativeness': c.talkativeness,
    'extensions': extensions,
  };
  // Wave CY.18.151: optionally embed a bound lorebook as `character_book` so
  // the world lore travels INSIDE the card. Re-importing the PNG anywhere
  // (Pyre, ST, Risu, Chub) sees the book — Pyre auto-extracts it via
  // lorebookFromCharacterBook (Wave CA). Skipped when the book is empty.
  if (lorebook != null && lorebook.entries.isNotEmpty) {
    data['character_book'] = charaCardBookJson(lorebook);
  }
  return <String, dynamic>{
    'spec': 'chara_card_v2',
    'spec_version': '2.0',
    'data': data,
  };
}

/// Serialize a Pyre [Lorebook] into a chara_card_v2 `character_book` object —
/// the inverse of `lorebookFromCharacterBook` in lorebook_import.dart. Uses
/// the STANDARD field names (`keys` / `content` / `enabled` / `constant` /
/// `insertion_order`) so other frontends read it, and Pyre round-trips it
/// cleanly (its importer reads `insertion_order` straight into `order`).
Map<String, dynamic> charaCardBookJson(Lorebook book) {
  return <String, dynamic>{
    'name': book.name,
    if (book.description.trim().isNotEmpty) 'description': book.description,
    'scan_depth': 4,
    'token_budget': 2048,
    'recursive_scanning': false,
    'extensions': <String, dynamic>{},
    'entries': <Map<String, dynamic>>[
      for (var i = 0; i < book.entries.length; i++)
        _charaCardBookEntry(book.entries[i], i),
    ],
  };
}

Map<String, dynamic> _charaCardBookEntry(LoreEntry e, int index) {
  return <String, dynamic>{
    'id': index,
    'keys': e.keys,
    'secondary_keys': <String>[],
    'comment': '',
    'content': e.content,
    'constant': e.constant,
    // `selective` (chara_card_v2): the entry fires only on a key match —
    // true for keyed entries, false for an always-on (constant) overview.
    'selective': !e.constant && e.keys.isNotEmpty,
    'insertion_order': e.order,
    'enabled': e.enabled,
    'position': 'before_char',
    'extensions': <String, dynamic>{},
  };
}

/// Encode a chara_card_v2 PNG by embedding [c]'s JSON in [avatarPngBytes].
///
/// [avatarPngBytes] must be a valid PNG (the Character's avatar, typically
/// already a 256x256 cropped square). Throws [FormatException] if the
/// input isn't a PNG.
Uint8List encodeCharaCardPng(Character c, Uint8List avatarPngBytes,
    {Lorebook? lorebook}) {
  final cardJson = jsonEncode(buildCharaCardV2Json(c, lorebook: lorebook));
  final cardB64 = base64Encode(utf8.encode(cardJson));

  // tEXt chunk data: keyword \0 text
  // Keyword is ASCII "chara", value is the base64-encoded JSON.
  final newTextChunkData = Uint8List.fromList([
    ...utf8.encode('chara'),
    0,
    ...utf8.encode(cardB64),
  ]);

  final chunks = parsePngChunks(avatarPngBytes);
  // Strip any pre-existing chara/ccv3 chunks so we don't double up.
  chunks.removeWhere((chunk) {
    if (chunk.type != 'tEXt' && chunk.type != 'iTXt') return false;
    final nullIdx = _findNullByte(chunk.data, 0);
    if (nullIdx < 0) return false;
    final key = String.fromCharCodes(chunk.data.sublist(0, nullIdx));
    return key == 'chara' || key == 'ccv3';
  });

  // Compose: 8-byte PNG signature + every original chunk, with our new
  // tEXt inserted immediately before IEND (the spec says IEND must be last).
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  var injected = false;
  for (final chunk in chunks) {
    if (!injected && chunk.type == 'IEND') {
      _writeChunk(out, 'tEXt', newTextChunkData);
      injected = true;
    }
    _writeChunk(out, chunk.type, chunk.data);
  }
  if (!injected) {
    // Malformed PNG without IEND — append as a tail. Won't be valid but
    // we never want to throw away the user's data either.
    _writeChunk(out, 'tEXt', newTextChunkData);
  }
  return out.toBytes();
}

void _writeChunk(BytesBuilder out, String type, Uint8List data) {
  final typeBytes = Uint8List.fromList(utf8.encode(type));
  out.add(_uint32BE(data.length));
  out.add(typeBytes);
  out.add(data);
  // CRC32 is computed over type + data (NOT over length).
  final crc = _crc32(<int>[...typeBytes, ...data]);
  out.add(_uint32BE(crc));
}

Uint8List _uint32BE(int v) {
  return Uint8List.fromList([
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ]);
}

int _findNullByte(Uint8List bytes, int from) {
  for (var i = from; i < bytes.length; i++) {
    if (bytes[i] == 0) return i;
  }
  return -1;
}

// Standard zlib CRC32 (polynomial 0xEDB88320). PNG mandates this exact
// polynomial — the chunk is rejected by every viewer if it's off.
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b & 0xFF;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
