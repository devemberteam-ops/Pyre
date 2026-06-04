// Wave CY.18.267 (Pyre 1.1): SillyTavern-style prompt post-processing.
//
// Many models served over OpenAI-compatible endpoints (DeepSeek, GLM,
// Mistral, Claude, and a lot of open-weight models) are strict about the
// shape of the `messages` array. They expect a SINGLE system message, no two
// consecutive messages from the same role, and strict user/assistant
// alternation that starts with a user turn. Pyre, however, assembles an
// OpenAI-shaped array that can legitimately contain multiple system-ish
// blocks plus consecutive turns coming from example dialogue / lorebook
// injection. On those strict models that hurts instruction adherence (and on
// some routes it's a hard 400).
//
// This module reshapes the outgoing message list right before it's
// serialised into the request body. It is a PURE transform over `(role,
// content)` pairs — Flutter-free and exhaustively testable. The default mode
// (`none`) is the identity function, so existing users get a byte-identical
// request body and zero behaviour change.
//
// The modes mirror SillyTavern's documented "Prompt Post-Processing" options
// exactly (Pyre has no tool calls, so the tool-call handling is intentionally
// dropped):
//   none            — identity. Messages unchanged.
//   mergeConsecutive— fold adjacent same-role messages into one (join with
//                     a blank line).
//   semiStrict      — mergeConsecutive, then collapse ALL system messages
//                     into a single system message placed first.
//   strict          — semiStrict, then guarantee the first non-system
//                     message is a user message (insert a " " placeholder if
//                     it would otherwise be an assistant turn) so the array
//                     alternates user/assistant after the optional system.
//   singleUser      — collapse EVERYTHING (including the system message) into
//                     ONE user message. The most restrictive mode.

/// SillyTavern-style prompt post-processing modes. See the file header for
/// what each does. Stored per-provider; persisted by enum [name].
enum PromptPostProcessing {
  none,
  mergeConsecutive,
  semiStrict,
  strict,
  singleUser,
}

/// The separator used everywhere we concatenate message contents. Matches
/// SillyTavern's blank-line join so a merged block reads as separate
/// paragraphs rather than run-on text.
const String _kJoin = '\n\n';

/// Decode a persisted string into a [PromptPostProcessing]. Tolerant: an
/// unknown / missing / malformed value falls back to [PromptPostProcessing.none]
/// (today's behaviour), so a corrupted or forward-version backup never breaks
/// a provider — it just loses the post-processing override.
PromptPostProcessing promptPostProcessingFromString(String? s) {
  if (s == null) return PromptPostProcessing.none;
  for (final v in PromptPostProcessing.values) {
    if (v.name == s) return v;
  }
  return PromptPostProcessing.none;
}

/// Encode a [PromptPostProcessing] to its stable string form (the enum name).
String promptPostProcessingToString(PromptPostProcessing v) => v.name;

/// A minimal, Flutter-free representation of one chat message for the pure
/// transform. The adapter in chat_api maps `ChatTurn` <-> this and back, so
/// this module never imports the app model and stays trivially testable.
///
/// NOTE: image attachments (`ChatTurn.imageDataUrls`) are deliberately NOT
/// modelled here. Merging/collapsing is a TEXT operation; the adapter only
/// routes messages through the pure transform when they are plain text (the
/// common case for the strict providers this targets), and leaves any
/// image-bearing turn untouched. See [applyPromptPostProcessingRoles].
class PpMessage {
  final String role; // 'system' | 'user' | 'assistant'
  final String content;
  const PpMessage(this.role, this.content);

  PpMessage copyWith({String? role, String? content}) =>
      PpMessage(role ?? this.role, content ?? this.content);

  @override
  bool operator ==(Object other) =>
      other is PpMessage && other.role == role && other.content == content;

  @override
  int get hashCode => Object.hash(role, content);

  @override
  String toString() => 'PpMessage($role, ${content.length} chars)';
}

/// Apply [mode] to a list of [PpMessage]s and return the reshaped list. Pure:
/// never mutates the input, always returns a fresh list. For
/// [PromptPostProcessing.none] it returns the input list reference unchanged
/// (the caller relies on this to keep the `none` request body byte-identical).
List<PpMessage> applyPromptPostProcessingRoles(
  List<PpMessage> messages,
  PromptPostProcessing mode,
) {
  if (mode == PromptPostProcessing.none) return messages;
  if (messages.isEmpty) return const <PpMessage>[];

  switch (mode) {
    case PromptPostProcessing.none:
      return messages;
    case PromptPostProcessing.mergeConsecutive:
      return _mergeConsecutive(messages);
    case PromptPostProcessing.semiStrict:
      return _semiStrict(messages);
    case PromptPostProcessing.strict:
      return _strict(messages);
    case PromptPostProcessing.singleUser:
      return _singleUser(messages);
  }
}

/// Fold adjacent same-role messages into one, joining their content with a
/// blank line, preserving order. `[sys, sys, user, user, asst]` →
/// `[sys+sys, user+user, asst]`.
List<PpMessage> _mergeConsecutive(List<PpMessage> messages) {
  final out = <PpMessage>[];
  for (final m in messages) {
    if (out.isNotEmpty && out.last.role == m.role) {
      out[out.length - 1] = out.last.copyWith(
        content: _joinContent(out.last.content, m.content),
      );
    } else {
      out.add(m);
    }
  }
  return out;
}

/// mergeConsecutive, THEN collapse every system message into a single system
/// message placed first (contents concatenated in original order). At most one
/// system message remains; the non-system tail keeps its order.
List<PpMessage> _semiStrict(List<PpMessage> messages) {
  final merged = _mergeConsecutive(messages);
  final systemParts = <String>[];
  final rest = <PpMessage>[];
  for (final m in merged) {
    if (m.role == 'system') {
      systemParts.add(m.content);
    } else {
      rest.add(m);
    }
  }
  final out = <PpMessage>[];
  if (systemParts.isNotEmpty) {
    out.add(PpMessage('system', _joinParts(systemParts)));
  }
  out.addAll(rest);
  // Pulling systems out of the middle can leave two same-role non-system
  // messages now adjacent (e.g. `asst, sys, asst` → `sys, asst, asst`), so
  // re-merge to keep the no-consecutive-same-role guarantee.
  return _mergeConsecutive(out);
}

/// semiStrict, THEN guarantee the first non-system message is a user message.
/// If it's an assistant message (e.g. the chat opens with the character's
/// greeting), insert a single-space `" "` placeholder user message before it —
/// innocuous and accepted by the strict APIs. The merge step already
/// guarantees alternation among the remaining turns.
List<PpMessage> _strict(List<PpMessage> messages) {
  final base = _semiStrict(messages);
  // Find the first non-system message.
  var firstNonSystem = -1;
  for (var i = 0; i < base.length; i++) {
    if (base[i].role != 'system') {
      firstNonSystem = i;
      break;
    }
  }
  // Nothing but a system message (or empty): leave as-is.
  if (firstNonSystem < 0) return base;
  if (base[firstNonSystem].role == 'user') return base;
  // First non-system turn is an assistant turn → inject a placeholder user
  // message just before it so the array reads [system?, user(" "), assistant…].
  final out = <PpMessage>[
    ...base.sublist(0, firstNonSystem),
    const PpMessage('user', ' '),
    ...base.sublist(firstNonSystem),
  ];
  return out;
}

/// Collapse ALL messages (system + user + assistant) into ONE user message,
/// concatenating their content in order with a blank line. The most
/// restrictive mode — for endpoints that only accept a single user turn.
List<PpMessage> _singleUser(List<PpMessage> messages) {
  final parts = <String>[
    for (final m in messages) m.content,
  ];
  return [PpMessage('user', _joinParts(parts))];
}

/// Join two content strings with the standard separator, but don't introduce
/// a leading/trailing blank-line pair when one side is empty.
String _joinContent(String a, String b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  return '$a$_kJoin$b';
}

/// Join an ordered list of content parts, skipping empties so we never emit a
/// run of blank-line separators around an empty system block.
String _joinParts(List<String> parts) {
  final nonEmpty = parts.where((p) => p.isNotEmpty);
  return nonEmpty.join(_kJoin);
}
