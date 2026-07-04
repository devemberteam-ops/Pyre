// 2026-07-04 (Gui): "o continue na conversa não funciona muito bem."
// The Continue stream used to APPEND blindly (`existing + chunk`), which
// produced the two classic artifacts users notice:
//   1. the model repeats the quoted tail (or restarts the whole message)
//      → duplicated prose;
//   2. the model starts at a word boundary → "wordword" gluing (or a
//      missing space after punctuation).
// This pure helper owns the seam: it trims the longest repeated overlap
// between the end of [existing] and the start of [continuation], then joins
// with a space only when the seam needs one. Also reused by the prefill
// ("Start reply with") display path — OpenAI-compatible backends that don't
// support assistant-prefix continuation often echo the prefill back, and the
// same overlap trim removes the echo.

/// Longest suffix window of [existing] considered for overlap detection.
const int _kOverlapWindow = 400;

/// Minimum overlap length that counts as a repeat. Shorter matches are far
/// more likely to be coincidence ("in." / "the ") than an echoed tail.
const int _kMinOverlap = 12;

final RegExp _ws = RegExp(r'\s');

/// Characters that GLUE to the end of [existing] without a space when the
/// continuation starts with them (closing/attaching punctuation).
final RegExp _attachers = RegExp(r'''[.,!?;:…)\]}»']''');

/// Characters at the END of [existing] after which the continuation glues
/// directly (openers / joiners).
final RegExp _openers = RegExp(r'[(\[{\-—–/]');

String mergeContinuationText({
  required String existing,
  required String continuation,
}) {
  if (existing.isEmpty) return continuation;
  if (continuation.isEmpty) return existing;

  final contTrimLead = continuation.replaceFirst(RegExp(r'^\s+'), '');
  final windowStart =
      existing.length > _kOverlapWindow ? existing.length - _kOverlapWindow : 0;
  final window = existing.substring(windowStart);

  // Longest-first: a full restart (continuation begins with the whole
  // message) is caught before a shorter tail echo.
  for (var len = window.length; len >= _kMinOverlap; len--) {
    final suffix = window.substring(window.length - len);
    if (continuation.startsWith(suffix)) {
      return _joinSeam(existing, continuation.substring(len));
    }
    if (contTrimLead.startsWith(suffix)) {
      return _joinSeam(existing, contTrimLead.substring(len));
    }
  }
  return _joinSeam(existing, continuation);
}

/// 2026-07-04 (Gui approved): resolve the preset's "Start reply with"
/// prefill — {{char}}/{{user}} macros filled, trimmed (Anthropic rejects a
/// trailing-whitespace assistant prefix; the display seam re-adds the space
/// via [mergeContinuationText]). Null when unset/blank, so the request
/// stays byte-identical.
String? resolveStartReplyWith({
  required String? raw,
  required String charName,
  required String userName,
}) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;
  final filled = text
      .replaceAll(RegExp(r'\{\{char\}\}', caseSensitive: false), charName)
      .replaceAll(RegExp(r'\{\{user\}\}', caseSensitive: false), userName)
      .trim();
  return filled.isEmpty ? null : filled;
}

String _joinSeam(String existing, String rest) {
  if (rest.isEmpty) return existing;
  if (existing.isEmpty) return rest;
  final last = existing[existing.length - 1];
  final first = rest[0];
  final needsSpace = !_ws.hasMatch(last) &&
      !_openers.hasMatch(last) &&
      !_ws.hasMatch(first) &&
      !_attachers.hasMatch(first);
  return needsSpace ? '$existing $rest' : '$existing$rest';
}
