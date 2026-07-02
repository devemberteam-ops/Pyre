// Audit 2026-06-05 (perf-at-scale #6): ChatText memoizes its char-by-char
// parse so a visible-but-unchanged bubble isn't re-parsed every ~16ms frame
// while another message streams or the user scrolls. These lock the memo:
// an unchanged bubble re-uses its cached spans across rebuilds, a changed
// body (streaming) re-parses, and distinct texts/styles get distinct entries.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/theme.dart';
import 'package:pyre/widgets/chat_text.dart';

Future<void> pumpBody(WidgetTester tester, String body,
    {TextStyle? style}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatText(body, baseStyle: style),
      ),
    ),
  );
}

/// Finds the color used for the dialogue span (`"quoted text"`) in the
/// rendered [ChatText] output, by walking the [InlineSpan] tree produced for
/// the sole [Text.rich] in the tree.
Color dialogueSpanColor(WidgetTester tester) {
  Color? found;
  void search(InlineSpan span) {
    if (span is TextSpan) {
      if ((span.text ?? '').contains('Sunken Gate')) {
        found = span.style!.color!;
        return;
      }
      for (final c in span.children ?? const <InlineSpan>[]) {
        search(c);
        if (found != null) return;
      }
    }
  }

  for (final richText in tester.widgetList<RichText>(find.byType(RichText))) {
    search(richText.text);
    if (found != null) return found!;
  }
  fail('dialogue span not found in rendered spans');
}

void main() {
  setUp(() {
    ChatText.debugClearParseCache();
    EmberColors.active = paletteById('ember');
  });
  tearDown(() {
    EmberColors.active = paletteById('ember');
  });

  group('ChatText parse memo', () {
    testWidgets('an unchanged bubble is parsed once across rebuilds',
        (tester) async {
      await pumpBody(tester, 'The "Sunken Gate" *yawned* open.');
      expect(ChatText.debugParseCacheSize, 1);

      // Several no-op rebuilds (mimics the ~16ms coalesced notify firing while
      // some OTHER bubble streams) must NOT add cache entries.
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(ChatText.debugParseCacheSize, 1);
    });

    testWidgets('a streaming (changing) body re-parses each distinct text',
        (tester) async {
      await pumpBody(tester, 'Hel');
      await pumpBody(tester, 'Hello');
      await pumpBody(tester, 'Hello world');
      // Three distinct bodies → three distinct parses memoized.
      expect(ChatText.debugParseCacheSize, 3);
    });

    testWidgets('identical text + style shares a single entry', (tester) async {
      const style = TextStyle(fontSize: 15);
      await pumpBody(tester, 'same text', style: style);
      await pumpBody(tester, 'same text', style: style);
      expect(ChatText.debugParseCacheSize, 1);
    });
  });

  group('ChatText parse memo is theme-aware', () {
    // NOTE: baseStyle is fixed to a palette-INDEPENDENT color (Colors.white)
    // on purpose. ChatText.build()'s default baseStyle bakes EmberColors
    // .textHigh in directly, which would make the TextStyle itself (and thus
    // today's cache key, which already includes `base`) change across a
    // palette switch — masking the real defect. Passing an explicit,
    // palette-independent baseStyle keeps `base`'s `==` identical across the
    // switch, isolating whether the memo itself tracks the active palette
    // for the palette-derived colors baked into spans inside `_parse`
    // (dialogue/italic/code use `base.copyWith(color: EmberColors.xxx)`).
    const fixedStyle = TextStyle(color: Colors.white, height: 1.4);

    testWidgets(
        'switching the active palette changes the rendered dialogue color '
        'instead of serving a stale cached parse', (tester) async {
      const body = 'The "Sunken Gate" *yawned* open.';

      // Parse once under palette A (ember).
      EmberColors.active = paletteById('ember');
      await pumpBody(tester, body, style: fixedStyle);
      final colorA = dialogueSpanColor(tester);
      expect(colorA, paletteById('ember').textHigh);

      // Switch to palette B (moonlit) — same text, same baseStyle — and
      // rebuild. A theme-unaware cache key would still return palette A's
      // memoized spans here.
      EmberColors.active = paletteById('moonlit');
      await pumpBody(tester, body, style: fixedStyle);
      final colorB = dialogueSpanColor(tester);

      expect(colorB, paletteById('moonlit').textHigh);
      expect(colorB, isNot(colorA));
    });

    testWidgets('re-parsing under the same palette still hits the cache',
        (tester) async {
      const body = 'The "Sunken Gate" *yawned* open.';
      EmberColors.active = paletteById('ember');

      await pumpBody(tester, body, style: fixedStyle);
      expect(ChatText.debugParseCacheSize, 1);

      // Several rebuilds under the SAME palette must not add cache entries.
      for (var i = 0; i < 5; i++) {
        await pumpBody(tester, body, style: fixedStyle);
      }
      expect(ChatText.debugParseCacheSize, 1);
    });
  });
}
