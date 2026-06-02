// Wave CY.18.99: pure refusal / empty classification for chat fallback.
//
// A real content refusal refuses the WHOLE prompt and comes back short,
// dry, and markup-free ("I'm sorry, but I can't…", "I won't…"), ending
// abruptly — whereas a normal RP reply is longer and carries *action*
// or "dialogue" markup. Refusals arrive in English regardless of the
// chat's language (model alignment is English-dominant), so ONLY
// English patterns are encoded here.
//
// See docs/superpowers/specs/2026-05-28-smart-provider-fallback-design.md.

/// Verdict for a COMPLETED response (run in the chat stream's onDone).
enum ResponseVerdict { ok, empty, likelyRefusal }

/// Short = likely refusal. A normal RP reply almost always runs longer.
/// Pinned here; locked by the test table. Tune only with a test.
const int _refusalWordCeiling = 60;

/// Strong refusal patterns. Two shapes:
///   - start-anchored openers (refusals begin at the very start),
///   - a verb-object pattern allowed anywhere (specific enough that it
///     won't fire on "I can't believe…" because the object list excludes
///     non-refusal verbs).
// Non-raw strings (doubled backslashes) so the apostrophe character
// class can include BOTH the straight apostrophe and the smart one
// (U+2019) — models emit "can't" with either, and a straight-only
// `'?` silently missed the smart-quote refusals.
final List<RegExp> _refusalPatterns = [
  RegExp("^\\s*i['’]?m sorry[,.]?\\s+(but|i)\\b", caseSensitive: false),
  RegExp("^\\s*i\\s+(can['’]?t|cannot|won['’]?t|will not)\\b",
      caseSensitive: false),
  RegExp(
      "\\bi\\s+(can['’]?t|cannot|won['’]?t|will not|am not able to|am unable to)\\s+"
      "(continue|comply|help|assist|do that|write|generate|create|produce|engage|provide|fulf(?:ill|il))",
      caseSensitive: false),
  RegExp("\\bi['’]?m\\s+(not able|unable)\\s+to\\b",
      caseSensitive: false),
  RegExp("\\bi must decline\\b", caseSensitive: false),
  // NOTE (audit M1): a bare `as an ai` pattern was REMOVED — on an RP
  // platform a character whose persona IS an AI ("As an AI, I was built
  // to serve you, master.") is a legitimate in-character line, not a
  // refusal. The verb-object patterns above catch real refusals without
  // it.
  RegExp("\\bi (do not|don['’]?t) feel comfortable\\b",
      caseSensitive: false),
  RegExp("\\bthis (request|content) (violates|goes against)\\b",
      caseSensitive: false),
];

/// Classify a completed chat response. Pure; no I/O.
ResponseVerdict classifyResponse(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return ResponseVerdict.empty;
  if (_looksLikeRefusal(trimmed)) return ResponseVerdict.likelyRefusal;
  return ResponseVerdict.ok;
}

bool _looksLikeRefusal(String text) {
  // Signal 1 (required): short. A short blob makes "phrase near the
  // start" equivalent to "phrase anywhere", so we don't need a separate
  // position check.
  final words =
      text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
  if (words > _refusalWordCeiling) return false;

  // Signal 2 (required, audit M1): NO roleplay markup. A real refusal is
  // flat prose — a genuine in-character line carries *action* asterisks
  // or "dialogue" double-quotes. Requiring markup-absence kills the
  // false positive on emotional RP beats like
  //   '"I'm sorry, but you left me no choice," she whispered.'
  // We check ONLY `*` and double-quotes (straight + smart). We do NOT
  // treat the apostrophe / single-quote as markup, because refusals are
  // contraction-heavy ("can't", "won't", "I'm") and many models emit a
  // smart apostrophe — counting that as markup would suppress real
  // refusals.
  if (_hasRpMarkup(text)) return false;

  // Signal 3 (required): a refusal phrase matches.
  return _refusalPatterns.any((re) => re.hasMatch(text));
}

bool _hasRpMarkup(String text) {
  return text.contains('*') ||
      text.contains('"') ||
      text.contains('“') || // “ left double quote
      text.contains('”'); // ” right double quote
}
