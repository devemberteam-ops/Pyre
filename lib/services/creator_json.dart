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

  final decoded = _tryDecodeObject(cleaned);
  if (decoded != null) return decoded;

  // CRITICAL 3 (tolerant repair): a BALANCED object can still be invalid for a
  // non-truncation reason — a lone control char (raw newline/tab) inside a
  // string value, or smart double-quotes used as the string delimiters. These
  // are exactly the damage cheap models produce. Run a tolerant repair pass and
  // re-decode before giving up. (Truncated/unbalanced objects never reach here —
  // `_scanObject` already returned null for them.)
  final repaired = _repairBalancedJson(cleaned);
  if (repaired != cleaned) {
    final reDecoded = _tryDecodeObject(repaired);
    if (reDecoded != null) return reDecoded;
  }
  return null;
}

/// Decode [s] and return it only if it is a JSON object; null on any failure.
Map<String, dynamic>? _tryDecodeObject(String s) {
  try {
    final decoded = jsonDecode(s);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  } catch (_) {
    return null;
  }
}

/// Tolerant repair pass for a BALANCED-but-invalid JSON object (CRITICAL 3).
/// Two pragmatic fixes for the classes of damage cheap models produce:
///   1. Escape lone CONTROL chars (newline / tab / etc.) inside string regions
///      — JSON forbids a raw control char in a string, so escape it to its
///      JSON form (`\n`, `\t`, `\r`, or `\uXXXX`) without touching control
///      chars OUTSIDE strings (structural whitespace).
///   2. If, after step 1, the text STILL has no straight `"` delimiters but
///      DOES contain smart double-quotes (the model used `“`/`”` as the string
///      delimiters), normalise those to `"`.
/// Pure; returns the input unchanged when no repair applies.
String _repairBalancedJson(String s) {
  // Step 1: escape lone control chars inside strings.
  var out = _escapeControlCharsInStrings(s);
  // Step 2: smart-quote delimiters — only when there are no straight quotes to
  // delimit strings at all (so we never touch smart quotes that live INSIDE a
  // normal string value, which decode fine as literal characters).
  if (!out.contains('"') &&
      (out.contains('“') || out.contains('”'))) {
    out = out
        .replaceAll('“', '"') // left double quotation mark
        .replaceAll('”', '"'); // right double quotation mark
  }
  return out;
}

/// Escape lone control chars (U+0000..U+001F) that appear INSIDE a JSON string
/// region to their valid JSON escape, leaving structural whitespace (outside
/// strings) untouched. String-aware: tracks in-string + backslash-escape state
/// exactly like the brace scanner.
String _escapeControlCharsInStrings(String s) {
  final buf = StringBuffer();
  bool inString = false;
  bool escape = false;
  var changed = false;
  for (int i = 0; i < s.length; i++) {
    final c = s[i];
    final code = s.codeUnitAt(i);
    if (escape) {
      buf.write(c);
      escape = false;
      continue;
    }
    if (c == r'\' && inString) {
      buf.write(c);
      escape = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      buf.write(c);
      continue;
    }
    if (inString && code < 0x20) {
      changed = true;
      switch (code) {
        case 0x0a:
          buf.write(r'\n');
          break;
        case 0x09:
          buf.write(r'\t');
          break;
        case 0x0d:
          buf.write(r'\r');
          break;
        case 0x08:
          buf.write(r'\b');
          break;
        case 0x0c:
          buf.write(r'\f');
          break;
        default:
          buf.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
      }
      continue;
    }
    buf.write(c);
  }
  return changed ? buf.toString() : s;
}

/// HIGH 5 — recover a structured object from a REASONING-INCLUSIVE buffer
/// (`<think>…</think>` PRESERVED) without ingesting the model's chain-of-thought
/// DRAFT object. A reasoning model often sketches a half-formed object inside
/// `<think>` ("let me try {…}") before emitting the real answer AFTER closing
/// the channel; a naive [extractJsonObject] grabs the FIRST `{` — the draft.
///
/// Strategy: if the buffer has a `</think>` close tag, scan the region AFTER the
/// LAST one first (the model's final, post-reasoning answer). Only when there is
/// no post-reasoning object (or no `</think>` at all) do we fall back to
/// scanning the whole buffer — so a model that put its whole answer inside the
/// reasoning channel is still recovered. Returns null when nothing parses.
Map<String, dynamic>? extractJsonAfterReasoning(String raw) {
  final lastClose = raw.toLowerCase().lastIndexOf('</think>');
  if (lastClose >= 0) {
    final after = raw.substring(lastClose + '</think>'.length);
    final post = extractJsonObject(after);
    if (post != null) return post;
  }
  return extractJsonObject(raw);
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

/// MEDIUM 8 — true when [reply] (a truncated partial) ends while still INSIDE
/// an unterminated JSON string. Used at the continuation-concat seam: if the
/// partial broke off mid-string AND the continuation chunk re-opens the whole
/// object with a leading `{`, that `{` is corruption (a well-behaved model
/// resumes the string content) and must be stripped before stitching.
bool endsInsideUnterminatedString(String reply) {
  final start = reply.indexOf('{');
  if (start < 0) return false;
  return _scanState(reply, start).inString;
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
