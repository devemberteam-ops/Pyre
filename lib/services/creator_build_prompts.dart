// Wave CY.18.225 (Creator Structured Build, Task 5): the PURE module that
// builds the LLM turns requesting each batch of card fields as a single
// structured JSON object — replacing the deleted `<<SHEET>>` marker protocol
// and the fragile self-healing cascade (which failed on DeepSeek).
//
// The model now returns STRUCTURED JSON (one object per batch of fields) and
// Pyre renders the card deterministically (creator_render.dart, Task 2). This
// file owns the *request* side: it composes a concise, provider-neutral
// system turn (role + the carried-forward quality rules), the Phase-1 Creator
// transcript as context, and a final user turn that names the EXACT batch
// fields with their labels + guidance + JSON shape and ends with a hard
// "ONE JSON object, English values, no fence" output contract.
//
// PURE Dart, no Flutter UI: it imports ONLY `creator_schema.dart` (the field
// schema + batch groupings) and `chat_api.dart` (the `ChatTurn` value type;
// `ChatRole` is a plain `String` typedef there). This mirrors the pure-fn,
// harness-usable style of `creator_schema.dart` / `chat_prompt_builder.dart`.
//
// Code-owned — these prompts are NOT preset-forkable. The user-facing Creator
// chat (architect) is where personality/voice lives; this is the deterministic
// extraction stage that runs after, and its contract must stay stable.

import 'chat_api.dart' show ChatTurn;
import 'creator_schema.dart';

// ── The carried-forward quality rules (from the architect prompts) ────────
//
// Phrased cleanly + provider-neutral (DeepSeek is the target). NO mention of
// `<<SHEET>>`, blocks, or markers — that machinery is being deleted.
const String _kQualityRules = '''
QUALITY RULES (apply to every value you write):
- English only: every value MUST be written in English, regardless of the language used in the conversation above.
- Invent confidently: fill anything not explicitly discussed with specific, plausible detail, to a rich depth. Never leave a field thin, vague, or hedged.
- Anti-seed-collapse: do NOT just echo or lightly expand the user's seed idea. The original seed should be at most ~30% of the result — build a fuller, fleshed-out character around it.
- Stated traits must manifest: if the character is described as (e.g.) half-Japanese/half-Irish, shy, or a NEET, those facts must concretely show up in the relevant fields — not merely asserted once.
- Frank and adult where the card calls for it: intimate, anatomical, and kink fields must be explicit and specific (this app is adult-friendly), never euphemistic or coy — when the batch contains such fields.
- Named inner circle: relationship fields name real people with names, ages, and the bond — never "his mother" or "a friend" placeholders.
- No meta: no author notes, no "as an AI", no fourth-wall breaks, no "this character is designed to…". Stay fully in-world.''';

const String _kSystemPreamble =
    'You are building one section of a character card. Return ONLY a single JSON object.';

// ── Brevity directive (CHARACTER + PERSONA only) ──────────────────────────
//
// The schema has ~50 description fields and the model writes a full paragraph
// per field with no length discipline — a single Description ballooned to
// ~14k tokens (3x a good card). This standing rule trims each field and forbids
// cross-field restatement, aiming the WHOLE assembled Description at a chosen
// token budget (declared target; reasoning models overshoot ~20%, so a stated
// ~5k lands a real ~6k). It is a SOFT aim (no padding, no mid-thought
// truncation) and applies ONLY to the Description sheet fields — never to
// first_mes, the dialogue examples / mes_example, creator_notes, the tagline,
// or post_history_instructions, which are written at their natural length.
//
// Wave CY.18.265: the budget is now USER-CHOSEN via `CreatorDescriptionSize`
// (Creator → Generation settings). `standard` reproduces the original ~5,000
// directive byte-for-byte, so untouched setups behave exactly as before.
String _brevityDirectiveFor(CreatorDescriptionSize size) {
  final (String tok, String opener, String fieldPhrase) = switch (size) {
    CreatorDescriptionSize.concise => (
        '2,500',
        'keep the Description tight',
        'tight — typically 1-2 sentences, a short paragraph at most',
      ),
    CreatorDescriptionSize.standard => (
        '5,000',
        'keep the Description tight',
        'tight — typically 1-3 sentences, a short paragraph at most',
      ),
    CreatorDescriptionSize.detailed => (
        '8,000',
        'give the Description room without bloat',
        'at a comfortable length — typically 2-4 sentences, a paragraph where '
            'the section earns it',
      ),
    CreatorDescriptionSize.veryDetailed => (
        '12,000',
        'let the Description run long, but never padded',
        'with room to breathe — typically a full paragraph, sometimes two where '
            'the section genuinely calls for it',
      ),
  };
  return 'LENGTH DISCIPLINE — $opener. Across all of its sheet '
      'sections combined, aim for roughly ~$tok tokens total. This is an '
      'APPROXIMATE target, NOT a hard limit: do NOT pad to reach it, and do NOT '
      'truncate a thought mid-sentence just to hit a number. To get there, write '
      'each sheet field $fieldPhrase — favouring concrete, specific detail over '
      'verbose or purple prose, '
      'and NEVER restate what another field already covers (the sections overlap '
      'a lot — e.g. Voice / Response Pattern / Language Style; Relational '
      'Dynamics / Inner Circle / Possessiveness; Intimate Experience / Horniness '
      '/ Fetishes). Quality and completeness stay; only padding goes. This '
      'budget applies ONLY to the Description sheet fields — it does NOT apply '
      'to first_mes, the dialogue examples / mes_example, creator_notes, the '
      'tagline, or post_history_instructions; write those at their natural '
      'length and do NOT count them toward the ~$tok.';
}

// ── Public API ────────────────────────────────────────────────────────────

/// Build the turns that request ONE batch of card fields from the model as a
/// single JSON object. The Phase-1 [transcript] (the Creator conversation that
/// defined the character) is included as context; the final user turn lists the
/// EXACT [batchKeys] for this batch with their labels + guidance + JSON shape,
/// and demands rich English prose values + a bare JSON object (no fence, no
/// prose). Code-owned — NOT preset-forkable.
///
/// EDIT MODE: when [existingFields] is non-null AND non-empty, the final user
/// turn ALSO carries an edit framing — the current value of each batch key that
/// exists in [existingFields], plus an instruction to apply ONLY the change(s)
/// the user asked for and return every other field UNCHANGED (verbatim). When
/// [existingFields] is null (create mode), the output is byte-identical to
/// before.
List<ChatTurn> buildBatchTurns({
  required CreatorMode mode,
  required List<String> batchKeys,
  required List<ChatTurn> transcript,
  Map<String, dynamic>? existingFields, // edit mode ("change only what's asked")
  Map<String, dynamic>? priorFields, // create-consistency (facts decided so far)
  // Wave CY.18.265: desired size of the assembled Description (char + persona
  // only). Defaults to `standard` so existing callers / tests stay byte-identical.
  CreatorDescriptionSize descriptionSize = CreatorDescriptionSize.standard,
}) {
  final schema = schemaFor(mode);

  final turns = <ChatTurn>[
    ChatTurn('system', '$_kSystemPreamble\n\n$_kQualityRules'),
  ];

  // Carry the Phase-1 conversation as context so the model knows who we are
  // building. Drop any prior SYSTEM turns from the transcript: they would
  // conflict with our extraction instructions. Non-empty user/assistant only.
  for (final t in transcript) {
    if (t.role == 'system') continue;
    if (t.content.trim().isEmpty) continue;
    final role = t.role == 'assistant' ? 'assistant' : 'user';
    turns.add(ChatTurn(role, t.content));
  }

  turns.add(ChatTurn(
      'user',
      _buildBatchRequest(mode, schema, batchKeys, existingFields, priorFields,
          descriptionSize)));
  return turns;
}

/// Build the turns for a bounded JSON-continuation retry when a batch response
/// was truncated (unterminated JSON). [priorTurns] is what produced the partial;
/// [partial] is the truncated JSON text. Appends [partial] as an assistant turn +
/// a user turn telling the model to continue the JSON object from exactly where
/// it stopped — no repeats, no preamble, no markdown fence.
List<ChatTurn> buildContinuationTurns({
  required List<ChatTurn> priorTurns,
  required String partial,
}) {
  return <ChatTurn>[
    ...priorTurns,
    ChatTurn('assistant', partial),
    ChatTurn(
      'user',
      'Continue the JSON object from exactly where you stopped. Do not '
          'repeat anything already emitted, no preamble, no markdown fence.',
    ),
  ];
}

// ── Internals ───────────────────────────────────────────────────────────

/// Compose the final user turn: the per-field request lines + the hard output
/// contract. Each key is resolved against [schema] (top-level AND nested
/// children) so its label/guidance/kind shape the line. When [existingFields]
/// is non-null AND non-empty, an EDIT framing block (current values + an
/// apply-only-the-asked-change / keep-the-rest-verbatim instruction) is
/// inserted before the output contract.
String _buildBatchRequest(
    CreatorMode mode, List<CardField> schema, List<String> batchKeys,
    [Map<String, dynamic>? existingFields,
    Map<String, dynamic>? priorFields,
    CreatorDescriptionSize descriptionSize = CreatorDescriptionSize.standard]) {
  final buf = StringBuffer();

  // FIX D — FULL SHEET MAP: every batch is otherwise blind to the others, so
  // the model crams several fields' worth of content into early fields and
  // duplicates across passes. Show the WHOLE sheet's section list (in order),
  // mark which sections this pass fills, and forbid cramming / repeating.
  final allLabels = <String>[];
  for (final f in schema) {
    if (f.kind == CardFieldKind.prose ||
        f.kind == CardFieldKind.nestedBullets ||
        f.kind == CardFieldKind.bulletList ||
        f.kind == CardFieldKind.topLevel ||
        f.kind == CardFieldKind.tags ||
        f.kind == CardFieldKind.dialogueExamples) {
      allLabels.add(f.label);
    }
  }
  final thisLabels = <String>[];
  for (final key in batchKeys) {
    thisLabels.add(_findField(schema, key)?.label ?? key);
  }
  buf.writeln(
      'The full character sheet has these sections (filled across several '
      'passes): ${allLabels.join(', ')}.');
  buf.writeln(
      'RIGHT NOW you are filling ONLY: ${thisLabels.join(', ')}. The other '
      'sections WILL be filled separately — so keep each field strictly scoped '
      'to itself: do NOT cram another field\'s content here, and do NOT repeat '
      'what belongs in another section.');

  // BREVITY — CHARACTER + PERSONA only (the Description fields fold into one
  // `description`; scenario assembles differently and is left untouched).
  if (mode == CreatorMode.character || mode == CreatorMode.persona) {
    buf.writeln();
    buf.writeln(_brevityDirectiveFor(descriptionSize));
  }
  buf.writeln();

  buf.writeln(
      'Fill EXACTLY the following fields for the character defined above. '
      'For each field, write a rich, specific English value following the '
      'quality rules.');
  buf.writeln();

  for (final key in batchKeys) {
    final field = _findField(schema, key);
    final label = field?.label ?? key;
    final guidance = field?.guidance ?? '';
    final guidanceSuffix = guidance.isEmpty ? '' : ' $guidance';
    buf.writeln('"$key" — $label:$guidanceSuffix');
    buf.writeln('   JSON shape: ${_shapeHint(field)}');
  }

  // FIX G — CONTINUITY (create-consistency): the facts decided in earlier
  // passes. Distinct from the EDIT block below: these aren't "current values
  // to preserve verbatim", they are established truths this pass must NOT
  // contradict (don't rename, don't change established ages/appearance/etc.).
  if (priorFields != null && priorFields.isNotEmpty) {
    final lines = <String>[];
    for (final entry in priorFields.entries) {
      if (batchKeys.contains(entry.key)) continue; // it's being filled now
      final value = _stringifyExisting(entry.value);
      if (value.trim().isEmpty) continue;
      final label = _findField(schema, entry.key)?.label ?? entry.key;
      lines.add('$label: $value');
    }
    if (lines.isNotEmpty) {
      buf.writeln();
      buf.writeln(
          'CONTINUITY — these facts are already decided for this character; '
          'stay consistent and do NOT contradict them (don\'t rename, don\'t '
          'change established ages/appearance/tattoos/etc.):');
      for (final line in lines) {
        buf.writeln(line);
      }
    }
  }

  // EDIT MODE: list the current value of each batch key present in
  // existingFields and instruct the model to preserve everything the user
  // didn't ask to change.
  if (existingFields != null && existingFields.isNotEmpty) {
    final lines = <String>[];
    for (final key in batchKeys) {
      if (!existingFields.containsKey(key)) continue;
      final value = _stringifyExisting(existingFields[key]);
      if (value.trim().isEmpty) continue;
      lines.add('"$key" current value: $value');
    }
    if (lines.isNotEmpty) {
      buf.writeln();
      buf.writeln(
          'THIS IS AN EDIT — a TARGETED change, NOT a rewrite. Current values '
          'of these fields:');
      for (final line in lines) {
        buf.writeln(line);
      }
      buf.writeln();
      // Wave CY.18.269: the model kept rewriting the WHOLE card (and dropping
      // fields) when the user only asked for one small change. Make the
      // verbatim-copy rule a hard, numbered contract — the apply layer renders
      // exactly what you emit, so anything you rephrase here changes the card.
      buf.writeln(
          'RULES — follow exactly:\n'
          '1. Apply ONLY the specific change(s) the user asked for in the '
          'conversation above. Nothing else.\n'
          '2. For EVERY field the user did NOT explicitly ask to change, return '
          'its current value above copied CHARACTER-FOR-CHARACTER. Do not '
          'rephrase, reorder, shorten, expand, "improve", or re-style it.\n'
          '3. NEVER return an empty value for a field that currently has '
          'content — if you are not changing it, echo the current value '
          'verbatim.\n'
          '4. Output every requested key, including the unchanged ones (with '
          'their verbatim current value).');
    }
  }

  buf.writeln();
  buf.write(
      'Respond with ONE JSON object whose keys are EXACTLY: '
      '${batchKeys.join(', ')}. English values. No markdown fence, no text '
      'before or after the JSON object.');
  return buf.toString();
}

/// Render an existing field value (string, list, or map) as a compact,
/// human-readable line for the EDIT framing block. nestedBullets / list values
/// are flattened; everything else is `toString()`d.
String _stringifyExisting(dynamic value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  if (value is List) {
    final parts = <String>[];
    for (final item in value) {
      if (item is Map) {
        final label = (item['label'] ?? '').toString().trim();
        final v = (item['value'] ?? item['dialogue'] ?? '').toString().trim();
        if (label.isNotEmpty && v.isNotEmpty) {
          parts.add('$label: $v');
        } else if (v.isNotEmpty) {
          parts.add(v);
        } else if (label.isNotEmpty) {
          parts.add(label);
        }
      } else {
        final s = item.toString().trim();
        if (s.isNotEmpty) parts.add(s);
      }
    }
    return parts.join('; ');
  }
  return value.toString().trim();
}

/// The JSON-value shape hint for a [field]. Drives how the model must
/// serialise each value so the deterministic renderer can parse it. For a
/// nestedBullets parent with canonical children, the hint ENUMERATES those
/// sub-labels so the model produces the full, consistent breakdown (Ren-depth)
/// instead of one or two generic bullets.
String _shapeHint(CardField? field) {
  switch (field?.kind) {
    case CardFieldKind.nestedBullets:
      // An array of label/value objects, ideally covering the schema's
      // canonical sub-points. For a parent without canonical children (e.g.
      // an inner-circle-style field), label = the person's name, value = age +
      // relationship + a concrete detail.
      final children = field?.children;
      final subLabels = (children == null || children.isEmpty)
          ? ''
          : ' Cover at least these sub-points (label = the sub-point, '
              'value = its description): '
              '${children.map((c) => c.label).join(', ')}. Add more if relevant.';
      return 'a JSON array of objects [{"label":"…","value":"…"}, …], one '
          'object per sub-point.$subLabels';
    case CardFieldKind.bulletList:
      // A FLAT list of short strings (no sub-labels) — rendered as one bullet
      // per element. Each item must be a discrete, tight phrase, not a
      // paragraph.
      return 'a JSON array of short strings ["…", "…", …], one discrete item '
          'per element (each a tight phrase, not a paragraph).';
    case CardFieldKind.dialogueExamples:
      // Action = *italic* stage direction, dialogue = the spoken line, beat =
      // optional mood tag. Include at least one charged/intimate beat.
      return 'a JSON array of objects '
          '[{"action":"…","dialogue":"…","beat":"…"}, …] — action is an '
          '*italic* stage direction, dialogue is the spoken line, beat is an '
          'optional mood tag; include at least one charged/intimate beat.';
    case CardFieldKind.tags:
      // FIX E — tags must be real, searchable discovery tags, not invented
      // snake_case prose phrases.
      return 'a JSON array of 5-10 SHORT, conventional, human-readable '
          'discovery tags a user would actually search/filter by — e.g. '
          '"Female", "OC", "Dominant", "NSFW", "Tattoo Artist", "Tarot", '
          '"Brazilian", "Slice of Life", "Modern". Use plain words / short '
          'phrases (spaces, Title Case) — NOT snake_case. Do NOT invent '
          'descriptive phrases, do NOT tag plot spoilers, do NOT tag NPCs or '
          'pets, and do NOT mash kinks into one tag.';
    case CardFieldKind.prose:
    case CardFieldKind.topLevel:
    case null:
      return 'a JSON string value.';
  }
}

/// Find a [CardField] by [key] in [schema], searching top-level fields AND the
/// `children` of any nestedBullets parent. Returns null if absent.
CardField? _findField(List<CardField> schema, String key) {
  for (final f in schema) {
    if (f.key == key) return f;
    final children = f.children;
    if (children != null) {
      for (final c in children) {
        if (c.key == key) return c;
      }
    }
  }
  return null;
}
