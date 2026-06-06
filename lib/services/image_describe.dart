// Helper for the "describe a reference image" flow of the AI-assisted
// character builder.
//
// Sends a vision request to the active provider with kImageAnalysisPrompt
// as the system message and the user's image as the user message, via the
// reasoning-aware streaming transport, and returns the descriptive profile
// as plain text (reasoning channel + control sentinels stripped).

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
  // creator-09 (mega audit 2026-06-04): a couple more formats common on
  // mobile gallery exports, so we don't mislabel them as PNG and trip a
  // strict vision provider's MIME check.
  // BMP: "BM"
  if (bytes.length > 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'data:image/bmp;base64,${base64Encode(bytes)}';
  }
  // AVIF / HEIC / HEIF: ISO-BMFF "ftyp" box at offset 4, with the major
  // brand following at offset 8. iOS exports HEIC; modern Androids AVIF.
  if (bytes.length > 12 &&
      bytes[4] == 0x66 && // f
      bytes[5] == 0x74 && // t
      bytes[6] == 0x79 && // y
      bytes[7] == 0x70) {
    // brand = bytes[8..11] as ASCII.
    final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
    if (brand.startsWith('avif') || brand == 'avis') {
      return 'data:image/avif;base64,${base64Encode(bytes)}';
    }
    if (brand.startsWith('heic') ||
        brand.startsWith('heif') ||
        brand.startsWith('hev') ||
        brand == 'mif1' ||
        brand == 'msf1') {
      return 'data:image/heic;base64,${base64Encode(bytes)}';
    }
  }
  // Unknown — let the model figure it out.
  return 'data:image/png;base64,${base64Encode(bytes)}';
}

/// Send the image + kImageAnalysisPrompt to the active provider and
/// return the structured visual profile as text. Throws if the provider
/// doesn't support multimodal input (HTTP 400 from the server, surfaced
/// verbatim).
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
  // contributes via the transport is sampling knobs (_samplingPayload),
  // and `preset?.temperature ?? settings.temperature` would let the RP
  // preset OVERRIDE the vision-specific temperature. A clinical image
  // description wants its own neutral sampling (visionTemperature +
  // creatorMaxTokens from _visionSettings), not the RP preset's tuning.
  //
  // creator-02 (mega audit 2026-06-04): route through the STREAMING,
  // reasoning-aware transport instead of one-shot `completeChat`. On
  // reasoning models that expose their CoT in `delta.reasoning_content`
  // (DeepSeek/R1) or `delta.reasoning` (OpenRouter-normalised / some Qwen
  // routes), `streamChatCompletion` already separates that channel and
  // wraps it in `<think>…</think>` for EVERY provider — so the profile
  // bubble no longer competes with leaked reasoning prose. This is
  // provider-AGNOSTIC: no Venice-only suffix / extraBody. `completeChat`
  // could only recover the *separated-field* case post-hoc; the streaming
  // path is where the separation actually happens live.
  //
  // `cleanVisionStreamedText` below strips the `<think>` block, the Pyre
  // end-of-stream sentinels the transport appends (finish-reason /
  // dropped-frames), and — as the final net — any leading plain-text CoT
  // for the worst case where a model emits reasoning as undelimited
  // content with no separate field (`stripVisionReasoningPreamble`).
  final buffer = StringBuffer();
  await for (final chunk in streamChatCompletion(
    provider: provider,
    settings: settings,
    messages: turns,
    preset: null,
    debugTag: 'creator-vision', // Wave CY.18.214 diagnostics tag
  )) {
    buffer.write(chunk);
  }
  final profile = cleanVisionStreamedText(buffer.toString());
  // H-11: SOFT truncation net. A multi-character ensemble can exceed the
  // provider's output-token cap and cut off mid-CHARACTER C. We do NOT
  // auto-continue (reverted in Wave 117 — reasoning models re-dump CoT on
  // "resume"). Instead, if the profile is missing its mandated NEXT close,
  // append a non-blocking note inviting the user to regenerate or edit.
  // Informational only; the profile text above it is left intact.
  if (profile.isNotEmpty && !visionProfileLooksComplete(profile)) {
    return '$profile\n\n$kVisionTruncationNote';
  }
  return profile;
}

/// Soft, user-facing note appended below a vision profile that
/// [visionProfileLooksComplete] flags as apparently cut off. Non-blocking:
/// the profile is still usable, this just invites a regenerate/edit.
const String kVisionTruncationNote =
    '⚠ This image profile may be cut off — you can regenerate it (↻) or '
    'edit it before building the card.';

/// Post-process a vision profile assembled from the STREAMING transport.
///
/// The reasoning-aware stream wraps any separated reasoning channel in
/// `<think>…</think>` and appends Pyre end-of-stream sentinels
/// ([pyreFinishSentinelRegex] / [pyreDroppedFramesRegex]). This strips
/// those, then runs [stripVisionReasoningPreamble] (which removes the
/// `<think>` block and any leading plain-text CoT before the first
/// recognised section header). Pure + deterministic (unit-tested).
String cleanVisionStreamedText(String raw) {
  final withoutSentinels = raw
      .replaceAll(pyreFinishSentinelRegex, '')
      .replaceAll(pyreDroppedFramesRegex, '');
  return stripVisionReasoningPreamble(withoutSentinels);
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

/// Soft, heuristic completeness check for a finished vision profile.
///
/// H-11: a multi-character ENSEMBLE profile can exceed the provider's
/// output-token cap and silently cut off mid-`CHARACTER C`. We CANNOT
/// auto-recover by asking the model to "continue" — that was deliberately
/// reverted in Wave 117 because reasoning models re-dump their
/// chain-of-thought when told to resume. So this function only INFORMS:
/// when it returns false the caller surfaces a non-blocking note inviting
/// the user to regenerate or edit. Never used to retry.
///
/// Because a false "truncated" verdict is benign (a dismissible note), the
/// check is deliberately simple and conservative. The vision prompt
/// ([kImageAnalysisPrompt]) mandates that EVERY shape closes with a bare
/// `NEXT` section header followed by one handoff sentence. So a profile
/// "looks complete" iff:
///   1. it contains a bare `NEXT` header LINE (not a body sentence that
///      merely starts with "Next, …"), and
///   2. there is at least one non-empty line AFTER that header (the
///      handoff sentence the prompt requires).
///
/// Pure + deterministic (unit-tested). Mirrors the prompt's contract, so
/// a normally-formed profile of any shape passes and a tail-truncated one
/// (no `NEXT`, or `NEXT` with nothing after it) fails.
bool visionProfileLooksComplete(String profile) {
  final text = profile.trim();
  if (text.isEmpty) return false;

  bool isNextHeader(String line) {
    var s = line.trim();
    // Strip leading markdown (#, *, -, >, spaces) and trailing * / spaces.
    s = s.replaceAll(RegExp(r'^[#*\->\s]+'), '');
    s = s.replaceAll(RegExp(r'[*\s]+$'), '');
    if (s.endsWith(':')) s = s.substring(0, s.length - 1).trimRight();
    // A bare NEXT header is the literal word on its own line — NOT a body
    // sentence like "Next, the lighting falls…" (which has a comma + more).
    return s.toUpperCase() == 'NEXT';
  }

  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (isNextHeader(lines[i])) {
      // The prompt requires a handoff sentence after NEXT. If there's a
      // non-empty line below the header, the closing section was emitted.
      for (var j = i + 1; j < lines.length; j++) {
        if (lines[j].trim().isNotEmpty) return true;
      }
      return false; // header present but stream cut off right after it.
    }
  }
  return false; // no closing NEXT marker → looks truncated.
}
