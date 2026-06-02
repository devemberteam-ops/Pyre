// Scene-aware chat backgrounds — manifest model + loader (Task 1),
// pure engine + classifier orchestration (Task 2). Mirrors the Live Sheet
// service structure (pure functions + completeChatStreamed orchestration).

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../models/models.dart';
import 'chat_api.dart';

/// One background image variant within a category.
class SceneImage {
  final String file;       // bare filename, e.g. "bedroom_modern_day_01.webp"
  final String aesthetic;  // one of the 18 aesthetics, or "natural" (any setting)
  final String timeOfDay;  // day | dusk | night
  final String? weather;   // clear | rain | snow (null on indoor/no-window)

  const SceneImage({
    required this.file,
    required this.aesthetic,
    required this.timeOfDay,
    this.weather,
  });

  factory SceneImage.fromJson(Map<String, dynamic> j) => SceneImage(
        file: (j['file'] ?? '') as String,
        aesthetic: (j['aesthetic'] ?? '') as String,
        timeOfDay: (j['timeOfDay'] ?? '') as String,
        weather: j['weather'] as String?,
      );
}

/// A location category (a "where") with its trigger keywords and image set.
class SceneCategory {
  final String slug;
  final String name;
  final String whenToUse;
  final String? notWhen;
  final int priority;
  final List<String> keywords;
  final List<SceneImage> images;

  const SceneCategory({
    required this.slug,
    required this.name,
    required this.whenToUse,
    required this.notWhen,
    required this.priority,
    required this.keywords,
    required this.images,
  });

  factory SceneCategory.fromJson(Map<String, dynamic> j) => SceneCategory(
        slug: (j['slug'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        whenToUse: (j['whenToUse'] ?? '') as String,
        notWhen: j['notWhen'] as String?,
        priority: (j['priority'] as num?)?.toInt() ?? 1,
        keywords: ((j['keywords'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        images: ((j['images'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => SceneImage.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );
}

/// The parsed `manifest.json`.
class SceneManifest {
  final int version;
  final String fallbackSlug;
  final List<String> aesthetics;
  final List<SceneCategory> categories;

  SceneManifest({
    required this.version,
    required this.fallbackSlug,
    required this.aesthetics,
    required this.categories,
  });

  factory SceneManifest.fromJson(Map<String, dynamic> j) => SceneManifest(
        version: (j['version'] as num?)?.toInt() ?? 1,
        fallbackSlug: (j['fallbackSlug'] ?? 'neutral') as String,
        aesthetics: ((j['aesthetics'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        categories: ((j['categories'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => SceneCategory.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  Set<String> get slugs => {for (final c in categories) c.slug};

  SceneCategory? categoryBySlug(String slug) {
    for (final c in categories) {
      if (c.slug == slug) return c;
    }
    return null;
  }
}

/// Loads + caches the bundled manifest. Returns null if it can't be read
/// or parsed (feature then stays silently inert). Mirrors the LiveSheet
/// discipline: never throws out to the caller.
SceneManifest? _cachedManifest;
bool _manifestLoadAttempted = false;

Future<SceneManifest?> loadSceneManifest() async {
  if (_cachedManifest != null) return _cachedManifest;
  if (_manifestLoadAttempted) return _cachedManifest; // failed once — don't retry-spam
  _manifestLoadAttempted = true;
  try {
    final raw = await rootBundle.loadString('assets/scene_bg/manifest.json');
    _cachedManifest =
        SceneManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    return _cachedManifest;
  } catch (e) {
    debugPrint('[SceneBg] manifest load failed: $e');
    return null;
  }
}

// ---------------------------------------------------------------------------
// TASK 2: pure engine + classifier orchestration.
// ---------------------------------------------------------------------------

/// The classifier's structured verdict.
class SceneVerdict {
  final String location;   // a category slug, or "none"
  final String setting;    // an aesthetic slug, or "unknown"
  final String timeOfDay;  // day | dusk | night | unknown
  final String confidence; // high | low
  // Wave CY.18.197: a short, free-text human phrase for the current place
  // (e.g. "candle-lit fantasy tavern"). Drives the chat's tracked
  // `sceneLocation` note (anti-drift anchor). '' when the model omits it.
  final String locationNote;
  const SceneVerdict({
    required this.location,
    required this.setting,
    required this.timeOfDay,
    required this.confidence,
    this.locationNote = '',
  });
}

const _kTimeOfDayValues = {'day', 'dusk', 'night', 'unknown'};
const _kConfidenceValues = {'high', 'low'};

/// Tolerant parse of the classifier's reply. Strips markdown fences / prose
/// by slicing from the first `{` to the last `}`. Validates `location` ∈
/// slugs∪{none} and `setting` ∈ aesthetics∪{unknown} (bad → null). Soft-
/// coerces unrecognised `timeOfDay`→"unknown" and `confidence`→"low"
/// (the safe, anti-flicker default). Returns null on any structural failure.
SceneVerdict? parseClassifierJson(String raw, SceneManifest manifest) {
  if (raw.trim().isEmpty) return null;
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  Map<String, dynamic> obj;
  try {
    final decoded = jsonDecode(raw.substring(start, end + 1));
    if (decoded is! Map) return null;
    obj = decoded.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
  final location = (obj['location'] as String?)?.trim() ?? '';
  final setting = (obj['setting'] as String?)?.trim() ?? '';
  var timeOfDay = (obj['timeOfDay'] as String?)?.trim() ?? 'unknown';
  var confidence = (obj['confidence'] as String?)?.trim() ?? 'low';
  // Wave CY.18.197: free-text place note. Optional — just trim; collapse
  // internal whitespace and cap the length so a runaway phrase can't bloat the
  // tracked location. Defaults to '' when absent.
  var locationNote = (obj['locationNote'] as String?)?.trim() ?? '';
  if (locationNote.isNotEmpty) {
    locationNote = locationNote.replaceAll(RegExp(r'\s+'), ' ');
    if (locationNote.length > 120) {
      locationNote = locationNote.substring(0, 120).trim();
    }
  }

  final validLocation = location == 'none' || manifest.slugs.contains(location);
  final validSetting =
      setting == 'unknown' || manifest.aesthetics.contains(setting);
  if (!validLocation || !validSetting) return null;
  if (!_kTimeOfDayValues.contains(timeOfDay)) timeOfDay = 'unknown';
  if (!_kConfidenceValues.contains(confidence)) confidence = 'low';

  return SceneVerdict(
    location: location,
    setting: setting,
    timeOfDay: timeOfDay,
    confidence: confidence,
    locationNote: locationNote,
  );
}

/// Wave CY.18.243: a one-line-per-category DESCRIBED catalog for the LLM
/// classifier, so the model sees what each slug MEANS rather than a bare list
/// of slugs. Each line is `"<slug> — <gloss>"`, where `gloss` is the first
/// sentence of the category's `whenToUse` (split on the first ". "), with
/// internal whitespace collapsed to single spaces and capped to ~90 chars.
/// Falls back to the category `name` when `whenToUse` is empty. Pure.
String sceneCatalog(SceneManifest m) {
  final lines = <String>[];
  for (final c in m.categories) {
    var gloss = c.whenToUse.trim();
    if (gloss.isEmpty) {
      gloss = c.name.trim();
    } else {
      final dot = gloss.indexOf('. ');
      if (dot >= 0) gloss = gloss.substring(0, dot);
    }
    gloss = gloss.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (gloss.length > 90) gloss = gloss.substring(0, 90).trim();
    lines.add('${c.slug} — $gloss');
  }
  return lines.join('\n');
}

/// Free, no-LLM location guess: scans [recentText] for any category keyword
/// (case-insensitive, whole-word). On overlap the highest-`priority` category
/// wins; ties break toward the longest matched keyword, then category order.
/// Returns the category slug, or null on no match.
String? keywordPrePass(SceneManifest manifest, String recentText) {
  if (recentText.trim().isEmpty) return null;
  SceneCategory? best;
  int bestLen = -1;
  for (final c in manifest.categories) {
    for (final kw in c.keywords) {
      final k = kw.trim();
      if (k.isEmpty) continue;
      final re = RegExp(r'\b' + RegExp.escape(k) + r'\b', caseSensitive: false);
      if (re.hasMatch(recentText)) {
        final better = best == null ||
            c.priority > best.priority ||
            (c.priority == best.priority && k.length > bestLen);
        if (better) {
          best = c;
          bestLen = k.length;
        }
      }
    }
  }
  return best?.slug;
}

/// Wave CY.18.243: a CONFIDENT-ONLY variant of [keywordPrePass]. Runs the same
/// highest-priority / longest-keyword scan, but only short-circuits the LLM
/// (returns a slug) when the WINNING matched keyword is high-specificity:
///   - the matched keyword is a multi-word PHRASE (contains a space), e.g.
///     "mushroom cave", "throne room"; OR
///   - the winning category's `priority >= 11` (a strongly distinctive place
///     like fantasy_tavern, dungeon, throne_room).
/// Otherwise returns null, so a lone GENERIC word ("ravine", "cave") falls
/// through to the smarter described-catalog LLM classifier instead of being
/// locked in by a weak keyword hit. Pure + additive ([keywordPrePass] is kept
/// as-is for other callers/tests).
String? confidentKeywordPrePass(SceneManifest manifest, String recentText) {
  if (recentText.trim().isEmpty) return null;
  SceneCategory? best;
  int bestLen = -1;
  String? bestKeyword;
  for (final c in manifest.categories) {
    for (final kw in c.keywords) {
      final k = kw.trim();
      if (k.isEmpty) continue;
      final re = RegExp(r'\b' + RegExp.escape(k) + r'\b', caseSensitive: false);
      if (re.hasMatch(recentText)) {
        final better = best == null ||
            c.priority > best.priority ||
            (c.priority == best.priority && k.length > bestLen);
        if (better) {
          best = c;
          bestLen = k.length;
          bestKeyword = k;
        }
      }
    }
  }
  if (best == null || bestKeyword == null) return null;
  final confident = bestKeyword.contains(' ') || best.priority >= 11;
  return confident ? best.slug : null;
}

/// Cheap pure weather cue from narration text. Returns 'rain', 'snow', or
/// null. Used only to PREFER a matching image variant — never required.
String? weatherCueFromText(String text) {
  final t = text.toLowerCase();
  if (RegExp(r'\b(rain|raining|rainy|downpour|drizzle|storm|thunderstorm)\b')
      .hasMatch(t)) {
    return 'rain';
  }
  if (RegExp(r'\b(snow|snowing|snowy|blizzard|snowfall)\b').hasMatch(t)) {
    return 'snow';
  }
  return null;
}

/// Deterministic, process-stable string hash (NOT String.hashCode, which is
/// not guaranteed stable across runs). Used to pick a steady image per chat.
int _stableHash(String s) {
  var h = 0;
  for (final cu in s.codeUnits) {
    h = (h * 31 + cu) & 0x7fffffff;
  }
  return h;
}

/// Picks one image filename from [category] for the given world [setting],
/// [timeOfDay] (day|dusk|night|unknown) and optional [weatherCue]
/// (clear|rain|snow|null), stable per [chatId]. Candidate rules:
///   1. aesthetic == setting OR aesthetic == "natural" (wildcard)
///   2. fallback: aesthetic == "modern" OR "natural"
///   3. fallback: all images
/// Then PREFER timeOfDay (when not "unknown"), then PREFER weather — each
/// preference only narrows the set when it leaves at least one candidate.
/// Returns null only when the category has no images at all.
String? pickSceneImage(
  SceneCategory category,
  String setting,
  String timeOfDay,
  String? weatherCue,
  String chatId,
) {
  if (category.images.isEmpty) return null;

  List<SceneImage> bySetting(bool Function(SceneImage) test) =>
      category.images.where(test).toList();

  var candidates = bySetting(
      (i) => i.aesthetic == setting || i.aesthetic == 'natural');
  if (candidates.isEmpty) {
    candidates = bySetting(
        (i) => i.aesthetic == 'modern' || i.aesthetic == 'natural');
  }
  if (candidates.isEmpty) candidates = List.of(category.images);

  if (timeOfDay != 'unknown') {
    final byTod = candidates.where((i) => i.timeOfDay == timeOfDay).toList();
    if (byTod.isNotEmpty) candidates = byTod;
  }
  if (weatherCue != null) {
    final byW = candidates.where((i) => i.weather == weatherCue).toList();
    if (byW.isNotEmpty) candidates = byW;
  }

  // Stable order (by filename) so the hash maps consistently regardless of
  // manifest list order, then pick by chatId hash.
  candidates.sort((a, b) => a.file.compareTo(b.file));
  final idx = _stableHash(chatId) % candidates.length;
  return candidates[idx].file;
}

enum SceneDecisionKind { keep, neutral, setLocation }

class SceneDecision {
  final SceneDecisionKind kind;
  final String? slug; // set only when kind == setLocation
  const SceneDecision(this.kind, [this.slug]);
}

/// Decides what to do with a non-null verdict. Anti-flicker by default:
///   - confidence "low" + something already showing -> keep it.
///   - location "none" (or low confidence) + nothing showing yet -> establish
///     a neutral backdrop so dynamic mode isn't blank.
///   - high confidence + a real slug -> switch to that location.
SceneDecision decideSwitch(SceneVerdict verdict, {required bool hasCurrent}) {
  if (verdict.location == 'none' || verdict.confidence == 'low') {
    return hasCurrent
        ? const SceneDecision(SceneDecisionKind.keep)
        : const SceneDecision(SceneDecisionKind.neutral);
  }
  return SceneDecision(SceneDecisionKind.setLocation, verdict.location);
}

/// Verbatim classifier system prompt (from pyre-scene-bg/classifier-prompt.md,
/// "SYSTEM PROMPT" section) + a trailing classify block. The 4 placeholders
/// are filled at call time. Sent as a single system turn (mirrors the robust
/// single-system-message pattern used elsewhere).
///
/// Wave CY.18.197: ANTI-DRIFT. The app now passes the CURRENTLY tracked
/// location + setting via {{CURRENT_LOCATION}}, and the model decides whether
/// the scene has actually MOVED rather than re-guessing from scratch each turn
/// (which made a guild hall flip to a modern festival). It also returns a short
/// human `locationNote` so the app can keep the tracked location current.
const String kSceneClassifierPrompt = r'''
You are a scene classifier for a roleplay chat app. You read the most recent
roleplay narration and decide which background image best fits the current
scene. You output ONLY a single JSON object — no explanation, no markdown.

Valid locations — choose the ONE slug whose description best fits the scene, or "none". Output ONLY the bare slug, exactly as written on the left:
{{LOCATION_CATALOG}}
none
Valid settings: {{VALID_SETTINGS}}, unknown

The scene is CURRENTLY tracked as: {{CURRENT_LOCATION}}

Rules:
1. Read the latest narration and decide if the scene has MOVED to a genuinely
   DIFFERENT place than the currently-tracked one. If it is still the SAME place
   (or just dialogue / inner thought with no setting), return "confidence":"low"
   so the app KEEPS the current background. Only return "confidence":"high" with
   a new `location` when the narration CLEARLY moves the scene somewhere new
   (a door opened, they walked outside, "later, at the docks…", etc.).
1a. Prefer the MOST SPECIFIC location whose description fits — choose a precise
   match (e.g. mushroom_cave, jungle_ruins, underground_lake, catacombs) over a
   generic one (basement, cave, canyon) when the precise description matches the
   narration.
2. `setting` is the world's overall aesthetic/era (modern, cyberpunk,
   medieval_fantasy, feudal_japan, etc.). It is established ONCE for the world
   and rarely changes. If a setting is ALREADY tracked above, KEEP it unless the
   narration shows a genuinely different world; NEVER flip an established
   medieval/fantasy world to modern (or vice-versa) just because one line lacks
   era cues. If no setting is tracked yet, infer it from world cues (technology,
   clothing, architecture, magic, era); if there is no clear cue, return
   "unknown".
3. `timeOfDay`: only set day/dusk/night from EXPLICIT cues in the text
   (sunlight, sunset, moon, stars, "midnight", lamps in the dark). Otherwise
   return "unknown".
4. `confidence`: return "low" when you are unsure, OR when the location has NOT
   actually changed from the tracked one, OR for a line of pure dialogue with no
   setting. Return "high" only when the narration clearly places the scene
   somewhere NEW. The app keeps the current background on "low", so prefer "low"
   over guessing — never flicker the background mid-conversation.
5. `locationNote`: a SHORT human phrase (a few words) naming where the scene is
   now — e.g. "candle-lit fantasy tavern", "the docks at night". Reuse/refine
   the tracked phrase when the place hasn't changed.
6. AUTHORITATIVE USER HINT: if the narration contains a line like "The user has
   indicated the current scene location is: X. Use this as the authoritative
   current location.", treat X as a direct command from the user. Return
   "confidence":"high" and map X to the CLOSEST valid `location` slug (e.g. a
   guild / guild hall / adventurers' hall in a fantasy world → fantasy_tavern; a
   modern guild office → office). Use the rest of the narration to pick the
   right WORLD: if the chat clearly shows a medieval / fantasy setting, set
   `setting` to that (e.g. medieval_fantasy) EVEN IF a different setting is
   currently tracked — an explicit user hint plus matching world cues OVERRIDES
   a previously-tracked setting. Set the `locationNote` to the user's phrase.
7. Output exactly: {"location": "...", "setting": "...", "timeOfDay": "...", "confidence": "...", "locationNote": "..."}

### Examples

Tracked: none
Narration: She pushed open the heavy oak door and stepped into the candle-lit
tavern, the smell of ale and woodsmoke washing over her. A bard tuned his lute
by the hearth.
{"location": "fantasy_tavern", "setting": "medieval_fantasy", "timeOfDay": "unknown", "confidence": "high", "locationNote": "candle-lit fantasy tavern"}

Tracked: alley (cyberpunk)
Narration: Neon signs buzzed overhead as rain hammered the cracked pavement. He
pulled his collar up and slipped down the narrow alley between two megatowers.
{"location": "alley", "setting": "cyberpunk", "timeOfDay": "night", "confidence": "low", "locationNote": "rain-slicked cyberpunk alley"}

Tracked: fantasy_tavern (medieval_fantasy)
Narration: "I just— I don't know what to say to him," she whispered, staring at
her hands. "It's complicated."
{"location": "none", "setting": "medieval_fantasy", "timeOfDay": "unknown", "confidence": "low", "locationNote": "candle-lit fantasy tavern"}

Tracked: guild_hall (medieval_fantasy)
Narration: "You really think the Guildmaster will agree?" she asked, leaning back
in her chair. He shrugged and took another sip of ale.
{"location": "none", "setting": "medieval_fantasy", "timeOfDay": "unknown", "confidence": "low", "locationNote": "the guild hall"}

Tracked: festival (modern)
Narration: The adventurers crowded around the worn oak notice-board, scanning the
bounty parchments. A mailed guard leaned on his halberd by the hearth while the
barkeep filled tankards of ale.

The user has indicated the current scene location is: Guild. Use this as the authoritative current location.
{"location": "fantasy_tavern", "setting": "medieval_fantasy", "timeOfDay": "unknown", "confidence": "high", "locationNote": "the adventurers' guild hall"}

Tracked: none
Narration: The waves rolled in under a sky turning pink and orange, the sun
sinking into the sea. She kicked off her sandals and let the warm sand run
between her toes.
{"location": "beach", "setting": "modern", "timeOfDay": "dusk", "confidence": "high", "locationNote": "beach at sunset"}

Tracked: none
Narration: He set the two coffees down on the little table by the window. Steam
curled up between them as the espresso machine hissed behind the counter.
{"location": "cafe", "setting": "modern", "timeOfDay": "unknown", "confidence": "high", "locationNote": "a cozy café"}

Tracked: throne_room (medieval_fantasy)
Narration: The throne room stretched out before them, banners hanging from
soaring stone arches, a single shaft of light falling on the empty golden seat.
{"location": "throne_room", "setting": "medieval_fantasy", "timeOfDay": "day", "confidence": "low", "locationNote": "grand throne room"}

Tracked: classroom (modern)
Narration: 彼女は廊下を歩いて屋上へ出た。午後の日差しが眩しい。
{"location": "rooftop", "setting": "modern", "timeOfDay": "day", "confidence": "high", "locationNote": "the school rooftop"}

Tracked: spaceship_interior (sci_fi)
Narration: The airlock hissed shut behind them. Through the viewport, a thousand
stars wheeled past the hull as the ship banked toward the distant station.
{"location": "spaceship_interior", "setting": "sci_fi", "timeOfDay": "unknown", "confidence": "low", "locationNote": "starship interior"}

Tracked: none
Narration: Steam rose off the outdoor hot spring as snow drifted down. She sank
into the water with a contented sigh, the wooden bathhouse glowing softly behind
her.
{"location": "onsen_bathhouse", "setting": "feudal_japan", "timeOfDay": "unknown", "confidence": "high", "locationNote": "snowy outdoor onsen"}

---
Now classify the following. Output ONLY the JSON object, nothing else.

Tracked: {{CURRENT_LOCATION}}
Narration: {{RECENT_MESSAGES}}
''';

/// In-memory error log for scene-classifier failures (mirrors LiveSheetErrors).
class SceneErrors {
  SceneErrors._();
  static final List<String> log = [];
  static const int _max = 20;
  static void record(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[SceneBg] $msg');
    log.insert(0, msg);
    if (log.length > _max) log.removeRange(_max, log.length);
  }
  static void clear() => log.clear();
}

/// The classifier output is a ~60-token JSON object. Cap maxTokens low (bound
/// a runaway non-JSON ramble) and pull temperature down for reliable JSON,
/// without raising a user's already-low cap. Mirrors _liveSheetSettings.
ModelSettings _sceneSettings(ModelSettings base) {
  final s = ModelSettings.fromJson(base.toJson());
  s.maxTokens = 256;
  if (s.temperature > 0.4) s.temperature = 0.4;
  return s;
}

/// Builds the "currently tracked" anchor phrase fed to the classifier via
/// {{CURRENT_LOCATION}}. Combines the human-readable [currentLocation] note
/// with the sticky [currentSetting] aesthetic. Returns "none yet" when nothing
/// is tracked, so the model knows it is establishing the scene for the first
/// time. Pure + testable.
String currentLocationAnchor(String currentLocation, String currentSetting) {
  final loc = currentLocation.trim();
  final set = currentSetting.trim();
  final hasSetting = set.isNotEmpty && set != 'unknown';
  if (loc.isEmpty) {
    return hasSetting ? 'none yet ($set world)' : 'none yet';
  }
  return hasSetting ? '$loc ($set world)' : loc;
}

/// Orchestrates one classifier call over the active provider. Fills the 4
/// placeholders, sends a single system turn, parses the reply. Returns null
/// on empty/error/invalid (caller keeps the current background — anti-flicker).
///
/// Wave CY.18.197: [currentLocation] + [currentSetting] are the chat's tracked
/// scene anchor, fed to the model so it only changes the background on a real
/// move (anti-drift) instead of re-guessing from the last few raw messages.
Future<SceneVerdict?> classifyScene({
  required SceneManifest manifest,
  required String recentText,
  required ApiProvider provider,
  required ModelSettings settings,
  String currentLocation = '',
  String currentSetting = '',
}) async {
  if (provider.baseUrl.isEmpty) return null;
  final sys = kSceneClassifierPrompt
      .replaceAll('{{LOCATION_CATALOG}}', sceneCatalog(manifest))
      .replaceAll('{{VALID_SETTINGS}}', manifest.aesthetics.join(', '))
      .replaceAll('{{CURRENT_LOCATION}}',
          currentLocationAnchor(currentLocation, currentSetting))
      .replaceAll('{{RECENT_MESSAGES}}', recentText.trim());
  try {
    final out = await completeChatStreamed(
      provider: provider,
      settings: _sceneSettings(settings),
      messages: [ChatTurn('system', sys)],
      debugTag: 'scene', // Wave CY.18.214 diagnostics tag
    );
    if (out.trim().isEmpty) {
      SceneErrors.record('classifyScene', 'LLM returned empty response');
      return null;
    }
    return parseClassifierJson(out, manifest);
  } catch (e) {
    SceneErrors.record('classifyScene', e);
    return null;
  }
}

/// Cheap stable key for the recent-message window, for classifier dedup.
String sceneWindowKey(String recentText) => _stableHash(recentText).toString();
