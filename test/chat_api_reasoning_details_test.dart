@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';

/// Mega-audit 2026-06-04 (F9) — end-to-end SSE test that the streaming reader
/// picks up OpenRouter's `delta.reasoning_details: [...]` array when a route
/// emits ONLY that shape (no flat `delta.reasoning`). The reasoning text must
/// land in the `<think>` channel just like the flat fields do.
void main() {
  late HttpServer server;
  late ApiProvider provider;
  final settings = ModelSettings();
  final messages = <ChatTurn>[ChatTurn('user', 'Hi.')];

  Future<void> startSseServer(List<String> sseLines) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      await utf8.decoder.bind(req).join();
      req.response.statusCode = 200;
      req.response.headers.set('content-type', 'text/event-stream');
      for (final l in sseLines) {
        req.response.write('$l\n');
      }
      await req.response.close();
    });
    provider = ApiProvider(
      id: 'p1',
      name: 'OpenRouter-like',
      baseUrl: 'http://${server.address.host}:${server.port}/v1',
      apiKey: 'sk-x',
      model: 'some/reasoning-route',
    );
  }

  tearDown(() async => server.close(force: true));

  String delta(Map<String, dynamic> d) => 'data: ${jsonEncode({
        'choices': [
          {'delta': d}
        ]
      })}';

  test('reasoning_details[] array-only route lands in <think>', () async {
    await startSseServer([
      delta({
        'reasoning_details': [
          {'type': 'reasoning.text', 'text': 'thinking-'},
          {'type': 'reasoning.text', 'text': 'hard'},
        ]
      }),
      '',
      delta({'content': 'final answer'}),
      '',
      'data: [DONE]',
      '',
    ]);

    final buf = StringBuffer();
    await for (final chunk in streamChatCompletion(
      provider: provider,
      settings: settings,
      messages: messages,
    )) {
      buf.write(chunk);
    }
    final out = buf.toString();
    expect(out, contains('<think>thinking-hard</think>'));
    expect(out, contains('final answer'));
  });

  test('flat delta.reasoning still wins over the array when both present',
      () async {
    await startSseServer([
      delta({
        'reasoning': 'flat-wins',
        'reasoning_details': [
          {'text': 'array-loses'}
        ]
      }),
      '',
      delta({'content': 'done'}),
      '',
      'data: [DONE]',
      '',
    ]);

    final buf = StringBuffer();
    await for (final chunk in streamChatCompletion(
      provider: provider,
      settings: settings,
      messages: messages,
    )) {
      buf.write(chunk);
    }
    final out = buf.toString();
    expect(out, contains('flat-wins'));
    expect(out, isNot(contains('array-loses')));
  });
}
