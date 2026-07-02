// Renders a message body with chub-style typographic distinctions:
//   "quoted text"   → dialogue, ember-warm
//   *italic* / _italic_ → narration emphasis, muted
//   **bold**        → bold
//   `code`          → monospace, dim background
//
// Falls back to plain text on parse problems. Single-pass tokenizer over a
// flat character stream — Markdown nesting is intentionally minimal so that
// half-finished tokens during streaming don't visually flicker.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'lightbox.dart';

class ChatText extends StatelessWidget {
  final String body;
  final TextStyle? baseStyle;

  /// When true (default), `<think>…</think>` blocks emitted by reasoning
  /// models like DeepSeek-R1 are stripped before rendering. The raw text
  /// stays in storage — only the visible render is filtered.
  final bool hideReasoning;

  /// Fix 2 (2026-07 perf pass): true while this bubble is the ACTIVE
  /// streaming target. The body grows every coalesced notifier flush
  /// (see `_ChatScreenState._streamingTextNotifier`), so every call is a
  /// guaranteed cache MISS against the shared [_parseCache] — parsing it
  /// there would (a) do nothing useful (never a hit) and (b) evict OTHER
  /// bubbles' cached parses out of the bounded LRU-ish cache for no benefit.
  /// Instead, a streaming body is parsed through a dedicated single-slot
  /// cache ([_streamParseKey] / [_streamParseSpans]) that only remembers the
  /// MOST RECENT streaming parse — still a full re-parse per call (the
  /// tokenizer's mid-token state
  /// isn't externalized, so a truly incremental resume isn't safe: a
  /// dangling `"`/`*` at the tail can resolve differently once more text
  /// arrives), but capped to at most once per caller rebuild. Combined with
  /// the coalesced ~16ms streaming notifier upstream, that keeps the parse
  /// rate at ~1/frame instead of once per raw SSE token (was O(N²) over a
  /// long reply). Formatting is identical either way — this only changes
  /// which cache the parse is memoized through.
  final bool isStreaming;
  const ChatText(
    this.body, {
    super.key,
    this.baseStyle,
    this.hideReasoning = true,
    this.isStreaming = false,
  });

  static final _thinkBlock = RegExp(
    r'<think>[\s\S]*?</think>',
    caseSensitive: false,
    multiLine: true,
  );
  static final _danglingThink = RegExp(
    r'<think>[\s\S]*$',
    caseSensitive: false,
    multiLine: true,
  );
  static final _thinkOpen = RegExp(
    r'<think>',
    caseSensitive: false,
    multiLine: true,
  );
  static final _thinkClose = RegExp(
    r'</think>',
    caseSensitive: false,
    multiLine: true,
  );

  /// True when the message body has a `<think>` block (R1-style
  /// reasoning models). Callers use this to decide whether to show
  /// the "Show / Hide reasoning" per-message toggle.
  static bool containsReasoning(String body) => _thinkOpen.hasMatch(body);

  /// Wave CY.18.153: reusable reasoning stripper, extracted from [_cleaned]
  /// and made PUBLIC + STATIC so non-render call sites can share the exact
  /// same logic. The critical consumer is Impersonate-Me, which pipes raw
  /// model output straight into the user's editable INPUT box — a reasoning
  /// model (DeepSeek-R1, Qwen-thinking) would otherwise dump
  /// `<think>…</think>` chain-of-thought there, where a hurried user could
  /// send it as their own message.
  ///
  /// Strips every complete `<think>…</think>` block plus a dangling open
  /// tail (mid-stream, before the closing tag arrives). If that empties a
  /// body that has BOTH tags — the model wrapped its whole answer in one
  /// think block (Qwen-thinking / some DeepSeek gateways) — falls back to
  /// dropping just the tags and keeping the inner text. Returns '' only when
  /// there's genuinely nothing but an unterminated reasoning preamble.
  static String stripReasoning(String body) {
    final stripped = stripReasoningStrict(body);
    if (stripped.isNotEmpty) return stripped;
    if (_thinkOpen.hasMatch(body) && _thinkClose.hasMatch(body)) {
      return body.replaceAll(_thinkOpen, '').replaceAll(_thinkClose, '').trim();
    }
    return '';
  }

  /// Strict variant for Creator-style tool surfaces: reasoning is metadata, not
  /// a fallback answer. If the model only produced `<think>`, return empty.
  static String stripReasoningStrict(String body) =>
      body.replaceAll(_thinkBlock, '').replaceAll(_danglingThink, '').trim();

  String _cleaned() {
    if (!hideReasoning) return body;
    return stripReasoning(body);
  }

  @override
  Widget build(BuildContext context) {
    final base =
        (baseStyle ?? TextStyle(color: EmberColors.textHigh, height: 1.4))
            .copyWith(fontSize: 15);
    final visible = _cleaned();
    if (visible.isEmpty) {
      return Text('…', style: TextStyle(color: EmberColors.textDim));
    }
    final spans = isStreaming
        ? _streamParseMemo(visible, base)
        : _parseMemo(visible, base);
    return Text.rich(
      TextSpan(children: spans),
      softWrap: true,
    );
  }

  // ── Parse memo ─────────────────────────────────────────────────────────
  //
  // Audit 2026-06-05 (perf-at-scale, finding #6): a visible-but-not-streaming
  // bubble (a long completed reply / card greeting) is re-parsed char-by-char
  // on EVERY ~16ms coalesced rebuild while another message streams or the user
  // scrolls. The parse output is a pure function of (cleaned body text, base
  // style), and both are stable for an unchanged bubble — so we memoize the
  // produced spans. The streaming bubble's text changes each frame, so it
  // misses the cache and re-parses (correct); every OTHER visible bubble hits
  // it. The cached spans are immutable (TextSpan / a const-friendly WidgetSpan
  // child) and safe to reuse across builds — _InlineImage reads MediaQuery at
  // ITS own build time, so layout still adapts. Bounded LRU-ish (clear on cap).
  //
  // Theme-correctness (whole-app audit #10): `_parse` also bakes in
  // EmberColors.textHigh / textMid / bgElevated directly for the dialogue,
  // italic and inline-code spans — independent of the caller-supplied `base`
  // style. EmberColors.active is a mutable runtime palette (Pyre supports
  // switching themes without restart), so the key must include those
  // palette-derived colors too; otherwise a message parsed under the OLD
  // palette is served from cache with the OLD colors baked in after the user
  // switches themes.
  static const _kParseCacheMax = 256;
  static final Map<_ParseKey, List<InlineSpan>> _parseCache =
      <_ParseKey, List<InlineSpan>>{};

  static List<InlineSpan> _parseMemo(String src, TextStyle base) {
    final key = _ParseKey(
      src,
      base,
      EmberColors.textHigh,
      EmberColors.textMid,
      EmberColors.bgElevated,
    );
    final hit = _parseCache[key];
    if (hit != null) return hit;
    final spans = _parse(src, base);
    if (_parseCache.length >= _kParseCacheMax) _parseCache.clear();
    _parseCache[key] = spans;
    return spans;
  }

  // ── Streaming parse memo (Fix 2) ────────────────────────────────────────
  //
  // Single-slot cache dedicated to the currently-streaming bubble(s). It
  // never shares `_parseCache` (every streaming call is a guaranteed miss
  // there, so it would only evict OTHER bubbles' entries for nothing).
  // Keyed the same way, but capped at ONE entry — a plain `==` short-circuit
  // means an unchanged (src, base, palette) tuple across back-to-back
  // rebuilds (e.g. two coalesced flushes landing the same text, or a sibling
  // repaint that doesn't touch this bubble) reuses the last parse instead of
  // re-tokenizing. Cleared whenever the key changes (bounded to size 1) and
  // by [debugClearParseCache] between tests.
  static _ParseKey? _streamParseKey;
  static List<InlineSpan>? _streamParseSpans;

  static List<InlineSpan> _streamParseMemo(String src, TextStyle base) {
    final key = _ParseKey(
      src,
      base,
      EmberColors.textHigh,
      EmberColors.textMid,
      EmberColors.bgElevated,
    );
    if (_streamParseKey == key && _streamParseSpans != null) {
      return _streamParseSpans!;
    }
    final spans = _parse(src, base);
    _streamParseKey = key;
    _streamParseSpans = spans;
    return spans;
  }

  /// Test-only: number of distinct (text, style) parses currently memoized.
  @visibleForTesting
  static int get debugParseCacheSize => _parseCache.length;

  /// Test-only: drop the parse memo (both the shared cache and the
  /// single-slot streaming cache).
  @visibleForTesting
  static void debugClearParseCache() {
    _parseCache.clear();
    _streamParseKey = null;
    _streamParseSpans = null;
  }

  static List<InlineSpan> _parse(String src, TextStyle base) {
    final spans = <InlineSpan>[];
    var i = 0;
    while (i < src.length) {
      final ch = src[i];

      // Inline image: ![alt](url) — render network/data images inline so a
      // card greeting that embeds an illustration shows the picture instead
      // of literal markdown. Only fires once the FULL token is present (a
      // closing `)` exists), so a half-streamed link stays as text until it
      // completes; unknown URL schemes fall through to plain text.
      if (ch == '!' && i + 1 < src.length && src[i + 1] == '[') {
        final altClose = src.indexOf(']', i + 2);
        if (altClose > 0 &&
            altClose + 1 < src.length &&
            src[altClose + 1] == '(') {
          final urlClose = src.indexOf(')', altClose + 2);
          if (urlClose > 0) {
            final alt = src.substring(i + 2, altClose);
            final url = src.substring(altClose + 2, urlClose).trim();
            final lower = url.toLowerCase();
            if (lower.startsWith('http://') ||
                lower.startsWith('https://') ||
                lower.startsWith('data:image/')) {
              spans.add(
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _InlineImage(url: url, alt: alt),
                ),
              );
              i = urlClose + 1;
              continue;
            }
          }
        }
      }

      // Dialogue: "..." (curly quotes count too) — rendered as cream-bold
      // to pop against the muted-italic narration around it (matches the
      // HTML prototype's typography).
      if (ch == '"' || ch == '“') {
        final closeIdx = _findMatch(src, i + 1, ['"', '”']);
        if (closeIdx > 0) {
          spans.add(
            TextSpan(
              text: src.substring(i, closeIdx + 1),
              style: base.copyWith(
                color: EmberColors.textHigh,
                fontWeight: FontWeight.w600,
                fontStyle: FontStyle.normal,
              ),
            ),
          );
          i = closeIdx + 1;
          continue;
        }
      }

      // Bold: **...**
      if (ch == '*' && i + 1 < src.length && src[i + 1] == '*') {
        final closeIdx = src.indexOf('**', i + 2);
        if (closeIdx > 0) {
          spans.add(
            TextSpan(
              text: src.substring(i + 2, closeIdx),
              style: base.copyWith(fontWeight: FontWeight.w700),
            ),
          );
          i = closeIdx + 2;
          continue;
        }
      }

      // Italic: *...* or _..._
      if ((ch == '*' || ch == '_') &&
          (i + 1 < src.length) &&
          src[i + 1] != ch &&
          src[i + 1] != ' ') {
        final closeIdx = src.indexOf(ch, i + 1);
        if (closeIdx > 0 && closeIdx - i > 1) {
          spans.add(
            TextSpan(
              text: src.substring(i + 1, closeIdx),
              style: base.copyWith(
                fontStyle: FontStyle.italic,
                color: EmberColors.textMid,
              ),
            ),
          );
          i = closeIdx + 1;
          continue;
        }
      }

      // Inline code: `...`
      if (ch == '`') {
        final closeIdx = src.indexOf('`', i + 1);
        if (closeIdx > 0) {
          spans.add(
            TextSpan(
              text: src.substring(i + 1, closeIdx),
              style: base.copyWith(
                fontFamily: 'monospace',
                backgroundColor: EmberColors.bgElevated,
                fontSize: (base.fontSize ?? 15) - 1,
              ),
            ),
          );
          i = closeIdx + 1;
          continue;
        }
      }

      // Plain text — accumulate up to next interesting character.
      final start = i;
      while (i < src.length) {
        final c = src[i];
        if (c == '"' || c == '“' || c == '*' || c == '_' || c == '`') {
          break;
        }
        if (c == '!' && i + 1 < src.length && src[i + 1] == '[') break;
        i++;
      }
      if (i > start) {
        spans.add(TextSpan(text: src.substring(start, i), style: base));
      } else {
        // Couldn't progress — emit single char and move on (guards against
        // pathological loops).
        spans.add(TextSpan(text: ch, style: base));
        i++;
      }
    }
    return spans;
  }

  /// Finds the next index in [src] (>= [from]) where any character of
  /// [closers] appears. Returns -1 if none.
  static int _findMatch(String src, int from, List<String> closers) {
    var best = -1;
    for (final c in closers) {
      final idx = src.indexOf(c, from);
      if (idx >= 0 && (best < 0 || idx < best)) best = idx;
    }
    return best;
  }
}

/// Composite cache key for [ChatText]'s parse memo: the cleaned body text,
/// the base [TextStyle] (which folds in caller-passed `baseStyle` + the
/// computed font size), and the palette-derived colors [_parse] bakes into
/// dialogue/italic/code spans (read from the mutable [EmberColors.active] at
/// parse time). `TextStyle` and `Color` both have value `==`/`hashCode`, so
/// two bubbles with identical text + style + active palette share a cache
/// entry, and a palette switch correctly misses the cache.
@immutable
class _ParseKey {
  final String src;
  final TextStyle base;
  final Color textHigh;
  final Color textMid;
  final Color bgElevated;
  const _ParseKey(
    this.src,
    this.base,
    this.textHigh,
    this.textMid,
    this.bgElevated,
  );

  @override
  bool operator ==(Object other) =>
      other is _ParseKey &&
      other.src == src &&
      other.base == base &&
      other.textHigh == textHigh &&
      other.textMid == textMid &&
      other.bgElevated == bgElevated;

  @override
  int get hashCode => Object.hash(src, base, textHigh, textMid, bgElevated);
}

/// Inline image for [ChatText]'s markdown `![](url)` support — common in
/// imported card greetings that embed an illustration. Network images load
/// lazily behind a sized placeholder and degrade to a small "image
/// unavailable" chip on error, so a dead link never breaks the bubble. Data
/// URLs decode in-process. NOTE: fetching a remote image reveals the user's
/// IP to that host — standard for RP card art, but a privacy toggle could
/// gate it later if needed.
class _InlineImage extends StatelessWidget {
  final String url;
  final String alt;
  const _InlineImage({required this.url, required this.alt});

  Widget _frame(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
  );

  Widget _brokenInner() => Container(
    width: 220,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    color: EmberColors.bgElevated,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 18, color: EmberColors.textDim),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            alt.trim().isNotEmpty ? alt.trim() : 'image unavailable',
            style: TextStyle(color: EmberColors.textDim, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Wave CY.18.144: size the inline image to the screen instead of a
    // fixed 320px (it read tiny on a wide desktop), and make it tappable to
    // open the fullscreen pinch-zoom Lightbox. Cap so a tall image can't
    // dominate the bubble; BoxFit.contain keeps the aspect ratio.
    final media = MediaQuery.sizeOf(context);
    final maxW = (media.width - 96).clamp(180.0, 560.0);
    final maxH = (media.height * 0.55).clamp(200.0, 620.0);
    final constraints = BoxConstraints(maxWidth: maxW, maxHeight: maxH);

    Widget inner;
    if (url.startsWith('data:')) {
      try {
        final comma = url.indexOf(',');
        final bytes = base64Decode(url.substring(comma + 1));
        inner = Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _brokenInner(),
        );
      } catch (_) {
        inner = _brokenInner();
      }
    } else {
      inner = Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _brokenInner(),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: 200,
            height: 150,
            color: EmberColors.bgElevated,
            alignment: Alignment.center,
            child: const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
      );
    }

    return _frame(
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Lightbox.show(context, dataUrl: url, fallback: alt),
        child: ConstrainedBox(constraints: constraints, child: inner),
      ),
    );
  }
}
