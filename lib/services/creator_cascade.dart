// Wave CY.18.102 (Creator v2, Pillar B.1): pure cascade logic, extracted
// from character_assistant_screen.dart so it is unit-testable without a
// Flutter State / BuildContext. No Flutter imports — plain Dart over
// `Map<String, dynamic>` canvases and `String` values.
//
// These functions are the engine of the convergent, completeness-driven
// cascade (Pillar B). Wave 102 only EXTRACTS + tests them and rewires
// `_looksTerminated` to call `looksTerminated`; the live cascade keeps
// running on the old block engine until Wave 103a swaps it in.

/// Required canvas keys for a COMPLETE card, per creator mode.
///
/// - character → no post_history_instructions (optional add-on).
/// - scenario  → ADDS post_history_instructions (the narrator anti-drift
///   bullet list is content-level, required for a usable scenario card).
///
/// Both modes leave `personality` and `system_prompt` empty by convention.
/// Optional keys (alternate_greetings, system_prompt, post_history for
/// character) are NEVER required and excluded here.
List<String> requiredKeysFor(String? mode) {
  if (mode == 'scenario') {
    return const [
      'name',
      'description',
      'scenario',
      'first_mes',
      'mes_example',
      'post_history_instructions',
      'tagline',
      'creator_notes',
      'tags',
    ];
  }
  // persona → the user's self-insert. A persona is much simpler than a
  // character: just who they are (name + description) and how they talk
  // (dialogue examples → canvas key `mes_example`). No scenario,
  // first_mes, tags, creator_notes — those are character-only. Tagline
  // is optional (never required).
  if (mode == 'persona') {
    return const [
      'name',
      'description',
      'mes_example',
    ];
  }
  // character (and any legacy/unknown block mode)
  return const [
    'name',
    'description',
    'scenario',
    'first_mes',
    'mes_example',
    'tagline',
    'creator_notes',
    'tags',
  ];
}

/// The `<Tag>` sections a COMPLETE scenario `description` must contain. A
/// scenario Description is built from six XML-style sections; the
/// structured build / renderer use this to know which sections a scenario
/// card needs.
///
/// Non-scenario modes have no required Description sections (character
/// Descriptions are label-style, not XML) → returns `const []`.
List<String> requiredDescriptionSectionsFor(String? mode) {
  if (mode == 'scenario') {
    return const [
      'Narrator',
      'Reading the Persona',
      'Scene Setup',
      'Tone',
      'World',
      'NPCs',
    ];
  }
  return const [];
}

/// Wave CY.18.217: derive the name for a "Save as a copy" fork of an
/// edited card / persona. Appends " (copy)" so the fork is distinguishable
/// from the original in the library, unless the name already ends in a
/// "(copy)" marker (case-insensitive) so re-copying a copy doesn't pile up
/// "(copy) (copy)". Trims first; an empty name becomes "(copy)".
String withCopyNameSuffix(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '(copy)';
  if (RegExp(r'\(copy\)$', caseSensitive: false).hasMatch(trimmed)) {
    return trimmed;
  }
  return '$trimmed (copy)';
}

/// Canvas value → plain text. Lists (e.g. tags, alternate_greetings)
/// join with ', '. Null / other → empty string.
String canvasText(dynamic v) {
  if (v is String) return v;
  if (v is List) return v.join(', ');
  return '';
}

// ── Wave CY.18.105 (Creator v2, Pillar D.1): description section merge ──
//
// NET-NEW infrastructure for the SCENARIO path ONLY (spec §7.2). The
// scenario architect's Description is a sequence of XML-style sections —
// `<Narrator>`, `<Reading the Persona>`, `<Scene Setup>`, `<Tone>`,
// `<World>`, `<NPCs>`. Before Wave 105 a SHEET `Description:` value was
// applied as a WHOLESALE REPLACE, so the prompt had to re-emit the full
// Description every turn. These functions let the runtime merge a
// per-section emission into the existing canvas Description by tag, which
// is what Wave 106's per-block emission needs. With the pre-106 prompt
// (full re-emit) a merge of all sections == replace, so there is NO
// behaviour change for existing scenario cards.
//
// The CHARACTER path is intentionally NOT routed through these — it emits
// label-style content (`Core Traits:` / `Abilities:`) merged by
// `_mergeBlockIntoDescription`, and an XML-tag merge would fall to the
// untagged-prose path and risk a silent regression on the app's
// highest-traffic path (plan-review #4, decided).

/// One parsed segment of a Description string. A tagged `<Tag>…</Tag>`
/// section has a non-empty [tag] and its inner [value]; untagged prose
/// (legacy/imported cards) is returned with an empty [tag] and the raw
/// prose as [value].
typedef DescriptionSection = ({String tag, String value});

/// Canonical emission order for the scenario Description sections
/// (spec §7.2). A new section is APPENDED at the slot implied by this
/// order; a tag not listed here sorts to the end (after all known tags).
const List<String> kDescriptionSectionOrder = <String>[
  'Narrator',
  'Reading the Persona',
  'Scene Setup',
  'Tone',
  'World',
  'NPCs',
];

/// Matches a `<Tag>…</Tag>` section. Tags are MULTI-WORD
/// (`<Reading the Persona>`, `<Scene Setup>`), so the name capture allows
/// spaces — a `\w+`-only capture would silently skip the spaced sections.
/// `dotAll` lets a section body span multiple lines; the back-reference
/// `\1` requires the close tag to match the open tag, so an unclosed /
/// mismatched tag is NOT captured (→ treated as incomplete).
final RegExp _kDescriptionSectionRe =
    RegExp(r'<([\w ]+?)>(.*?)</\1>', dotAll: true);

/// Parse [text] into an ordered list of [DescriptionSection]s: each
/// `<Tag>…</Tag>` segment (tag + trimmed inner value) interleaved with the
/// untagged prose that surrounds it (empty tag, trimmed value). Untagged
/// gaps that are empty after trimming are dropped. An unclosed / malformed
/// tag is NOT a section — its text falls into the surrounding untagged
/// prose (so the field reads as "not terminated" and the cascade keeps
/// going).
List<DescriptionSection> parseDescriptionSections(String text) {
  final sections = <DescriptionSection>[];
  var cursor = 0;
  for (final m in _kDescriptionSectionRe.allMatches(text)) {
    if (m.start > cursor) {
      final prose = text.substring(cursor, m.start).trim();
      if (prose.isNotEmpty) sections.add((tag: '', value: prose));
    }
    sections.add((tag: m.group(1)!.trim(), value: m.group(2)!.trim()));
    cursor = m.end;
  }
  if (cursor < text.length) {
    final prose = text.substring(cursor).trim();
    if (prose.isNotEmpty) sections.add((tag: '', value: prose));
  }
  return sections;
}

/// Rank a tag for canonical-order insertion. Known tags sort by their
/// index in [kDescriptionSectionOrder]; unknown tags sort last.
int _sectionRank(String tag) {
  final i = kDescriptionSectionOrder.indexOf(tag);
  return i < 0 ? kDescriptionSectionOrder.length : i;
}

/// Serialise a segment list back to a Description string: tagged segments
/// as `<Tag>value</Tag>`, untagged prose verbatim, joined by blank-free
/// single newlines.
String _serializeDescriptionSections(List<DescriptionSection> sections) {
  return sections
      .map((s) => s.tag.isEmpty ? s.value : '<${s.tag}>${s.value}</${s.tag}>')
      .join('\n');
}

/// Merge the XML sections found in [incoming] into [current] (spec §7.2),
/// returning the merged Description. SCENARIO PATH ONLY.
///
/// For each well-formed `<Tag>…</Tag>` in [incoming]:
/// - if a section with that tag already exists in [current] → REPLACE it
///   in place (position preserved);
/// - else → APPEND it at the slot implied by [kDescriptionSectionOrder].
///
/// Untagged prose already in [current] is preserved. A malformed / unclosed
/// incoming tag (no matching close) is NOT merged — there is nothing
/// well-formed to parse, so [current] is returned unchanged and the field
/// stays "not terminated" so the completeness loop keeps going. When
/// [incoming] contributes no well-formed sections, [current] is returned
/// byte-for-byte unchanged.
String mergeDescriptionSections(String current, String incoming) {
  final incomingSections =
      parseDescriptionSections(incoming).where((s) => s.tag.isNotEmpty);
  if (incomingSections.isEmpty) return current;

  final merged = parseDescriptionSections(current);
  for (final inc in incomingSections) {
    final existingIdx = merged.indexWhere((s) => s.tag == inc.tag);
    if (existingIdx >= 0) {
      // Replace in place.
      merged[existingIdx] = inc;
      continue;
    }
    // Append at the canonical slot: before the first existing TAGGED
    // section that ranks after this one; otherwise at the end. Untagged
    // prose is never used as an insertion landmark (keeps a trailing
    // legacy paragraph trailing).
    final incRank = _sectionRank(inc.tag);
    var insertAt = merged.length;
    for (var i = 0; i < merged.length; i++) {
      final s = merged[i];
      if (s.tag.isEmpty) continue;
      if (_sectionRank(s.tag) > incRank) {
        insertAt = i;
        break;
      }
    }
    merged.insert(insertAt, inc);
  }
  return _serializeDescriptionSections(merged);
}

// ---------------------------------------------------------------------------
// Wave CY.18.200: mode label for the sheet-status pill.

/// Maps a [CreatorSession]'s [mode] + [editingPersonaId] to a short
/// human-readable label shown in the sheet-status pill.
///
/// Returns `null` when no badge should be shown (mode is null → the user
/// hasn't picked a mode yet).
///
/// Accepts the two discriminating values as plain strings so this
/// function stays a pure-Dart helper with no Flutter / model imports,
/// and can be unit-tested without a full AppStore.
String? creatorModeLabel({
  required String? mode,
  required String? editingPersonaId,
}) {
  switch (mode) {
    case 'character':
      return 'Build a character';
    case 'scenario':
      return 'Build a Scenario';
    case 'persona':
      if (editingPersonaId != null) return 'Edit persona';
      return 'Build a persona';
    case 'edit':
      if (editingPersonaId != null) return 'Edit persona';
      return 'Edit card';
    default:
      return null; // null / unknown → no badge
  }
}

// ---------------------------------------------------------------------------
// Wave CY.18.242 — Build-by-message trigger
//
// The floating "Build the sheet" / "Apply changes" pill was removed. The
// structured build is now triggered two ways, both ASCII-only:
//   1. the conversational architect emits the marker `[[BUILD_SHEET]]` on its
//      own final line when the user signals readiness (multilingual — the
//      LLM decides; the marker itself is fixed ASCII), and the screen strips
//      it from the displayed reply + auto-fires the build, OR
//   2. the user types the deterministic `/build` command in the Creator input.
//
// These two pure helpers keep the detection/strip + command-match logic
// testable without a Flutter State / BuildContext.

/// The exact ASCII marker the architect emits, on its own final line, when the
/// user has clearly signalled they want to build the card NOW. Detection is
/// case-insensitive and tolerates surrounding whitespace/newlines.
const String kBuildSheetMarker = '[[BUILD_SHEET]]';

/// Matches the build-sheet marker anywhere in an assistant message,
/// case-insensitive, with any surrounding whitespace/newlines absorbed so the
/// stripped text reads cleanly. The `[[` / `]]` brackets are escaped for the
/// regex. We match every occurrence (replaceAll) so a model that emits it more
/// than once still ends up clean.
final RegExp _buildSheetMarkerRe = RegExp(
  r'\s*\[\[\s*BUILD_SHEET\s*\]\]\s*',
  caseSensitive: false,
  multiLine: true,
);

/// Result of [detectAndStripBuildMarker]: the message with the marker removed
/// plus whether the marker was present.
class BuildMarkerResult {
  const BuildMarkerResult(this.text, this.found);

  /// The assistant message with every `[[BUILD_SHEET]]` occurrence stripped
  /// and the result trimmed. When [found] is false this is the input,
  /// trimmed.
  final String text;

  /// True when at least one `[[BUILD_SHEET]]` marker was present in the input.
  final bool found;
}

/// Detect + strip the `[[BUILD_SHEET]]` marker from a completed assistant
/// message. Returns the cleaned text (marker removed, trimmed) and whether the
/// marker was found. Pure — no side effects — so the auto-fire decision can be
/// unit-tested without the widget.
BuildMarkerResult detectAndStripBuildMarker(String raw) {
  final found = _buildSheetMarkerRe.hasMatch(raw);
  if (!found) return BuildMarkerResult(raw.trim(), false);
  // Replace each marker (plus the whitespace it absorbs) with a single space,
  // then collapse + trim so we don't leave a dangling blank line where the
  // marker sat on its own final line.
  final stripped = raw.replaceAll(_buildSheetMarkerRe, '\n').trim();
  return BuildMarkerResult(stripped, true);
}

/// True when the user's OUTGOING Creator-input message is the deterministic
/// `/build` command (the safety-net fallback if the architect ever forgets the
/// marker). Accepts exactly `/build` and `/build the sheet`, case-insensitive,
/// ignoring surrounding whitespace. Anything else → false (so it gets sent to
/// the architect as a normal turn). ASCII-only.
bool isBuildCommand(String raw) {
  final s = raw.trim().toLowerCase();
  return s == '/build' || s == '/build the sheet';
}

/// C-2 (CRITICAL): true when a normal Creator chat send must be BLOCKED.
///
/// A send is blocked when there's nothing to send (empty text AND no staged
/// attachments) OR a generation is already in flight (`generating`) OR a
/// structured build is in flight (`structuredBuilding`).
///
/// The `structuredBuilding` arm is the load-bearing one: a normal send during
/// an in-flight build calls `_runConversation`, which bumps `_streamGen`; the
/// build then bails at its `myGen != _streamGen` guard BEFORE writing the
/// canvas / done-status, silently discarding the whole build (the "pass N of M"
/// status bubble freezes forever and the sheet stays empty). Blocking the send
/// keeps the build's generation token stable so it completes.
bool creatorSendBlocked({
  required String trimmedText,
  required bool hasPendingAttachments,
  required bool generating,
  required bool structuredBuilding,
}) {
  if (trimmedText.isEmpty && !hasPendingAttachments) return true;
  if (generating || structuredBuilding) return true;
  return false;
}
