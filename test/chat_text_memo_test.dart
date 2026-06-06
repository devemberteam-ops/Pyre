// Audit 2026-06-05 (perf-at-scale #6): ChatText memoizes its char-by-char
// parse so a visible-but-unchanged bubble isn't re-parsed every ~16ms frame
// while another message streams or the user scrolls. These lock the memo:
// an unchanged bubble re-uses its cached spans across rebuilds, a changed
// body (streaming) re-parses, and distinct texts/styles get distinct entries.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  setUp(ChatText.debugClearParseCache);

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
}
