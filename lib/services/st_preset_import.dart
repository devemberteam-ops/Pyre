// SillyTavern preset → Pyre Preset (best-effort, marker-aware).
//
// ST presets are a prompt-pipeline DSL: a flat `prompts` list keyed by
// `identifier`, plus a `prompt_order` describing which ones to include and
// in what order. Crucially, the order contains a `chatHistory` marker that
// splits the pipeline into:
//
//   • before chatHistory  → goes into the SYSTEM prompt
//   • after  chatHistory  → goes into postHistoryInstructions (jailbreak
//                            / prefill / final reminder)
//
// We also need to resolve the standard markers (`charDescription`,
// `charPersonality`, `scenario`, `personaDescription`, `dialogueExamples`,
// `worldInfoBefore`, `worldInfoAfter`, `enhanceDefinitions`) into our own
// template tokens like `{{description}}` so the chat builder can splice in
// the live character / persona / lorebook content at send time.
//
// References:
//   - The HTML prototype's identical port: `js/screens.js::importSillyTavernPreset`
//   - Real-world example: `FluffPreset - RP.json` (DeepSeek-targeted preset
//     with main / nsfw / jailbreak + custom fluffpreset_* prompts).

import 'dart:convert';

import '../models/models.dart';

class StImportResult {
  final Preset preset;
  final int promptCount;
  final List<String> skipped;
  StImportResult(this.preset, this.promptCount, this.skipped);
}

StImportResult parseSillyTavernPreset(String jsonText) {
  final root = jsonDecode(jsonText);
  if (root is! Map) throw const FormatException('Not a JSON object');
  final map = root.cast<String, dynamic>();

  // Pass-through path — re-importing one of our own exports.
  if (map['mainPrompt'] != null || map['modelSettings'] != null) {
    final p = Preset.fromJson(map);
    p.id = newId('preset');
    p.name = '${p.name} (imported)';
    p.locked = false;
    return StImportResult(p, 0, const []);
  }

  if (map['prompts'] is! List && map['prompt_order'] is! List) {
    throw const FormatException(
      'Not a SillyTavern preset (no `prompts` or `prompt_order`).',
    );
  }

  // Index prompts by identifier.
  final promptsById = <String, Map<String, dynamic>>{};
  if (map['prompts'] is List) {
    for (final raw in (map['prompts'] as List)) {
      if (raw is Map && raw['identifier'] is String) {
        promptsById[raw['identifier'] as String] =
            raw.cast<String, dynamic>();
      }
    }
  }

  // Pick the first prompt_order block (ST puts the default at
  // character_id 100000; subsequent entries are per-character overrides).
  final orderList = <Map<String, dynamic>>[];
  if (map['prompt_order'] is List &&
      (map['prompt_order'] as List).isNotEmpty) {
    final first = (map['prompt_order'] as List).first;
    if (first is Map && first['order'] is List) {
      for (final raw in (first['order'] as List)) {
        if (raw is Map && raw['identifier'] is String) {
          orderList.add(raw.cast<String, dynamic>());
        }
      }
    }
  }
  // Fall back: walk prompts in insertion order.
  if (orderList.isEmpty) {
    for (final p in promptsById.values) {
      orderList.add({
        'identifier': p['identifier'],
        'enabled': p['enabled'] ?? true,
      });
    }
  }

  // Split before/after the chatHistory marker.
  final before = <Map<String, dynamic>>[];
  final after = <Map<String, dynamic>>[];
  var pastHistory = false;
  for (final item in orderList) {
    if (item['enabled'] == false) continue;
    final id = item['identifier'] as String?;
    if (id == null) continue;
    if (id == 'chatHistory') {
      pastHistory = true;
      continue;
    }
    (pastHistory ? after : before).add(item);
  }

  /// Resolve an identifier to its rendered text. Standard markers become
  /// our template tokens; custom prompts return their literal `content`.
  String renderIdentifier(String id, List<String> skipped) {
    final p = promptsById[id];
    switch (id) {
      case 'main':
        return p?['content'] is String ? p!['content'] as String : '';
      case 'charDescription':
        return '{{description}}';
      case 'charPersonality':
        return '{{personality}}';
      case 'scenario':
        return '{{scenario}}';
      case 'personaDescription':
        return '## About {{user}}\n{{persona}}';
      case 'dialogueExamples':
        return '{{mesExample}}';
      case 'worldInfoBefore':
        return '{{wiBefore}}';
      case 'worldInfoAfter':
        return '{{wiAfter}}';
      case 'enhanceDefinitions':
      case 'nsfw':
      case 'jailbreak':
        // ST sometimes leaves these empty (acting as switches); honour
        // literal content when present.
        return p?['content'] is String ? p!['content'] as String : '';
      default:
        if (p == null) {
          skipped.add('$id (unknown)');
          return '';
        }
        if (p['marker'] == true) {
          skipped.add('$id (unhandled marker)');
          return '';
        }
        final c = p['content'];
        return c is String ? c : '';
    }
  }

  final skipped = <String>[];
  String build(List<Map<String, dynamic>> items) {
    final parts = <String>[];
    for (final item in items) {
      final id = item['identifier'] as String;
      final text = renderIdentifier(id, skipped).trim();
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.join('\n\n');
  }

  final mainPrompt = build(before);
  final postHistory = build(after);

  // Pull sampling settings — ST uses snake_case + openai-prefix.
  double? readDouble(String key) {
    final v = map[key];
    return v is num ? v.toDouble() : null;
  }

  // Wave CY.18.43: type-safe extractors. Pre-Wave the import did `as
  // int?` and `as String?` casts directly on top-level fields. JSON
  // doesn't distinguish int from double (so `2048.0` lands as double
  // and a plain `as int` throws CastError), and a malformed preset
  // could put a number where a string belongs, killing the whole
  // import on a single bad field. These helpers coerce when safe and
  // return null otherwise, so a single garbage field can no longer
  // brick a perfectly valid preset.
  int? readInt(String key) {
    final v = map[key];
    if (v is int) return v;
    if (v is double) return v.toInt();
    return null;
  }

  String? readString(String key) {
    final v = map[key];
    return v is String ? v : null;
  }

  final preset = Preset(
    id: newId('preset'),
    name: '${readString('name') ?? 'SillyTavern preset'} (imported)',
    mainPrompt: mainPrompt,
    postHistoryInstructions: postHistory,
    impersonationPrompt: readString('impersonation_prompt'),
    continueNudgePrompt: readString('continue_nudge_prompt'),
    temperature: readDouble('temperature'),
    topP: readDouble('top_p'),
    // Wave CY.18.43: the existing `is int && > 0` guard already
    // tolerates a missing or non-int top_k. We keep the integrity
    // check (negative / zero → null) but route through readInt so a
    // double `top_k: 40.0` also parses cleanly.
    topK: () {
      final v = readInt('top_k');
      return (v != null && v > 0) ? v : null;
    }(),
    maxTokens: readInt('openai_max_tokens') ??
        readInt('max_tokens') ??
        readInt('max_length'),
    frequencyPenalty: readDouble('frequency_penalty'),
    presencePenalty: readDouble('presence_penalty'),
    minP: readDouble('min_p'),
    topA: readDouble('top_a'),
    repetitionPenalty: readDouble('repetition_penalty'),
    source: 'sillytavern',
  );

  final usedCount = before.length + after.length;
  return StImportResult(preset, usedCount, skipped);
}
