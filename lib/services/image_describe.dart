// Helper for the "describe a reference image" flow of the AI-assisted
// character builder.
//
// Sends a one-shot vision request to the active provider with
// kImageAnalysisPrompt as the system message and the user's image as
// the user message. Returns the descriptive profile as plain text.

import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';
import 'card_assist_prompts.dart';
import 'chat_api.dart';

/// Encode the raw bytes of an image into a data URL the multimodal
/// chat API will accept. We sniff the format from the first few bytes
/// so we don't mislabel a JPEG as a PNG (some vision models care).
String encodeImageDataUrl(Uint8List bytes) {
  // PNG: 89 50 4E 47
  if (bytes.length > 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'data:image/png;base64,${base64Encode(bytes)}';
  }
  // JPEG: FF D8 FF
  if (bytes.length > 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'data:image/jpeg;base64,${base64Encode(bytes)}';
  }
  // WEBP: starts with "RIFF" then 4 bytes size then "WEBP"
  if (bytes.length > 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'data:image/webp;base64,${base64Encode(bytes)}';
  }
  // GIF: "GIF8"
  if (bytes.length > 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'data:image/gif;base64,${base64Encode(bytes)}';
  }
  // Unknown — let the model figure it out.
  return 'data:image/png;base64,${base64Encode(bytes)}';
}

/// One-shot call: send the image + kImageAnalysisPrompt to the active
/// provider, return the structured visual profile as text. Throws if
/// the provider doesn't support multimodal input (HTTP 400 from the
/// server, surfaced verbatim).
///
/// [userNote] is the optional message the user typed alongside the
/// image (e.g. "focus on her tattoos"). When provided, it's folded
/// into the user turn so the vision model can bias its emphasis.
/// Empty / null means a generic analysis.
Future<String> describeCharacterImage({
  required ApiProvider provider,
  required ModelSettings settings,
  required Uint8List imageBytes,
  String? userNote,
}) async {
  final dataUrl = encodeImageDataUrl(imageBytes);
  final noteTrimmed = userNote?.trim() ?? '';
  // Wave CY.18.166: REVERTED the Wave 165 persona-framing. The persona
  // creator ALSO builds a full self-insert (appearance + personality +
  // voice), so the standard character-framed vision — including the
  // "what personality does this <subject> have?" NEXT line — is CORRECT
  // for personas too. Keep one shared vision flow.
  final userText = noteTrimmed.isEmpty
      ? ''
      : 'Note from the user attaching this image:\n"$noteTrimmed"\n\n'
          'Use this only to bias emphasis (which details to highlight, '
          'what to ask about in NEXT). Always produce the full structured '
          'profile.';
  final turns = <ChatTurn>[
    ChatTurn('system', kImageAnalysisPrompt),
    ChatTurn('user', userText, imageDataUrls: [dataUrl]),
  ];
  // Wave CY.18.118: vision is a CLOSED CIRCUIT — deliberately NO preset.
  // The messages are already just the vision prompt + the image (no
  // architect prompt, conversation, or canvas). The only thing a preset
  // contributes via completeChat is sampling knobs (_samplingPayload),
  // and `preset?.temperature ?? settings.temperature` would let the RP
  // preset OVERRIDE the vision-specific temperature. A clinical image
  // description wants its own neutral sampling (visionTemperature +
  // creatorMaxTokens from _visionSettings), not the RP preset's tuning.
  final raw = await completeChat(
    provider: provider,
    settings: settings,
    messages: turns,
    debugTag: 'creator-vision', // Wave CY.18.214 diagnostics tag
  );
  // Wave CY.18.117: REVERTED the Wave CY.18.116 continuation loop — it
  // backfired on reasoning models. Asked to "continue where you left
  // off", they emitted their chain-of-thought about being confused
  // (re-listing empty headers, "Wait, the user says resume…") instead of
  // resuming. A reasoning model thinks in plain text before answering, so
  // any continuation instruction just produces more leaked reasoning that
  // no post-filter can reliably separate. Single-shot + the leading-
  // reasoning strip below is the lesser evil: a genuinely truncated long
  // profile is rarer and far less broken than a confused dump. If
  // truncation bites, the real fix is a leaner vision model or a higher
  // Max Response Tokens — not a conversational continuation.
  return stripVisionReasoningPreamble(raw);
}

/// The vision profile ALWAYS opens with one of these uppercase section
/// headers (one per shape from [kImageAnalysisPrompt]). They are
/// distinctive multi-word phrases that never appear as a bare line
/// inside a model's reasoning prose, so the first line matching one
/// marks where the real profile begins.
const _kVisionOpeningHeaders = <String>{
  'GENERAL PHYSICAL FEATURES', // single character
  'GROUP COMPOSITION', // ensemble
  'LOCATION TYPE', // setting / mixed
};

/// Strip any reasoning / "Shape Picker:" / "the user wants…" preamble a
/// vision model leaks ABOVE the clinical profile (plus any
/// `<think>…</think>` blocks). [kImageAnalysisPrompt] forbids this, but
/// some models emit their chain-of-thought as plain text regardless —
/// this is the belt-and-braces guard so the user never sees it.
///
/// Pure + deterministic (unit-tested). If no opening header is found
/// the (think-stripped) text is returned unchanged — we never risk
/// nuking an unusual-but-valid profile down to nothing.
String stripVisionReasoningPreamble(String raw) {
  // Drop any <think>…</think> reasoning blocks first.
  final text = raw.replaceAll(
    RegExp(r'<think>.*?</think>', dotAll: true, caseSensitive: false),
    '',
  );

  bool isOpeningHeader(String line) {
    var s = line.trim();
    // Strip leading markdown (#, *, -, >, spaces) and trailing * / spaces.
    s = s.replaceAll(RegExp(r'^[#*\->\s]+'), '');
    s = s.replaceAll(RegExp(r'[*\s]+$'), '');
    if (s.endsWith(':')) s = s.substring(0, s.length - 1).trimRight();
    final up = s.toUpperCase();
    if (_kVisionOpeningHeaders.contains(up)) return true;
    // CHARACTER A / CHARACTER B / CHARACTER 1 … (character-led ensemble).
    if (RegExp(r'^CHARACTER\s+[A-Z0-9]+$').hasMatch(up)) return true;
    return false;
  }

  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (isOpeningHeader(lines[i])) {
      return lines.sublist(i).join('\n').trim();
    }
  }
  return text.trim();
}
