// Lightweight token estimator. We deliberately avoid pulling in a real
// tokenizer (tiktoken / sentencepiece) — adding ~3MB and a native dep
// for a UX hint isn't worth it. The chars/4 heuristic is what OpenAI
// itself ships in their docs for English; for CJK it under-estimates,
// for code it over-estimates, but for the "feel" we want (is this
// reply 100 tokens or 5000?) it's accurate enough.

import '../models/models.dart';

/// Approximate token count for [text]. Returns 0 for null/empty.
int approxTokens(String? text) {
  if (text == null || text.isEmpty) return 0;
  // Round, not floor — a 3-char string is closer to 1 token than 0.
  return (text.length / 4).round();
}

/// Format an estimate compactly for UI: 0–999 as plain integer,
/// thousands as "1.2k", etc. Returns null for 0 so callers can skip
/// rendering when there's nothing to show.
String? formatApproxTokens(String? text) {
  return formatTokenCount(approxTokens(text));
}

/// Format a pre-counted token total. Mirrors [formatApproxTokens]
/// but accepts an int directly — used when callers sum across multiple
/// strings (a character's fields, a lorebook's entries, etc).
String? formatTokenCount(int n) {
  if (n == 0) return null;
  if (n < 1000) return '~$n tokens';
  return '~${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k tokens';
}

/// Wave CM: total token weight of a character — sum of every field
/// that the runtime sends to the LLM during chat (descriptions,
/// scenarios, dialogue, etc.). Avatar / metadata fields are skipped.
int approxTokensForCharacter(Character c) {
  return approxTokens(c.description) +
      approxTokens(c.personality) +
      approxTokens(c.scenario) +
      approxTokens(c.firstMes) +
      approxTokens(c.mesExample) +
      approxTokens(c.systemPrompt) +
      approxTokens(c.postHistoryInstructions) +
      approxTokens(c.depthPrompt) +
      c.alternateGreetings.fold<int>(0, (n, g) => n + approxTokens(g));
}

/// Wave CM: total token weight of a persona — description is the only
/// substantive field that hits the LLM. Tagline is metadata.
int approxTokensForPersona(Persona p) {
  return approxTokens(p.description);
}

/// Wave CM: total token weight of a lorebook — sum across enabled
/// entry contents. Disabled entries never inject so they're skipped.
/// Keys themselves don't go to the LLM (they're scan triggers only).
int approxTokensForLorebook(Lorebook l) {
  var n = 0;
  for (final e in l.entries) {
    if (!e.enabled) continue;
    n += approxTokens(e.content);
  }
  return n;
}

/// Wave CQ: token weight of a Creator canvas (Map shape, before it
/// becomes a Character on save). Mirrors `approxTokensForCharacter`
/// but works directly on the raw canvas keys so the in-progress
/// sheet can show a live count.
int approxTokensForCanvas(Map<String, dynamic> canvas) {
  String s(String key) {
    final v = canvas[key];
    return v is String ? v : '';
  }

  var total = approxTokens(s('description')) +
      approxTokens(s('personality')) +
      approxTokens(s('scenario')) +
      approxTokens(s('first_mes')) +
      approxTokens(s('mes_example')) +
      approxTokens(s('system_prompt')) +
      approxTokens(s('post_history_instructions'));
  final greetings = canvas['alternate_greetings'];
  if (greetings is List) {
    for (final g in greetings) {
      if (g is String) total += approxTokens(g);
    }
  }
  return total;
}
