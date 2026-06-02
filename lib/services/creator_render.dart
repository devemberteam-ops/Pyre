// Wave CY.18.226 (Creator Structured Build, Task 2): the deterministic
// renderer + its inverse. PURE Dart — NO Flutter imports — so it is
// unit-testable headless (mirrors creator_cascade.dart / creator_schema.dart).
//
// `renderCard` turns a semantic field map (filled by the structured-output
// pipeline, Task 6) into the chara_card_v2 canvas map. Pyre — not the LLM —
// owns format / spacing / label order / English, killing the spacing +
// completeness bugs of the old marker cascade by construction.
//
// `decomposeDescription` is the EXACT inverse of the Description assembly:
// it parses an existing card's Description back into the field map so edit
// mode can re-run a single batch and re-render without corrupting the rest.
//
// ── Field-map value shapes ──────────────────────────────────────────────────
// A field-map value is one of:
//   • String                       — a prose section / top-level field.
//   • List<Map>  or  List<String>  — nestedBullets children: each item is
//                                    {'label': sub, 'value': text} (the JSON
//                                    request shape), OR a verbatim `* Sub: …`
//                                    bullet string.
//   • String (verbatim block)      — nestedBullets children may ALSO arrive as
//                                    the raw multi-line `  * Sub: …` block
//                                    (this is how `decomposeDescription`
//                                    stores them → a faithful round-trip).
//   • List<String> / String        — tags (list or comma-joined).
//   • List (maps/strings)          — dialogueExamples.
//
// `decomposeDescription` returns Map<String,String>: nestedBullets parents map
// to their verbatim children block, every other label to its verbatim value.
// Foreign top-level labels (non-Pyre cards) are tolerated — keyed by their
// literal label text and re-emitted after the known schema sections.

import 'creator_cascade.dart' show parseDescriptionSections;
import 'creator_schema.dart';

// ── Public API ───────────────────────────────────────────────────────────

/// Render a semantic [fields] map (per [mode]) into the chara_card_v2 canvas
/// map: `name`, `description`, `first_mes`, `mes_example`, `tags`,
/// `creator_notes`, `tagline`, and (scenario) `post_history_instructions`.
///
/// The DESCRIPTION assembly is the core:
///  - character / persona → labeled Description (each top-level label on its
///    own line, exactly ONE blank line between top-level topics, nested
///    bullets TIGHT under their parent).
///  - scenario → balanced `<Tag>…</Tag>` XML.
///  - a label whose value is empty is SKIPPED entirely (no `Label: —`).
Map<String, dynamic> renderCard(Map<String, dynamic> fields, CreatorMode mode) {
  final out = <String, dynamic>{};

  // Description.
  if (mode == CreatorMode.scenario) {
    out['description'] = _renderScenarioDescription(fields, mode);
  } else {
    out['description'] = _renderLabeledDescription(fields, mode);
  }

  // name = the Full Name (or, for scenario, left to the caller — scenarios
  // title themselves separately; we surface it only if present in fields).
  final fullName = _asString(fields['fullName']).trim();
  if (fullName.isNotEmpty) {
    out['name'] = _clampName(fullName);
  }
  final scenarioName = _asString(fields['name']).trim();
  if (scenarioName.isNotEmpty) out['name'] = scenarioName;

  // Top-level passthrough fields (skip empties).
  for (final f in schemaFor(mode)) {
    switch (f.kind) {
      case CardFieldKind.topLevel:
        final v = _asString(fields[f.key]).trim();
        if (v.isNotEmpty) out[f.key] = v;
        break;
      case CardFieldKind.tags:
        final tags = _asTags(fields[f.key]);
        if (tags.isNotEmpty) out[f.key] = tags;
        break;
      case CardFieldKind.dialogueExamples:
        final raw = fields[f.key];
        final mes = raw is List
            ? renderMesExample(raw)
            : _asString(raw).trim();
        if (mes.isNotEmpty) out['mes_example'] = mes;
        break;
      case CardFieldKind.prose:
      case CardFieldKind.nestedBullets:
      case CardFieldKind.bulletList:
        break; // already folded into the Description
    }
  }

  return out;
}

/// Inverse of [renderCard]'s Description assembly: parse a Description
/// [description] string (for [mode]) back into the field map.
///
/// char/persona: split on the schema's top-level labels (+ nested `  * Sub:`
/// children, kept as the verbatim block under the parent key). `Alternative
/// Clothing:` is treated as a FLAT label, never a child of Clothing. Foreign
/// (non-schema) top-level labels are tolerated, keyed by their literal label.
/// A label line only opens a new section when it is the first line or follows a
/// blank line (the renderer's blank-line-between-topics invariant), so a
/// label-like line embedded inside a prose value is not mis-split.
///
/// scenario: each `<Tag>…</Tag>` section → its field key; a duplicate tag gets
/// a `#N` suffix on the key so order + duplicates round-trip faithfully (the
/// renderer strips the suffix).
Map<String, String> decomposeDescription(
    String description, CreatorMode mode) {
  if (mode == CreatorMode.scenario) {
    return _decomposeScenario(description);
  }
  return _decomposeLabeled(description, mode);
}

/// Build the `mes_example` string from a [dialogueExamples] list: `<START>`
/// separated exchanges, each with `*action/expression*` italics interlaced
/// with `**dialogue**` bold. List items may be maps (`{action, dialogue,
/// beat}` or `{user, char}` line maps) OR pre-formatted strings.
String renderMesExample(List dialogueExamples) {
  final blocks = <String>[];
  for (final item in dialogueExamples) {
    final block = _renderExchange(item);
    if (block.trim().isNotEmpty) blocks.add(block.trim());
  }
  if (blocks.isEmpty) return '';
  // Each exchange under its own <START> marker.
  return blocks.map((b) => '<START>\n$b').join('\n');
}

/// Required schema-field keys (per [mode]) whose value is empty after fill —
/// a soft, informational note (spec §C), never a retry gate.
List<String> missingRequired(Map<String, dynamic> fields, CreatorMode mode) {
  final missing = <String>[];
  for (final key in requiredKeysFor(mode)) {
    if (_isEmptyValue(fields[key])) missing.add(key);
  }
  return missing;
}

// ── Labeled (character / persona) render ──────────────────────────────────

String _renderLabeledDescription(
    Map<String, dynamic> fields, CreatorMode mode) {
  final topics = <String>[];
  final emittedKeys = <String>{};

  for (final f in schemaFor(mode)) {
    // Only Description sections (prose / nestedBullets / bulletList) belong in
    // the body.
    if (f.kind != CardFieldKind.prose &&
        f.kind != CardFieldKind.nestedBullets &&
        f.kind != CardFieldKind.bulletList) {
      continue;
    }
    emittedKeys.add(f.key);
    final block = _renderLabeledField(f, fields[f.key]);
    if (block != null && block.trim().isNotEmpty) topics.add(block);
  }

  // Preserve any tolerated FOREIGN top-level labels (non-schema) at the end,
  // so a round-trip of a non-Pyre card doesn't drop them. They were keyed by
  // their literal label text by `decomposeDescription`.
  for (final entry in fields.entries) {
    final key = entry.key;
    if (emittedKeys.contains(key)) continue;
    if (!_looksForeignLabel(key)) continue;
    final value = _asString(entry.value).trim();
    if (value.isEmpty) continue;
    topics.add('$key: ${_asString(entry.value)}'.trimRight());
  }

  // Exactly one blank line between top-level topics.
  return topics.join('\n\n');
}

/// Render one labeled field (prose / nestedBullets / bulletList). Returns null
/// when empty.
String? _renderLabeledField(CardField f, dynamic value) {
  if (f.kind == CardFieldKind.nestedBullets) {
    final childBlock = _renderChildren(f, value);
    if (childBlock.trim().isEmpty) return null;
    // A childless nestedBullets parent (e.g. Inner Circle) whose value is a
    // SINGLE non-bullet prose line renders INLINE (`Label: prose`) — matching
    // a card that stated it as one sentence (e.g. Vesna). Anything with a
    // bullet, or more than one line, renders as a `Label:\n<bullets>` block.
    final blockLines = childBlock.split('\n');
    final isSingleProse = blockLines.length == 1 &&
        !RegExp(r'^\s*[*\-•]').hasMatch(blockLines.first);
    if (isSingleProse) return '${f.label}: ${blockLines.first.trim()}';
    return '${f.label}:\n$childBlock';
  }
  if (f.kind == CardFieldKind.bulletList) {
    final block = _renderBulletList(value);
    if (block.trim().isEmpty) return null;
    // A single, non-bullet prose line renders INLINE (`Label: prose`) — this is
    // how a legacy card (e.g. Ren / Vesna's Core Traits) that stated the field
    // as one sentence round-trips unchanged. A real list (or any bullet / any
    // multi-line value) renders as a `Label:\n  * item` block.
    final lines = block.split('\n');
    final isSingleProse =
        lines.length == 1 && !RegExp(r'^\s*[*\-•]').hasMatch(lines.first);
    if (isSingleProse) return '${f.label}: ${lines.first.trim()}';
    return '${f.label}:\n$block';
  }
  // prose
  final text = _asString(value).trimRight();
  if (text.trim().isEmpty) return null;
  // A value that begins on the next line (e.g. an Inner Circle whose body is a
  // bullet list) is emitted as `Label:\n<value>`; an inline value as
  // `Label: <value>`.
  if (text.startsWith('\n')) return '${f.label}:$text';
  return '${f.label}: $text';
}

/// Render the tight `  * Sub: …` children block for a nestedBullets parent.
/// Accepts:
///  - a verbatim String block (already `  * Sub: …` lines) → emitted as-is
///    (trimmed of surrounding blank lines) for a faithful round-trip;
///  - a List of {'label','value'} maps or `* Sub: …` strings;
///  - a bare Map of arbitrary `SubLabel: value` keys (the variable-nestedBullets
///    object shape — Likes & Dislikes, Behavioral Modes, Fetishes & Kinks, …);
///    each key/value becomes one `  * SubLabel: value` bullet, in insertion
///    order.
String _renderChildren(CardField parent, dynamic value) {
  if (value is String) {
    // Verbatim children block from decomposeDescription — re-emit each
    // non-empty line, normalising the bullet prefix to `  * `.
    final lines = <String>[];
    for (final raw in value.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      lines.add(_normaliseBullet(line));
    }
    return lines.join('\n');
  }
  if (value is Map) {
    // A bare {SubLabel: value} object (variable nestedBullets). Skip a `label`/
    // `value` pair that is really a SINGLE {'label','value'} item misplaced as
    // a bare map (defer to the List path's shape) — but in practice a parent
    // value that is a Map is the object form, so render each entry as a bullet.
    final lines = <String>[];
    value.forEach((k, v) {
      final label = _asString(k).trim();
      final text = _asString(v).trim();
      if (label.isEmpty && text.isEmpty) return;
      if (text.isEmpty) {
        lines.add('  * $label:');
      } else if (label.isEmpty) {
        lines.add('  * $text');
      } else {
        lines.add('  * $label: $text');
      }
    });
    return lines.join('\n');
  }
  if (value is List) {
    final lines = <String>[];
    for (final item in value) {
      if (item is Map) {
        final label = _asString(item['label'] ?? item['name']).trim();
        final text = _asString(item['value'] ?? item['text']).trim();
        if (label.isEmpty && text.isEmpty) continue;
        if (text.isEmpty) {
          lines.add('  * $label:');
        } else if (label.isEmpty) {
          lines.add('  * $text');
        } else {
          lines.add('  * $label: $text');
        }
      } else {
        final s = _asString(item).trim();
        if (s.isNotEmpty) lines.add(_normaliseBullet(s));
      }
    }
    return lines.join('\n');
  }
  return '';
}

/// Render a flat [CardFieldKind.bulletList] value as tight `  * item` lines.
/// Accepts:
///  - a List of short strings (the JSON request shape / preferred) → one
///    `  * item` bullet per element;
///  - a String that is EITHER a verbatim `  * item` block (from
///    `decomposeDescription`, re-emitted via `_normaliseBullet`) OR a single
///    prose line that legacy cards stored inline (returned as-is so
///    `_renderLabeledField` can keep it inline). A multi-line String is split
///    per line and each line bulleted.
String _renderBulletList(dynamic value) {
  if (value is List) {
    final lines = <String>[];
    for (final item in value) {
      // A list of {label,value}-style maps is tolerated (flatten to text).
      final s = item is Map
          ? _flattenMapItem(item)
          : _asString(item).trim();
      if (s.isEmpty) continue;
      lines.add('  * ${_stripBulletPrefix(s)}');
    }
    return lines.join('\n');
  }
  if (value is String) {
    final raw = value;
    // A single non-bullet line → keep verbatim so it renders inline.
    final split = raw.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (split.length == 1 && !RegExp(r'^\s*[*\-•]').hasMatch(split.first)) {
      return split.first.trim();
    }
    final lines = <String>[];
    for (final l in split) {
      lines.add(_normaliseBullet(l.trimRight()));
    }
    return lines.join('\n');
  }
  return '';
}

/// Flatten a stray `{label,value}` map item that arrived in a bulletList into a
/// single string (the model occasionally returns objects where strings were
/// asked for) — `label: value`, or whichever half is present.
String _flattenMapItem(Map item) {
  final label = _asString(item['label'] ?? item['name']).trim();
  final text = _asString(item['value'] ?? item['text']).trim();
  if (label.isNotEmpty && text.isNotEmpty) return '$label: $text';
  if (text.isNotEmpty) return text;
  return label;
}

/// Strip a leading `*`/`-`/`•` bullet marker (and following whitespace) from a
/// string, leaving just the item text.
String _stripBulletPrefix(String s) {
  final trimmed = s.trimLeft();
  final m = RegExp(r'^([*\-•])\s*').firstMatch(trimmed);
  if (m == null) return trimmed;
  return trimmed.substring(m.end);
}

/// Normalise a child line to the canonical `  * ` bullet prefix WHEN it is a
/// bullet. A line that is NOT a bullet (no leading `*`/`-`/`•` marker) is a
/// free-standing prose line — e.g. the trailing "Beyond these four, almost no
/// one…" summary under Ren's Inner Circle — and is preserved verbatim so a
/// nestedBullets block with a trailing prose tail round-trips faithfully.
String _normaliseBullet(String line) {
  final trimmed = line.trimLeft();
  final m = RegExp(r'^([*\-•])\s*').firstMatch(trimmed);
  if (m == null) return trimmed; // free-standing prose line — keep as-is
  return '  * ${trimmed.substring(m.end)}';
}

// ── Labeled (character / persona) decompose ───────────────────────────────

Map<String, String> _decomposeLabeled(String text, CreatorMode mode) {
  final schema = schemaFor(mode)
      .where((f) =>
          f.kind == CardFieldKind.prose ||
          f.kind == CardFieldKind.nestedBullets ||
          f.kind == CardFieldKind.bulletList)
      .toList();
  // Map label → field key, AND track which keys are nestedBullets parents.
  // bulletList fields are NOT nested parents: their `  * item` body is captured
  // verbatim by the flat path (no `Sub: value` decomposition), and the renderer
  // re-bullets it identically — so a decompose→render round-trip is stable.
  final labelToKey = <String, String>{};
  final nestedParents = <String>{};
  for (final f in schema) {
    labelToKey[f.label] = f.key;
    if (f.kind == CardFieldKind.nestedBullets) nestedParents.add(f.key);
  }

  // Find every TOP-LEVEL label line (start of line, NOT a `  * ` child) whose
  // leading text matches a known label. We also capture foreign top-level
  // labels (any `^Label:` line that isn't a child bullet) so nothing is lost.
  final lines = text.split('\n');
  // positions: list of (startLineIndex, key, isForeign)
  final marks = <_LabelMark>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.startsWith(' ') || line.startsWith('\t')) continue; // child
    // Respect the renderer's blank-line-between-topics invariant (I1): a
    // top-level label only opens a NEW section when it is the FIRST line OR the
    // PREVIOUS line is blank. This stops a label-like line embedded inside a
    // prose value (e.g. a "Note: …" sentence mid-paragraph, or a colon line in
    // Background) from being mis-split into its own section.
    if (i > 0 && lines[i - 1].trim().isNotEmpty) continue;
    final m = _kTopLabelRe.firstMatch(line);
    if (m == null) continue;
    final rawLabel = m.group(1)!.trim();
    final key = labelToKey[rawLabel];
    if (key != null) {
      marks.add(_LabelMark(i, key, foreign: false, isNested: nestedParents.contains(key)));
    } else {
      // Foreign top-level label — preserve under its literal label text.
      marks.add(_LabelMark(i, rawLabel, foreign: true, isNested: false));
    }
  }

  final out = <String, String>{};
  for (var mi = 0; mi < marks.length; mi++) {
    final mark = marks[mi];
    final startLine = mark.lineIndex;
    final endLine =
        mi + 1 < marks.length ? marks[mi + 1].lineIndex : lines.length;
    final segment = lines.sublist(startLine, endLine);

    if (mark.isNested) {
      // Parent label line is segment[0] ("Detailed Features:" / "Inner
      // Circle:"); the rest are the verbatim children bullet lines. A
      // childless nestedBullets parent (e.g. Inner Circle) MAY instead carry
      // its value inline on the parent line itself ("Inner Circle: No one,
      // currently…") — capture that inline body as the first block line so it
      // is never lost, and the renderer reproduces it inline.
      final first = segment.first;
      final colon = first.indexOf(':');
      var inline = colon >= 0 ? first.substring(colon + 1) : '';
      if (inline.startsWith(' ')) inline = inline.substring(1);
      final blockLines = <String>[];
      if (inline.trim().isNotEmpty) blockLines.add(inline.trimRight());
      for (final l in segment.sublist(1)) {
        final line = l.trimRight();
        if (line.trim().isEmpty) continue;
        blockLines.add(line);
      }
      out[mark.key] = blockLines.join('\n');
    } else {
      // Flat prose (or foreign): drop the label header, keep the value
      // VERBATIM after the colon. Preserve whether it's inline (`Label: x`)
      // or on following lines (`Label:\n  * …`, e.g. Ren's Inner Circle) so
      // the round-trip is faithful — consume only the single space that
      // follows the colon on an inline value.
      final first = segment.first;
      final colon = first.indexOf(':');
      var firstBody = colon >= 0 ? first.substring(colon + 1) : '';
      // Strip the one separating space after the colon on an inline value;
      // leave a newline-led (next-line) value untouched.
      if (firstBody.startsWith(' ')) firstBody = firstBody.substring(1);
      final rest = segment.sublist(1).map((l) => l.trimRight()).toList();
      final inlineEmpty = firstBody.trim().isEmpty;
      String body;
      if (rest.isEmpty) {
        body = firstBody.trimRight();
      } else if (inlineEmpty) {
        // Original was `Label:\n<body>` — preserve the leading newline so the
        // re-render reproduces it (e.g. Ren's Inner Circle bullet list).
        body = '\n${rest.join('\n')}';
      } else {
        body = [firstBody.trimRight(), ...rest].join('\n');
      }
      // Trim trailing blank lines; keep a leading newline (next-line value).
      out[mark.key] = body.replaceFirst(RegExp(r'\s+$'), '');
    }
  }
  return out;
}

/// A top-level label line: `Label: …` at the very start of a line (NOT a
/// `  * ` child). The label is plain text up to the first colon, allowing
/// spaces, `&`, `/`, `,`, and `'` (covers `Apparent Age, Height & Weight`,
/// `Language / Writing Style / Spelling`, etc.). Markdown-bold is tolerated.
final RegExp _kTopLabelRe =
    RegExp(r"^\**\s*([A-Za-z][A-Za-z0-9 ,&/'’()\-]*?)\**\s*:");

// ── Scenario render / decompose ───────────────────────────────────────────

/// Render the scenario Description as balanced `<Tag>\n<body>\n</Tag>` blocks
/// joined by a blank line, matching the on-disk bundled-card format.
String _renderScenarioDescription(
    Map<String, dynamic> fields, CreatorMode mode) {
  // Field key → tag label.
  final keyToLabel = <String, String>{};
  for (final f in schemaFor(mode)) {
    if (f.kind == CardFieldKind.prose) keyToLabel[f.key] = f.label;
  }

  final sections = <String>[];
  final emitted = <String>{};

  // Seed `emitted` with EVERY schema field key (not just prose), so the
  // foreign-tag fallback below can never re-emit a known non-prose schema field
  // (name, first_mes, tags, dialogueExamples, post_history_instructions,
  // creator_notes, tagline) as a stray `<key>…</key>` block. The prose-emission
  // loop below emits unconditionally (it does NOT gate on `emitted`), so this
  // pre-seed does not suppress the real `<World>` / `<NPCs>` / etc. sections.
  for (final f in schemaFor(mode)) {
    emitted.add(f.key);
  }

  // Emit known scenario sections in schema order, expanding `#N` duplicate
  // suffixes back into repeated tags at the right slot.
  for (final f in schemaFor(mode)) {
    if (f.kind != CardFieldKind.prose) continue;
    emitted.add(f.key);
    // Base key, then any `key#2`, `key#3`, … in order.
    final variants = <String>[f.key];
    var n = 2;
    while (fields.containsKey('${f.key}#$n')) {
      variants.add('${f.key}#$n');
      n++;
    }
    for (final vk in variants) {
      emitted.add(vk);
      final body = _asString(fields[vk]).trim();
      if (body.isEmpty) continue;
      sections.add('<${f.label}>\n$body\n</${f.label}>');
    }
  }

  // Tolerate foreign `<Tag>` sections (keys not in the scenario schema) — emit
  // them at the end so a non-Pyre scenario round-trips.
  for (final entry in fields.entries) {
    final key = entry.key;
    if (emitted.contains(key)) continue;
    if (!_looksForeignLabel(key)) continue;
    final tag = key.replaceFirst(RegExp(r'#\d+$'), '');
    final body = _asString(entry.value).trim();
    if (body.isEmpty) continue;
    sections.add('<$tag>\n$body\n</$tag>');
  }

  return sections.join('\n\n');
}

Map<String, String> _decomposeScenario(String description) {
  final labelToKey = <String, String>{};
  for (final f in schemaFor(CreatorMode.scenario)) {
    if (f.kind == CardFieldKind.prose) labelToKey[f.label] = f.key;
  }

  final out = <String, String>{};
  final seen = <String, int>{}; // base key → count emitted so far
  for (final section in parseDescriptionSections(description)) {
    if (section.tag.isEmpty) continue; // drop untagged prose gaps
    final baseKey = labelToKey[section.tag] ?? section.tag; // foreign → label
    final count = (seen[baseKey] ?? 0) + 1;
    seen[baseKey] = count;
    final key = count == 1 ? baseKey : '$baseKey#$count';
    out[key] = section.value;
  }
  return out;
}

// ── mes_example exchange rendering ────────────────────────────────────────

String _renderExchange(dynamic item) {
  if (item is String) {
    // Pre-formatted — pass through, dropping any leading <START>.
    return item.replaceFirst(RegExp(r'^\s*<START>\s*\n?'), '').trim();
  }
  if (item is Map) {
    // Shape A: {action, dialogue, beat} → one interlaced {{char}} line.
    final action = _asString(item['action'] ?? item['expression']).trim();
    final dialogue = _asString(item['dialogue'] ?? item['speech']).trim();
    if (action.isNotEmpty || dialogue.isNotEmpty) {
      final parts = <String>[];
      if (action.isNotEmpty) parts.add('*${_strip(action, '*')}*');
      if (dialogue.isNotEmpty) parts.add('**${_strip(dialogue, '*')}**');
      final speaker = _asString(item['speaker']).trim();
      final prefix = speaker.isNotEmpty
          ? '$speaker: '
          : (item.containsKey('user') ? '{{user}}: ' : '{{char}}: ');
      return '$prefix${parts.join(' ')}';
    }
    // Shape B: {user, char} line pair.
    final user = _asString(item['user']).trim();
    final char = _asString(item['char']).trim();
    final lines = <String>[];
    if (user.isNotEmpty) lines.add('{{user}}: $user');
    if (char.isNotEmpty) lines.add('{{char}}: $char');
    return lines.join('\n');
  }
  return '';
}

/// Strip a wrapping markdown marker [marker] from [s] if present at both ends
/// (so we don't double `**bold**` an already-bolded value).
String _strip(String s, String marker) {
  var out = s.trim();
  final m2 = marker + marker; // `**`
  if (out.startsWith(m2) && out.endsWith(m2) && out.length > m2.length * 2) {
    out = out.substring(m2.length, out.length - m2.length);
  } else if (out.startsWith(marker) &&
      out.endsWith(marker) &&
      out.length > marker.length * 2) {
    out = out.substring(marker.length, out.length - marker.length);
  }
  return out.trim();
}

/// Clamp a possibly-descriptive [fullName] down to JUST the display name.
/// The model sometimes packs aliases / "goes by" / a whole sentence into Full
/// Name; the canvas `name` must stay short. Take the first line, then cut at
/// the FIRST of these delimiters — whichever appears earliest:
///   ` — ` (space-emdash-space), ` – ` (space-en-dash-space), `;`, `.`, ` (`.
/// A normal name with no delimiter is returned unchanged.
String _clampName(String fullName) {
  var s = fullName.split('\n').first;
  var cut = s.length;
  for (final delim in const [' — ', ' – ', ';', '.', ' (']) {
    final i = s.indexOf(delim);
    if (i >= 0 && i < cut) cut = i;
  }
  return s.substring(0, cut).trim();
}

// ── small value coercers ──────────────────────────────────────────────────

String _asString(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is List) return v.join(', ');
  return v.toString();
}

List<String> _asTags(dynamic v) {
  if (v == null) return const [];
  if (v is List) {
    return v
        .map((e) => _asString(e).trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  if (v is String) {
    return v
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return const [];
}

bool _isEmptyValue(dynamic v) {
  if (v == null) return true;
  if (v is String) return v.trim().isEmpty;
  if (v is List) return v.isEmpty;
  if (v is Map) return v.isEmpty;
  return false;
}

/// A key that looks like a human-readable foreign label (contains a space or
/// uppercase word) rather than a camelCase schema key — so we only re-emit
/// genuinely foreign labels, never accidental stray keys.
bool _looksForeignLabel(String key) {
  if (key.isEmpty) return false;
  // schema keys are camelCase / snake-ish with no spaces; a foreign label has
  // a space or starts uppercase (e.g. "Quirk", "Theme Song").
  return key.contains(' ') ||
      (key[0].toUpperCase() == key[0] && key[0].toLowerCase() != key[0]);
}

class _LabelMark {
  _LabelMark(this.lineIndex, this.key,
      {required this.foreign, required this.isNested});
  final int lineIndex;
  final String key;
  final bool foreign;
  final bool isNested;
}
