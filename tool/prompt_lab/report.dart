// Wave CY.18.211 (Prompt Observability — `inspect` harness): the REPORT
// WRITER for the prompt-lab harness.
//
// Given a scenario id + the assembly result, it writes two sibling files to
// `tool/prompt_lab/out/`:
//   • `<id>.md`          — human-readable: each PromptSegment under a labeled
//                          `## [<kind>]  (~N tokens)` heading, a grand-total
//                          line, and the final `messages` role/length summary.
//   • `<id>.request.json` — the raw outgoing request: `{ "messages": [...] }`
//                          (each turn via `ChatTurn.toJson()`), pretty-printed.
//
// Token estimates reuse the app's own `approxTokens` (chars/4) so the numbers
// match what the in-app token chips show. NO model, NO key — assembly only.

import 'dart:convert';
import 'dart:io';

import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/chat_prompt_builder.dart';
import 'package:pyre/services/token_estimate.dart';

/// Output directory (relative to the package root), created on demand.
const outDir = 'tool/prompt_lab/out';

/// A small result so the entrypoint can print a summary table without
/// re-deriving the numbers.
class ReportSummary {
  final String id;
  final int totalTokens;
  final int segmentOrTurnCount;
  final String mdPath;
  final String jsonPath;
  const ReportSummary(
    this.id,
    this.totalTokens,
    this.segmentOrTurnCount,
    this.mdPath,
    this.jsonPath,
  );
}

const _kindLabels = <PromptSegmentKind, String>{
  PromptSegmentKind.systemPrompt: 'systemPrompt',
  PromptSegmentKind.persona: 'persona',
  PromptSegmentKind.character: 'character',
  PromptSegmentKind.lorebookBefore: 'lorebookBefore',
  PromptSegmentKind.lorebookAfter: 'lorebookAfter',
  PromptSegmentKind.ltmRecap: 'ltmRecap',
  PromptSegmentKind.liveSheet: 'liveSheet',
  PromptSegmentKind.script: 'script',
  PromptSegmentKind.groupRoster: 'groupRoster',
  PromptSegmentKind.history: 'history',
  PromptSegmentKind.postHistory: 'postHistory',
};

// ---------------------------------------------------------------------------
// Golden serialization (Wave CY.18.212)
// ---------------------------------------------------------------------------
//
// A STABLE, DETERMINISTIC text dump of an assembled result — this is what the
// committed goldens in `test/goldens/prompt_lab/<id>.txt` store and what the
// golden test (`test/prompt_lab_golden_test.dart`) re-derives + diffs.
//
// Unlike the markdown report, the golden text contains ONLY the labeled
// content: NO token counts, NO timestamps, NO file paths, NO `{{random:}}`
// surprise (the fixtures use fixed-length message lists so the resolver is
// deterministic). That keeps the golden a pure function of the prompt
// assembly, so a diff in `*.txt` == a real change in what the model sees.

/// Separator between segments/turns in the golden text. A line of dashes
/// fenced by blank lines — visible in a diff, and chosen so it never collides
/// with prompt content (prompt framing uses `--- Lore ---` style markers, not
/// a bare 40-dash rule on its own line).
const _goldenSep = '\n----------------------------------------\n';

/// Stable serialization of a CHAT assembly: each [PromptSegment] emitted as
///   `[<kind>]`
///   `<segment.text>`
/// joined by [_goldenSep]. Deterministic — no tokens, no timestamps.
String goldenTextForChat(ChatPromptResult result) {
  final parts = <String>[];
  for (final seg in result.segments) {
    final label = _kindLabels[seg.kind] ?? seg.kind.name;
    parts.add('[$label]\n${seg.text}');
  }
  return parts.join(_goldenSep);
}

/// Stable serialization of a CREATOR assembly: each [ChatTurn] emitted as
///   `[<role>]`
///   `<turn text (or an explicit image/empty marker)>`
/// joined by [_goldenSep]. Image turns append a stable `[+N image(s)]` line
/// (NOT the base64 bytes — those are huge + irrelevant to a prompt diff).
String goldenTextForCreator(List<ChatTurn> turns) {
  final parts = <String>[];
  for (final t in turns) {
    final body = StringBuffer();
    if (t.content.isNotEmpty) {
      body.write(t.content);
    } else {
      body.write('(no text content)');
    }
    final images = t.imageDataUrls;
    if (images != null && images.isNotEmpty) {
      body.write('\n[+${images.length} image(s)]');
    }
    parts.add('[${t.role}]\n$body');
  }
  return parts.join(_goldenSep);
}

File _ensureOut(String id, String ext) {
  Directory(outDir).createSync(recursive: true);
  return File('$outDir/$id.$ext');
}

String _fence(String text) {
  // Pick a fence long enough that the content can't accidentally close it.
  var ticks = '```';
  while (text.contains(ticks)) {
    ticks += '`';
  }
  return '$ticks\n$text\n$ticks';
}

String _requestJson(List<ChatTurn> turns) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert({'messages': turns.map((t) => t.toJson()).toList()});
}

/// Short one-line summary of a turn for the messages table at the bottom of
/// the report: `system (1234 chars, ~308 tokens)`.
String _turnSummaryLine(ChatTurn t, int index) {
  final chars = t.content.length;
  final tok = approxTokens(t.content);
  final img = (t.imageDataUrls?.isNotEmpty ?? false)
      ? ' +${t.imageDataUrls!.length} image(s)'
      : '';
  return '$index. ${t.role} — $chars chars, ~$tok tokens$img';
}

/// Write the CHAT report (segments + turns) for [id] / [result].
ReportSummary writeChatReport(
  String id,
  String description,
  ChatPromptResult result,
) {
  final buf = StringBuffer();
  buf.writeln('# Prompt Lab — $id');
  buf.writeln();
  buf.writeln('> $description');
  buf.writeln('>');
  buf.writeln('> Generated by `tool/prompt_lab/prompt_lab.dart` (no model). '
      'Token counts use `approxTokens` (chars/4).');
  buf.writeln();

  var total = 0;
  buf.writeln('## Labeled segments');
  buf.writeln();
  for (final seg in result.segments) {
    final tok = approxTokens(seg.text);
    total += tok;
    final label = _kindLabels[seg.kind] ?? seg.kind.name;
    buf.writeln('## [$label]  (~$tok tokens)');
    if (seg.note != null && seg.note!.isNotEmpty) {
      buf.writeln('_note: ${seg.note}_');
    }
    buf.writeln();
    buf.writeln(_fence(seg.text));
    buf.writeln();
  }

  buf.writeln('---');
  buf.writeln();
  buf.writeln('**Total segment tokens (~):** $total  ·  '
      '**segments:** ${result.segments.length}');
  buf.writeln();

  buf.writeln('## Final `messages` (role / length)');
  buf.writeln();
  var turnTotal = 0;
  for (var i = 0; i < result.turns.length; i++) {
    final t = result.turns[i];
    turnTotal += approxTokens(t.content);
    buf.writeln('- ${_turnSummaryLine(t, i + 1)}');
  }
  buf.writeln();
  buf.writeln('**Turns:** ${result.turns.length}  ·  '
      '**Total turn tokens (~):** $turnTotal');
  buf.writeln();

  final md = _ensureOut(id, 'md');
  md.writeAsStringSync(buf.toString());
  final js = _ensureOut(id, 'request.json');
  js.writeAsStringSync(_requestJson(result.turns));

  return ReportSummary(id, total, result.segments.length, md.path, js.path);
}

/// Write a CREATOR report — Creator builders return raw turns (no labeled
/// segments), so each turn is dumped under a `## [<role> #N]` heading.
ReportSummary writeCreatorReport(
  String id,
  String description,
  List<ChatTurn> turns,
) {
  final buf = StringBuffer();
  buf.writeln('# Prompt Lab — $id');
  buf.writeln();
  buf.writeln('> $description');
  buf.writeln('>');
  buf.writeln('> Generated by `tool/prompt_lab/prompt_lab.dart` (no model). '
      'Token counts use `approxTokens` (chars/4).');
  buf.writeln();

  var total = 0;
  buf.writeln('## Turns');
  buf.writeln();
  for (var i = 0; i < turns.length; i++) {
    final t = turns[i];
    final tok = approxTokens(t.content);
    total += tok;
    final img = (t.imageDataUrls?.isNotEmpty ?? false)
        ? '  · +${t.imageDataUrls!.length} image(s)'
        : '';
    buf.writeln('## [${t.role} #${i + 1}]  (~$tok tokens)$img');
    buf.writeln();
    // For an image-only / empty-text turn, note the absence explicitly.
    buf.writeln(_fence(t.content.isEmpty ? '(no text content)' : t.content));
    buf.writeln();
  }

  buf.writeln('---');
  buf.writeln();
  buf.writeln('**Total turn tokens (~):** $total  ·  '
      '**turns:** ${turns.length}');
  buf.writeln();

  buf.writeln('## Final `messages` (role / length)');
  buf.writeln();
  for (var i = 0; i < turns.length; i++) {
    buf.writeln('- ${_turnSummaryLine(turns[i], i + 1)}');
  }
  buf.writeln();

  final md = _ensureOut(id, 'md');
  md.writeAsStringSync(buf.toString());
  final js = _ensureOut(id, 'request.json');
  js.writeAsStringSync(_requestJson(turns));

  return ReportSummary(id, total, turns.length, md.path, js.path);
}

// ---------------------------------------------------------------------------
// LIVE report (Wave CY.18.213)
// ---------------------------------------------------------------------------
//
// Live mode fires a REAL model call per scenario and writes a SEPARATE report
// (`<id>.live.md`) so it never clobbers the deterministic `inspect` dumps. The
// file holds: the assembled-prompt summary, the RAW response, the
// finish_reason, and the feature-specific parse outcome — never the API key.

/// Path of the live report for [id] (relative to the package root).
String liveReportPath(String id) => '$outDir/$id.live.md';

/// Write the LIVE report for [id]. [promptSummary] is a short turns/segments
/// line, [response] is the RAW (already sentinel-stripped) reply, [finishReason]
/// is the captured reason (or null), [parseOutcome] is the feature-specific
/// classification line, and [error] (when non-null) records a call failure —
/// in which case [response]/[finishReason] are skipped.
void writeLiveReport(
  String id, {
  required String description,
  required String promptSummary,
  String? response,
  String? finishReason,
  String? parseOutcome,
  String? error,
}) {
  final buf = StringBuffer();
  buf.writeln('# Prompt Lab — $id (LIVE)');
  buf.writeln();
  buf.writeln('> $description');
  buf.writeln('>');
  buf.writeln('> Generated by `tool/prompt_lab/prompt_lab_live.dart` — a REAL '
      'model call. The API key is NEVER written here.');
  buf.writeln();

  buf.writeln('## Assembled prompt');
  buf.writeln();
  buf.writeln(promptSummary);
  buf.writeln();

  if (error != null) {
    buf.writeln('## Result: ERROR');
    buf.writeln();
    buf.writeln('The live call failed (the harness did not crash):');
    buf.writeln();
    buf.writeln(_fence(error));
    buf.writeln();
  } else {
    buf.writeln('## finish_reason');
    buf.writeln();
    buf.writeln('`${finishReason ?? '(none reported)'}`');
    buf.writeln();

    buf.writeln('## Raw response');
    buf.writeln();
    buf.writeln(_fence((response ?? '').isEmpty
        ? '(empty response)'
        : response!));
    buf.writeln();

    buf.writeln('## Parse outcome');
    buf.writeln();
    buf.writeln(parseOutcome ?? '(no parse outcome)');
    buf.writeln();
  }

  final md = File(liveReportPath(id));
  Directory(outDir).createSync(recursive: true);
  md.writeAsStringSync(buf.toString());
}
