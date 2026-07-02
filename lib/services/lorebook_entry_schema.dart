// Wave CY.18.XX (Lorebook Creator, Wave 1 foundation): pure LoreEntry JSON
// mapper. Converts the AI-emitted JSON object (from [[BUILD_ENTRY]]) to a
// LoreEntry with a fresh id and safe defaults.
//
// PURE Dart — NO Flutter imports — unit-testable headless.
//
// The shape the architect is asked to emit:
//   {"keys":["..."],"content":"...","constant":false,"comment":"short label"}
//
// `entryJsonToLoreEntry` is intentionally TOLERANT:
//   - missing/wrong-typed fields → safe defaults, never throws
//   - 0/1 (and other ints/bools) accepted for the constant bool
//   - a single string accepted for keys (treated as a one-element list)
//   - extra/unknown keys in the object are silently ignored
//
// `comment` is parsed from the JSON but NOT stored in LoreEntry (the model
// has no comment field). It is returned as a separate value if a caller ever
// needs to surface it; `entryJsonToLoreEntry` simply discards it so the
// function signature stays clean.

import '../models/models.dart'
    show LoreEntry, LoreSelectiveLogic, loreSelectiveLogicFromSt, newId;

// ── Public API ────────────────────────────────────────────────────────────────

/// The JSON shape description — useful as a doc-comment reference for prompt
/// construction and test data.
const String kLoreEntryJsonShape =
    '{"entries":[{"keys":["..."],"secondaryKeys":["..."],'
    '"selectiveLogic":"andAny","content":"...","constant":false,'
    '"order":0,"caseSensitive":false,"matchWholeWords":true,'
    '"probability":100,"useProbability":false,"comment":"short label"}]}';

/// Map an AI-emitted JSON object to one or more [LoreEntry] objects.
///
/// Accepts both the modern wrapper shape:
///   {"entries":[{...},{...}]}
/// and the legacy single-entry shape:
///   {"keys":[...],"content":"...","constant":false}
List<LoreEntry> entryJsonToLoreEntries(Map<String, dynamic> json) {
  final rawEntries = json['entries'];
  if (rawEntries is List) {
    return rawEntries
        .whereType<Map>()
        .map((m) => entryJsonToLoreEntry(m.cast<String, dynamic>()))
        .where((e) => e.keys.isNotEmpty || e.content.trim().isNotEmpty)
        .toList();
  }
  final single = entryJsonToLoreEntry(json);
  return single.keys.isEmpty && single.content.trim().isEmpty
      ? <LoreEntry>[]
      : <LoreEntry>[single];
}

/// Map an AI-emitted JSON object to a [LoreEntry] with a fresh id.
///
/// Tolerant: any missing/null/wrong-typed field falls back to a safe default.
/// Never throws. Keys are trimmed and empty strings dropped.
LoreEntry entryJsonToLoreEntry(Map<String, dynamic> json) {
  final probability = (_parseInt(json['probability'])?.clamp(0, 100) ?? 100)
      .toInt();
  final explicitUseProbability = _parseBoolOrNull(json['useProbability']);
  return LoreEntry(
    id: newId('lore-entry'),
    keys: _parseKeys(json['keys']),
    content: _parseString(json['content']),
    constant: _parseBool(json['constant']),
    enabled: _parseBoolOrNull(json['enabled']) ?? true,
    order:
        _parseInt(json['order']) ??
        _parseInt(json['insertion_order']) ??
        _parseInt(json['priority']) ??
        0,
    secondaryKeys: _parseKeys(
      json['secondaryKeys'] ?? json['secondary_keys'] ?? json['keysecondary'],
    ),
    selectiveLogic: _parseSelectiveLogic(json['selectiveLogic']),
    caseSensitive: _parseBoolOrNull(json['caseSensitive']),
    matchWholeWords: _parseBoolOrNull(json['matchWholeWords']),
    probability: probability,
    useProbability: explicitUseProbability ?? probability < 100,
  );
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Parse the `keys` field. Accepts:
///   - a `List<dynamic>` of strings (the intended shape)
///   - a single String (one-element list)
///   - anything else → empty list
/// Trims whitespace and drops empty strings.
List<String> _parseKeys(dynamic v) {
  if (v is List) {
    return v
        .whereType<Object>()
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (v is String) {
    final t = v.trim();
    return t.isEmpty ? [] : [t];
  }
  return [];
}

/// Parse a string field. Accepts any value that has a .toString() but only
/// really uses actual Strings; non-String non-null → ''. Null → ''.
String _parseString(dynamic v) {
  if (v is String) return v;
  return '';
}

/// Parse a bool field. Accepts:
///   - bool directly
///   - int 0 → false, non-zero → true
///   - string "true"/"1" → true (case-insensitive)
///   - anything else → false (safe default)
bool _parseBool(dynamic v) {
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is String) {
    final s = v.toLowerCase().trim();
    return s == 'true' || s == '1';
  }
  return false;
}

bool? _parseBoolOrNull(dynamic v) {
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase().trim();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return null;
}

int? _parseInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

LoreSelectiveLogic _parseSelectiveLogic(dynamic v) {
  if (v is int || v is num) return loreSelectiveLogicFromSt(v);
  if (v is String) {
    final s = v.trim();
    final normalized = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    switch (normalized) {
      case '0':
      case 'andany':
        return LoreSelectiveLogic.andAny;
      case '1':
      case 'notall':
        return LoreSelectiveLogic.notAll;
      case '2':
      case 'notany':
        return LoreSelectiveLogic.notAny;
      case '3':
      case 'andall':
        return LoreSelectiveLogic.andAll;
    }
  }
  return LoreSelectiveLogic.andAny;
}
