// Wave CY.18.214: tests for the opt-in LLM diagnostics log.
//
// Covers the three load-bearing guarantees:
//   (a) when ENABLED, `record` writes a tagged JSONL line that round-trips;
//   (b) when DISABLED, NOTHING is written (strict no-op);
//   (c) KEY-ABSENCE — a record built from a request whose provider used a
//       recognizable sentinel apiKey must not contain that sentinel
//       ANYWHERE in the serialized record / the written JSONL line.
//
// The log dir is redirected to a temp dir via `debugOverrideDir`, so these
// tests need no path_provider mock. `enabled` is persisted via
// SharedPreferences, so we install the in-memory mock + the test binding.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/llm_debug_log.dart';

/// The recognizable dummy key. It must NEVER appear in any logged bytes.
const String _kSentinelKey = 'sk-SENTINEL-DO-NOT-LOG';

/// Build the EXACT key-free request body chat_api serialises, then turn it
/// into an [LlmCallRecord] the way the chat_api hook does — capturing only
/// the provider NAME (not its apiKey/baseUrl/headers). This mirrors the
/// production capture path so the key-absence assertion is meaningful.
LlmCallRecord _recordFromProvider(
  ApiProvider provider, {
  required String feature,
  required List<ChatTurn> messages,
  required String response,
}) {
  // The body chat_api builds: extraParams + model + messages + sampling +
  // stream. NOTE: NO apiKey here — it rides the Authorization header.
  final body = <String, dynamic>{
    ...provider.extraParams,
    'model': provider.model,
    'messages': messages.map((m) => m.toJson()).toList(),
    'temperature': 0.8,
    'top_p': 0.95,
    'max_tokens': 512,
    'stream': true,
  };
  return LlmCallRecord(
    ts: DateTime.now().millisecondsSinceEpoch,
    feature: feature,
    provider: provider.name, // NAME ONLY — never the key
    model: provider.model,
    messages: (body['messages'] as List?) ?? const <dynamic>[],
    sampling: <String, dynamic>{
      for (final e in body.entries)
        if (e.key != 'messages') e.key: e.value,
    },
    response: response,
    finishReason: 'stop',
    durationMs: 1234,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('pyre_llm_log_test_');
    LlmDebugLog.instance.debugOverrideDir = tmp;
    // Start from a known-OFF state each test.
    await LlmDebugLog.instance.setEnabled(false);
  });

  tearDown(() async {
    LlmDebugLog.instance.debugOverrideDir = null;
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('(a) when enabled, record writes a tagged JSONL line that round-trips',
      () async {
    await LlmDebugLog.instance.setEnabled(true);
    expect(LlmDebugLog.instance.enabled, isTrue);

    final provider = ApiProvider(
      id: 'p1',
      name: 'Test Provider',
      baseUrl: 'https://api.example.com',
      apiKey: _kSentinelKey,
      model: 'test-model-x',
    );
    final rec = _recordFromProvider(
      provider,
      feature: 'chat',
      messages: [
        ChatTurn('system', 'You are a test.'),
        ChatTurn('user', 'Hello there.'),
      ],
      response: 'General Kenobi.',
    );

    await LlmDebugLog.instance.record(rec);

    // Exactly one .jsonl file (today's), with exactly one line.
    final files = await LlmDebugLog.instance.logFiles();
    expect(files, hasLength(1));
    final raw = await files.first.readAsString();
    final lines = const LineSplitter()
        .convert(raw)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    expect(lines, hasLength(1));

    // Round-trip the JSON line and check the captured fields.
    final decoded = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(decoded['feature'], 'chat');
    expect(decoded['provider'], 'Test Provider');
    expect(decoded['model'], 'test-model-x');
    expect(decoded['response'], 'General Kenobi.');
    expect(decoded['finishReason'], 'stop');
    expect(decoded['durationMs'], 1234);
    final msgs = decoded['messages'] as List;
    expect(msgs, hasLength(2));
    expect((msgs.first as Map)['role'], 'system');
    expect((msgs.last as Map)['content'], 'Hello there.');
    final sampling = decoded['sampling'] as Map<String, dynamic>;
    expect(sampling['model'], 'test-model-x');
    expect(sampling['temperature'], 0.8);
    expect(sampling.containsKey('messages'), isFalse); // split out cleanly
  });

  test('(b) when disabled, NOTHING is written', () async {
    // enabled is false from setUp.
    expect(LlmDebugLog.instance.enabled, isFalse);

    final provider = ApiProvider(
      id: 'p2',
      name: 'Test Provider',
      apiKey: _kSentinelKey,
      model: 'test-model-x',
    );
    final rec = _recordFromProvider(
      provider,
      feature: 'ltm',
      messages: [ChatTurn('user', 'Summarise.')],
      response: 'A recap.',
    );

    await LlmDebugLog.instance.record(rec);

    // No file should have been created at all.
    final files = await LlmDebugLog.instance.logFiles();
    expect(files, isEmpty);
    expect(await LlmDebugLog.instance.readAll(), isEmpty);
  });

  test(
      '(c) KEY-ABSENCE: the sentinel apiKey appears nowhere in the serialized '
      'record or the written JSONL line', () async {
    await LlmDebugLog.instance.setEnabled(true);

    final provider = ApiProvider(
      id: 'p3',
      name: 'Venice', // a realistic display name
      baseUrl: 'https://api.venice.ai/api/v1',
      apiKey: _kSentinelKey,
      model: 'qwen-3.6-plus',
      // Even put junk in extraParams + headers to be thorough — only
      // extraParams flows into the body; headers must NEVER be logged.
      extraParams: {'reasoning': {'effort': 'none'}},
      headers: {'X-Custom': 'value'},
    );
    final rec = _recordFromProvider(
      provider,
      feature: 'creator-vision',
      messages: [
        ChatTurn('system', 'Describe the image.'),
        ChatTurn('user', 'Here it is.'),
      ],
      response: 'A clinical description.',
    );

    // 1. The in-memory serialized record must not contain the key.
    final serialized = jsonEncode(rec.toJson());
    expect(serialized.contains(_kSentinelKey), isFalse,
        reason: 'sentinel key leaked into the serialized LlmCallRecord');

    // 2. Write it and re-read the whole file — still no key anywhere.
    await LlmDebugLog.instance.record(rec);
    final onDisk = await LlmDebugLog.instance.readAll();
    expect(onDisk.isNotEmpty, isTrue);
    expect(onDisk.contains(_kSentinelKey), isFalse,
        reason: 'sentinel key leaked into the written JSONL log');

    // 3. Sanity: the log DID capture the (key-free) request — so the
    // absence above is meaningful, not just an empty file.
    expect(onDisk.contains('qwen-3.6-plus'), isTrue);
    expect(onDisk.contains('Describe the image.'), isTrue);
    expect(onDisk.contains('A clinical description.'), isTrue);
    // The header value must not be present either.
    expect(onDisk.contains('X-Custom'), isFalse);
    expect(onDisk.contains('"value"'), isFalse);
  });
}
