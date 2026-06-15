@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';

/// Pyre 1.1.3 — Anthropic adapter defect tests.
///
/// Defect 1 (retry): param-error 4xx on Anthropic paths must retry EXACTLY
/// ONCE with [minimalAnthropicRetryBody], mirroring the OpenAI path.
///
/// Defect 2 (system placement): only LEADING system turns belong in the
/// top-level `system` field; post-history system turns must appear IN-ORDER
/// as user-role turns in `messages`, not folded into `system`.

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

final ModelSettings defaultSettings = ModelSettings();

// ---------------------------------------------------------------------------
// Pure body-builder tests (no network)
// ---------------------------------------------------------------------------

void main() {
  group('buildAnthropicBody — Defect 2: system turn placement', () {
    test(
        'leading system turn lands in top-level `system` field, '
        'not in `messages`', () {
      final msgs = [
        ChatTurn('system', 'You are a helpful assistant.'),
        ChatTurn('user', 'Hi.'),
        ChatTurn('assistant', 'Hello!'),
      ];
      final body = buildAnthropicBody(
        messages: msgs,
        settings: defaultSettings,
        model: 'claude-3-5-sonnet-20241022',
        stream: false,
      );

      expect(body['system'], 'You are a helpful assistant.');
      final messages = body['messages'] as List;
      // System text must NOT appear in any message turn.
      for (final m in messages) {
        final content = m['content'];
        if (content is String) {
          expect(content, isNot(contains('You are a helpful assistant.')),
              reason: 'leading system content must not appear in messages');
        }
      }
    });

    test(
        'post-history system turn appears as a user-role turn IN ORDER '
        'in `messages`, NOT folded into top-level `system`', () {
      // Simulates: char card system turn, then chat, then a post-history
      // jailbreak / scene / roadmap injected as a system turn AFTER turns.
      final msgs = [
        ChatTurn('system', 'Character card system prompt.'),
        ChatTurn('user', 'Turn 1.'),
        ChatTurn('assistant', 'Reply 1.'),
        ChatTurn('system', 'POST-HISTORY JAILBREAK'), // <-- the defect case
        ChatTurn('user', 'Turn 2.'),
      ];
      final body = buildAnthropicBody(
        messages: msgs,
        settings: defaultSettings,
        model: 'claude-3-5-sonnet-20241022',
        stream: false,
      );

      // Leading system → top-level `system`.
      expect(body['system'], 'Character card system prompt.');
      // Post-history system text must NOT be in the top-level `system` field.
      expect(body['system'], isNot(contains('POST-HISTORY JAILBREAK')),
          reason:
              'post-history system turn must not be folded into system field');

      // It MUST appear in `messages` as a user-role turn in order.
      final messages = body['messages'] as List;
      // Find the position of the post-history content.
      final postHistIdx = messages.indexWhere((m) {
        final c = m['content'];
        return c is String && c.contains('POST-HISTORY JAILBREAK');
      });
      expect(postHistIdx, greaterThan(-1),
          reason: 'post-history jailbreak must appear in messages');
      expect(messages[postHistIdx]['role'], 'user',
          reason: 'post-history system turn must be converted to user role');

      // The post-history turn must appear BEFORE Turn 2 (position check).
      final turn2Idx = messages.indexWhere((m) {
        final c = m['content'];
        return c is String && c.contains('Turn 2');
      });
      // Note: the merge logic may fold consecutive user turns together.
      // Either the jailbreak is a separate entry before turn2 OR it was
      // merged into the same user turn that contains "Turn 2". Both are
      // correct; what matters is it's NOT in `system` and the roles alternate.
      if (postHistIdx != -1 && turn2Idx != -1) {
        // If they are separate entries, jailbreak must come before turn2.
        expect(postHistIdx, lessThanOrEqualTo(turn2Idx),
            reason: 'post-history jailbreak must precede turn 2 in messages');
      }
    });

    test('role alternation is preserved when post-history system is inline',
        () {
      // Pattern: user turn, then post-history system (→ user), then next user.
      // The merge must fold them to avoid two consecutive user turns.
      final msgs = [
        ChatTurn('system', 'System prompt.'),
        ChatTurn('user', 'User message.'),
        ChatTurn('assistant', 'Assistant reply.'),
        ChatTurn('system', 'Mid-scene injection.'), // converts to user
        ChatTurn('user', 'Next user message.'),   // already user → should merge
      ];
      final body = buildAnthropicBody(
        messages: msgs,
        settings: defaultSettings,
        model: 'claude-3-5-sonnet-20241022',
        stream: false,
      );

      final messages = body['messages'] as List;
      // Verify strict alternation: no two consecutive same-role turns.
      for (var i = 0; i < messages.length - 1; i++) {
        expect(messages[i]['role'], isNot(messages[i + 1]['role']),
            reason:
                'consecutive messages[$i] and messages[${i + 1}] have the '
                'same role "${messages[i]['role']}" — role alternation broken');
      }
    });

    test('multiple leading system turns are all folded into top-level `system`',
        () {
      final msgs = [
        ChatTurn('system', 'Part A.'),
        ChatTurn('system', 'Part B.'),
        ChatTurn('user', 'Hello.'),
      ];
      final body = buildAnthropicBody(
        messages: msgs,
        settings: defaultSettings,
        model: 'claude-3-5-sonnet-20241022',
        stream: false,
      );
      expect(body['system'], contains('Part A.'));
      expect(body['system'], contains('Part B.'));
    });

    test('no system turns → `system` field absent', () {
      final msgs = [
        ChatTurn('user', 'Hi.'),
        ChatTurn('assistant', 'Hey.'),
      ];
      final body = buildAnthropicBody(
        messages: msgs,
        settings: defaultSettings,
        model: 'claude-3-5-sonnet-20241022',
        stream: false,
      );
      expect(body.containsKey('system'), isFalse);
    });

    test('only-system-turns message list → `system` set, `messages` empty '
        '(or just the injected leading user turn if needed)', () {
      final msgs = [
        ChatTurn('system', 'All system.'),
      ];
      final body = buildAnthropicBody(
        messages: msgs,
        settings: defaultSettings,
        model: 'claude-3-5-sonnet-20241022',
        stream: false,
      );
      expect(body['system'], 'All system.');
      // No convo turns → messages array should be empty (no user/assistant).
      final messages = body['messages'] as List;
      expect(messages, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Defect 1 (Defect 1): minimalAnthropicRetryBody pure unit tests
  // ---------------------------------------------------------------------------

  group('minimalAnthropicRetryBody — Defect 1: managed keys / extras dropped',
      () {
    test('drops extra params (e.g. frequency_penalty from an OpenAI preset)',
        () {
      final body = <String, dynamic>{
        'model': 'claude-3-5-sonnet-20241022',
        'max_tokens': 4096,
        'system': 'System prompt.',
        'messages': [
          {'role': 'user', 'content': 'Hi.'}
        ],
        'stream': false,
        'temperature': 0.7,
        'top_p': 0.9,
        'top_k': 40,
        'stop_sequences': ['END'],
        // Extras that Anthropic rejects:
        'frequency_penalty': 0.5,
        'presence_penalty': 0.2,
        'response_format': {'type': 'json_object'},
        'reasoning_effort': 'high',
        'some_custom_param': 'bad',
      };

      final minimal = minimalAnthropicRetryBody(body);

      // Managed keys preserved.
      expect(minimal['model'], 'claude-3-5-sonnet-20241022');
      expect(minimal['max_tokens'], 4096);
      expect(minimal['system'], 'System prompt.');
      expect(minimal['messages'], isA<List>());
      expect(minimal['stream'], false);
      expect(minimal['temperature'], 0.7);
      expect(minimal['top_p'], 0.9);
      expect(minimal['top_k'], 40);
      expect(minimal['stop_sequences'], ['END']);

      // Extras dropped.
      expect(minimal.containsKey('frequency_penalty'), isFalse);
      expect(minimal.containsKey('presence_penalty'), isFalse);
      expect(minimal.containsKey('response_format'), isFalse);
      expect(minimal.containsKey('reasoning_effort'), isFalse);
      expect(minimal.containsKey('some_custom_param'), isFalse);
    });

    test('preserves managed keys even when extras are absent', () {
      final body = <String, dynamic>{
        'model': 'claude-opus-4-5',
        'max_tokens': 2048,
        'messages': <dynamic>[],
        'stream': true,
      };
      final minimal = minimalAnthropicRetryBody(body);
      expect(minimal['model'], 'claude-opus-4-5');
      expect(minimal['max_tokens'], 2048);
      expect(minimal['stream'], true);
    });

    test('does not mutate the original body', () {
      final body = <String, dynamic>{
        'model': 'm',
        'max_tokens': 100,
        'messages': <dynamic>[],
        'stream': false,
        'bad_param': 'oops',
      };
      final original = Map<String, dynamic>.from(body);
      minimalAnthropicRetryBody(body);
      expect(body, equals(original),
          reason: 'minimalAnthropicRetryBody must be pure / non-mutating');
    });

    test('omits optional managed keys when they are absent from original', () {
      final body = <String, dynamic>{
        'model': 'm',
        'max_tokens': 512,
        'messages': <dynamic>[],
        'stream': false,
        // no system, top_p, top_k, stop_sequences, temperature
      };
      final minimal = minimalAnthropicRetryBody(body);
      expect(minimal.containsKey('system'), isFalse);
      expect(minimal.containsKey('top_p'), isFalse);
      expect(minimal.containsKey('top_k'), isFalse);
      expect(minimal.containsKey('stop_sequences'), isFalse);
      expect(minimal.containsKey('temperature'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Defect 1 (integration): retry on param-error 4xx — loopback HTTP server
  // ---------------------------------------------------------------------------

  group('_streamAnthropic — Defect 1: param-error retry', () {
    late HttpServer server;
    late ApiProvider provider;
    late List<Map<String, dynamic>> receivedBodies;

    const paramErrBody =
        '{"type":"error","error":{"type":"invalid_request_error",'
        '"message":"Unsupported parameter: \'frequency_penalty\' is not '
        'supported with this model."}}';

    String okAnthropicJson(String content) => jsonEncode({
          'id': 'msg_test',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': content}
          ],
          'model': 'claude-3-5-sonnet-20241022',
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 10, 'output_tokens': 5},
        });

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
        req.response.headers.contentType = ContentType.json;
        req.response.write(respBody);
        await req.response.close();
      });
      provider = ApiProvider(
        id: 'ant-test',
        name: 'Anthropic Test',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'sk-ant-secret',
        model: 'claude-3-5-sonnet-20241022',
        format: ApiFormat.anthropic,
        // Stray OpenAI-ish extra param that Anthropic /v1/messages rejects.
        extraParams: {'frequency_penalty': 0.5},
      );
    }

    tearDown(() async {
      await server.close(force: true);
    });

    test('streamChatCompletion retries once with minimal body and succeeds',
        () async {
      await startServer((index, body) async {
        if (index == 0) return (400, paramErrBody);
        return (200, okAnthropicJson('hello after retry'));
      });

      final buf = StringBuffer();
      await for (final chunk in streamChatCompletion(
        provider: provider,
        settings: defaultSettings,
        messages: [ChatTurn('user', 'Hi.')],
      )) {
        buf.write(chunk);
      }
      expect(buf.toString(), contains('hello after retry'));
      expect(receivedBodies.length, 2,
          reason: 'must send original + 1 retry, no more');

      // First body has the stray extra param.
      expect(receivedBodies[0].containsKey('frequency_penalty'), isTrue);

      // Retry body must NOT have the stray param.
      final retry = receivedBodies[1];
      expect(retry.containsKey('frequency_penalty'), isFalse,
          reason: 'extra param must be dropped in retry body');
      // Managed keys must be present.
      expect(retry['model'], 'claude-3-5-sonnet-20241022');
      expect(retry['max_tokens'], isA<int>());
      expect(retry['messages'], isA<List>());
    });

    test('does NOT retry a non-param 4xx (auth error)', () async {
      const authErr =
          '{"type":"error","error":{"type":"authentication_error",'
          '"message":"Invalid API key provided."}}';
      await startServer((index, body) async => (401, authErr));

      Future<void> drain() async {
        await for (final _ in streamChatCompletion(
          provider: provider,
          settings: defaultSettings,
          messages: [ChatTurn('user', 'Hi.')],
        )) {}
      }

      await expectLater(drain(), throwsA(isA<ChatApiError>()));
      expect(receivedBodies.length, 1,
          reason: 'auth error must not be retried');
    });

    test(
        'second param-error 4xx on the retry surfaces error (no loop)',
        () async {
      await startServer(
          (index, body) async => (400, paramErrBody)); // always fail

      Future<void> drain() async {
        await for (final _ in streamChatCompletion(
          provider: provider,
          settings: defaultSettings,
          messages: [ChatTurn('user', 'Hi.')],
        )) {}
      }

      await expectLater(drain(), throwsA(isA<ChatApiError>()));
      expect(receivedBodies.length, 2,
          reason: 'exactly 2 attempts: original + one retry, then error');
    });
  });

  group('_completeAnthropic — Defect 1: param-error retry', () {
    late HttpServer server;
    late ApiProvider provider;
    late List<Map<String, dynamic>> receivedBodies;

    const paramErrBody =
        '{"type":"error","error":{"type":"invalid_request_error",'
        '"message":"Unsupported parameter: \'response_format\' is not '
        'supported with this model."}}';

    String okAnthropicJson(String content) => jsonEncode({
          'id': 'msg_test',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': content}
          ],
          'model': 'claude-3-5-sonnet-20241022',
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 10, 'output_tokens': 5},
        });

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
        req.response.headers.contentType = ContentType.json;
        req.response.write(respBody);
        await req.response.close();
      });
      provider = ApiProvider(
        id: 'ant-test',
        name: 'Anthropic Test',
        baseUrl: 'http://${server.address.host}:${server.port}/v1',
        apiKey: 'sk-ant-secret',
        model: 'claude-3-5-sonnet-20241022',
        format: ApiFormat.anthropic,
        extraParams: {'response_format': 'bad_field'},
      );
    }

    tearDown(() async {
      await server.close(force: true);
    });

    test('completeChat retries once with minimal body and succeeds', () async {
      await startServer((index, body) async {
        if (index == 0) return (400, paramErrBody);
        return (200, okAnthropicJson('one-shot after retry'));
      });

      final text = await completeChat(
        provider: provider,
        settings: defaultSettings,
        messages: [ChatTurn('user', 'Hi.')],
      );
      expect(text, contains('one-shot after retry'));
      expect(receivedBodies.length, 2);

      expect(receivedBodies[0].containsKey('response_format'), isTrue);
      expect(receivedBodies[1].containsKey('response_format'), isFalse);
    });

    test('does NOT retry a non-param 4xx on completeChat', () async {
      const authErr =
          '{"type":"error","error":{"type":"authentication_error",'
          '"message":"Invalid API key."}}';
      await startServer((index, body) async => (401, authErr));

      await expectLater(
        completeChat(
          provider: provider,
          settings: defaultSettings,
          messages: [ChatTurn('user', 'Hi.')],
        ),
        throwsA(isA<ChatApiError>()),
      );
      expect(receivedBodies.length, 1);
    });

    test('second param-error 4xx on the retry surfaces error (no loop)',
        () async {
      await startServer(
          (index, body) async => (400, paramErrBody)); // always fail

      await expectLater(
        completeChat(
          provider: provider,
          settings: defaultSettings,
          messages: [ChatTurn('user', 'Hi.')],
        ),
        throwsA(isA<ChatApiError>()),
      );
      expect(receivedBodies.length, 2,
          reason: 'exactly 2 attempts: original + one retry, then error');
    });
  });
}
