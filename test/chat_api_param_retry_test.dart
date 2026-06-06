@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';

/// Mega-audit 2026-06-04 — integration test for the UNIVERSAL param-error
/// retry-without-extras (the priority cross-model fix). Stands up a real
/// loopback HTTP server that mimics a strict provider: the first request is
/// rejected with a param-shape 4xx, the retry (minimal body) succeeds. Asserts
/// the retry happens, that the retried body is the minimal safe set, and that
/// non-param 4xx errors are NOT retried.
void main() {
  late HttpServer server;
  late ApiProvider provider;
  final settings = ModelSettings();
  final messages = <ChatTurn>[
    ChatTurn('system', 'You are a test.'),
    ChatTurn('user', 'Hello.'),
  ];

  // Capture every received request body so tests can assert on the retry.
  late List<Map<String, dynamic>> receivedBodies;

  /// Start a server whose [handler] receives (requestIndex, decodedBody) and
  /// returns the (statusCode, responseBody) to send.
  Future<void> startServer(
    FutureOr<(int, String)> Function(int index, Map<String, dynamic> body)
        handler,
  ) async {
    receivedBodies = [];
    var index = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final raw = await utf8.decoder.bind(req).join();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      receivedBodies.add(decoded);
      final (status, respBody) = await handler(index++, decoded);
      req.response.statusCode = status;
      // Default to JSON so the streaming path takes the one-shot JSON branch.
      req.response.headers.contentType = ContentType.json;
      req.response.write(respBody);
      await req.response.close();
    });
    provider = ApiProvider(
      id: 'p1',
      name: 'Strict Test Provider',
      baseUrl: 'http://${server.address.host}:${server.port}/v1',
      apiKey: 'sk-secret',
      model: 'gpt-4o', // non-reasoning → no proactive stripping, exercises retry
    );
  }

  String okJson(String content) => jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
            'finish_reason': 'stop',
          }
        ],
      });

  const paramErrBody =
      '{"error":{"message":"Unsupported parameter: \'temperature\' is not supported with this model."}}';
  const authErrBody = '{"error":{"message":"Invalid API key provided"}}';

  tearDown(() async {
    await server.close(force: true);
  });

  group('completeChat — universal param-error retry', () {
    test('retries once with the minimal body and succeeds', () async {
      await startServer((index, body) async {
        if (index == 0) return (400, paramErrBody);
        return (200, okJson('hello after retry'));
      });

      final text = await completeChat(
        provider: provider,
        settings: settings,
        messages: messages,
      );

      expect(text, 'hello after retry');
      expect(receivedBodies.length, 2, reason: 'should send original + 1 retry');

      // First body carries the full sampling set; the retry is minimal.
      final first = receivedBodies[0];
      expect(first.containsKey('temperature'), isTrue);

      final retry = receivedBodies[1];
      expect(retry.containsKey('temperature'), isFalse);
      expect(retry.containsKey('top_p'), isFalse);
      expect(retry['model'], 'gpt-4o');
      expect(retry['stream'], false);
      // Token cap present under BOTH names.
      expect(retry.containsKey('max_tokens'), isTrue);
      expect(retry.containsKey('max_completion_tokens'), isTrue);
      expect(retry['max_tokens'], retry['max_completion_tokens']);
      expect(retry['messages'], isA<List<dynamic>>());
    });

    test('does NOT retry a non-param 4xx (auth error)', () async {
      await startServer((index, body) async => (401, authErrBody));

      await expectLater(
        completeChat(
          provider: provider,
          settings: settings,
          messages: messages,
        ),
        throwsA(isA<ChatApiError>()),
      );
      expect(receivedBodies.length, 1, reason: 'auth error must not retry');
    });

    test('a second param-error 4xx on the retry surfaces the error (no loop)',
        () async {
      await startServer((index, body) async => (400, paramErrBody));

      await expectLater(
        completeChat(
          provider: provider,
          settings: settings,
          messages: messages,
        ),
        throwsA(isA<ChatApiError>()),
      );
      // Exactly two attempts: original + one retry. Terminates, no loop.
      expect(receivedBodies.length, 2);
    });
  });

  group('streamChatCompletion — universal param-error retry', () {
    test('retries once with the minimal body and succeeds', () async {
      await startServer((index, body) async {
        if (index == 0) return (400, paramErrBody);
        return (200, okJson('streamed after retry'));
      });

      final buf = StringBuffer();
      await for (final chunk in streamChatCompletion(
        provider: provider,
        settings: settings,
        messages: messages,
      )) {
        buf.write(chunk);
      }
      expect(buf.toString(), contains('streamed after retry'));
      expect(receivedBodies.length, 2);

      final retry = receivedBodies[1];
      expect(retry.containsKey('temperature'), isFalse);
      expect(retry['model'], 'gpt-4o');
      expect(retry.containsKey('max_tokens'), isTrue);
      expect(retry.containsKey('max_completion_tokens'), isTrue);
    });

    test('does NOT retry a non-param 4xx (auth error)', () async {
      await startServer((index, body) async => (401, authErrBody));

      Future<void> drain() async {
        await for (final _ in streamChatCompletion(
          provider: provider,
          settings: settings,
          messages: messages,
        )) {}
      }

      await expectLater(drain(), throwsA(isA<ChatApiError>()));
      expect(receivedBodies.length, 1);
    });
  });

  // BLOCKER 1: the Creator structured build sends `response_format:json_object`
  // via extraBody. When a provider rejects an unknown body key, the transport
  // already retries-without-extras — but it must SIGNAL the param fallback so
  // the build can latch a per-build flag and stop re-sending `response_format`
  // on every subsequent batch (avoiding a wasted 4xx round-trip each time).
  group('streamChatCompletion — onParamFallback signal', () {
    test('fires onParamFallback exactly once on a param-error retry', () async {
      await startServer((index, body) async {
        if (index == 0) return (400, paramErrBody);
        return (200, okJson('ok after retry'));
      });

      var fallbacks = 0;
      await for (final _ in streamChatCompletion(
        provider: provider,
        settings: settings,
        messages: messages,
        extraBody: const {
          'response_format': {'type': 'json_object'}
        },
        onParamFallback: () => fallbacks++,
      )) {}

      expect(fallbacks, 1, reason: 'param fallback should signal once');
    });

    test('does NOT fire onParamFallback on a clean (no-retry) request',
        () async {
      await startServer((index, body) async => (200, okJson('clean')));

      var fallbacks = 0;
      await for (final _ in streamChatCompletion(
        provider: provider,
        settings: settings,
        messages: messages,
        onParamFallback: () => fallbacks++,
      )) {}

      expect(fallbacks, 0);
    });
  });
}
