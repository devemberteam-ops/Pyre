import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/scene_background.dart';

// Reads the real bundled manifest off disk (test cwd == flutter_app/),
// mirroring test/example_seed_test.dart.
SceneManifest _realManifest() {
  final f = File('assets/scene_bg/manifest.json');
  return SceneManifest.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
}

void main() {
  group('SceneManifest.fromJson (real bundled manifest)', () {
    test('parses 200 categories, 18 aesthetics, neutral fallback', () {
      final m = _realManifest();
      expect(m.version, 1);
      expect(m.fallbackSlug, 'neutral');
      expect(m.aesthetics.length, 18);
      expect(m.aesthetics, contains('modern'));
      expect(m.aesthetics, contains('cyberpunk'));
      expect(m.categories.length, 200);
      expect(m.slugs, contains('neutral'));
    });

    test('every category has whenToUse + keywords; every image has file/aesthetic/timeOfDay', () {
      final m = _realManifest();
      for (final c in m.categories) {
        expect(c.slug, isNotEmpty);
        expect(c.whenToUse, isNotEmpty, reason: 'whenToUse empty for ${c.slug}');
        expect(c.keywords, isNotEmpty, reason: 'no keywords for ${c.slug}');
        expect(c.images, isNotEmpty, reason: 'no images for ${c.slug}');
        for (final img in c.images) {
          expect(img.file, isNotEmpty);
          expect(img.aesthetic, isNotEmpty);
          expect(img.timeOfDay, isNotEmpty);
        }
      }
    });

    test('categoryBySlug returns the matching category or null', () {
      final m = _realManifest();
      expect(m.categoryBySlug('neutral')?.slug, 'neutral');
      expect(m.categoryBySlug('definitely_not_a_slug'), isNull);
    });
  });

  group('manifest-vs-disk spot-check', () {
    test('a handful of manifest-referenced image files actually exist', () {
      final m = _realManifest();
      // Sample across the category list so a partial copy is caught.
      for (final idx in [0, 50, 100, 150, 199]) {
        final c = m.categories[idx];
        final file = c.images.first.file;
        final onDisk = File('assets/scene_bg/images/$file');
        expect(onDisk.existsSync(), isTrue,
            reason: 'missing bundled asset: $file (category ${c.slug})');
      }
    });
  });

  group('parseClassifierJson', () {
    final m = _realManifest();

    test('clean JSON object', () {
      final v = parseClassifierJson(
          '{"location":"bedroom","setting":"modern","timeOfDay":"night","confidence":"high"}',
          m);
      expect(v, isNotNull);
      expect(v!.location, 'bedroom');
      expect(v.setting, 'modern');
      expect(v.timeOfDay, 'night');
      expect(v.confidence, 'high');
      expect(v.locationNote, ''); // absent -> empty
    });

    test('parses a locationNote when present', () {
      final v = parseClassifierJson(
          '{"location":"fantasy_tavern","setting":"medieval_fantasy","timeOfDay":"unknown","confidence":"high","locationNote":"candle-lit fantasy tavern"}',
          m);
      expect(v, isNotNull);
      expect(v!.location, 'fantasy_tavern');
      expect(v.locationNote, 'candle-lit fantasy tavern');
    });

    test('locationNote absent -> empty string (not null)', () {
      final v = parseClassifierJson(
          '{"location":"cafe","setting":"modern","timeOfDay":"unknown","confidence":"high"}',
          m);
      expect(v?.locationNote, '');
    });

    test('locationNote collapses internal whitespace + trims', () {
      // \\n is a JSON-escaped newline inside the string value (valid JSON);
      // the parser must collapse it + the runs of spaces to single spaces.
      final v = parseClassifierJson(
          '{"location":"beach","setting":"modern","timeOfDay":"dusk","confidence":"high","locationNote":"  beach   at\\n sunset  "}',
          m);
      expect(v?.locationNote, 'beach at sunset');
    });

    test('a long locationNote prose is accepted (capped, not rejected)', () {
      final longNote = 'a ' * 200; // ~400 chars
      final v = parseClassifierJson(
          '{"location":"beach","setting":"modern","timeOfDay":"unknown","confidence":"low","locationNote":"$longNote"}',
          m);
      expect(v, isNotNull, reason: 'prose in locationNote must not fail parse');
      expect(v!.locationNote.length, lessThanOrEqualTo(120));
    });

    test('strips ```json fences', () {
      final v = parseClassifierJson(
          '```json\n{"location":"beach","setting":"modern","timeOfDay":"dusk","confidence":"high"}\n```',
          m);
      expect(v?.location, 'beach');
    });

    test('tolerates leading/trailing prose', () {
      final v = parseClassifierJson(
          'Sure! Here is the classification:\n{"location":"cafe","setting":"modern","timeOfDay":"unknown","confidence":"high"} Hope that helps.',
          m);
      expect(v?.location, 'cafe');
    });

    test('accepts location "none" + setting "unknown"', () {
      final v = parseClassifierJson(
          '{"location":"none","setting":"unknown","timeOfDay":"unknown","confidence":"low"}',
          m);
      expect(v?.location, 'none');
      expect(v?.setting, 'unknown');
      expect(v?.confidence, 'low');
    });

    test('unknown location slug -> null', () {
      final v = parseClassifierJson(
          '{"location":"narnia_wardrobe","setting":"modern","timeOfDay":"day","confidence":"high"}',
          m);
      expect(v, isNull);
    });

    test('unknown setting -> null', () {
      final v = parseClassifierJson(
          '{"location":"bedroom","setting":"klingon","timeOfDay":"day","confidence":"high"}',
          m);
      expect(v, isNull);
    });

    test('garbage / no JSON -> null', () {
      expect(parseClassifierJson('I cannot help with that.', m), isNull);
      expect(parseClassifierJson('', m), isNull);
    });

    test('soft-coerces invalid timeOfDay/confidence to safe defaults', () {
      final v = parseClassifierJson(
          '{"location":"bedroom","setting":"modern","timeOfDay":"twilight","confidence":"maybe"}',
          m);
      expect(v, isNotNull);
      expect(v!.timeOfDay, 'unknown'); // unrecognised -> unknown
      expect(v.confidence, 'low');     // unrecognised -> low (= keep, anti-flicker)
    });
  });

  group('keywordPrePass', () {
    final m = _realManifest();

    test('matches a real category keyword (case-insensitive, word-boundary)', () {
      // "bedroom" is a keyword of the bedroom category.
      expect(keywordPrePass(m, 'She collapsed onto her BEDROOM floor.'), 'bedroom');
    });

    test('no match returns null', () {
      expect(keywordPrePass(m, 'asdf qwerty zzz nothing here'), isNull);
    });

    test('no false substring match', () {
      // a keyword should not fire as a substring of a larger word.
      // "bed" inside "embedded" must NOT match a "bed" keyword.
      final r = keywordPrePass(m, 'the firmware was embedded deeply');
      expect(r == 'bedroom', isFalse);
    });

    test('higher-priority category wins on overlap', () {
      // Build a tiny synthetic manifest so the priority tie-break is exact.
      final synth = SceneManifest(
        version: 1,
        fallbackSlug: 'neutral',
        aesthetics: const ['modern'],
        categories: [
          SceneCategory(
              slug: 'low',
              name: 'Low',
              whenToUse: '',
              notWhen: null,
              priority: 2,
              keywords: const ['garden'],
              images: const []),
          SceneCategory(
              slug: 'high',
              name: 'High',
              whenToUse: '',
              notWhen: null,
              priority: 9,
              keywords: const ['garden'],
              images: const []),
        ],
      );
      expect(keywordPrePass(synth, 'they walked through the garden'), 'high');
    });
  });

  group('sceneCatalog (Wave 243)', () {
    final m = _realManifest();

    test('one described line per category, each starts with "<slug> —"', () {
      final cat = sceneCatalog(m);
      final lines = cat.split('\n');
      expect(lines.length, m.categories.length);
      for (final c in m.categories) {
        // Every category contributes exactly one "<slug> — …" line.
        final hit = lines.where((l) => l.startsWith('${c.slug} — ')).toList();
        expect(hit.length, 1, reason: 'missing/dup catalog line for ${c.slug}');
      }
    });

    test('mushroom_cave line carries its glowing-fungi gloss', () {
      final cat = sceneCatalog(m);
      final line = cat
          .split('\n')
          .firstWhere((l) => l.startsWith('mushroom_cave — '));
      // The whenToUse mentions glowing mushrooms / bioluminescent fungi.
      final lower = line.toLowerCase();
      expect(lower.contains('glowing') || lower.contains('bioluminescent'),
          isTrue,
          reason: 'mushroom_cave gloss should describe glowing fungi: $line');
    });

    test('jungle_ruins line carries its jungle/temple gloss', () {
      final cat = sceneCatalog(m);
      final line =
          cat.split('\n').firstWhere((l) => l.startsWith('jungle_ruins — '));
      final lower = line.toLowerCase();
      expect(lower.contains('jungle') || lower.contains('temple'), isTrue,
          reason: 'jungle_ruins gloss should describe a jungle temple: $line');
    });

    test('each gloss is capped to ~90 chars', () {
      for (final line in sceneCatalog(m).split('\n')) {
        final dash = line.indexOf(' — ');
        final gloss = dash >= 0 ? line.substring(dash + 3) : line;
        expect(gloss.length, lessThanOrEqualTo(90), reason: line);
      }
    });

    test('falls back to category name when whenToUse is empty', () {
      final synth = SceneManifest(
        version: 1,
        fallbackSlug: 'neutral',
        aesthetics: const ['modern'],
        categories: const [
          SceneCategory(
              slug: 'blank',
              name: 'A Blank Place',
              whenToUse: '',
              notWhen: null,
              priority: 1,
              keywords: ['blank'],
              images: []),
        ],
      );
      expect(sceneCatalog(synth), 'blank — A Blank Place');
    });
  });

  group('confidentKeywordPrePass (Wave 243)', () {
    final m = _realManifest();

    test('lone generic single-word keyword ("ravine") -> null (defers to LLM)', () {
      // "ravine" is a keyword of canyon (priority 8) — generic + single word,
      // so the confident pre-pass must NOT lock it in.
      expect(confidentKeywordPrePass(m, 'at the foot of a ravine'), isNull);
      // sanity: the old authoritative pre-pass DID pick canyon here.
      expect(keywordPrePass(m, 'at the foot of a ravine'), 'canyon');
    });

    test('multi-word phrase ("mushroom cave") -> confident pick', () {
      expect(
          confidentKeywordPrePass(
              m, 'they entered the mushroom cave, glowing fungi everywhere'),
          'mushroom_cave');
    });

    test('high-priority (>=11) single-word keyword still fires', () {
      // dungeon is priority 11 with a single-word keyword "dungeon".
      expect(m.categoryBySlug('dungeon')!.priority, greaterThanOrEqualTo(11));
      expect(confidentKeywordPrePass(m, 'they were thrown into the dungeon'),
          'dungeon');
    });

    test('empty / no-match -> null', () {
      expect(confidentKeywordPrePass(m, ''), isNull);
      expect(confidentKeywordPrePass(m, 'asdf qwerty zzz nothing here'), isNull);
    });
  });

  group('weatherCueFromText', () {
    test('detects rain / snow / null', () {
      expect(weatherCueFromText('rain hammered the pavement'), 'rain');
      expect(weatherCueFromText('snow drifted down softly'), 'snow');
      expect(weatherCueFromText('a calm quiet afternoon'), isNull);
    });
  });

  group('pickSceneImage', () {
    SceneCategory cat(List<SceneImage> imgs) => SceneCategory(
        slug: 'x', name: 'X', whenToUse: '', notWhen: null,
        priority: 5, keywords: const [], images: imgs);

    test('prefers exact setting match', () {
      final c = cat(const [
        SceneImage(file: 'a_modern_day.webp', aesthetic: 'modern', timeOfDay: 'day'),
        SceneImage(file: 'b_cyber_day.webp', aesthetic: 'cyberpunk', timeOfDay: 'day'),
      ]);
      expect(pickSceneImage(c, 'cyberpunk', 'unknown', null, 'chat1'),
          'b_cyber_day.webp');
    });

    test('natural images match any setting', () {
      final c = cat(const [
        SceneImage(file: 'nat_day.webp', aesthetic: 'natural', timeOfDay: 'day'),
      ]);
      expect(pickSceneImage(c, 'cyberpunk', 'unknown', null, 'chat1'),
          'nat_day.webp');
    });

    test('falls back setting -> modern -> any', () {
      final c = cat(const [
        SceneImage(file: 'mod_day.webp', aesthetic: 'modern', timeOfDay: 'day'),
        SceneImage(file: 'goth_day.webp', aesthetic: 'gothic', timeOfDay: 'day'),
      ]);
      // requested setting 'wuxia' absent -> modern fallback wins.
      expect(pickSceneImage(c, 'wuxia', 'unknown', null, 'chat1'),
          'mod_day.webp');
    });

    test('prefers timeOfDay when available', () {
      final c = cat(const [
        SceneImage(file: 'm_day.webp', aesthetic: 'modern', timeOfDay: 'day'),
        SceneImage(file: 'm_night.webp', aesthetic: 'modern', timeOfDay: 'night'),
      ]);
      expect(pickSceneImage(c, 'modern', 'night', null, 'chat1'),
          'm_night.webp');
    });

    test('prefers weather when available', () {
      final c = cat(const [
        SceneImage(file: 'm_clear.webp', aesthetic: 'modern', timeOfDay: 'day', weather: 'clear'),
        SceneImage(file: 'm_rain.webp', aesthetic: 'modern', timeOfDay: 'day', weather: 'rain'),
      ]);
      expect(pickSceneImage(c, 'modern', 'day', 'rain', 'chat1'),
          'm_rain.webp');
    });

    test('deterministic for a fixed chatId', () {
      final c = cat(const [
        SceneImage(file: 'm1.webp', aesthetic: 'modern', timeOfDay: 'day'),
        SceneImage(file: 'm2.webp', aesthetic: 'modern', timeOfDay: 'day'),
        SceneImage(file: 'm3.webp', aesthetic: 'modern', timeOfDay: 'day'),
      ]);
      final a = pickSceneImage(c, 'modern', 'unknown', null, 'chatXYZ');
      final b = pickSceneImage(c, 'modern', 'unknown', null, 'chatXYZ');
      expect(a, b);
    });

    test('empty category -> null', () {
      expect(pickSceneImage(cat(const []), 'modern', 'day', null, 'c'), isNull);
    });
  });

  group('decideSwitch', () {
    SceneVerdict v(String loc, String conf) => SceneVerdict(
        location: loc, setting: 'modern', timeOfDay: 'unknown', confidence: conf);

    test('low confidence -> keep', () {
      expect(decideSwitch(v('bedroom', 'low'), hasCurrent: true).kind,
          SceneDecisionKind.keep);
    });
    test('location none + has current -> keep', () {
      expect(decideSwitch(v('none', 'high'), hasCurrent: true).kind,
          SceneDecisionKind.keep);
    });
    test('location none + nothing yet -> neutral', () {
      expect(decideSwitch(v('none', 'low'), hasCurrent: false).kind,
          SceneDecisionKind.neutral);
    });
    test('high + real slug -> setLocation', () {
      final d = decideSwitch(v('bedroom', 'high'), hasCurrent: true);
      expect(d.kind, SceneDecisionKind.setLocation);
      expect(d.slug, 'bedroom');
    });
  });

  group('kSceneClassifierPrompt', () {
    final m = _realManifest();

    test('contains all 4 runtime placeholders', () {
      // Wave CY.18.243: the bare-slug list ({{VALID_LOCATIONS}}) was replaced
      // by a described catalog placeholder ({{LOCATION_CATALOG}}).
      expect(kSceneClassifierPrompt.contains('{{LOCATION_CATALOG}}'), isTrue);
      expect(kSceneClassifierPrompt.contains('{{VALID_LOCATIONS}}'), isFalse);
      expect(kSceneClassifierPrompt.contains('{{VALID_SETTINGS}}'), isTrue);
      expect(kSceneClassifierPrompt.contains('{{RECENT_MESSAGES}}'), isTrue);
      // Wave CY.18.197: the anti-drift anchor placeholder.
      expect(kSceneClassifierPrompt.contains('{{CURRENT_LOCATION}}'), isTrue);
    });

    test('Wave 243: documents the prefer-most-specific rule', () {
      expect(kSceneClassifierPrompt.contains('MOST SPECIFIC'), isTrue);
    });

    test('asks for locationNote in the JSON output spec', () {
      expect(kSceneClassifierPrompt.contains('locationNote'), isTrue);
    });

    test('Wave 199: documents the authoritative user-hint rule', () {
      // The manual "Current location" edit feeds a hint line of this exact
      // shape; the prompt must explain how to honour it (resolve to the
      // closest slug + override a stuck setting from chat world cues).
      expect(
          kSceneClassifierPrompt
              .contains('authoritative current location'),
          isTrue);
      expect(kSceneClassifierPrompt.contains('OVERRIDES'), isTrue);
      // The guild → fantasy_tavern mapping the "Guild" complaint depends on.
      expect(kSceneClassifierPrompt.contains('fantasy_tavern'), isTrue);
    });

    test('Wave 199: fantasy_tavern is a real slug for the guild mapping', () {
      // The "Guild" fix relies on the model mapping a guild hall to a slug
      // that actually exists in the bundled manifest.
      expect(m.slugs, contains('fantasy_tavern'));
    });
  });

  group('currentLocationAnchor', () {
    test('nothing tracked -> "none yet"', () {
      expect(currentLocationAnchor('', ''), 'none yet');
      expect(currentLocationAnchor('', 'unknown'), 'none yet');
    });

    test('setting-only -> "none yet (<setting> world)"', () {
      expect(currentLocationAnchor('', 'medieval_fantasy'),
          'none yet (medieval_fantasy world)');
    });

    test('location + setting -> "<loc> (<setting> world)"', () {
      expect(
          currentLocationAnchor('the guild hall', 'medieval_fantasy'),
          'the guild hall (medieval_fantasy world)');
    });

    test('location only (no/unknown setting) -> just the location', () {
      expect(currentLocationAnchor('the guild hall', ''), 'the guild hall');
      expect(
          currentLocationAnchor('the guild hall', 'unknown'), 'the guild hall');
    });
  });

  group('Chat scene-bg fields round-trip', () {
    test('dynamic source + scene fields survive toJson/fromJson', () {
      final chat = Chat(id: 'c1', characterIds: const ['ch1']);
      chat.backgroundSource = ChatBackgroundSource.dynamic;
      chat.sceneBgFile = 'bedroom_modern_night_01.webp';
      chat.sceneSetting = 'cyberpunk';
      chat.sceneLastClassifyMsgCount = 7;
      chat.sceneLastClassifyKey = 'abc123';
      chat.sceneLocation = 'the Serpent\'s Fang guild hall';
      final back = Chat.fromJson(chat.toJson());
      expect(back.backgroundSource, ChatBackgroundSource.dynamic);
      expect(back.sceneBgFile, 'bedroom_modern_night_01.webp');
      expect(back.sceneSetting, 'cyberpunk');
      expect(back.sceneLastClassifyMsgCount, 7);
      expect(back.sceneLastClassifyKey, 'abc123');
      expect(back.sceneLocation, 'the Serpent\'s Fang guild hall');
    });

    test('defaults: no scene fields on a fresh chat', () {
      final back = Chat.fromJson(Chat(id: 'c2', characterIds: const ['ch1']).toJson());
      expect(back.sceneBgFile, isNull);
      expect(back.sceneSetting, 'modern');
      expect(back.sceneLastClassifyMsgCount, 0);
      expect(back.sceneLastClassifyKey, '');
      expect(back.sceneLocation, '');
    });

    test('empty sceneLocation is omitted from JSON (persist-when-non-empty)', () {
      final json = Chat(id: 'c3', characterIds: const ['ch1']).toJson();
      expect(json.containsKey('sceneLocation'), isFalse);
    });

    test('ChatSettings accepts dynamic backgroundSource', () {
      final s = ChatSettings(backgroundSource: ChatBackgroundSource.dynamic);
      expect(ChatSettings.fromJson(s.toJson()).backgroundSource,
          ChatBackgroundSource.dynamic);
    });
  });
}
