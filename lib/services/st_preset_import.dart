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
        // Pyre has no after-history lore slot, so `{{wiAfter}}` is a dead
        // token (always resolves to ''). Rather than emit a no-op the user is
        // promised will work, drop the marker entirely — all lorebook hits
        // inject before history via `{{wiBefore}}`. (datamodel-...-02)
        return '';
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

  // Pyre 1.1 (Prompt Manager): in ADDITION to the flatten above, preserve the
  // MODULAR structure as a list of toggleable PromptBlocks so the user can flip
  // individual modules on/off without editing text.
  //
  // We iterate the SAME `orderList` (the FIRST prompt_order entry — ST's global
  // default at character_id 100000/100001; per-character overrides come after,
  // and the flatten above already uses this entry, so blocks + mainPrompt stay
  // consistent) — or, when there's no prompt_order, the prompts[] insertion
  // order (orderList falls back to that above, all enabled). Structural markers
  // and empty-content prompts carry nothing to toggle, so they're skipped. The
  // result feeds preset.promptBlocks; if no authored content survives the list
  // stays empty and the preset behaves exactly like a flat one.
  final blocks = <PromptBlock>[];
  // Track the chatHistory-marker split exactly as the flat path does (line
  // 92-101): any block whose ORDER is AFTER the `chatHistory` marker is a
  // post-history block (jailbreak / final reminder / prefill), regardless of
  // `injection_position`. Without this the modular path put authored
  // post-history prompts into the SYSTEM prompt (real ST presets either omit
  // `injection_position` or set it to 0 on a post-history prompt — neither of
  // which is 1 — so the chatHistory split is the authoritative signal). See
  // audit finding import-2-01.
  var blockPastHistory = false;
  for (final item in orderList) {
    final id = item['identifier'] as String?;
    if (id == null) continue;
    if (id == 'chatHistory') {
      blockPastHistory = true;
      continue;
    }
    final p = promptsById[id];
    if (p == null) continue;
    // Structural placeholder (charDescription / ...) — no authored content to
    // toggle. (chatHistory is handled above so it still flips pastHistory.)
    if (p['marker'] == true) continue;
    final content = p['content'];
    if (content is! String || content.trim().isEmpty) continue;

    final name = (p['name'] is String && (p['name'] as String).isNotEmpty)
        ? p['name'] as String
        : id;
    final role = (p['role'] is String && (p['role'] as String).isNotEmpty)
        ? p['role'] as String
        : 'system';
    // Position = post-history if EITHER (a) the block sits after the
    // `chatHistory` marker in prompt_order (the dominant real-world signal,
    // matching the flat split), OR (b) ST flags it as in-chat injection
    // (`injection_position: 1` — rendered at depth as a reminder/jailbreak).
    final injectionPosition =
        item['injection_position'] ?? p['injection_position'];
    final position = (blockPastHistory || injectionPosition == 1)
        ? PromptBlockPosition.afterHistory
        : PromptBlockPosition.beforeHistory;
    // `enabled` from the order entry; default true (the prompts[] fallback path
    // sets it true above, and a malformed order entry should still show up).
    final enabled = item['enabled'] != false;

    blocks.add(PromptBlock(
      id: newId('block'),
      name: name,
      content: content,
      enabled: enabled,
      role: role,
      position: position,
    ));
  }

  // datamodel-...-03: `PromptBlock.role` round-trips on the model but assembly
  // flattens every enabled block into system / post-history TEXT — it does NOT
  // yet inject user/assistant-role blocks as separate chat turns. If any enabled
  // block carries a non-system role (e.g. an assistant prefill or a user-role
  // nudge), surface a one-line note in the import summary so the fidelity loss
  // isn't silent. (`role` is preserved, so a future role-as-turn assembly can
  // honour it without re-importing.)
  final rolefulCount = blocks
      .where((b) => b.enabled && b.role.toLowerCase() != 'system')
      .length;
  if (rolefulCount > 0) {
    skipped.add(
      '$rolefulCount block${rolefulCount == 1 ? "" : "s"} with a non-system '
      'role flattened to system text (role not honored yet)',
    );
  }

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
    // Pyre 1.1: the modular structure (empty when nothing authored survives →
    // flat behaviour). mainPrompt/postHistoryInstructions above stay populated
    // as a safe fallback for any direct reader.
    promptBlocks: blocks,
    source: 'sillytavern',
  );

  final usedCount = before.length + after.length;
  return StImportResult(preset, usedCount, skipped);
}
