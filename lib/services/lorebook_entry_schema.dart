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

import '../models/models.dart' show LoreEntry, newId;

// ── Public API ────────────────────────────────────────────────────────────────

/// The JSON shape description — useful as a doc-comment reference for prompt
/// construction and test data.
const String kLoreEntryJsonShape = '{"keys":["..."],"content":"...",'
    '"constant":false,"comment":"short label"}';

/// Map an AI-emitted JSON object to a [LoreEntry] with a fresh id.
///
/// Tolerant: any missing/null/wrong-typed field falls back to a safe default.
/// Never throws. Keys are trimmed and empty strings dropped.
LoreEntry entryJsonToLoreEntry(Map<String, dynamic> json) {
  return LoreEntry(
    id: newId('lore-entry'),
    keys: _parseKeys(json['keys']),
    content: _parseString(json['content']),
    constant: _parseBool(json['constant']),
    // All other LoreEntry fields use their constructor defaults:
    //   enabled=true, order=0, secondaryKeys=[], selectiveLogic=andAny,
    //   caseSensitive=null, matchWholeWords=null, probability=100,
    //   useProbability=false.
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
