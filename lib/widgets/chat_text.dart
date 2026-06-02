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
  const ChatText(this.body, {super.key, this.baseStyle, this.hideReasoning = true});

  static final _thinkBlock = RegExp(r'<think>[\s\S]*?</think>',
      caseSensitive: false, multiLine: true);
  static final _danglingThink = RegExp(r'<think>[\s\S]*$',
      caseSensitive: false, multiLine: true);
  static final _thinkOpen =
      RegExp(r'<think>', caseSensitive: false, multiLine: true);
  static final _thinkClose =
      RegExp(r'</think>', caseSensitive: false, multiLine: true);

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
    final stripped = body
        .replaceAll(_thinkBlock, '')
        .replaceAll(_danglingThink, '')
        .trim();
    if (stripped.isNotEmpty) return stripped;
    if (_thinkOpen.hasMatch(body) && _thinkClose.hasMatch(body)) {
      return body
          .replaceAll(_thinkOpen, '')
          .replaceAll(_thinkClose, '')
          .trim();
    }
    return '';
  }

  String _cleaned() {
    if (!hideReasoning) return body;
    return stripReasoning(body);
  }

  @override
  Widget build(BuildContext context) {
    final base = (baseStyle ??
            const TextStyle(color: EmberColors.textHigh, height: 1.4))
        .copyWith(fontSize: 15);
    final visible = _cleaned();
    if (visible.isEmpty) {
      return const Text('…', style: TextStyle(color: EmberColors.textDim));
    }
    return Text.rich(
      TextSpan(children: _parse(visible, base)),
      softWrap: true,
    );
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
              spans.add(WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: _InlineImage(url: url, alt: alt),
              ));
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
          spans.add(TextSpan(
            text: src.substring(i, closeIdx + 1),
            style: base.copyWith(
              color: EmberColors.textHigh,
              fontWeight: FontWeight.w600,
              fontStyle: FontStyle.normal,
            ),
          ));
          i = closeIdx + 1;
          continue;
        }
      }

      // Bold: **...**
      if (ch == '*' &&
          i + 1 < src.length &&
          src[i + 1] == '*') {
        final closeIdx = src.indexOf('**', i + 2);
        if (closeIdx > 0) {
          spans.add(TextSpan(
            text: src.substring(i + 2, closeIdx),
            style: base.copyWith(fontWeight: FontWeight.w700),
          ));
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
          spans.add(TextSpan(
            text: src.substring(i + 1, closeIdx),
            style: base.copyWith(
              fontStyle: FontStyle.italic,
              color: EmberColors.textMid,
            ),
          ));
          i = closeIdx + 1;
          continue;
        }
      }

      // Inline code: `...`
      if (ch == '`') {
        final closeIdx = src.indexOf('`', i + 1);
        if (closeIdx > 0) {
          spans.add(TextSpan(
            text: src.substring(i + 1, closeIdx),
            style: base.copyWith(
              fontFamily: 'monospace',
              backgroundColor: EmberColors.bgElevated,
              fontSize: (base.fontSize ?? 15) - 1,
            ),
          ));
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: child,
        ),
      );

  Widget _brokenInner() => Container(
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        color: EmberColors.bgElevated,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                size: 18, color: EmberColors.textDim),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                alt.trim().isNotEmpty ? alt.trim() : 'image unavailable',
                style:
                    const TextStyle(color: EmberColors.textDim, fontSize: 13),
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
        inner = Image.memory(bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => _brokenInner());
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
