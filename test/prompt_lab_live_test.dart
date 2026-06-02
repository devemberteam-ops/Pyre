// Wave CY.18.213 (Prompt Observability — `live` mode): unit tests for the
// LIVE-mode plumbing in `tool/prompt_lab/live.dart`.
//
// This runs in the DEFAULT `flutter test` suite (it lives under `test/`) and
// NEVER touches the network or a real `tool/prompt_lab/local.json`:
//   • config PARSE — valid / comment-tolerant / invalid / placeholder.
//   • MISSING-config graceful path — `loadLiveConfig` on an absent file → null.
//   • parse-outcome CLASSIFICATION on CANNED response strings (one per feature).
//   • the apiKey never leaks into LiveConfig.toString().
//
// The actual live entrypoint (`tool/prompt_lab/prompt_lab_live.dart`) is NOT
// run here — it fires a real model call and is opt-in/manual.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/creator_schema.dart' show CreatorMode;

import '../tool/prompt_lab/live.dart';

void main() {
  group('parseLiveConfig', () {
    test('parses a minimal valid config', () {
      final cfg = parseLiveConfig('''
        { "baseUrl": "https://api.example/v1", "model": "m1",
          "apiKey": "sk-live-abc", "extraParams": {"reasoning": {"effort": "none"}} }
      ''');
      expect(cfg.baseUrl, 'https://api.example/v1');
      expect(cfg.model, 'm1');
      expect(cfg.apiKey, 'sk-live-abc');
      expect(cfg.extraParams['reasoning'], {'effort': 'none'});
      expect(cfg.kind, ProviderKind.external_);
    });

    test('ignores // comment keys (the example file documents itself)', () {
      // The committed local.example.json shape: comment keys + real keys.
      final cfg = parseLiveConfig('''
        {
          "//": "copy me to local.json",
          "//baseUrl": "the provider base url",
          "baseUrl": "https://x/v1",
          "model": "y",
          "apiKey": "PUT-YOUR-KEY-HERE",
          "extraParams": {},
          "kind": "localhost"
        }
      ''');
      expect(cfg.baseUrl, 'https://x/v1');
      expect(cfg.model, 'y');
      expect(cfg.kind, ProviderKind.localhost);
      // Placeholder key is recognised so we don't fire a doomed call.
      expect(cfg.hasPlaceholderKey, isTrue);
    });

    test('throws LiveConfigError on invalid JSON', () {
      expect(() => parseLiveConfig('{ not json'),
          throwsA(isA<LiveConfigError>()));
    });

    test('throws LiveConfigError when baseUrl is missing/blank', () {
      expect(() => parseLiveConfig('{ "model": "m" }'),
          throwsA(isA<LiveConfigError>()));
      expect(() => parseLiveConfig('{ "baseUrl": "  ", "model": "m" }'),
          throwsA(isA<LiveConfigError>()));
    });

    test('throws LiveConfigError when model is missing/blank', () {
      expect(() => parseLiveConfig('{ "baseUrl": "https://x" }'),
          throwsA(isA<LiveConfigError>()));
    });

    test('blank apiKey counts as placeholder (not configured)', () {
      final cfg = parseLiveConfig('{ "baseUrl": "https://x", "model": "m" }');
      expect(cfg.apiKey, '');
      expect(cfg.hasPlaceholderKey, isTrue);
    });
  });

  group('LiveConfig safety', () {
    test('toString never contains the apiKey', () {
      final cfg = parseLiveConfig(
          '{ "baseUrl": "https://x/v1", "model": "m", "apiKey": "sk-SECRET-XYZ" }');
      expect(cfg.toString(), isNot(contains('sk-SECRET-XYZ')));
      expect(cfg.toString(), contains('<redacted>'));
    });

    test('providerFromConfig carries the key into ApiProvider only', () {
      final cfg = parseLiveConfig(
          '{ "baseUrl": "https://x/v1", "model": "m", "apiKey": "sk-K" }');
      final p = providerFromConfig(cfg);
      expect(p.apiKey, 'sk-K');
      expect(p.baseUrl, 'https://x/v1');
      expect(p.model, 'm');
      // toJson() defaults to NOT including the key (matches Pyre persistence).
      expect(p.toJson().toString(), isNot(contains('sk-K')));
    });
  });

  group('loadLiveConfig — graceful missing-config path', () {
    test('returns null when the file is absent (no throw)', () {
      final cfg = loadLiveConfig(
          path: 'tool/prompt_lab/__definitely_not_here__.json');
      expect(cfg, isNull);
    });

    test('parses a present temp file', () {
      final tmp = File('${Directory.systemTemp.path}/pl_live_${pid}_a.json');
      tmp.writeAsStringSync(
          '{ "baseUrl": "https://x/v1", "model": "m", "apiKey": "k" }');
      try {
        final cfg = loadLiveConfig(path: tmp.path);
        expect(cfg, isNotNull);
        expect(cfg!.model, 'm');
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });

    test('re-throws on a present-but-invalid file', () {
      final tmp = File('${Directory.systemTemp.path}/pl_live_${pid}_b.json');
      tmp.writeAsStringSync('{ "model": "m" }'); // missing baseUrl
      try {
        expect(() => loadLiveConfig(path: tmp.path),
            throwsA(isA<LiveConfigError>()));
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });
  });

  group('the committed local.example.json is parseable + placeholder', () {
    test('parses with the placeholder key recognised', () {
      final file = File('tool/prompt_lab/local.example.json');
      expect(file.existsSync(), isTrue,
          reason: 'local.example.json must be committed');
      final cfg = parseLiveConfig(file.readAsStringSync());
      // The example must NOT carry a usable key — it's the placeholder.
      expect(cfg.hasPlaceholderKey, isTrue);
    });
  });

  group('featureForScenarioId', () {
    test('maps the known scenario ids', () {
      expect(featureForScenarioId('chat_single'), PromptLabFeature.chat);
      expect(featureForScenarioId('chat_group'), PromptLabFeature.chat);
      expect(featureForScenarioId('creator_character'),
          PromptLabFeature.creator);
      expect(featureForScenarioId('creator_scenario'),
          PromptLabFeature.creator);
      expect(featureForScenarioId('creator_persona'),
          PromptLabFeature.creator);
      expect(featureForScenarioId('creator_vision'), PromptLabFeature.vision);
      expect(featureForScenarioId('ltm_recap'), PromptLabFeature.ltm);
      expect(featureForScenarioId('livesheet_delta'),
          PromptLabFeature.liveSheet);
      expect(featureForScenarioId('scene_classify'), PromptLabFeature.scene);
    });

    test('unknown ids default to chat', () {
      expect(featureForScenarioId('whatever_new'), PromptLabFeature.chat);
    });
  });

  group('classifyLiveResponse — canned responses', () {
    test('chat: non-empty', () {
      final out = classifyLiveResponse(
          PromptLabFeature.chat, 'Vesna eyes the Gate warily.');
      expect(out, contains('non-empty'));
      expect(out, isNot(contains('truncated')));
    });

    test('chat: truncated when finish_reason=length', () {
      final out = classifyLiveResponse(
          PromptLabFeature.chat, 'a long reply cut off',
          finishReason: 'length');
      expect(out, contains('truncated'));
    });

    test('chat: empty', () {
      final out = classifyLiveResponse(PromptLabFeature.chat, '   ');
      expect(out, contains('EMPTY'));
    });

    test('creator: JSON-object reply + renderCard verdict over fixture fields',
        () {
      // The structured build expects ONE JSON object per batch; the outcome
      // line reports the JSON-object shape AND runs renderCard/missingRequired
      // over the fixture field map (the structured renderer's complete signal).
      final fields = <String, dynamic>{
        'fullName': 'Mina Calloway',
        'apparentAge': '22, 158cm, 49kg',
        'race': 'Catgirl',
        'generalAppearance': 'Small, self-effacing, ears that flatten.',
        'coreTraits': 'Shy, observant, secretly fierce.',
        'background': 'Raised above the cafe; stayed when her aunt passed.',
        'first_mes': '*Mina freezes mid-pour.* "O-oh — you\'re still here."',
        'dialogueExamples': [
          {'action': 'twisting her apron', 'dialogue': "It's just... late."},
        ],
      };
      final out = classifyLiveResponse(
        PromptLabFeature.creator,
        '{ "fullName": "Mina Calloway", "race": "Catgirl" }',
        creatorFields: fields,
        creatorMode: CreatorMode.character,
      );
      expect(out, contains('looks like a JSON object'));
      expect(out, contains('renderCard(character)'));
      expect(out, contains('Description non-empty'));
    });

    test('creator: reply that is NOT a bare JSON object', () {
      final out = classifyLiveResponse(
        PromptLabFeature.creator,
        'Let me think about how to fill the identity fields first.',
      );
      expect(out, contains('is NOT a bare JSON object'));
    });

    test('creator: empty reply', () {
      final out = classifyLiveResponse(PromptLabFeature.creator, '   ');
      expect(out, contains('is EMPTY'));
    });

    test('ltm: recapLooksComplete true on a terminated recap', () {
      final out = classifyLiveResponse(
          PromptLabFeature.ltm, 'They edged together toward the Maw.');
      expect(out, contains('recapLooksComplete = true'));
    });

    test('ltm: recapLooksComplete false on a cut-off recap', () {
      final out = classifyLiveResponse(
          PromptLabFeature.ltm, 'They edged together toward the',
          finishReason: 'length');
      expect(out, contains('recapLooksComplete = false'));
      expect(out, contains('truncated'));
    });

    test('liveSheet: parses delta ops from a canned delta', () {
      const canned = 'ENTITY: Ren\n+ clothing: skull hoodie, no trousers\n'
          'ENTITY: Vesna\n+ possessions: coil of delver rope';
      final out = classifyLiveResponse(PromptLabFeature.liveSheet, canned);
      expect(out, contains('delta op(s)'));
    });

    test('liveSheet: NO_CHANGE', () {
      final out =
          classifyLiveResponse(PromptLabFeature.liveSheet, 'NO_CHANGE');
      expect(out, contains('NO_CHANGE'));
    });

    test('scene (pure path): detects a JSON object', () {
      final out = classifyLiveResponse(PromptLabFeature.scene,
          '{ "location": "tavern", "setting": "fantasy" }');
      expect(out, contains('contains'));
    });

    test('vision: non-empty profile', () {
      final out = classifyLiveResponse(
          PromptLabFeature.vision, 'GENERAL PHYSICAL FEATURES\n...');
      expect(out, contains('non-empty profile'));
    });
  });
}
