// OpenAI-compatible /v1/chat/completions client with SSE streaming.
// Mirrors js/api.js — keeps prompt construction caller-side (the chat screen
// composes the system prompt + history before calling here).

import 'dart:async';
import 'dart:convert';
// Wave CY.18.46: dart:io doesn't exist on Flutter Web. We import it
// only for `SocketException` (used as a typed marker in
// `_classifyNetworkError`) and ONLY guard the runtime check with
// `e is SocketException`. The companion string-match fallback below
// catches the same condition on web (where SocketException isn't a
// thing) by looking at `e.toString()`. So the import stays needed on
// desktop + mobile and the future web build will swap to a conditional
// (`if (dart.library.io) 'dart:io' show SocketException;`) once the
// web target is actually enabled. For now, desktop + mobile only.
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'lan_client.dart';
import 'llm_debug_log.dart';

typedef ChatRole = String; // 'system' | 'user' | 'assistant'

class ChatTurn {
  final ChatRole role;
  final String content;
  /// Optional image data URLs (`data:image/<fmt>;base64,...`). When
  /// present, the message is serialised in OpenAI's multimodal
  /// content-array form so vision-capable models can see the image.
  /// Plain-text-only models will reject the request — that's the
  /// signal to the user that they need a vision-capable provider.
  final List<String>? imageDataUrls;
  ChatTurn(this.role, this.content, {this.imageDataUrls});

  Map<String, dynamic> toJson() {
    final images = imageDataUrls;
    if (images == null || images.isEmpty) {
      return {'role': role, 'content': content};
    }
    return {
      'role': role,
      'content': [
        if (content.isNotEmpty) {'type': 'text', 'text': content},
        for (final url in images)
          {'type': 'image_url', 'image_url': {'url': url}},
      ],
    };
  }
}

/// Wave CY.18.45: classify failure modes so the UI can pick the right
/// message. Pre-Wave every failure was a generic `ChatApiError` and the
/// chat screen showed the raw `toString()` to the user — which for a
/// `SocketException` reads "SocketException: Failed host lookup: ..."
/// in console-speak. Users on flaky mobile connections couldn't tell
/// "API server returned 500" (their provider's problem) from "your
/// phone has no internet" (their own connection). Now: callers
/// translate the typed kind into a human snackbar.
enum ChatApiErrorKind {
  /// No connection at all — DNS lookup failed, no route to host, etc.
  /// User should check wifi/data, then retry.
  offline,
  /// Connection established but the server didn't respond in time, OR
  /// the stream stalled mid-flight. Likely a flaky network or an
  /// overloaded provider. Retry usually fixes it.
  timeout,
  /// Server responded with a 4xx / 5xx, or returned a malformed body.
  /// User probably has a misconfigured provider (wrong URL, bad
  /// API key, model name doesn't exist).
  server,
  /// Anything we couldn't classify — fallback bucket. Treated like
  /// `server` in the UI but worth a separate slot for diagnostics.
  other,
}

class ChatApiError implements Exception {
  final int? statusCode;
  final String message;
  /// Wave CY.18.45: see [ChatApiErrorKind].
  final ChatApiErrorKind kind;
  ChatApiError(
    this.message, {
    this.statusCode,
    this.kind = ChatApiErrorKind.server,
  });

  /// Convenience factory for "DNS failed / no route / connection
  /// refused". Used by the network-error wrappers around the http
  /// calls.
  factory ChatApiError.offline([String? message]) => ChatApiError(
        message ??
            'You appear to be offline. Check your connection and try '
                'again.',
        kind: ChatApiErrorKind.offline,
      );

  /// Convenience factory for "server didn't respond in time".
  factory ChatApiError.timeout([String? message]) => ChatApiError(
        message ?? 'The request timed out. The server may be busy.',
        kind: ChatApiErrorKind.timeout,
      );

  @override
  String toString() => 'ChatApiError($statusCode): $message';
}

/// Wave CY.18.45: classify a raw exception thrown anywhere inside the
/// HTTP / SSE pipeline into a [ChatApiError] with the right kind.
/// Pass it the original `Object e` from a `try { ... } catch (e)`
/// block; it returns the ChatApiError to rethrow.
ChatApiError _classifyNetworkError(Object e) {
  // Already classified — just bubble.
  if (e is ChatApiError) return e;
  final s = e.toString();
  // SocketException covers DNS-fail, connection refused, no route to
  // host, etc. Dart's `package:http` also wraps these in
  // `http.ClientException` on some platforms — match by class name +
  // message text since neither type is imported here cleanly.
  final lower = s.toLowerCase();
  if (e is SocketException ||
      lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('connection failed') ||
      lower.contains('network is unreachable') ||
      lower.contains('no address associated')) {
    return ChatApiError.offline();
  }
  if (e is TimeoutException ||
      lower.contains('timeoutexception') ||
      lower.contains('timed out') ||
      lower.contains('deadline exceeded')) {
    return ChatApiError.timeout();
  }
  // Anything else — keep the original toString so debug logs stay
  // informative, but mark as `other` so the UI doesn't dress it up
  // with an offline-style message.
  return ChatApiError(s, kind: ChatApiErrorKind.other);
}

/// Wave CY.1: scrub provider error bodies before surfacing them. Some
/// proxies (and misconfigured OpenAI-compat servers) reflect the
/// `Authorization: Bearer …` header into their 4xx response body. Same
/// goes for `x-api-key` and a few other token-shaped headers seen in
/// the wild. If that body lands in a Snackbar / exception toString /
/// chat warning, the key is on-screen, screenshottable, and one paste
/// away from leaking. This redacts both the `Bearer …` form and bare
/// token shapes (the long base64/hex strings providers tend to issue).
String _scrubProviderBody(String body) {
  if (body.isEmpty) return body;
  var s = body;
  // `Bearer <token>` (any whitespace, any token chars).
  s = s.replaceAll(
    RegExp(r'[Bb]earer\s+[A-Za-z0-9._\-]{8,}'),
    'Bearer [redacted]',
  );
  // Raw header echoes: `Authorization: ...` / `x-api-key: ...` /
  // `api-key: ...` / `OpenAI-Organization: ...` until end-of-line.
  // Dart's RegExp has no `(?i)` inline flag — pass `caseSensitive`
  // explicitly. And `replaceAll(regex, String)` treats the replacement
  // as a literal, so use `replaceAllMapped` to keep the matched
  // header name in the redacted output.
  s = s.replaceAllMapped(
    RegExp(
      r'(authorization|x-api-key|api[_-]?key|openai-organization)\s*[:=]\s*[^\s",}]+',
      caseSensitive: false,
    ),
    (m) => '${m[1]}: [redacted]',
  );
  // Standalone OpenAI-style `sk-` / `sk_live_` / `pk_` etc. tokens that
  // slipped through any structured field in the error JSON.
  s = s.replaceAll(
    RegExp(r'\b(sk|sk_live|sk_test|pk_live|pk_test|or)[\-_][A-Za-z0-9]{16,}\b'),
    '[redacted-token]',
  );
  return s;
}

/// Merge sampling values from a preset on top of the global ModelSettings,
/// SillyTavern-style: each preset field is an OPTIONAL override. A null on
/// the preset means "use the user's global default"; a non-null wins.
///
/// Returns a plain `{key: value}` map ready to spread into the request
/// payload. Fields that the model server doesn't recognise are silently
/// ignored on its end — we just send everything we know about so providers
/// that support more params (OpenRouter, Soji, etc.) get to use them.
Map<String, dynamic> _samplingPayload(ModelSettings settings, Preset? preset) {
  // For temp/top_p/max_tokens we always send a value — fall back to the
  // global setting. For the rest we ONLY include them when something
  // actually sets them; otherwise we let the server use its defaults.
  final temp = preset?.temperature ?? settings.temperature;
  final topP = preset?.topP ?? settings.topP;
  final maxTokens = preset?.maxTokens ?? settings.maxTokens;
  // top_k: preset wins, else global (0 = disabled on our slider).
  final topK = preset?.topK ?? settings.topK;
  final out = <String, dynamic>{
    'temperature': temp,
    'top_p': topP,
    'max_tokens': maxTokens,
    if (topK != 0) 'top_k': topK,
  };
  // Pure preset-only fields — only include if set.
  if (preset?.frequencyPenalty != null) {
    out['frequency_penalty'] = preset!.frequencyPenalty;
  }
  if (preset?.presencePenalty != null) {
    out['presence_penalty'] = preset!.presencePenalty;
  }
  if (preset?.minP != null) out['min_p'] = preset!.minP;
  if (preset?.topA != null) out['top_a'] = preset!.topA;
  if (preset?.repetitionPenalty != null) {
    out['repetition_penalty'] = preset!.repetitionPenalty;
  }
  return out;
}

// Wave CY.18.120: kind-aware timeouts for LOCAL providers (LM Studio /
// Ollama). A cold local server doesn't send HTTP response headers until
// the model finishes its JIT load off disk — a 7B–70B model on a spinning
// disk or a busy machine can take well over a minute before the first byte
// comes back. The default 25s/45s/75s windows (great for hosted APIs that
// respond in ms) would time that out before it ever started. These widened
// windows ONLY apply when `provider.kind == ProviderKind.localhost`; every
// non-local provider keeps the original tight timeouts unchanged.
//  - connect:        4 min for the first response headers (covers a slow
//                    cold JIT load + TCP/TLS handshake).
//  - inter-chunk:    2 min of zero data once the SSE stream is open.
//  - one-shot total: 5 min for a full non-streamed completion.
const Duration _kLocalConnectTimeout = Duration(seconds: 240);
const Duration _kLocalStreamStallTimeout = Duration(seconds: 120);
const Duration _kLocalCompleteTimeout = Duration(seconds: 300);

/// Build the OpenAI-style chat-completions request body. Extracted so it is
/// unit-testable and so the structured-output pipeline can inject
/// `response_format` via [extraBody]. [extraBody] is spread LAST, so it
/// overrides a stale `response_format` (etc.) coming from
/// `provider.extraParams`. When [extraBody] is null this is byte-identical to
/// the previous inline body. The apiKey is NEVER in the body (it rides the
/// Authorization header), so this map is safe to log.
Map<String, dynamic> buildRequestBody({
  required ApiProvider provider,
  required ModelSettings settings,
  required List<ChatTurn> messages,
  Preset? preset,
  List<String>? stop,
  required bool stream,
  Map<String, dynamic>? extraBody,
}) {
  return <String, dynamic>{
    // Per-provider extra params come FIRST so Pyre-managed fields
    // (model, messages, stream, sampling) win on any conflict. The
    // user can still inject orthogonal params here (reasoning toggle,
    // safety_filter, etc.) without breaking the core request shape.
    ...provider.extraParams,
    'model': provider.model,
    'messages': messages.map((m) => m.toJson()).toList(),
    ..._samplingPayload(settings, preset),
    if (stop != null && stop.isNotEmpty) 'stop': stop,
    'stream': stream,
    ...?extraBody,
  };
}

/// Streams partial completions as they arrive. The returned stream yields
/// incremental text chunks (not the cumulative buffer). Cancel the
/// subscription to abort the request.
///
/// [stop] is an optional list of stop sequences forwarded to the provider
/// via OpenAI's `stop` parameter. When the model emits any of these
/// strings, the server cuts off generation IMMEDIATELY at the boundary.
/// This is how the Character Creator enforces its per-block emission
/// discipline — the prompt tells the model to write `<<BLOCK_END>>`
/// after each block, and the server hard-stops there even when the
/// model "wants" to keep barrelling through into the next block.
/// Without this, prompt instructions alone can't override the model's
/// trained instinct to complete the whole task in one turn.
Stream<String> streamChatCompletion({
  required ApiProvider provider,
  required ModelSettings settings,
  required List<ChatTurn> messages,
  Preset? preset,
  List<String>? stop,
  // Wave CY.18.214: opt-in diagnostics tag. When the LlmDebugLog is
  // enabled, the request body (KEY-FREE — see below) + the assembled
  // response + duration are recorded to a local JSONL under this feature
  // tag (`chat`, `ltm`, `livesheet`, `creator-architect`, `creator-vision`,
  // `scene`). When null OR the log is disabled it is a STRICT no-op: we
  // never build a record, never touch disk, zero overhead on the hot path.
  String? debugTag,
  // Extra request-body fields spread LAST onto the assembled body — the
  // structured-output pipeline injects `response_format: {type:
  // 'json_object'}` here. Null = byte-identical to the previous body.
  Map<String, dynamic>? extraBody,
}) async* {
  // Wave CY.18.71: web/PWA proxy mode. When running in a browser tab
  // that's paired to a desktop Pyre server, we don't call the upstream
  // LLM directly (CORS + no SecureKeys would mean exposing API keys in
  // JS). Instead we POST to `/llm/stream` on the paired server, which
  // makes the upstream call with ITS own SecureKeys-stored API key and
  // streams the tokens back as SSE. Text-only path — vision attachments
  // and reasoning don't round-trip cleanly through the proxy yet (Wave
  // 72+ follow-up). Native builds skip this entirely.
  if (kIsWeb && LanClient.instance.isPaired) {
    yield* _streamViaLanProxy(
      provider: provider,
      messages: messages,
      stop: stop,
    );
    return;
  }
  if (provider.baseUrl.isEmpty) {
    throw ChatApiError('Provider has no baseUrl configured');
  }
  final url = Uri.parse(buildChatUrl(provider.baseUrl, 'chat/completions'));

  final body = buildRequestBody(
    provider: provider,
    settings: settings,
    messages: messages,
    preset: preset,
    stop: stop,
    stream: true,
    extraBody: extraBody,
  );

  // Wave CY.18.214: capture for the diagnostics log. The `body` map above
  // is KEY-FREE by construction — the apiKey is set on the Authorization
  // header below, never in the body — so we can log it as-is. We snapshot
  // the timing + accumulate the yielded text and the captured finish
  // reason, then write ONE record when the stream completes (success OR
  // error). Guarded so it's a strict no-op when the log is off / untagged.
  final bool shouldLog = debugTag != null && LlmDebugLog.instance.enabled;
  final Stopwatch? logSw = shouldLog ? (Stopwatch()..start()) : null;
  final StringBuffer? logBuf = shouldLog ? StringBuffer() : null;
  String? logFinishReason;
  // Emits the captured record exactly once; never throws into the stream.
  var logDone = false;
  void emitDebugRecord({String? parseOutcome}) {
    if (!shouldLog || logDone) return;
    logDone = true;
    try {
      LlmDebugLog.instance.record(LlmCallRecord(
        ts: DateTime.now().millisecondsSinceEpoch,
        feature: debugTag,
        provider: provider.name,
        model: provider.model,
        messages: (body['messages'] as List?) ?? const <dynamic>[],
        sampling: <String, dynamic>{
          for (final e in body.entries)
            if (e.key != 'messages') e.key: e.value,
        },
        response: logBuf?.toString() ?? '',
        finishReason: logFinishReason,
        durationMs: logSw?.elapsedMilliseconds ?? 0,
        parseOutcome: parseOutcome,
      ));
    } catch (_) {
      // Never let diagnostics break a generation.
    }
  }

  final req = http.Request('POST', url);
  req.headers.addAll({
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
    if (provider.apiKey.isNotEmpty) 'Authorization': 'Bearer ${provider.apiKey}',
    ..._sanitiseHeaders(provider.headers),
  });
  req.body = jsonEncode(body);

  final client = http.Client();
  try {
    // Wave CY.18.6: explicit timeouts so a silent stall surfaces as a
    // real error instead of leaving the chat bubble stuck on
    // "Generating…" forever. Real API errors (4xx/5xx) come back in
    // milliseconds — these timeouts are ONLY for the pathological
    // case where the connection is open but the server has gone
    // silent (network drop without RST, hung proxy, dead worker).
    //  - connect window: 25s for response headers (TCP + TLS +
    //    request + provider routing all together — way more than
    //    healthy servers need; reasoning latency hits AFTER headers).
    //  - inter-chunk window: 45s of zero data once streaming is open.
    // Both surface as ChatApiError → propagates through the listener's
    // onError → _finishWithError → user-visible snackbar with Retry.
    // Wave CY.18.45: classify any raw network / DNS / connection-refused
    // exception into a typed `ChatApiError` BEFORE it bubbles out of the
    // try/finally. Without this the chat screen got the raw
    // SocketException toString ("Failed host lookup: ...") in a snackbar
    // and the user couldn't tell if their phone was offline or the
    // provider URL was wrong. Now: `kind: ChatApiErrorKind.offline` for
    // DNS/no-route, `timeout` for stalls, `server` for HTTP 4xx/5xx,
    // and the UI renders a friendly message per kind.
    final http.StreamedResponse resp;
    try {
      // Wave CY.18.120: local servers get a much longer connect window
      // because a cold model can JIT-load for minutes before sending any
      // response headers; hosted providers keep the tight 25s window.
      resp = await client.send(req).timeout(
        provider.kind == ProviderKind.localhost
            ? _kLocalConnectTimeout
            : const Duration(seconds: 25),
        onTimeout: () => throw ChatApiError.timeout(
            'Timed out connecting to the provider. For local servers a '
            'model may still be loading; check the server and try again.'),
      );
    } catch (e) {
      throw _classifyNetworkError(e);
    }
    if (resp.statusCode >= 400) {
      final errBody = await resp.stream.bytesToString();
      // Wave CY.1: redact any leaked auth token/header before
      // surfacing — the body is displayed in Snackbars / chat
      // warnings.
      throw ChatApiError(
        _scrubProviderBody(errBody),
        statusCode: resp.statusCode,
      );
    }

    // Some providers silently ignore `stream: true` and return a
    // regular JSON body. Detect this via Content-Type and fall back
    // to one-shot parsing so the caller still gets the response.
    // We only switch to JSON when the type is EXPLICITLY application/
    // json — missing / generic types still try SSE first.
    final contentType =
        (resp.headers['content-type'] ?? '').toLowerCase();
    final isJson = contentType.contains('application/json');
    if (isJson) {
      // NOTE: named `jsonBody`, not `body`, to avoid shadowing the outer
      // request `body` map that the `emitDebugRecord` diagnostics closure
      // captures by lexical scope (Wave CY.18.214 code review MINOR-2).
      //
      // Bound the body read with the same kind-aware stall window the SSE
      // branch applies to each chunk. A provider that ignores `stream:true`
      // and returns a single JSON body could otherwise hold the socket open
      // indefinitely (e.g. a model that hangs after sending headers) with no
      // timeout at all, unlike the SSE path. Local servers get the longer
      // window (a cold model can be slow to produce the full body); cloud
      // keeps the tight 45s.
      final jsonBody = await resp.stream.bytesToString().timeout(
            provider.kind == ProviderKind.localhost
                ? _kLocalStreamStallTimeout
                : const Duration(seconds: 45),
            onTimeout: () => throw ChatApiError.timeout(
                'The provider returned a non-streamed response but stopped '
                'sending data before the body finished. The connection is '
                'open but the model has stopped responding.'),
          );
      try {
        final obj = jsonDecode(jsonBody);
        final choices = obj['choices'];
        if (choices is List && choices.isNotEmpty) {
          final msg = choices[0]['message'];
          if (msg is Map) {
            // Wrap reasoning content in <think> tags so the existing
            // ChatText reasoning toggle hides it by default but the
            // user can opt to see it.
            //
            // Wave BT: providers disagree on the field name —
            //   - DeepSeek native / R1-style: `reasoning_content`
            //   - OpenRouter (normalized): `reasoning`
            //   - Some Qwen routes: also `reasoning`
            // Read both so we don't silently drop reasoning tokens on
            // a route that uses the shorter name. Dropping them
            // manifested as "model returns empty" in the user's
            // OpenRouter→DeepSeek V4 Pro setup (Wave BS trail proved
            // the buffer reached `_streamArchitectTurn` empty — the
            // reasoning was already lost upstream of that point).
            final reasoning = (msg['reasoning_content'] is String &&
                    (msg['reasoning_content'] as String).isNotEmpty)
                ? msg['reasoning_content'] as String
                : (msg['reasoning'] is String &&
                        (msg['reasoning'] as String).isNotEmpty)
                    ? msg['reasoning'] as String
                    : null;
            if (reasoning != null) {
              logBuf?.write('<think>$reasoning</think>');
              yield '<think>$reasoning</think>';
            }
            final content = msg['content'];
            if (content is String && content.isNotEmpty) {
              logBuf?.write(content);
              yield content;
            }
          }
          // Wave BY: surface finish_reason from the one-shot path too
          // so callers can discriminate clean stops from truncation
          // regardless of which streaming mode the provider used.
          final fr = choices[0]['finish_reason'];
          if (fr is String && fr.isNotEmpty) {
            logFinishReason = fr;
            yield '$pyreFinishSentinelOpen$fr$pyreFinishSentinelClose';
          }
        }
      } catch (e) {
        throw ChatApiError(
            'Non-SSE response and JSON parse failed: $e\n\nBody:\n${_scrubProviderBody(jsonBody)}');
      }
      return;
    }

    // SSE path. Some chunks may contain `delta.content` (visible
    // tokens), others reasoning tokens. We emit both, wrapping
    // reasoning in <think> tags so the existing ChatText filter can
    // hide it by default.
    //
    // Wave BT: providers disagree on the reasoning field name —
    //   - DeepSeek native / R1-style: `delta.reasoning_content`
    //   - OpenRouter (normalized): `delta.reasoning`
    //   - Some Qwen routes: also `delta.reasoning`
    // Read both. Without this fallback the OpenRouter→DeepSeek V4 Pro
    // route streamed all reasoning into `delta.reasoning` which we
    // dropped, leaving the caller with an empty response and triggering
    // the Wave BR no-stop fallback in a loop. The user's Wave BS trail
    // pinpointed this exact failure mode.
    // Wave CY.18.6: inter-chunk idle timeout. Once headers arrived
    // and the SSE stream is open, the model needs time to produce
    // the first chunk (reasoning models think for a while) — but
    // after THAT first chunk, gaps of 45s mean the stream is dead.
    // The .timeout() Stream extension applies a sliding window to
    // EACH expected event, so the first window covers "headers → first
    // chunk" (reasoning latency) and subsequent windows cover gaps
    // between chunks. 45s is roomy enough for any sane reasoning model
    // and tight enough to surface real stalls before the user gives up.
    // Wave CY.18.120: local servers get a longer inter-chunk window too —
    // a cold model can have a long gap between the headers and the first
    // token even after the connection opens; hosted providers keep 45s.
    final lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(
      provider.kind == ProviderKind.localhost
          ? _kLocalStreamStallTimeout
          : const Duration(seconds: 45),
      onTimeout: (sink) {
        sink.addError(ChatApiError(
            'Stream stalled — no data from the server for a while. '
            'The connection is open but the model has stopped responding.'));
        sink.close();
      },
    );
    var openedThink = false;
    // Wave BY: capture finish_reason as it arrives — last non-null
    // value wins. The OpenAI spec puts it on the final SSE delta
    // (where content is empty); some providers emit it on multiple
    // chunks. Streaming completes via [DONE] or end-of-stream.
    String? capturedFinishReason;
    // Wave CY.18.42: count frames we couldn't parse instead of
    // swallowing them silently. A single dropped frame is harmless
    // SSE noise (keepalive comment, stray whitespace, etc.) but
    // dozens of them mean the model's actual content is going to
    // /dev/null without any user-visible signal. We emit the count
    // as a sentinel at stream end so the caller can render a
    // "stream had N parse errors" warning.
    var droppedFrames = 0;
    Object? lastDropError;
    await for (final line in lines) {
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') break;
      try {
        final obj = jsonDecode(payload);
        final choices = obj['choices'];
        if (choices is List && choices.isNotEmpty) {
          // Wave BY: finish_reason sits on the choice (sibling of
          // `delta`), not inside it. Capture every non-null value;
          // the model emits it on the final chunk for clean stops
          // and on the same chunk as the truncation for length cuts.
          final fr = choices[0]['finish_reason'];
          if (fr is String && fr.isNotEmpty) {
            capturedFinishReason = fr;
          }
          final delta = choices[0]['delta'];
          if (delta is Map) {
            // Try both field names — prefer `reasoning_content` (more
            // explicit / DeepSeek-native) and fall back to `reasoning`
            // (OpenRouter-normalized).
            final rcRaw = delta['reasoning_content'];
            final rRaw = delta['reasoning'];
            final reasoning = (rcRaw is String && rcRaw.isNotEmpty)
                ? rcRaw
                : (rRaw is String && rRaw.isNotEmpty)
                    ? rRaw
                    : null;
            if (reasoning != null) {
              if (!openedThink) {
                logBuf?.write('<think>');
                yield '<think>';
                openedThink = true;
              }
              logBuf?.write(reasoning);
              yield reasoning;
            }
            final piece = delta['content'];
            if (piece is String && piece.isNotEmpty) {
              if (openedThink) {
                logBuf?.write('</think>');
                yield '</think>';
                openedThink = false;
              }
              logBuf?.write(piece);
              yield piece;
            }
          }
        }
      } catch (e) {
        // Wave CY.18.42: keep streaming, but count the failure so we
        // can surface it at end-of-stream. A frame we couldn't parse
        // is a frame whose content the user never sees — historically
        // (Wave BT debugging) this is exactly the kind of failure
        // that produced empty assistant turns + retry loops without
        // any in-app diagnostic. The last error is preserved to
        // include in the sentinel for triage.
        droppedFrames += 1;
        lastDropError = e;
      }
    }
    if (openedThink) {
      // Stream ended mid-reasoning (model never produced visible
      // content). Close the tag so the regex in ChatText can hide it.
      yield '</think>';
    }
    // Wave CY.18.42: emit dropped-frame count BEFORE the finish_reason
    // sentinel so the caller can render both. The sanitiser strips it
    // alongside the other Pyre sentinels (see pyreDroppedFramesRegex).
    if (droppedFrames > 0) {
      // ignore: avoid_print
      // Include the last error type in the sentinel so the user
      // can tell "120 keepalive blanks" from "120 JSON parse fails".
      final errKind = lastDropError == null
          ? 'unknown'
          : lastDropError.runtimeType.toString();
      yield '$pyreDroppedFramesSentinelOpen$droppedFrames:$errKind$pyreDroppedFramesSentinelClose';
    }
    // Wave BY: emit the captured finish_reason as a sentinel chunk so
    // the caller can discriminate `stop` (clean — server cut on our
    // stop sequence OR model emitted EOS) from `length` (truncated by
    // max_tokens). The sanitiser strips this marker before display so
    // it never leaks into the brief.
    if (capturedFinishReason != null) {
      logFinishReason = capturedFinishReason;
      yield '$pyreFinishSentinelOpen$capturedFinishReason$pyreFinishSentinelClose';
    }
  } finally {
    client.close();
    // Wave CY.18.214: write the diagnostics record exactly once, AFTER the
    // stream finishes for any reason (clean end, early return, thrown
    // error, or the consumer cancelling the subscription). `finally` in a
    // generator runs on all of those, and emitDebugRecord is itself
    // idempotent + swallows its own errors, so this never affects the
    // generation. No-op when the log is off / untagged.
    emitDebugRecord();
  }
}

/// Wave BY: sentinels that wrap a finish_reason value emitted at
/// stream end. The strings are deliberately ugly so they won't
/// collide with anything a model might naturally emit; the caller
/// scans for them in the buffer and strips them before display.
/// Format: `<<__PYRE_FINISH__:length__>>` or `<<__PYRE_FINISH__:stop__>>`.
const String pyreFinishSentinelOpen = '<<__PYRE_FINISH__:';
const String pyreFinishSentinelClose = '__>>';

/// Wave BY: regex that matches the finish-reason sentinel in a buffer
/// and exposes its `value` capture group. Used by the sanitiser to
/// strip the sentinel before rendering, and by callers that want to
/// read the captured reason.
final RegExp pyreFinishSentinelRegex = RegExp(
    r'<<__PYRE_FINISH__:([a-z_]+)__>>',
    caseSensitive: false);

/// Wave CY.18.42: dropped-frame sentinel. Emitted at end-of-stream
/// when one or more SSE frames couldn't be parsed. Format:
/// `<<__PYRE_DROPPED__:42:FormatException__>>` — count then error
/// type, colon-separated. The sanitiser strips it; callers that want
/// to surface a warning extract count + kind via the regex.
const String pyreDroppedFramesSentinelOpen = '<<__PYRE_DROPPED__:';
const String pyreDroppedFramesSentinelClose = '__>>';

/// Matches the dropped-frames sentinel. Capture 1 is count, capture 2
/// is the runtime type of the last drop error.
final RegExp pyreDroppedFramesRegex = RegExp(
    r'<<__PYRE_DROPPED__:(\d+):([A-Za-z_][A-Za-z0-9_]*)__>>',
    caseSensitive: false);

/// One-shot (non-streamed) completion. Returns the full assistant text.
/// [stop] mirrors the streaming variant — see [streamChatCompletion].
Future<String> completeChat({
  required ApiProvider provider,
  required ModelSettings settings,
  required List<ChatTurn> messages,
  Preset? preset,
  List<String>? stop,
  // Wave CY.18.214: opt-in diagnostics tag (e.g. `creator-vision`). The
  // one-shot path is a DIFFERENT transport from streamChatCompletion, so
  // it carries its own capture point. KEY-FREE: the body below holds no
  // apiKey (it rides the Authorization header). Strict no-op when off.
  String? debugTag,
  // Wave CY.18.236: extra top-level request-body fields (e.g.
  // `response_format` for the structured Creator build), spread LAST so they
  // override a stale `provider.extraParams` entry. Null for all existing
  // callers → byte-identical body. The structured build prefers this
  // NON-streaming path: a reasoning model (DeepSeek-v4-pro) can think for far
  // longer than the streaming inter-chunk stall window before emitting its
  // first content token, which intermittently aborts the stream to empty;
  // one-shot waits for the whole response instead.
  Map<String, dynamic>? extraBody,
}) async {
  if (provider.baseUrl.isEmpty) {
    throw ChatApiError('Provider has no baseUrl configured');
  }
  final url = Uri.parse(buildChatUrl(provider.baseUrl, 'chat/completions'));
  // Wave CY.18.214: build the body once so the diagnostics hook can log
  // the exact request (key-free). Guard so it's a strict no-op when off.
  final bool shouldLog = debugTag != null && LlmDebugLog.instance.enabled;
  final Stopwatch? logSw = shouldLog ? (Stopwatch()..start()) : null;
  final reqBody = <String, dynamic>{
    ...provider.extraParams,
    'model': provider.model,
    'messages': messages.map((m) => m.toJson()).toList(),
    ..._samplingPayload(settings, preset),
    if (stop != null && stop.isNotEmpty) 'stop': stop,
    'stream': false,
    ...?extraBody,
  };
  void emitDebugRecord({
    required String response,
    String? finishReason,
    String? parseOutcome,
  }) {
    if (!shouldLog) return;
    try {
      LlmDebugLog.instance.record(LlmCallRecord(
        ts: DateTime.now().millisecondsSinceEpoch,
        feature: debugTag,
        provider: provider.name,
        model: provider.model,
        messages: (reqBody['messages'] as List?) ?? const <dynamic>[],
        sampling: <String, dynamic>{
          for (final e in reqBody.entries)
            if (e.key != 'messages') e.key: e.value,
        },
        response: response,
        finishReason: finishReason,
        durationMs: logSw?.elapsedMilliseconds ?? 0,
        parseOutcome: parseOutcome,
      ));
    } catch (_) {
      // Never let diagnostics break a generation.
    }
  }
  // Wave CY.18.6: hard timeout on the one-shot completion. Used by
  // the long-term memory summariser (fire-and-forget after each
  // message). 75s covers a slow reasoning model writing a 2-3
  // paragraph recap with plenty of margin; a hang past that is the
  // server being broken, not "still thinking".
  // Wave CY.18.45: classify offline / DNS / timeout vs server errors —
  // see the matching wrapper in the streaming path. The one-shot route
  // is used by the memory summariser fire-and-forget; without this an
  // offline auto-summarise leaks `SocketException: Failed host lookup`
  // into MemoryErrors.log and the user sees console-speak gibberish
  // instead of a clean "looks like the device is offline" entry.
  final http.Response resp;
  try {
    resp = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        if (provider.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${provider.apiKey}',
        ..._sanitiseHeaders(provider.headers),
      },
      body: jsonEncode(reqBody),
    ).timeout(
      // Wave CY.18.120: local servers get a 5-minute one-shot window for a
      // cold model load; hosted providers keep the original 75s.
      provider.kind == ProviderKind.localhost
          ? _kLocalCompleteTimeout
          : const Duration(seconds: 75),
      onTimeout: () => throw ChatApiError.timeout(
          'Request timed out. The model never produced a response (a local '
          'server may still be loading the model).'),
    );
  } catch (e) {
    // Wave CY.18.214: record the failed call (empty response + the error
    // as the parse outcome) before rethrowing, so the diagnostics log
    // shows attempts that never produced a body too.
    final classified = _classifyNetworkError(e);
    emitDebugRecord(response: '', parseOutcome: 'error: $classified');
    throw classified;
  }
  if (resp.statusCode >= 400) {
    emitDebugRecord(
        response: '', parseOutcome: 'http ${resp.statusCode}');
    throw ChatApiError(_scrubProviderBody(resp.body),
        statusCode: resp.statusCode);
  }
  final obj = jsonDecode(resp.body);
  final choices = obj['choices'];
  if (choices is List && choices.isNotEmpty) {
    final msg = choices[0]['message'];
    final fr = choices[0]['finish_reason'];
    if (msg is Map) {
      final text = extractCompletionMessageText(msg);
      emitDebugRecord(
        response: text,
        finishReason: fr is String && fr.isNotEmpty ? fr : null,
      );
      return text;
    }
  }
  emitDebugRecord(response: '', parseOutcome: 'no choices');
  return '';
}

/// Wave CY.18.160: run a chat completion to completion over the STREAMING
/// transport and return the full assembled text, with Pyre's internal
/// stream sentinels + reasoning stripped.
///
/// WHY a second "complete" entry point: the long-term-memory summariser
/// used the one-shot [completeChat] (`stream:false`). That request shape
/// is a DIFFERENT code path from the live chat (which always streams), and
/// some providers handle it differently — Chub/Soji in particular returned
/// nothing usable on `stream:false`, so the summariser silently produced no
/// checkpoint while the chat itself worked fine. This variant reuses the
/// EXACT [streamChatCompletion] transport the chat uses, so it succeeds on
/// every provider the chat succeeds on, and inherits its JSON-fallback,
/// reasoning handling, web/LAN-proxy routing, and timeouts for free.
Future<String> completeChatStreamed({
  required ApiProvider provider,
  required ModelSettings settings,
  required List<ChatTurn> messages,
  List<String>? stop,
  // Wave CY.18.214: threaded straight through to streamChatCompletion,
  // which owns the single capture point. Logging this variant here too
  // would double-record, so we DON'T — the underlying stream records once.
  String? debugTag,
  // Forwarded to streamChatCompletion (structured-output `response_format`).
  Map<String, dynamic>? extraBody,
  // Optional out-sink for the REASONING-INCLUSIVE text: the same accumulated
  // stream with Pyre's internal sentinels stripped but the `<think>…</think>`
  // reasoning channel PRESERVED. The normal return value still strips
  // reasoning. The Creator's structured build uses this to recover a JSON
  // object that a reasoning model emitted in its reasoning channel (so
  // `content` — and thus the return value — comes back empty). Null = no-op,
  // so every other caller is byte-identical.
  StringBuffer? rawSink,
}) async {
  final buf = StringBuffer();
  await for (final chunk in streamChatCompletion(
    provider: provider,
    settings: settings,
    messages: messages,
    stop: stop,
    debugTag: debugTag,
    extraBody: extraBody,
  )) {
    buf.write(chunk);
  }
  final raw = buf.toString();
  if (rawSink != null) {
    // Strip only the Pyre sentinels — keep `<think>` so the build can scan the
    // reasoning channel for a JSON object the model put there.
    rawSink.write(raw
        .replaceAll(pyreFinishSentinelRegex, '')
        .replaceAll(pyreDroppedFramesRegex, ''));
  }
  return stripStreamArtifacts(raw);
}

/// Strip Pyre's internal streaming sentinels (finish-reason, dropped-frame)
/// and any `<think>…</think>` reasoning from accumulated stream text,
/// leaving just the model's prose. Pure + testable.
String stripStreamArtifacts(String raw) => _stripThinkBlocks(raw
    .replaceAll(pyreFinishSentinelRegex, '')
    .replaceAll(pyreDroppedFramesRegex, ''));

// Regexes for the one-shot completion text extraction. Mirror
// ChatText.stripReasoning (widgets/chat_text.dart) but live here so the
// service layer doesn't import Flutter material. Kept in sync deliberately.
final RegExp _completionThinkBlock =
    RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false, multiLine: true);
final RegExp _completionDanglingThink =
    RegExp(r'<think>[\s\S]*$', caseSensitive: false, multiLine: true);

/// Strip every complete `<think>…</think>` block plus a dangling open tail
/// from a one-shot completion. Pure; mirrors ChatText.stripReasoning.
String _stripThinkBlocks(String body) => body
    .replaceAll(_completionThinkBlock, '')
    .replaceAll(_completionDanglingThink, '')
    .trim();

/// Wave CY.18.160: extract usable text from a non-streaming
/// `choices[0].message`, reasoning-aware.
///
/// The streaming path (the SSE / JSON-fallback branch above) already reads
/// the reasoning channel — `reasoning_content` (DeepSeek/R1) or `reasoning`
/// (OpenRouter / some Qwen routes) — but the one-shot `completeChat` only
/// ever read `content`. For a reasoning model that spends its token budget
/// in the reasoning channel (e.g. Venice's uncensored Qwen, whose
/// uncensoring rides ON the reasoning phase) `content` comes back EMPTY,
/// so the LTM auto-summariser (which calls completeChat) silently got ''
/// → "empty summary" → null checkpoint → nothing ever fired. Vision
/// (`describeCharacterImage`) hit the same blind spot.
///
/// Strategy:
///  1. Prefer `content` with any inline `<think>…</think>` stripped.
///  2. If that's empty, fall back to the reasoning channel (also
///     think-stripped) so callers get SOMETHING instead of failing
///     silently. The summary is internal context, not shown verbatim, so a
///     slightly "thinky" recap beats no recap at all.
String extractCompletionMessageText(Map msg) {
  final content = msg['content'];
  if (content is String) {
    final clean = _stripThinkBlocks(content);
    if (clean.isNotEmpty) return clean;
  }
  // Reasoning-only fallback. Same field precedence as the streaming branch:
  // prefer `reasoning_content`, then `reasoning`.
  final reasoning = (msg['reasoning_content'] is String &&
          (msg['reasoning_content'] as String).trim().isNotEmpty)
      ? msg['reasoning_content'] as String
      : (msg['reasoning'] is String &&
              (msg['reasoning'] as String).trim().isNotEmpty)
          ? msg['reasoning'] as String
          : '';
  return _stripThinkBlocks(reasoning);
}

/// Wave CY.18.120: fire a minimal completion to make a local server
/// (LM Studio / Ollama) JIT-load [provider.model] BEFORE the user's
/// first real request — otherwise the cold load blocks long enough to
/// time the first request out. Best-effort + fire-and-forget: every
/// error is swallowed (a failed warm-up just means the first real
/// request pays the cold-load cost). Long timeout so the socket stays
/// open through a slow load. No-op when baseUrl or model is empty.
Future<void> warmUpProvider(ApiProvider provider) async {
  // Nothing to load if we don't know where to send the request or which
  // model to ask for (e.g. a half-filled provider row).
  if (provider.baseUrl.trim().isEmpty || provider.model.trim().isEmpty) {
    return;
  }
  try {
    final url = Uri.parse(buildChatUrl(provider.baseUrl, 'chat/completions'));
    // Same URL/header shape as completeChat so the request is
    // indistinguishable from a real one to the server.
    await http
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            if (provider.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${provider.apiKey}',
            ..._sanitiseHeaders(provider.headers),
          },
          // Tiny body: one user turn + max_tokens 1 so the server does the
          // expensive part (loading weights into RAM/VRAM) but barely any
          // generation. extraParams first so Pyre-managed fields win.
          body: jsonEncode({
            ...provider.extraParams,
            'model': provider.model,
            'messages': [
              {'role': 'user', 'content': 'hi'},
            ],
            'max_tokens': 1,
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 300));
  } catch (e) {
    // Swallow EVERYTHING — warm-up is purely an optimisation. A failure
    // (offline, model name typo, server not up yet) is harmless: the
    // first real request just eats the cold-load cost as it did before.
    debugPrint('warmUpProvider(${provider.name}) skipped: $e');
  }
}

/// Strip any header whose name or value contains CR/LF — those characters
/// allow HTTP header injection (smuggling a second header / starting an
/// early response body). Dart's `http` package already validates header
/// values on send, but defending in depth in our own code lets the UI
/// give nicer feedback (we just silently drop the entry).
Map<String, String> _sanitiseHeaders(Map<String, String> headers) {
  final out = <String, String>{};
  headers.forEach((k, v) {
    if (k.contains('\r') || k.contains('\n')) return;
    if (v.contains('\r') || v.contains('\n')) return;
    if (k.isEmpty) return;
    out[k] = v;
  });
  return out;
}

String _trimSlash(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;

/// Compose an OpenAI-compatible endpoint URL while honouring whatever
/// version segment the user already pasted into the base URL.
///
/// Many providers document their base WITH `/v1` already in it
/// (e.g. `https://mars.chub.ai/chub/soji/v1`, `https://openrouter.ai/api/v1`),
/// while others document it WITHOUT (e.g. `https://api.openai.com`). Naively
/// appending `/v1/<path>` produces a `/v1/v1/…` 404 on the former group.
///
/// Rule:
///  • if the trimmed base already ends in `/v1` (or any `/v\d+`), append
///    only the trailing path
///  • otherwise add `/v1/` between base and path
String buildChatUrl(String baseUrl, String path) {
  final base = _trimSlash(baseUrl.trim());
  final hasVersion = RegExp(r'/v\d+$').hasMatch(base);
  final p = path.startsWith('/') ? path.substring(1) : path;
  return hasVersion ? '$base/$p' : '$base/v1/$p';
}

/// Wave CY.18.71: web/PWA path — proxy the chat through the paired
/// desktop's `/llm/stream` endpoint instead of calling the LLM
/// upstream directly. The desktop uses ITS own SecureKeys-stored
/// API key, so the browser never sees credentials. Server response
/// is SSE (`data: <chunk>\n\n` + `data: [DONE]`); we decode + reverse
/// the newline escape applied server-side.
Stream<String> _streamViaLanProxy({
  required ApiProvider provider,
  required List<ChatTurn> messages,
  List<String>? stop,
}) async* {
  final lan = LanClient.instance;
  final baseUrl = lan.baseUrl;
  final bearer = lan.bearerToken;
  if (baseUrl == null || bearer == null) {
    throw ChatApiError(
        'LAN client not paired — open More > Connect to LAN.');
  }
  final body = jsonEncode({
    'providerId': provider.id,
    'messages': messages
        .map((m) => {'role': m.role, 'content': m.content})
        .toList(),
    if (stop != null && stop.isNotEmpty) 'stop': stop,
  });
  final req = http.Request('POST', Uri.parse('$baseUrl/llm/stream'));
  req.headers.addAll({
    'authorization': 'Bearer $bearer',
    'content-type': 'application/json',
    'accept': 'text/event-stream',
  });
  req.body = body;
  final httpClient = http.Client();
  try {
    // Kind-aware connect timeout, matching the native path. When the paired
    // desktop is proxying a LOCAL model (localhost provider), the upstream
    // server can JIT-load weights for minutes before the desktop forwards
    // any bytes — a hard 25s would abort the proxy mid-load. Cloud-backed
    // providers keep the tight 25s window.
    final resp = await httpClient.send(req).timeout(
      provider.kind == ProviderKind.localhost
          ? _kLocalConnectTimeout
          : const Duration(seconds: 25),
      onTimeout: () {
        throw ChatApiError(
            'LAN proxy timeout - is the PC server still running?');
      },
    );
    if (resp.statusCode == 401) {
      throw ChatApiError(
          'LAN bearer revoked - re-pair from More > Connect to LAN.');
    }
    if (resp.statusCode != 200) {
      final errBody = await resp.stream.bytesToString();
      throw ChatApiError(
          'LAN proxy HTTP ${resp.statusCode}: $errBody');
    }
    // SSE buffering. Events are separated by blank line; within each
    // event a `data:` line carries the chunk. `event: error` signals
    // an upstream LLM failure the server forwarded.
    final buf = StringBuffer();
    await for (final chunk in resp.stream.transform(utf8.decoder)) {
      buf.write(chunk);
      while (true) {
        final s = buf.toString();
        final sep = s.indexOf('\n\n');
        if (sep < 0) break;
        final event = s.substring(0, sep);
        buf
          ..clear()
          ..write(s.substring(sep + 2));
        String? data;
        String? eventName;
        for (final line in event.split('\n')) {
          if (line.startsWith('data:')) {
            data = line.substring(5).trimLeft();
          } else if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          }
        }
        if (data == null) continue;
        if (eventName == 'error') {
          throw ChatApiError('Upstream error via LAN proxy: $data');
        }
        if (data == '[DONE]') return;
        yield _unescapeSseChunk(data);
      }
    }
  } finally {
    httpClient.close();
  }
}

/// Reverse the server-side escape applied in pyre_server.dart
/// `_escapeForSse`. We walk the string once, expanding each `\X`
/// escape sequence we recognise. Unrecognised `\X` passes through
/// verbatim.
String _unescapeSseChunk(String s) {
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final next = s[i + 1];
      if (next == 'n') {
        out.write('\n');
        i++;
        continue;
      }
      if (next == 'r') {
        out.write('\r');
        i++;
        continue;
      }
      if (next == '\\') {
        out.write('\\');
        i++;
        continue;
      }
    }
    out.write(c);
  }
  return out.toString();
}
