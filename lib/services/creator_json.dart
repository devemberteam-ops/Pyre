// Wave CY.18.227 (Creator Structured Build, Task 3): JSON extraction + truncation
// detection for the structured-output pipeline.
//
// PURE Dart — NO Flutter imports, NO other project imports — unit-testable
// headless, mirroring creator_schema.dart / creator_render.dart's pure-fn pattern.
//
// `extractJsonObject` — finds the first balanced JSON object in a model reply
//   that may be wrapped in prose or a ```json fence, tolerating trailing commas.
//   The orchestrator MUST strip <think>/sentinels BEFORE calling this; this
//   function is a PURE brace-scanner and does NOT strip those artifacts itself.
//
// `looksTruncatedJson` — returns true when the reply contains an opening `{`
//   whose braces never balance (depth > 0 at end), or the scan ends while still
//   inside an unterminated string (= the continuation trigger).

import 'dart:convert';

// ── Public API ────────────────────────────────────────────────────────────────

/// Extract the first JSON object from a model reply that may be wrapped in prose
/// or a ```json fence; tolerant of trailing commas. Returns null if unrecoverable.
/// PURE brace-scanner — it does NOT strip `<think>`/sentinels. The orchestrator
/// strips artifacts BEFORE calling this, including at the continuation-concat seam.
Map<String, dynamic>? extractJsonObject(String reply) {
  final start = reply.indexOf('{');
  if (start < 0) return null;

  final result = _scanObject(reply, start);
  if (result == null) return null;

  // Strip trailing commas before } or ] — safe simple regex for well-formed
  // JSON-with-trailing-commas (this is pragmatically fine for the app's inputs).
  final cleaned = result.replaceAllMapped(
    RegExp(r',(\s*[}\]])'),
    (m) => m.group(1)!,
  );

  try {
    final decoded = jsonDecode(cleaned);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  } catch (_) {
    return null;
  }
}

/// True if `reply` looks like a TRUNCATED JSON object (unbalanced braces / ends
/// mid-string). Returns false for a balanced object (even if wrapped in prose),
/// and false for a reply with no `{` at all (nothing to continue).
bool looksTruncatedJson(String reply) {
  final start = reply.indexOf('{');
  if (start < 0) return false; // no object started at all

  final state = _scanState(reply, start);
  // Truncated = we ran off the end while depth > 0 or while inside a string.
  return state.depth > 0 || state.inString;
}

// ── Internal ──────────────────────────────────────────────────────────────────

/// Scan from [start] (which must be a `{`) and return the balanced substring,
/// or null if the braces never balance.
String? _scanObject(String s, int start) {
  final state = _scanState(s, start);
  if (state.closeIndex < 0) return null;
  return s.substring(start, state.closeIndex + 1);
}

class _ScanResult {
  /// Index of the closing `}` that balanced the opening `{`, or -1 if never found.
  final int closeIndex;

  /// Brace depth at the END of the scan (0 = balanced).
  final int depth;

  /// Whether the scan ended while still inside an unterminated string.
  final bool inString;

  const _ScanResult(this.closeIndex, this.depth, this.inString);
}

/// String-aware brace scanner. Starts at [start] (a `{`).
/// Tracks depth, in-string, and escaped-backslash states.
_ScanResult _scanState(String s, int start) {
  int depth = 0;
  bool inString = false;
  bool escape = false; // the previous character was an unescaped backslash

  for (int i = start; i < s.length; i++) {
    final c = s[i];

    if (escape) {
      // The character AFTER a backslash is always consumed literally.
      escape = false;
      continue;
    }

    if (c == r'\' && inString) {
      // An unescaped backslash inside a string — next char is escaped.
      escape = true;
      continue;
    }

    if (c == '"') {
      inString = !inString;
      continue;
    }

    if (inString) {
      // Braces and brackets inside strings don't affect depth.
      continue;
    }

    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) {
        return _ScanResult(i, 0, false);
      }
    }
  }

  // Ran off the end without balancing.
  return _ScanResult(-1, depth, inString);
}
