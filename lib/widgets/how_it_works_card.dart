// Wave CY.18.206: shared "How it works" explainer card.
//
// Extracted from the Character Creator's `_HowItWorksCard` so that the
// Long-term Memory, Live Sheet, and Script settings screens can show a
// RICH, structured explainer that looks byte-identical to the Creator's.
//
// Content model:
//   HowItWorksCard(
//     title:    'How <feature> works',
//     subtitle: 'one short line under the header',
//     sections: [
//       HowItWorksSection('SECTION HEADER (rendered orange + caps)', [
//         HowItWorksBlock.paragraph('body text with **bold** runs'),
//         HowItWorksBlock.bullet('a bullet, also **bold**-aware'),
//         ...
//       ]),
//       ...
//     ],
//   )
//
// Styling is lifted verbatim from the Creator card: a collapsible
// ExpansionTile shell (collapsed by default), an orange help icon +
// w600 title, a textMid subtitle, then per-section centered orange caps
// headers, 13px body paragraphs and indented bullets, all with the same
// `**bold** / *italic*` inline parser. There is ONE renderer now, so
// every "How it works" card across the app is visually consistent.

import 'package:flutter/material.dart';

import '../theme.dart';

/// One content block inside a [HowItWorksSection] — either a body
/// paragraph or a bullet line. Both support `**bold**` / `*italic*`
/// inline markers via the shared parser.
class HowItWorksBlock {
  final String text;
  final bool isBullet;

  const HowItWorksBlock._(this.text, this.isBullet);

  /// A body paragraph.
  const HowItWorksBlock.paragraph(String text) : this._(text, false);

  /// A single bullet line (rendered with a small leading dot).
  const HowItWorksBlock.bullet(String text) : this._(text, true);
}

/// A titled section: an orange centered caps header + an ordered list of
/// paragraph / bullet blocks.
class HowItWorksSection {
  final String header;
  final List<HowItWorksBlock> blocks;

  const HowItWorksSection(this.header, this.blocks);
}

/// A collapsible, richly-formatted "How it works" explainer card.
///
/// Collapsed by default (matches the Creator card). Feed it a [title],
/// a one-line [subtitle], and the [sections] to render.
class HowItWorksCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<HowItWorksSection> sections;

  const HowItWorksCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.sections,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final section in sections) {
      children.add(_h2(section.header));
      for (final block in section.blocks) {
        children.add(block.isBullet ? _bullet(block.text) : _p(block.text));
      }
    }
    children.add(const SizedBox(height: 8));

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Row(
            children: [
              const Icon(Icons.help_outline,
                  size: 16, color: EmberColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2, left: 24),
            child: Text(
              subtitle,
              style: const TextStyle(color: EmberColors.textMid, fontSize: 11),
            ),
          ),
          children: children,
        ),
      ),
    );
  }

  // ── Renderers (lifted verbatim from the Creator card) ───────────────────

  static Widget _h2(String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: EmberColors.primary,
            fontWeight: FontWeight.w700,
            fontSize: 11,
            letterSpacing: 1.2,
          ),
        ),
      );

  static Widget _p(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(
          TextSpan(
            children: _parseInline(text),
            style: const TextStyle(
              color: EmberColors.textHigh,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      );

  static Widget _bullet(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 8, top: 6),
              child: Icon(Icons.circle, size: 4, color: EmberColors.textMid),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: _parseInline(text),
                  style: const TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  /// Tiny inline parser so `**bold**` and `*italic*` markers in the help
  /// copy render properly. Walks the text char by char with a (bold,
  /// italic) toggle state. Doesn't try to be a full markdown engine — we
  /// don't need links/code/headings inside body copy, just emphasis.
  /// Anything not recognised falls through as plain text.
  static List<InlineSpan> _parseInline(String text) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();
    var bold = false;
    var italic = false;
    var i = 0;
    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(
        text: buffer.toString(),
        style: TextStyle(
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        ),
      ));
      buffer.clear();
    }

    while (i < text.length) {
      if (i + 1 < text.length && text[i] == '*' && text[i + 1] == '*') {
        flush();
        bold = !bold;
        i += 2;
      } else if (text[i] == '*') {
        flush();
        italic = !italic;
        i += 1;
      } else {
        buffer.write(text[i]);
        i += 1;
      }
    }
    flush();
    return spans;
  }
}
