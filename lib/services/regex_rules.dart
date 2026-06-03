// Pyre 1.1 (F4) — Regex find/replace, SillyTavern-style "Regex" scripts.
//
// A POWER-USER feature to rewrite text on the fly: strip a model's quirk,
// reformat names, hide tokens, etc.
//
// DESIGN — NON-DESTRUCTIVE. Pyre regex rules NEVER mutate stored messages.
// Each rule applies at one or both of two STAGES:
//   - display : transform only what's RENDERED in the chat bubble (storage
//               untouched).
//   - prompt  : transform only what's SENT to the model in the prompt
//               (history transformed in-flight; storage untouched).
// And each rule targets one or both STREAMS (by message role):
//   - userInput : the user's / persona turns.
//   - aiOutput  : the character / AI turns.
//
// This module is PURE (no Flutter, no AppStore): it owns the rule model, the
// enums, the substitution engine, the `/pat/flags` literal parser, and the
// SillyTavern import parser. Everything here is unit-testable in isolation —
// the apply-points (chat prompt builder + message renderer) and the editor UI
// live elsewhere and only call into these functions.

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Which message ROLE a rule targets. A rule may carry one or both.
enum RegexStream { userInput, aiOutput }

/// WHEN a rule fires. `display` = the rendered bubble; `prompt` = the text
/// sent to the model. A rule may apply to one or both (see
/// [RegexRule.affectsDisplay] / [RegexRule.affectsPrompt]).
enum RegexStage { display, prompt }

/// One non-destructive find/replace rule. Mirrors the LWW-sync metadata
/// (`mtime` / `deleted`) carried by Pyre's other synced top-level lists
/// (lorebooks, presets) so it rides the LAN sync the same way.
class RegexRule {
  String id;
  String name;

  /// Raw regex SOURCE — no surrounding slashes. (The UI's "Find" box accepts
  /// a `/pat/flags` literal and splits it via [parseRegexLiteral] before
  /// storing here.)
  String pattern;

  /// Flag letters, e.g. "gi". Supported: i (case-insensitive), m (multiline),
  /// s (dotAll), g (global / replace-all). Unknown letters are ignored.
  String flags;

  /// Replacement string. Supports `$1`..`$9` capture-group refs and the
  /// literal macro `{{match}}` (the whole matched substring).
  String replacement;

  /// Substrings stripped from the matched text wherever the replacement
  /// references the match (`{{match}}` / `$0`). SillyTavern's `trimStrings`.
  List<String> trimStrings;

  /// Roles this rule targets. Defaults to BOTH.
  List<RegexStream> streams;

  /// Apply to the rendered bubble (display stage). Default true.
  bool affectsDisplay;

  /// Apply to the prompt sent to the model (prompt stage). Default true.
  bool affectsPrompt;

  /// Disabled rules are skipped entirely by [applyRegexRules].
  bool enabled;

  /// LWW sync metadata. See Character.mtime in models.dart for rationale.
  int mtime;
  bool deleted;

  RegexRule({
    String? id,
    this.name = 'Rule',
    this.pattern = '',
    this.flags = '',
    this.replacement = '',
    List<String>? trimStrings,
    List<RegexStream>? streams,
    this.affectsDisplay = true,
    this.affectsPrompt = true,
    this.enabled = true,
    this.mtime = 0,
    this.deleted = false,
  })  : id = id ?? _uuid.v4(),
        trimStrings = trimStrings ?? <String>[],
        streams = streams ?? <RegexStream>[RegexStream.userInput, RegexStream.aiOutput];

  /// True iff this rule should run at [stage] (per its affects* flags).
  bool appliesToStage(RegexStage stage) =>
      stage == RegexStage.display ? affectsDisplay : affectsPrompt;

  RegexRule clone() => RegexRule(
        id: id,
        name: name,
        pattern: pattern,
        flags: flags,
        replacement: replacement,
        trimStrings: List<String>.from(trimStrings),
        streams: List<RegexStream>.from(streams),
        affectsDisplay: affectsDisplay,
        affectsPrompt: affectsPrompt,
        enabled: enabled,
        mtime: mtime,
        deleted: deleted,
      );

  factory RegexRule.fromJson(Map<String, dynamic> j) => RegexRule(
        id: j['id'] as String?,
        name: (j['name'] as String?) ?? 'Rule',
        pattern: (j['pattern'] as String?) ?? '',
        flags: (j['flags'] as String?) ?? '',
        replacement: (j['replacement'] as String?) ?? '',
        trimStrings: (j['trimStrings'] as List?)
                ?.whereType<String>()
                .toList() ??
            <String>[],
        streams: _parseStreams(j['streams']),
        affectsDisplay: (j['affectsDisplay'] as bool?) ?? true,
        affectsPrompt: (j['affectsPrompt'] as bool?) ?? true,
        enabled: (j['enabled'] as bool?) ?? true,
        mtime: (j['mtime'] as num?)?.toInt() ?? 0,
        deleted: (j['deleted'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'pattern': pattern,
        'flags': flags,
        'replacement': replacement,
        'trimStrings': trimStrings,
        'streams': streams.map((s) => s.name).toList(),
        'affectsDisplay': affectsDisplay,
        'affectsPrompt': affectsPrompt,
        'enabled': enabled,
        'mtime': mtime,
        if (deleted) 'deleted': true,
      };

  /// Tolerant stream-list decoder. Missing / empty / all-unknown → BOTH
  /// streams (the safe, ST-compatible default — a rule with no target stream
  /// would silently never fire).
  static List<RegexStream> _parseStreams(dynamic v) {
    if (v is List) {
      final out = <RegexStream>[];
      for (final e in v) {
        if (e is! String) continue;
        for (final s in RegexStream.values) {
          if (s.name == e && !out.contains(s)) out.add(s);
        }
      }
      if (out.isNotEmpty) return out;
    }
    return <RegexStream>[RegexStream.userInput, RegexStream.aiOutput];
  }
}

/// Apply every ENABLED rule in [rules] that targets [stream] AND applies to
/// [stage], in order, to [text]. Returns [text] unchanged when nothing
/// applies (identity). NEVER throws — an invalid pattern makes that one rule
/// a no-op while the rest still run.
String applyRegexRules(
  String text,
  List<RegexRule> rules, {
  required RegexStream stream,
  required RegexStage stage,
}) {
  if (rules.isEmpty || text.isEmpty) return text;
  var out = text;
  for (final rule in rules) {
    if (!rule.enabled || rule.deleted) continue;
    if (!rule.streams.contains(stream)) continue;
    if (!rule.appliesToStage(stage)) continue;
    out = _applyOne(out, rule);
  }
  return out;
}

/// Apply ONE rule. Compiles the pattern with its flags inside a try/catch —
/// an invalid pattern returns the input untouched (no-op). The `g` flag (or
/// the word "global") means replace-all; without it, only the first match is
/// replaced.
String _applyOne(String text, RegexRule rule) {
  if (rule.pattern.isEmpty) return text;
  final lower = rule.flags.toLowerCase();
  final RegExp re;
  try {
    re = RegExp(
      rule.pattern,
      caseSensitive: !lower.contains('i'),
      multiLine: lower.contains('m'),
      dotAll: lower.contains('s'),
    );
  } catch (_) {
    // Invalid pattern → no-op (never crash the chat).
    return text;
  }
  final global = lower.contains('g') || lower.contains('global');

  String expand(Match m) => _expandReplacement(rule, m);

  try {
    if (global) {
      return text.replaceAllMapped(re, expand);
    }
    // First-only: find the first match and splice the replacement in.
    final m = re.firstMatch(text);
    if (m == null) return text;
    return text.replaceRange(m.start, m.end, expand(m));
  } catch (_) {
    return text;
  }
}

/// Build the replacement for a single [Match]:
///   - `{{match}}` → the whole matched substring (group 0), with [trimStrings]
///     stripped (ST semantics: trims are removed from the captured match).
///   - `$1`..`$9`  → the corresponding capture group (empty if absent / null).
///   - `$0`        → the whole match, also trim-stripped (treated as the match).
///   - `$$`        → a literal `$`.
String _expandReplacement(RegexRule rule, Match m) {
  final trimmedMatch = _applyTrim(m.group(0) ?? '', rule.trimStrings);
  final src = rule.replacement;
  final buf = StringBuffer();
  var i = 0;
  while (i < src.length) {
    // {{match}} macro (case-insensitive).
    if (src.startsWith('{{', i)) {
      final close = src.indexOf('}}', i + 2);
      if (close > 0) {
        final token = src.substring(i + 2, close).trim().toLowerCase();
        if (token == 'match') {
          buf.write(trimmedMatch);
          i = close + 2;
          continue;
        }
      }
    }
    // $-references.
    if (src[i] == r'$' && i + 1 < src.length) {
      final next = src[i + 1];
      if (next == r'$') {
        buf.write(r'$');
        i += 2;
        continue;
      }
      final code = next.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39) {
        final n = code - 0x30; // 0..9
        if (n == 0) {
          buf.write(trimmedMatch);
        } else {
          final g = (n <= m.groupCount) ? m.group(n) : null;
          buf.write(g ?? '');
        }
        i += 2;
        continue;
      }
    }
    buf.write(src[i]);
    i++;
  }
  return buf.toString();
}

/// Remove every substring in [trims] from [s] (faithful-but-simple ST
/// `trimStrings` semantics). Empty trims and an empty list are no-ops.
String _applyTrim(String s, List<String> trims) {
  if (trims.isEmpty) return s;
  var out = s;
  for (final t in trims) {
    if (t.isEmpty) continue;
    out = out.replaceAll(t, '');
  }
  return out;
}

/// Split a UI "Find" input into (pattern, flags). When [input] looks like a
/// `/pat/flags` literal (leading slash + a later slash, the segment after the
/// last slash being only flag letters), the body becomes the pattern and the
/// trailing letters the flags. Otherwise the whole string is the pattern with
/// empty flags. A bare `/foo/` (no flags) is still recognised. An unterminated
/// `/foo` is treated as a literal pattern.
({String pattern, String flags}) parseRegexLiteral(String input) {
  final s = input;
  if (s.length >= 2 && s.startsWith('/')) {
    final lastSlash = s.lastIndexOf('/');
    if (lastSlash > 0) {
      final body = s.substring(1, lastSlash);
      final flags = s.substring(lastSlash + 1);
      // Only treat as a literal when the trailing segment is flag letters
      // (or empty). This keeps a path-like pattern "/a/b/c" usable verbatim
      // when "b/c" isn't a flag run — but "/a/gi" splits cleanly.
      if (RegExp(r'^[a-zA-Z]*$').hasMatch(flags) && body.isNotEmpty) {
        return (pattern: body, flags: flags);
      }
    }
  }
  return (pattern: s, flags: '');
}

// ===========================================================================
// SillyTavern "Regex" script import.
// ===========================================================================

/// Parse ONE SillyTavern regex-script JSON object into a [RegexRule], or
/// `null` when it carries no usable pattern. Tolerant of missing keys.
///
/// ST field mapping:
///   scriptName     → name
///   findRegex      → pattern + flags (a `/pat/flags` literal, split here)
///   replaceString  → replacement (keeps `$1`, `{{match}}`)
///   trimStrings    → trimStrings (list)
///   placement[]    → streams: contains 1 ⇒ userInput, 2 ⇒ aiOutput;
///                    empty/absent ⇒ both.
///   markdownOnly   → display-only (affectsDisplay=true, affectsPrompt=false)
///   promptOnly     → prompt-only  (affectsPrompt=true, affectsDisplay=false)
///                    neither (or both) ⇒ both true.
///   disabled       → enabled = !disabled
RegexRule? parseStRegexScript(Map<dynamic, dynamic> json) {
  final j = json.cast<dynamic, dynamic>();
  final find = (j['findRegex'] as String?)?.trim() ?? '';
  if (find.isEmpty) return null;
  final lit = parseRegexLiteral(find);

  final name = (j['scriptName'] as String?)?.trim();
  final replacement = (j['replaceString'] as String?) ?? '';

  final trims = (j['trimStrings'] as List?)
          ?.whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList() ??
      <String>[];

  // placement → streams.
  final placement = (j['placement'] as List?)
          ?.map((e) => e is num ? e.toInt() : null)
          .whereType<int>()
          .toList() ??
      const <int>[];
  final streams = <RegexStream>[];
  if (placement.contains(1)) streams.add(RegexStream.userInput);
  if (placement.contains(2)) streams.add(RegexStream.aiOutput);
  if (streams.isEmpty) {
    streams
      ..add(RegexStream.userInput)
      ..add(RegexStream.aiOutput);
  }

  // markdownOnly / promptOnly → stages.
  final markdownOnly = (j['markdownOnly'] as bool?) ?? false;
  final promptOnly = (j['promptOnly'] as bool?) ?? false;
  bool affectsDisplay;
  bool affectsPrompt;
  if (markdownOnly && !promptOnly) {
    affectsDisplay = true;
    affectsPrompt = false;
  } else if (promptOnly && !markdownOnly) {
    affectsDisplay = false;
    affectsPrompt = true;
  } else {
    // neither set, OR both set → both true.
    affectsDisplay = true;
    affectsPrompt = true;
  }

  final disabled = (j['disabled'] as bool?) ?? false;

  return RegexRule(
    name: (name == null || name.isEmpty) ? 'Imported rule' : name,
    pattern: lit.pattern,
    flags: lit.flags,
    replacement: replacement,
    trimStrings: trims,
    streams: streams,
    affectsDisplay: affectsDisplay,
    affectsPrompt: affectsPrompt,
    enabled: !disabled,
  );
}

/// Parse a FILE of ST regex scripts. Accepts either a bare array of script
/// objects, a single script object, or a wrapper `{ "regexScripts": [...] }`
/// (some exports nest them). Skips entries that don't parse. Never throws.
List<RegexRule> parseStRegexScripts(dynamic root) {
  final out = <RegexRule>[];
  Iterable<dynamic> items;
  if (root is List) {
    items = root;
  } else if (root is Map) {
    final nested = root['regexScripts'] ?? root['scripts'];
    if (nested is List) {
      items = nested;
    } else {
      // A single script object.
      items = [root];
    }
  } else {
    return out;
  }
  for (final item in items) {
    if (item is Map) {
      final rule = parseStRegexScript(item);
      if (rule != null) out.add(rule);
    }
  }
  return out;
}
