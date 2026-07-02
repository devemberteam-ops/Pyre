// E (#131): widget smoke test for the in-app LLM diagnostics viewer. Since a
// Flutter mobile screen can't be screenshotted in CI, this pumps the REAL
// screen and drives the list → detail navigation, proving the render + parse
// path end-to-end.
//
// The screen's `loadRaw` seam is injected with a canned JSONL string: the
// production loader does real `dart:io` reads, and real file futures never
// complete under `pumpAndSettle`'s fake-async clock (a microtask-resolved
// stub does). This keeps the test hermetic and fast.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/screens/llm_debug_log_viewer_screen.dart';

String _seededLog() => [
      jsonEncode({
        'ts': 1000,
        'feature': 'chat',
        'provider': 'Venice',
        'model': 'qwen-x',
        'messages': [
          {'role': 'user', 'content': 'ping'}
        ],
        'sampling': {'temperature': 0.7, 'max_tokens': 256},
        'response': 'pong from the model',
        'finishReason': 'stop',
        'durationMs': 1500,
      }),
      jsonEncode({'ts': 900, 'trace': 'scene: classified as forest'}),
    ].join('\n');

void main() {
  testWidgets('empty log shows the enable-and-reproduce guidance',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LlmDebugLogViewerScreen(loadRaw: () async => ''),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No diagnostics yet'), findsOneWidget);
    expect(find.textContaining('Storage → Developer'), findsOneWidget);
  });

  testWidgets('a captured call renders in the list and opens its detail',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LlmDebugLogViewerScreen(loadRaw: () async => _seededLog()),
    ));
    await tester.pumpAndSettle();

    // List tile shows feature + provider·model + response snippet.
    expect(find.text('chat'), findsWidgets);
    expect(find.textContaining('Venice · qwen-x'), findsOneWidget);
    expect(find.textContaining('pong from the model'), findsWidgets);
    // The trace breadcrumb also renders.
    expect(find.textContaining('scene: classified as forest'), findsOneWidget);

    // Tap the call tile → detail screen with the request + response sections.
    await tester.tap(find.textContaining('Venice · qwen-x'));
    await tester.pumpAndSettle();

    expect(find.text('Request messages'), findsOneWidget);
    expect(find.text('Sampling'), findsOneWidget);
    expect(find.text('Response'), findsOneWidget);
    // The pretty-printed request + response content is present.
    expect(find.textContaining('ping'), findsWidgets);
    expect(find.textContaining('pong from the model'), findsWidgets);
    expect(find.textContaining('temperature'), findsOneWidget);
  });
}
