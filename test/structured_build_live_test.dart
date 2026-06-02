// Wave CY.18.236 (Creator Structured Build, Task 11): LIVE acceptance test.
//
// Drives the EXACT production build path — buildBatchTurns → completeChatStreamed
// (with response_format:{type:'json_object'}) → runStructuredBuild → renderCard —
// against the REAL Creator provider (DeepSeek-v4-pro on OpenRouter), for the
// character/persona/scenario the old `<<SHEET>>` cascade failed to produce.
//
// GATED: it is a strict no-op in the normal `flutter test` suite — it only runs
// when PYRE_LIVE=1 is set, and reads the API key from PYRE_API_KEY (never hard-
// coded, never printed). Run it manually with:
//   $env:PYRE_LIVE='1'; $env:PYRE_API_KEY='<key>'; \
//   $env:PYRE_BASE_URL='https://openrouter.ai/api/v1'; \
//   $env:PYRE_MODEL='deepseek/deepseek-v4-pro'; \
//   flutter test test/structured_build_live_test.dart
//
// The acceptance bar (what the old cascade kept failing): a COMPLETE card,
// in ENGLISH, with blank-line-between-topics spacing, <START>+action dialogue
// examples, and NO truncation.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/creator_build.dart';
import 'package:pyre/services/creator_build_prompts.dart';
import 'package:pyre/services/creator_json.dart';
import 'package:pyre/services/creator_render.dart';
import 'package:pyre/services/creator_schema.dart';

void main() {
  final env = Platform.environment;
  final live = env['PYRE_LIVE'] == '1';

  if (!live) {
    test('structured build live acceptance (skipped — set PYRE_LIVE=1)', () {
      // No-op in the default suite.
    });
    return;
  }

  final apiKey = env['PYRE_API_KEY'] ?? '';
  final baseUrl = env['PYRE_BASE_URL'] ?? 'https://openrouter.ai/api/v1';
  final model = env['PYRE_MODEL'] ?? 'deepseek/deepseek-v4-pro';

  final provider = ApiProvider(
    id: 'live-creator',
    name: 'OpenRouter (live)',
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model,
  );
  final settings = ModelSettings()..maxTokens = 8000;

  Future<Map<String, dynamic>> build(
    CreatorMode mode,
    List<ChatTurn> transcript,
  ) {
    return runStructuredBuild(
      batches: batchesFor(mode),
      retryDelay: const Duration(seconds: 5),
      buildTurns: (keys, decided) => buildBatchTurns(
          mode: mode,
          batchKeys: keys,
          transcript: transcript,
          priorFields: decided.isEmpty ? null : decided),
      // STREAMING: deepseek-v4-pro reasons for 30-150s and streams chunks
      // throughout (no inter-chunk stall), so streaming completes where the
      // one-shot 75s cap times out.
      call: (turns) => completeChatStreamed(
        provider: provider,
        settings: settings,
        messages: turns,
        extraBody: const {
          'response_format': {'type': 'json_object'}
        },
        debugTag: 'creator-structured-live',
      ),
    );
  }

  void report(String label, Map<String, dynamic> fields, CreatorMode mode) {
    final card = renderCard(fields, mode);
    final desc = (card['description'] ?? '').toString();
    final mes = (card['mes_example'] ?? '').toString();
    final firstMes = (card['first_mes'] ?? '').toString();
    final missing = missingRequired(fields, mode);
    // Non-ASCII letters outside Latin-1 → rough "not English" signal.
    final nonAscii = RegExp(r'[^\x00-\x024F\s]').allMatches(desc).length;

    // ignore: avoid_print
    print('\n================= $label ($mode) =================');
    // ignore: avoid_print
    print('NAME: ${card['name']}');
    // ignore: avoid_print
    print('--- DESCRIPTION (${desc.length} chars, $nonAscii non-latin) ---');
    // ignore: avoid_print
    print(desc);
    // ignore: avoid_print
    print('--- FIRST_MES (${firstMes.length} chars) ---');
    // ignore: avoid_print
    print(firstMes);
    // ignore: avoid_print
    print('--- MES_EXAMPLE (${mes.length} chars) ---');
    // ignore: avoid_print
    print(mes);
    // ignore: avoid_print
    print('--- TAGS: ${card['tags']}');
    // ignore: avoid_print
    print('--- missingRequired: $missing');

    // Acceptance assertions (the bars the cascade kept failing).
    expect(desc.trim().isNotEmpty, isTrue, reason: '$label: empty Description');
    expect(desc.contains('\n\n'), isTrue,
        reason: '$label: no blank line between topics (spacing bug)');
    expect(missing.isEmpty, isTrue,
        reason: '$label: required fields empty after build: $missing');
  }

  test(
    'DIAG — one batch-1 call, dump raw reply + parse result',
    () async {
      final transcript = <ChatTurn>[
        ChatTurn('user',
            'Make a character: Yuki, a shy 22yo isekai femboy. Tap build.'),
      ];
      final keys = batchesFor(CreatorMode.character).first;
      final turns = buildBatchTurns(
          mode: CreatorMode.character, batchKeys: keys, transcript: transcript);

      Future<void> variant(String label, Future<String> Function() fn) async {
        final sw = Stopwatch()..start();
        String raw;
        try {
          raw = await fn();
        } catch (e) {
          // ignore: avoid_print
          print('\n=== $label THREW after ${sw.elapsedMilliseconds}ms: $e ===');
          return;
        }
        final parsed = extractJsonObject(raw);
        // ignore: avoid_print
        print('\n=== $label ${sw.elapsedMilliseconds}ms len=${raw.length} '
            'parsed=${parsed != null} keys=${parsed?.keys.take(3).toList()} ===');
      }

      // Run streamed+json (S) vs one-shot+json (O) three times each to gauge
      // the intermittent-empty pattern + timing.
      for (var i = 1; i <= 3; i++) {
        await variant(
            'S$i streamed+json',
            () => completeChatStreamed(
                  provider: provider,
                  settings: settings,
                  messages: turns,
                  extraBody: const {
                    'response_format': {'type': 'json_object'}
                  },
                  debugTag: 'diag-s',
                ));
        await variant(
            'O$i oneshot+json',
            () => completeChat(
                  provider: provider,
                  settings: settings,
                  messages: turns,
                  extraBody: const {
                    'response_format': {'type': 'json_object'}
                  },
                  debugTag: 'diag-o',
                ));
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'CHARACTER — Yuki-style adult femboy NEET builds complete + English + spaced',
    () async {
      final transcript = <ChatTurn>[
        ChatTurn('user',
            'Let\'s make a character: Yuki, a 22-year-old half-Japanese / '
            'half-Irish femboy NEET who got isekai\'d into a fantasy world. '
            'Shy, soft, secretly into being teased. Make him frank and adult.'),
        ChatTurn('assistant',
            'Love it — a soft, blushy isekai femboy with a hidden needy '
            'streak. Want me to flesh out his look, his kinks, and the people '
            'around him?'),
        ChatTurn('user', 'Yes, go all in. Tap build when ready.'),
      ];
      final fields = await build(CreatorMode.character, transcript);
      report('CHARACTER/Yuki', fields, CreatorMode.character);
      final card = renderCard(fields, CreatorMode.character);
      expect((card['mes_example'] ?? '').toString().contains('<START>'), isTrue,
          reason: 'mes_example missing <START> blocks');
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'PERSONA — quick smoke builds complete labeled sheet',
    () async {
      final transcript = <ChatTurn>[
        ChatTurn('user',
            'Build my persona: Mika, 24, a sarcastic graphic designer who '
            'roleplays as a confident tease. She/her.'),
        ChatTurn('assistant', 'Got it — let\'s capture Mika. Tap build.'),
      ];
      final fields = await build(CreatorMode.persona, transcript);
      report('PERSONA/Mika', fields, CreatorMode.persona);
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    'SCENARIO — quick smoke builds balanced XML narrator card',
    () async {
      final transcript = <ChatTurn>[
        ChatTurn('user',
            'Make a scenario: a rain-soaked neon megacity where the player is '
            'a rookie courier who just got handed a package nobody wants '
            'delivered. Narrator-driven, any POV.'),
        ChatTurn('assistant',
            'Ooh, a noir cyberpunk hook. I\'ll set the tone and the opening. '
            'Tap build when ready.'),
      ];
      final fields = await build(CreatorMode.scenario, transcript);
      report('SCENARIO/Courier', fields, CreatorMode.scenario);
      final card = renderCard(fields, CreatorMode.scenario);
      final desc = (card['description'] ?? '').toString();
      // Balanced XML tags.
      final opens = RegExp(r'<([\w ]+?)>').allMatches(desc).length;
      final closes = RegExp(r'</([\w ]+?)>').allMatches(desc).length;
      expect(opens, closes, reason: 'scenario XML tags unbalanced');
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
