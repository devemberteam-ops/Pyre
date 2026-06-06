// Mega-audit 2026-06-04 — cross-model / cross-provider compatibility.
//
// Pyre sends a fixed OpenAI-flavoured request body to every provider. That is
// great for permissive providers (OpenRouter, Venice, vLLM, LM Studio, Chub)
// but a small set of mainstream providers a real user base WILL hit reject
// some of the fields unconditionally:
//   * OpenAI reasoning models (o1/o3/GPT-5) 400 on temperature/top_p/penalties
//     and require `max_completion_tokens` instead of `max_tokens`.
//   * Mistral strictly validates → 422 on any unknown field (the extended
//     samplers top_k/min_p/top_a/repetition_penalty + custom extraParams).
//
// This file is the PURE, provider-agnostic, default-open policy layer:
//
//  1. [isUnsupportedParamError] — does a scrubbed 4xx body look like a
//     param-shape rejection (vs auth / rate-limit / model-not-found)?
//  2. [minimalRetryBody] — rebuild a request body with the MINIMAL safe set
//     (model, messages, stream, and the token cap under BOTH names). The
//     universal reactive backstop: retry ONCE with this on a param-error 4xx.
//  3. [safeBodyFor] — OPTIONAL proactive per-kind/host allowlist. Drops the
//     fields known to break a handful of strict providers BEFORE the request.
//     Default / unknown providers get EVERYTHING unchanged — we never regress
//     a permissive provider.
//
// Nothing here imports Flutter; everything is unit-testable in isolation.

import '../models/models.dart' show ApiProvider, ProviderKind;

/// Request-body keys that are NEVER stripped — the irreducible core of a
/// chat-completions request. The token cap is handled separately because its
/// NAME varies by provider (`max_tokens` vs `max_completion_tokens`).
const Set<String> _coreBodyKeys = {'model', 'messages', 'stream'};

/// The two interchangeable names for the output-token cap. Different providers
/// want different ones (OpenAI reasoning wants `max_completion_tokens`, Mistral
/// rejects it and wants `max_tokens`), so the minimal retry sends both.
const String _kMaxTokens = 'max_tokens';
const String _kMaxCompletionTokens = 'max_completion_tokens';

/// Sampling / sampler fields Pyre may emit. Used by the proactive allowlist to
/// know what to drop for a strict provider.
const String _kTemperature = 'temperature';
const String _kTopP = 'top_p';
const String _kTopK = 'top_k';
const String _kMinP = 'min_p';
const String _kTopA = 'top_a';
const String _kRepetitionPenalty = 'repetition_penalty';
const String _kFrequencyPenalty = 'frequency_penalty';
const String _kPresencePenalty = 'presence_penalty';

/// Extended samplers that the OpenAI-official API and Mistral reject but
/// OpenRouter / vLLM / local servers model.
const Set<String> _extendedSamplers = {
  _kTopK,
  _kMinP,
  _kTopA,
  _kRepetitionPenalty,
};

/// Standard OpenAI chat-completions fields. Anything OUTSIDE this set is an
/// "extra" param that a strict validator (Mistral) will 422 on. Used only by
/// the Mistral branch of [safeBodyFor]; permissive providers never consult it.
const Set<String> _openAiStandardFields = {
  'model',
  'messages',
  'stream',
  'temperature',
  'top_p',
  'max_tokens',
  'max_completion_tokens',
  'frequency_penalty',
  'presence_penalty',
  'stop',
  'n',
  'seed',
  'response_format',
  'tools',
  'tool_choice',
  'logprobs',
  'top_logprobs',
  'logit_bias',
  'user',
  'stream_options',
  'parallel_tool_calls',
};

/// Param-error signatures. These are substrings that appear in the (already
/// scrubbed) error body of a 4xx that rejected a PARAMETER shape — as opposed
/// to auth, rate-limit, or model-not-found errors, which a retry-without-extras
/// would not help. Drawn from the audit doc + real provider error strings
/// (OpenAI, Mistral, Azure, open-webui / LibreChat issue trails).
///
/// All lower-cased; the matcher lower-cases the body before comparing.
const List<String> _paramErrorSignatures = [
  'unsupported parameter',
  'unrecognized request argument',
  'unsupported_value',
  'extra inputs are not permitted',
  'does not support the parameter',
  'extra fields not permitted',
  'extra_forbidden',
  // Token-cap rename complaints (OpenAI reasoning models).
  'max_completion_tokens',
  'max_tokens',
];

/// Returns true when [scrubbedBody] looks like a provider rejecting the SHAPE
/// of the request (an unsupported / extra / mis-named parameter), for which the
/// right move is to retry once with the minimal safe body. Returns false for
/// auth, rate-limit, quota, and other 4xx that a retry-without-extras can't
/// fix. Case-insensitive. Empty body ⇒ false.
bool isUnsupportedParamError(String scrubbedBody) {
  if (scrubbedBody.isEmpty) return false;
  final lower = scrubbedBody.toLowerCase();
  for (final sig in _paramErrorSignatures) {
    if (lower.contains(sig)) return true;
  }
  return false;
}

/// Rebuild [body] keeping ONLY the minimal safe set: model, messages, stream,
/// and the output-token cap under BOTH names (so whichever the provider wants
/// is present and the other is harmlessly ignored). Everything else
/// (temperature, top_p, all samplers, penalties, response_format, reasoning,
/// custom extraParams) is dropped.
///
/// This is the body used for the universal retry-once on a param-error 4xx.
/// Pure: never mutates [body]. Terminates — there is no loop; the caller
/// retries exactly once with this.
Map<String, dynamic> minimalRetryBody(Map<String, dynamic> body) {
  final out = <String, dynamic>{};
  for (final key in _coreBodyKeys) {
    if (body.containsKey(key)) out[key] = body[key];
  }
  // Resolve the token cap from whichever name the original body used.
  final cap = body[_kMaxTokens] ?? body[_kMaxCompletionTokens];
  if (cap != null) {
    out[_kMaxTokens] = cap;
    out[_kMaxCompletionTokens] = cap;
  }
  return out;
}

/// True for OpenAI reasoning model ids (o1 / o3 / o4 families + GPT-5). These
/// reject temperature/top_p/penalties and require `max_completion_tokens`.
/// Matches a bare family prefix or a `provider/` route prefix (e.g.
/// `openai/o3-mini`). Standard chat models (gpt-4o, gpt-4.1, gpt-3.5) are NOT
/// reasoning models and stay permissive.
bool _isOpenAiReasoningModel(String model) {
  final m = model.toLowerCase().trim();
  // Strip an OpenRouter-style `vendor/` prefix so `openai/o3` matches.
  final id = m.contains('/') ? m.split('/').last : m;
  // o-series: o1, o3, o4, optionally with a suffix (o3-mini, o1-preview).
  if (RegExp(r'^o[1-9](\b|[-_])').hasMatch(id)) return true;
  // GPT-5 family (reasoning by default).
  if (RegExp(r'^gpt-5(\b|[-_.])').hasMatch(id)) return true;
  return false;
}

/// True when the provider's base URL points at the OpenAI OFFICIAL API host
/// (api.openai.com), where param validation is strict. Third-party
/// OpenAI-compatible proxies (OpenRouter, Azure, local) are NOT this and stay
/// permissive — only the official endpoint hard-400s on the o-series.
bool _isOpenAiOfficialHost(String baseUrl) {
  final host = _hostOf(baseUrl);
  return host == 'api.openai.com';
}

/// True when the provider's base URL points at Mistral's API host, which
/// strictly validates the body (422 on any unknown field + the extended
/// samplers).
bool _isMistralHost(String baseUrl) {
  final host = _hostOf(baseUrl);
  return host == 'api.mistral.ai' || host.endsWith('.mistral.ai');
}

/// Lower-cased host of [baseUrl], or '' when it can't be parsed.
String _hostOf(String baseUrl) {
  final u = Uri.tryParse(baseUrl.trim());
  return (u?.host ?? '').toLowerCase();
}

/// Proactive per-kind/host param allowlist. Returns a body safe to send to
/// [provider] / [model], dropping the fields known to break a small set of
/// strict providers BEFORE the request goes out:
///
///   * OpenAI OFFICIAL host + a reasoning model id (o-series / GPT-5) →
///     drop temperature/top_p/penalties/extended-samplers and rename
///     `max_tokens` → `max_completion_tokens`.
///   * Mistral host → drop the extended samplers (top_k/min_p/top_a/
///     repetition_penalty) AND any non-standard "extra" field (custom
///     extraParams) it would 422 on; keep `max_tokens` (NOT
///     `max_completion_tokens`) + core sampling.
///   * Everything else (default / unknown / localhost / OpenRouter / Venice /
///     vLLM) → send EVERYTHING unchanged. We never regress a permissive
///     provider.
///
/// Pure: never mutates [body]; returns the SAME reference when no change
/// applies (so the request stays byte-identical for the common case).
Map<String, dynamic> safeBodyFor(
  ApiProvider provider,
  String model,
  Map<String, dynamic> body,
) {
  // Never touch local servers — they accept (and JIT-handle) anything, and a
  // user pointing a localhost provider at a custom model id must not be
  // second-guessed.
  if (provider.kind == ProviderKind.localhost) return body;

  final baseUrl = provider.baseUrl;

  if (_isOpenAiOfficialHost(baseUrl) && _isOpenAiReasoningModel(model)) {
    final out = <String, dynamic>{};
    for (final e in body.entries) {
      switch (e.key) {
        case _kTemperature:
        case _kTopP:
        case _kFrequencyPenalty:
        case _kPresencePenalty:
        case _kTopK:
        case _kMinP:
        case _kTopA:
        case _kRepetitionPenalty:
          // Dropped — reasoning models reject these.
          break;
        case _kMaxTokens:
          out[_kMaxCompletionTokens] = e.value;
          break;
        default:
          out[e.key] = e.value;
      }
    }
    return out;
  }

  if (_isMistralHost(baseUrl)) {
    final out = <String, dynamic>{};
    for (final e in body.entries) {
      if (_extendedSamplers.contains(e.key)) continue; // 422 on these
      // Drop unknown "extra" fields Mistral's strict validator rejects.
      // `max_completion_tokens` is also dropped here (Mistral wants
      // `max_tokens`) since it's not in the standard set.
      if (!_openAiStandardFields.contains(e.key)) continue;
      out[e.key] = e.value;
    }
    return out;
  }

  // Default / unknown / permissive — unchanged.
  return body;
}

/// LOW F9 — OpenRouter's newer streaming reasoning shape is
/// `delta.reasoning_details: [...]` (an array of typed parts) instead of (or
/// in addition to) the flat `delta.reasoning` string. Routes that emit ONLY
/// the array would drop the reasoning channel entirely.
///
/// Concatenate every part's `.text` then `.summary` (in array order) into one
/// string for the `<think>` channel. Parts with neither (e.g. encrypted
/// reasoning blobs) are skipped. Returns null for a non-list, empty, or
/// all-empty input so the caller can fall back to the flat fields.
String? extractReasoningDetailsText(Object? details) {
  if (details is! List || details.isEmpty) return null;
  final buf = StringBuffer();
  for (final part in details) {
    if (part is! Map) continue;
    final text = part['text'];
    if (text is String && text.isNotEmpty) {
      buf.write(text);
      continue;
    }
    final summary = part['summary'];
    if (summary is String && summary.isNotEmpty) {
      buf.write(summary);
    }
  }
  final s = buf.toString();
  return s.isEmpty ? null : s;
}
