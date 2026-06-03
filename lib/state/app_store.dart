// Central state store for Pyre — ChangeNotifier-based, persisted
// via JsonStorage. Mirrors the JS prototype's localStorage shape so that
// backup JSONs stay portable between the prototype and the Flutter app.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/attachment_migration.dart';
import '../services/attachment_refs.dart';
import '../services/attachment_store.dart';
import '../services/chat_api.dart' show warmUpProvider;
import '../services/example_seed.dart';
import '../services/provider_fallback.dart';
import '../services/regex_rules.dart';
import '../services/secure_keys.dart';
import '../services/store_backend.dart';

class AppStore extends ChangeNotifier {
  // Wave CY.18.63: persistence is now behind a `StoreBackend` interface.
  // On native this resolves to LocalBackend (no behavioural change —
  // wraps the existing JsonStorage). On web/PWA (Wave 71) this becomes
  // RemoteBackend, which routes load/save through the LAN server's
  // /pull and /push endpoints. AppStore itself doesn't know which
  // implementation it has and doesn't need to.
  final StoreBackend _storage;

  bool _loaded = false;
  bool get loaded => _loaded;

  /// Wave CY.18.127: guards the once-per-launch orphan-attachment GC kicked
  /// off in `load()`. The desktop also runs the GC when the LAN server
  /// starts; this local sweep is what reclaims disk for mobile-only /
  /// never-run-the-server users. No-op on web (`gcOrphans` returns 0).
  bool _attachmentGcRan = false;

  // Collections
  List<ApiProvider> providers = [];
  String? activeProviderId;
  /// Wave CY.18.99: per-provider refusal counter (self-learning). Bumped
  /// when a provider's reply is classified as a content refusal. Powers
  /// the "this one tends to censor → try a clean one" suggestion. Keyed
  /// by provider id; persisted in the main JSON blob (tiny).
  Map<String, int> providerRefusals = {};
  /// Optional override: when non-null, the AI character builder uses
  /// this provider instead of [activeProviderId]. Useful when the user
  /// wants (a) an uncensored text model for chatting (DeepSeek, Soji),
  /// plus (b) a different vision-capable / extra-uncensored model for
  /// the creator flow (Venice qwen, Grok, Pixtral, etc.). Null means
  /// "use the same one as chat".
  String? creatorProviderId;
  /// Optional override for IMAGE-ONLY calls (vision analysis when the
  /// user attaches a reference image). Falls back to [creatorProvider]
  /// (which itself falls back to [activeProvider]). Lets the user pin
  /// a vision-capable model (Qwen-VL, Pixtral, Venice qwen, Claude,
  /// GPT) without having to use it for chat / sheet generation, where
  /// a text-only model like DeepSeek may be a better fit.
  String? visionProviderId;

  List<Character> characters = [];
  List<Persona> personas = [];
  String? activePersonaId;

  /// Wave BG: in-progress card drafts from the manual editor. These
  /// are full Character objects that haven't been "Saved" yet — they
  /// only exist so the user doesn't lose work on back-out. Save
  /// promotes a draft to `characters` and removes it from here; an
  /// explicit Discard, or backing out of an editor with NO content,
  /// removes the draft silently. Persisted across app restarts so
  /// you can resume a session that got interrupted.
  List<Character> characterDrafts = [];

  /// Wave BC: the user's botbooru.com username, used as the `creator`
  /// field on cards built via the Character Creator. Case-sensitive on
  /// botbooru's end — exporting a card with a mismatched case won't
  /// link back to the user's uploaded profile. Set in More → BotBooru
  /// Profile. Empty string when never configured (falls back to the
  /// active persona's name during Save Card).
  String botbooruUsername = '';

  /// Wave CY.18.30: decorative profile picture for the BotBooru
  /// Profile screen. Stored as a `data:image/png;base64,...` URL,
  /// same shape as Character.avatar / Persona.avatar. Pure UX flair —
  /// not surfaced anywhere else in the app (no auto-binding to chat
  /// avatars or card creator fields). Null when never set.
  String? botbooruAvatar;

  /// Wave CY.18.30: free-form "about me" from the user, written in
  /// their own voice.
  ///
  /// Wave CY.18.36: scope CHANGED. Pre-Wave this was appended to the
  /// Character Creator architect's system prompt as soft context.
  /// Now it's purely personal bio — displayed on the Profile screen,
  /// not used as architect context. Reason: the architect already has
  /// `creatorPromptAddendum` (Your additions) for user-driven nudges;
  /// having TWO different fields feeding the same prompt was
  /// conceptually muddy. About Me is now strictly identity-level
  /// (sits on Profile next to avatar + name + custom title), and
  /// architect-side rules live solely in Your additions.
  String botbooruAboutMe = '';

  /// Wave CY.18.36: user-editable custom title that sits under the
  /// username on the Profile screen — replaces the hardcoded
  /// "BotBooru creator" subtitle (which assumed everyone uploads to
  /// BotBooru, which they don't). Discord-style free text. Empty
  /// string when never configured → Profile shows no subtitle.
  String botbooruTitle = '';

  /// Wave CY.18.36: optional pronouns chip on the Profile (Discord-
  /// style small badge under the username). Free text — common
  /// presets (he/him, she/her, they/them) suggested in the editor,
  /// but custom values allowed.
  String botbooruPronouns = '';

  /// Wave CY.18.36: id of the character the user pinned as their
  /// "Featured" on the Profile. Renders as a spotlighted card under
  /// the stats row — pure self-curation, no other functional impact.
  /// Null when not set or when the pinned character has been
  /// deleted (the Profile renderer falls back gracefully).
  String? botbooruFeaturedCharacterId;

  /// Wave CY.18.36: timestamp of the first AppStore load on this
  /// device — used to compute "X days on Pyre" stat. Set ONCE on
  /// fresh install when this field is missing from the loaded JSON;
  /// any subsequent load preserves the existing value. Backups
  /// carry it across devices so a restored user keeps their original
  /// joined-on date.
  int? installedAt;

  List<Chat> chats = [];
  List<Lorebook> lorebooks = [];

  /// Wave CY.18.38: user-created character folders. Each folder
  /// references character ids; characters can be in multiple folders.
  /// Empty list = no folders, library renders as the flat "All" view.
  List<Folder> folders = [];

  /// Wave CY.18.38: persisted filter / sort state for the Characters
  /// list. UI reads and writes these via setters; they survive across
  /// app launches so the user's last view shape sticks.
  ///   - charSortKey: one of 'recent' | 'created' | 'alpha' | 'chatted'
  ///   - charSelectedTags: tag chips currently active (AND logic)
  ///   - charFolderId: when non-null, list is filtered to that folder
  ///   - charFavoritesExpanded: state of the Favorites section header
  String charSortKey = 'recent';
  List<String> charSelectedTags = [];
  String? charFolderId;
  bool charFavoritesExpanded = true;

  /// Wave CY.18.38: same idea for Personas, but Personas tab is
  /// simpler — sort + favorites only, no tag filter, no folders.
  String personaSortKey = 'recent';

  /// Wave CY.18.39: latches to true the moment the user hits "Get
  /// started" on the welcome screen. Pre-Wave the onboarding gate
  /// was `providers.isEmpty` — meaning a user who tapped Skip without
  /// configuring a provider saw the same onboarding pop on every
  /// launch. With this flag, the welcome shows ONCE; further sessions
  /// drop straight into the app (the chat screen handles the
  /// "no provider configured" empty-state CTA on its own).
  bool seenOnboarding = false;

  /// Wave CY.18.121: latches to true the first time the bundled example
  /// cards are evaluated for seeding (see [seedExamplesIfFresh]). Mirrors
  /// [seenOnboarding] exactly — a field read in `load()` with `?? false`
  /// and written in `_persist()` only when true. Once set, the example
  /// set is never re-seeded, so a user who deletes the examples stays
  /// rid of them.
  bool exampleContentSeeded = false;

  /// Wave CY.18.188: latches to true after the one-time migration that
  /// removes the stale seeded Vesna persona from pre-Wave-161 installs.
  /// Pre-Wave-161 builds seeded BOTH a Ren persona AND a Vesna persona;
  /// Wave CY.18.161 demoted Vesna to library-only (no persona), but
  /// existing installs kept the old Vesna persona. This migration removes
  /// it exactly once, so the Personas list shows only Ren (our mascot) on
  /// upgraded installs, matching what fresh installs already see.
  ///
  /// Same persisted-flag pattern as [exampleContentSeeded]: read `?? false`
  /// in load(), written only when true in _persist() (omit-when-false).
  /// Fresh installs (no stale Vesna) are still guarded by the flag so the
  /// check is unconditional and runs exactly once regardless.
  bool vesnaExamplePersonaSwept = false;

  /// Wave CY.18.204: latches to true after the one-time migration that
  /// adjusts persona defaults on an EXISTING install to match the new
  /// fresh-install behaviour (Gui): un-favourite the seeded example Ren
  /// persona, clear `activePersonaId` if it still points at that Ren, and
  /// flip `askPersonaOnNewChat` to true. All three actions are
  /// non-destructive/reversible; the flag just guarantees it runs once.
  ///
  /// Same persisted-flag pattern as [exampleContentSeeded] /
  /// [vesnaExamplePersonaSwept]: read `?? false` in load(), written only
  /// when true in _persist() (omit-when-false). Fresh installs already get
  /// the right defaults from the seeder + the model defaults, so the
  /// migration is effectively a no-op there — but the flag still latches so
  /// the check runs exactly once regardless.
  bool personaDefaultsAdjustedV2 = false;

  /// Wave CY.18.209: SUPERSEDES the Wave-204 [personaDefaultsAdjustedV2]
  /// migration, which never actually fired. The Wave-204 guard matched the
  /// seeded Ren persona by `name == 'Ren'`, but the persona is created via
  /// `buildPersonaFromCharacter` (which copies `name` from the source card)
  /// and the card's real name is "Ren Brennan" — so the match was always
  /// false and the v2 pass did nothing while still latching its flag.
  ///
  /// `shouldUnfavoriteSeededRen` is now corrected (matches `startsWith('Ren')`),
  /// but because v2 already latched on existing installs we cannot reuse its
  /// flag — we gate the corrected pass behind THIS new flag so it fires
  /// exactly once on the next launch. The three actions (un-favourite the
  /// matched Ren persona, clear `activePersonaId` if it points at it, flip
  /// `askPersonaOnNewChat` to true) are identical to v2 and all
  /// non-destructive/reversible. v2 is kept as-is (harmless dead latch).
  ///
  /// Same persisted-flag pattern: read `?? false` in load(), written only
  /// when true in _persist() (omit-when-false).
  bool personaDefaultsAdjustedV3 = false;

  /// Wave CY.18.40: per-model load errors captured during `load()`.
  /// Each entry is a human-readable string describing what failed
  /// (e.g. "characters: 2 items skipped due to malformed JSON").
  /// Surfaced in the Storage screen so the user can tell exactly
  /// what was lost during recovery. Cleared at the start of every
  /// load().
  List<String> loadErrors = [];

  List<Preset> presets = [];
  String? activePresetId;

  /// Wave CY.18.107 — Pillar E. Forkable Creator architect prompts. Mirrors
  /// [presets] / [activePresetId]. The locked default ('Pyre Default') is
  /// seeded on load and supplies the architect base in
  /// `_architectPromptForSession` when active.
  List<CreatorPreset> creatorPresets = [];
  String? activeCreatorPresetId;

  /// Pyre 1.1 (F4) — Regex find/replace rules. A top-level SYNCED list
  /// (LWW via mtime + deleted, mirroring [lorebooks]). Applied
  /// non-destructively at the prompt + display stages; stored messages are
  /// never mutated. An EMPTY list leaves chat rendering + prompts
  /// byte-identical to today.
  List<RegexRule> regexRules = [];

  ModelSettings modelSettings = ModelSettings();
  ChatSettings chatSettings = ChatSettings();
  MemorySettings memorySettings = MemorySettings();
  LiveSheetSettings liveSheetSettings = LiveSheetSettings();
  ScriptSettings scriptSettings = ScriptSettings();
  UiPrefs uiPrefs = UiPrefs();

  /// One CreatorSession per in-progress card build. The drawer in the
  /// character-creator screen lists these; tapping a row swaps the
  /// active session in-place.
  List<CreatorSession> creatorSessions = [];
  String? activeCreatorSessionId;

  /// Wave CY.18.256: synced tombstone LOG for deletion propagation. Keyed
  /// by `'<kind>:<id>'` (kinds: `character`, `persona`, `chat`, `lorebook`,
  /// `preset`); value = deletion time in millis-since-epoch.
  ///
  /// Why a separate log rather than the per-record `deleted` flag: deletes
  /// here HARD-remove the record from its collection (so every read site
  /// stays simple — no ghost-item filtering). But a hard remove leaves no
  /// trace for sync, so a paired peer that still holds the record re-pushes
  /// it and the deletion RESURRECTS on the next pull. The tombstone log is
  /// the trace: it travels in the push/pull payload, suppresses a peer's
  /// stale live copy (see [isTombstonedNewer]), and is GC'd after 30 days
  /// (same window as [_gcTombstones]) so it never grows unbounded.
  ///
  /// Additive on the wire: a peer that doesn't send `tombstones` (older
  /// build) is treated as an empty map everywhere.
  final Map<String, int> tombstones = {};

  // Wave CY.18.63: accept StoreBackend instead of JsonStorage directly.
  // Default is LocalBackend (native disk via JsonStorage) so existing
  // call sites keep working with no change.
  AppStore({StoreBackend? storage}) : _storage = storage ?? LocalBackend();

  // -------------------------------------------------------------------------
  // Lifecycle

  /// Wave CY.18.40: parse a JSON list of model items with PER-ITEM
  /// isolation. One malformed character no longer nukes the entire
  /// characters list; we skip it and log the failure into
  /// [loadErrors] for diagnostics. Returns the successfully-parsed
  /// items in order.
  ///
  /// Use this for every model-backed list in load(): providers,
  /// characters, personas, drafts, chats, lorebooks, presets, folders,
  /// creatorSessions. Each gets its own field name so the diagnostics
  /// pinpoint which collection had the problem.
  List<T> _parseList<T>(
    dynamic raw,
    String fieldName,
    T Function(Map<String, dynamic>) parse,
  ) {
    if (raw == null) return <T>[];
    if (raw is! List) {
      loadErrors.add(
          '$fieldName: expected a list, got ${raw.runtimeType} — '
          'skipped entirely.');
      return <T>[];
    }
    final out = <T>[];
    var skipped = 0;
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) {
        skipped++;
        continue;
      }
      try {
        out.add(parse(item.cast<String, dynamic>()));
      } catch (e) {
        skipped++;
        debugPrint('[load] $fieldName[$i] failed: $e');
      }
    }
    if (skipped > 0) {
      loadErrors.add(
          '$fieldName: $skipped of ${raw.length} item(s) failed to '
          'parse and were skipped.');
    }
    return out;
  }

  /// Wave CY.18.40: parse an embedded settings/prefs object with
  /// failure isolation. If the object is missing or malformed, the
  /// caller's existing default stays in place.
  T _parseObject<T>(
    dynamic raw,
    String fieldName,
    T Function(Map<String, dynamic>) parse,
    T fallback,
  ) {
    if (raw == null) return fallback;
    if (raw is! Map) {
      loadErrors.add('$fieldName: expected an object, got '
          '${raw.runtimeType} — using defaults.');
      return fallback;
    }
    try {
      return parse(raw.cast<String, dynamic>());
    } catch (e) {
      loadErrors.add('$fieldName: $e — using defaults.');
      return fallback;
    }
  }

  Future<void> load() async {
    loadErrors = [];
    final raw = await _storage.load();
    // Fresh install (or post-wipe / post-applicationId-rename) — there's
    // no state file yet. Don't early-return; we still need to seed the
    // locked default preset below so the Presets screen isn't empty on
    // first launch. Only the deserialization block is conditional on raw
    // being non-null.
    //
    // Wave CY.18.40: REPLACED the single big try/catch with per-model
    // isolation via `_parseList` / `_parseObject`. Before: a single
    // malformed character would silently nuke characters AND every
    // model loaded after it (personas, chats, presets, etc.). Now:
    // one bad item is skipped (logged in loadErrors), every other
    // collection still loads cleanly.
    if (raw != null) {
      // Wave CY.18.45: schema version sniff. Pre-Wave the only "old vs
      // new" signal was best-effort tolerance in each fromJson — which
      // works for additive schema changes but is silent on subtractive
      // ones. Now an explicit `schemaVersion` field on the persisted
      // blob lets us:
      //   - know we're reading data older than the current app
      //     understands (current code) → run any migrations registered
      //     for that range,
      //   - or know we're reading data NEWER than current (user
      //     downgraded the APK?) → warn in loadErrors so the Storage
      //     screen banner surfaces it. We still load — the fromJson
      //     code may be defensive enough — but the user is told.
      // Inline int-decode (the helper in models.dart is private). A
      // schemaVersion of `1.0` from a JS-prototype-style backup parses
      // as double; coerce.
      final rawVer = raw['schemaVersion'];
      final fileVersion = rawVer is int
          ? rawVer
          : (rawVer is num ? rawVer.toInt() : 0);
      if (fileVersion > schemaVersion) {
        loadErrors.add(
            'Loaded data is schema v$fileVersion but this build only '
            'understands v$schemaVersion. Some fields may be ignored. '
            'If you upgraded the APK then downgraded, install the '
            'newer build to restore full compatibility.');
      }
      // v0 → v1: no actual transformation needed, the v0 schema is a
      // strict subset of v1 (we only added optional fields). The
      // marker is here so future migrations can hook in cleanly.
      // ignore: dead_code
      if (fileVersion < schemaVersion) {
        // Reserved for future migration handlers. Each migration is a
        // function (Map<String,dynamic> raw) → Map<String,dynamic>.
      }
      providers = _parseList<ApiProvider>(
          raw['providers'], 'providers', ApiProvider.fromJson);
      activeProviderId = raw['activeProviderId'] as String?;
      creatorProviderId = raw['creatorProviderId'] as String?;
      visionProviderId = raw['visionProviderId'] as String?;
      // Wave CY.18.99: per-provider refusal history (self-learning).
      final rawRefusals = raw['providerRefusals'];
      if (rawRefusals is Map) {
        providerRefusals = rawRefusals.map(
          (k, v) => MapEntry(k.toString(), (v as num?)?.toInt() ?? 0),
        );
      }

      // Hydrate API keys from OS-secure storage. We support a one-time
      // migration: if a provider blob still has a key in plain JSON (from
      // a build before secure storage existed, or from a backup restore),
      // move it into secure storage and clear the in-memory plain-text
      // reference's source on next save.
      //
      // Wave CY.18.40: wrapped in try/catch so a flaky keystore call
      // doesn't abort the whole load. A failed read leaves the in-memory
      // key empty; the user can re-paste in API Connections.
      for (final p in providers) {
        try {
          final fromBlob = p.apiKey;
          if (fromBlob.isNotEmpty) {
            await SecureKeys.write(p.id, fromBlob);
          } else {
            p.apiKey = await SecureKeys.read(p.id);
          }
        } catch (e) {
          loadErrors.add('provider "${p.name}": secure key hydration '
              'failed ($e) — re-paste in API Connections.');
        }
      }

      characters = _parseList<Character>(
          raw['characters'], 'characters', Character.fromJson);
      personas = _parseList<Persona>(
          raw['personas'], 'personas', Persona.fromJson);
      activePersonaId = raw['activePersonaId'] as String?;
      // Wave BG: in-progress drafts from the manual editor.
      characterDrafts = _parseList<Character>(
          raw['characterDrafts'], 'characterDrafts', Character.fromJson);
      // Wave BC: botbooru creator handle. Defaults to '' so existing
      // backups without this field load cleanly.
      botbooruUsername = (raw['botbooruUsername'] as String?) ?? '';
      // Wave CY.18.30: profile picture + about-me, both optional and
      // backwards-compatible with pre-Wave backups (missing fields →
      // empty / null).
      botbooruAvatar = raw['botbooruAvatar'] as String?;
      botbooruAboutMe = (raw['botbooruAboutMe'] as String?) ?? '';
      // Wave CY.18.36: Profile expansion fields, all optional + back-
      // compat. `installedAt` gets set on this load if absent (see
      // below, after the try/catch closes the load branch).
      botbooruTitle = (raw['botbooruTitle'] as String?) ?? '';
      botbooruPronouns = (raw['botbooruPronouns'] as String?) ?? '';
      botbooruFeaturedCharacterId =
          raw['botbooruFeaturedCharacterId'] as String?;
      installedAt = (raw['installedAt'] as num?)?.toInt();

      folders = _parseList<Folder>(
          raw['folders'], 'folders', Folder.fromJson);
      charSortKey = (raw['charSortKey'] as String?) ?? 'recent';
      charSelectedTags =
          (raw['charSelectedTags'] as List?)?.cast<String>() ?? [];
      charFolderId = raw['charFolderId'] as String?;
      charFavoritesExpanded =
          (raw['charFavoritesExpanded'] as bool?) ?? true;
      personaSortKey = (raw['personaSortKey'] as String?) ?? 'recent';
      seenOnboarding = (raw['seenOnboarding'] as bool?) ?? false;
      // Wave CY.18.121: example-seed latch. Missing on pre-Wave backups
      // → false, but the seed gate's `charactersEmpty` + `!seenOnboarding`
      // clauses still protect any non-fresh install from re-seeding.
      exampleContentSeeded =
          (raw['exampleContentSeeded'] as bool?) ?? false;
      // Wave CY.18.188: stale-Vesna-persona sweep latch. Missing on
      // pre-Wave-188 installs → false (sweep runs once on first load).
      vesnaExamplePersonaSwept =
          (raw['vesnaExamplePersonaSwept'] as bool?) ?? false;
      // Wave CY.18.204: persona-defaults migration latch. Missing on
      // pre-Wave-204 installs → false (the one-time adjustment runs once
      // on first load after upgrade).
      personaDefaultsAdjustedV2 =
          (raw['personaDefaultsAdjustedV2'] as bool?) ?? false;
      // Wave CY.18.209: corrected persona-defaults migration latch (the v2
      // pass matched the wrong name and was a no-op). Missing on installs
      // that predate this wave → false, so the corrected pass runs once.
      personaDefaultsAdjustedV3 =
          (raw['personaDefaultsAdjustedV3'] as bool?) ?? false;

      chats = _parseList<Chat>(raw['chats'], 'chats', Chat.fromJson);
      lorebooks = _parseList<Lorebook>(
          raw['lorebooks'], 'lorebooks', Lorebook.fromJson);
      presets = _parseList<Preset>(
          raw['presets'], 'presets', Preset.fromJson);
      activePresetId = raw['activePresetId'] as String?;
      creatorPresets = _parseList<CreatorPreset>(
          raw['creatorPresets'], 'creatorPresets', CreatorPreset.fromJson);
      activeCreatorPresetId = raw['activeCreatorPresetId'] as String?;
      // Pyre 1.1 (F4): regex find/replace rules. Missing key → empty list,
      // which leaves chat byte-identical to pre-1.1 behaviour.
      regexRules = _parseList<RegexRule>(
          raw['regexRules'], 'regexRules', RegexRule.fromJson);

      modelSettings = _parseObject<ModelSettings>(
          raw['modelSettings'],
          'modelSettings',
          ModelSettings.fromJson,
          modelSettings);
      chatSettings = _parseObject<ChatSettings>(
          raw['chatSettings'],
          'chatSettings',
          ChatSettings.fromJson,
          chatSettings);
      memorySettings = _parseObject<MemorySettings>(
          raw['memorySettings'],
          'memorySettings',
          MemorySettings.fromJson,
          memorySettings);
      liveSheetSettings = _parseObject<LiveSheetSettings>(
          raw['liveSheetSettings'],
          'liveSheetSettings',
          LiveSheetSettings.fromJson,
          liveSheetSettings);
      scriptSettings = _parseObject<ScriptSettings>(
          raw['scriptSettings'],
          'scriptSettings',
          ScriptSettings.fromJson,
          scriptSettings);
      uiPrefs = _parseObject<UiPrefs>(
          raw['uiPrefs'], 'uiPrefs', UiPrefs.fromJson, uiPrefs);

      creatorSessions = _parseList<CreatorSession>(raw['creatorSessions'],
          'creatorSessions', CreatorSession.fromJson);
      activeCreatorSessionId = raw['activeCreatorSessionId'] as String?;

      // Wave CY.18.256: synced tombstone log. Absent on pre-Wave backups
      // → stays the empty map (deletion propagation simply has no history
      // yet). Tolerant of malformed entries (non-int values coerce to 0).
      final rawTombstones = raw['tombstones'];
      if (rawTombstones is Map) {
        tombstones.clear();
        rawTombstones.forEach((k, v) {
          tombstones[k.toString()] = (v as num?)?.toInt() ?? 0;
        });
      }

      // Wave CY.18.62: schema v1 → v2 migration. v2 adds `mtime` / `deleted`
      // to every synced record. Pre-Wave-62 records load with mtime=0
      // (their fromJson defaults). Stamp them now so the first LAN sync
      // after upgrade treats them as recently-edited — which IS correct:
      // the user has them locally; the (eventual) server has nothing.
      // Idempotent: skips records that already have mtime > 0 (e.g. from
      // a manual edit between earlier-Wave-62 and now).
      if (fileVersion < 2) {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final c in characters) {
          if (c.mtime == 0) c.mtime = now;
        }
        for (final p in personas) {
          if (p.mtime == 0) p.mtime = now;
        }
        for (final ch in chats) {
          if (ch.mtime == 0) ch.mtime = now;
          for (final m in ch.messages) {
            if (m.mtime == 0) m.mtime = now;
          }
          for (final mc in ch.memoryCheckpoints) {
            if (mc.mtime == 0) mc.mtime = now;
          }
        }
        for (final p in presets) {
          if (p.mtime == 0) p.mtime = now;
        }
        for (final l in lorebooks) {
          if (l.mtime == 0) l.mtime = now;
        }
      }
    } // end if (raw != null)

    // Locked default — always refresh from the build so updates ship to
    // every existing install (AND seed on fresh installs that took the
    // raw==null path above). The user can't edit it anyway (locked), so
    // overwriting in place is safe and avoids a stale prompt sticking
    // around after a release that changes the canonical text.
    final freshLockedDefault = buildLockedDefaultPreset();
    final existingLockedIdx =
        presets.indexWhere((p) => p.id == lockedDefaultPresetId);
    if (existingLockedIdx >= 0) {
      presets[existingLockedIdx] = freshLockedDefault;
    } else {
      presets.insert(0, freshLockedDefault);
    }
    activePresetId ??= lockedDefaultPresetId;

    // Wave CY.18.107: locked default Creator preset — same seed-on-load /
    // refresh-in-place semantics as the chat Preset above. If the list is
    // empty or lacks the locked default, (re)insert it; always refresh from
    // the build so prompt updates ship to every install. Default the active
    // id to it on a fresh install.
    final freshLockedCreatorDefault = buildLockedDefaultCreatorPreset();
    final existingLockedCreatorIdx = creatorPresets
        .indexWhere((p) => p.id == lockedDefaultCreatorPresetId);
    if (existingLockedCreatorIdx >= 0) {
      creatorPresets[existingLockedCreatorIdx] = freshLockedCreatorDefault;
    } else {
      creatorPresets.insert(0, freshLockedCreatorDefault);
    }
    activeCreatorPresetId ??= lockedDefaultCreatorPresetId;

    // Drop stale empty creator sessions — accidental drawer "+ New"
    // taps leave behind blank "Untitled" rows that pile up otherwise.
    // Pinned + saved sessions are kept.
    pruneEmptyCreatorSessions();

    // Repair zero-mtime synced records so they become LAN-sync-eligible.
    // The `fileVersion < 2` migration above only stamped pre-v2 backups;
    // it never runs for installs already at v2. But seeded example records
    // (the bundled lorebook + characters + Ren persona) were persisted at
    // `mtime == 0` on v2 installs, and the server's `/pull` only sends
    // records where `mtime > since` — with `since == 0` on a fresh client,
    // `0 > 0` is false, so they would NEVER sync. A chat that references
    // the seeded Ren persona then arrives on the phone without him → the
    // link looks orphaned and the sweep below would null it.
    //
    // This pass runs every load and is naturally idempotent: it only
    // touches records whose mtime is still 0. `stampMtimeIfZero` prefers
    // the record's own `updatedAt` so the LWW merge keeps the right order;
    // Preset has no `updatedAt`, so its `createdAt` stands in.
    final mtimeNow = DateTime.now().millisecondsSinceEpoch;
    for (final c in characters) {
      c.mtime = stampMtimeIfZero(c.mtime, c.updatedAt, mtimeNow);
    }
    for (final p in personas) {
      p.mtime = stampMtimeIfZero(p.mtime, p.updatedAt, mtimeNow);
    }
    for (final ch in chats) {
      ch.mtime = stampMtimeIfZero(ch.mtime, ch.updatedAt, mtimeNow);
    }
    for (final p in presets) {
      // Preset tracks `createdAt` instead of `updatedAt`.
      p.mtime = stampMtimeIfZero(p.mtime, p.createdAt, mtimeNow);
    }
    for (final l in lorebooks) {
      l.mtime = stampMtimeIfZero(l.mtime, l.updatedAt, mtimeNow);
    }
    // Wave CY.18.268: providers were MISSING from this repair pass, so a
    // provider created before the mtime field existed (or by the old
    // add/update paths that never stamped it) stayed at mtime=0 and was
    // invisible to LAN key-sync forever. ApiProvider has no updatedAt, so
    // installedAt is the stable fallback (now() on a fresh install).
    for (final p in providers) {
      p.mtime = stampMtimeIfZero(p.mtime, installedAt ?? mtimeNow, mtimeNow);
    }

    // Wave CY.18.44: load-time reference-integrity sweep. Pre-Wave this
    // ran only after a manual backup restore (Wave CY.18.42 / 43). But
    // an orphan reference can land in the on-disk JSON for any reason:
    //   - User deletes the active provider via Providers screen → the
    //     UI reassigns `activeProviderId`, but a half-cancelled flow
    //     can leave a dangling pointer.
    //   - A migration drops a model and forgets to clean up references.
    //   - User restores a backup from an older Pyre version with a
    //     different schema.
    // Whatever the cause, an orphan id surfaces as: opening a chat that
    // crashes because `primaryCharacterId` resolves to no Character;
    // active preset / provider menus showing "(unknown)"; chat injection
    // silently skipping bound lorebooks that don't exist.
    //
    // Same sweep we run on restore, just inlined here so every load
    // benefits — even installs that never used import/export.
    _sweepOrphanReferences();

    // Wave CY.18.36: stamp the install date on first run so the
    // Profile screen's "X days on Pyre" stat has a starting point.
    // No-op on subsequent loads (the timestamp from the JSON sticks).
    installedAt ??= DateTime.now().millisecondsSinceEpoch;

    // Wave CY.18.64: externalise any remaining inline data-URL avatars
    // into the content-addressed AttachmentStore. Idempotent + cheap
    // on subsequent loads (early-returns when the migrated pref is
    // set). Bumps mtime on touched records so the next LAN sync
    // pushes the new `pyre://attachment/...` URL form.
    final migrated = await AttachmentMigration.runIfNeeded(this);

    // Wave CY.18.121: seed the bundled example cards on a genuinely fresh
    // install (gated inside). Runs BEFORE notifyListeners() so the very
    // first frame already shows the seeded library — no empty-then-pop
    // flicker. Awaited because asset loading is async. Self-contained:
    // it does its own single persist when it actually seeds.
    await seedExamplesIfFresh();

    // Wave CY.18.188: remove the stale seeded Vesna persona from pre-Wave-161
    // installs. Pre-Wave-161 builds seeded Vesna as BOTH a library character
    // AND a persona; Wave CY.18.161 demoted her to library-only. Existing
    // installs kept the old persona — this one-time migration removes it.
    // Guarded by `vesnaExamplePersonaSwept` so it runs once and never again.
    // No-op if the persona doesn't exist (fresh installs / already swept).
    if (!vesnaExamplePersonaSwept) {
      final staleBefore = personas.length;
      personas.removeWhere(shouldRemoveAsSeededVesnaPersona);
      final removed = staleBefore - personas.length;
      if (activePersonaId != null &&
          !personas.any((p) => p.id == activePersonaId)) {
        // The active persona was the stale Vesna — fall back to null so
        // the app's own "no active persona" logic picks the next best
        // (Ren is favourite and was seeded BEFORE Vesna, so activePersonaId
        // was already Ren on post-Wave-122 installs; this is belt-and-
        // suspenders for edge cases).
        activePersonaId = null;
      }
      vesnaExamplePersonaSwept = true;
      if (removed > 0) {
        // Sync the removal to disk right away so it survives an immediate
        // force-quit. Fire-and-forget (unawaited) — same pattern used for
        // AttachmentMigration below.
        unawaited(_persist());
      }
    }

    // Wave CY.18.204: one-time persona-defaults adjustment for EXISTING
    // installs, to match the new fresh-install behaviour (Gui). Three
    // non-destructive/reversible actions, run exactly once:
    //   1. Un-favourite the seeded example Ren persona (he was starred by
    //      the old seeder for no real reason). Identified the SAME safe way
    //      Wave 188 identified Vesna — see `shouldUnfavoriteSeededRen` in
    //      example_seed.dart (name=='Ren' && favorite && no lorebook bind);
    //      there is no deterministic id since personas get random UUIDs.
    //   2. Clear `activePersonaId` IF it still points at that seeded Ren, so
    //      the install matches "no default persona" like a fresh one.
    //   3. Flip `askPersonaOnNewChat` to true (Gui's explicit request) so the
    //      user is asked who they play as on each new chat. This only
    //      touches the persisted ChatSettings once; the user can toggle it
    //      back in Chat Behaviors at any time.
    // Guarded by `personaDefaultsAdjustedV2` so it runs once and never again.
    // Effectively a no-op on fresh installs (the new seeder already leaves Ren
    // unfavourited + no active persona, and the model default is already true).
    if (!personaDefaultsAdjustedV2) {
      var touched = false;
      // 1 + 2: find the seeded Ren persona (if any) and unstar it / drop it
      //        as the active persona.
      for (final p in personas) {
        if (shouldUnfavoriteSeededRen(p)) {
          p.favorite = false;
          touched = true;
          if (activePersonaId == p.id) {
            activePersonaId = null;
          }
        }
      }
      // 3: prompt-on-new-chat default flip (Gui's explicit ask). Only counts
      //    as a "touch" if it actually changes the persisted value.
      if (!chatSettings.askPersonaOnNewChat) {
        chatSettings.askPersonaOnNewChat = true;
        touched = true;
      }
      personaDefaultsAdjustedV2 = true;
      if (touched) {
        // Persist right away so the adjustment survives an immediate
        // force-quit (same fire-and-forget pattern as the Vesna sweep above).
        unawaited(_persist());
      }
    }

    // Wave CY.18.209: corrected persona-defaults adjustment. SUPERSEDES the
    // Wave-204 block above, which matched the seeded Ren persona by
    // `name == 'Ren'` and so never fired (the persona's real name is
    // "Ren Brennan" — `buildPersonaFromCharacter` copies the card name).
    // `shouldUnfavoriteSeededRen` is now corrected, but the v2 flag already
    // latched on existing installs, so we gate the corrected pass behind a
    // NEW flag (`personaDefaultsAdjustedV3`) so it fires exactly once on the
    // next launch. Same three non-destructive/reversible actions as v2.
    if (!personaDefaultsAdjustedV3) {
      var touched = false;
      for (final p in personas) {
        if (shouldUnfavoriteSeededRen(p)) {
          p.favorite = false;
          touched = true;
          if (activePersonaId == p.id) {
            activePersonaId = null;
          }
        }
      }
      if (!chatSettings.askPersonaOnNewChat) {
        chatSettings.askPersonaOnNewChat = true;
        touched = true;
      }
      personaDefaultsAdjustedV3 = true;
      if (touched) {
        unawaited(_persist());
      }
    }

    _loaded = true;
    notifyListeners();

    // Wave CY.18.127: once-per-launch orphan-attachment GC. The desktop
    // also runs this when the LAN server starts (PyreServer), but that
    // never fires for mobile-only / never-run-the-server users — so this
    // local sweep is what keeps their disk from accumulating dead blobs
    // (e.g. a removed gallery image whose hash nothing references anymore).
    // Fully fire-and-forget so a large attachments dir can't stall startup;
    // guarded by `_attachmentGcRan` so a repeat `load()` doesn't re-scan.
    // No-op on web — `gcOrphans` returns 0 (no filesystem).
    if (!_attachmentGcRan) {
      _attachmentGcRan = true;
      unawaited(AttachmentStore.gcOrphans(collectReferencedAttachmentHashes(this)));
    }

    // Wave CY.18.120: kick off model preloads for every opted-in local
    // provider exactly once, right after providers are available. Fully
    // fire-and-forget (never awaited) so a slow cold load can't block app
    // startup or the UI thread — the goal is that the model is warm by the
    // time the user sends their first real message.
    warmUpLocalProviders();

    // Persist outside the load critical section so a slow disk write
    // doesn't keep the splash screen up. Fire-and-forget — worst case
    // the migration re-runs on next launch (idempotent).
    if (migrated) {
      unawaited(_persist());
    }
  }

  /// Wave CY.18.120: fire a best-effort warm-up for each localhost provider
  /// that opted into preload-on-launch and has a model set. Each warm-up is
  /// an unawaited fire-and-forget call (warmUpProvider swallows all errors),
  /// so this returns immediately and never blocks the caller.
  void warmUpLocalProviders() {
    for (final p in providers) {
      if (p.kind == ProviderKind.localhost &&
          p.warmUpOnLaunch &&
          p.model.trim().isNotEmpty) {
        unawaited(warmUpProvider(p));
      }
    }
  }

  /// Wave CY.18.44: reference-integrity sweep called on every load + on
  /// every backup restore. Filters out dangling ids that point at items
  /// that aren't in the current collections, so downstream code never
  /// sees an "id that doesn't resolve".
  void _sweepOrphanReferences() {
    final providerIds = providers.map((p) => p.id).toSet();
    final characterIdSet = characters.map((c) => c.id).toSet();
    final personaIds = personas.map((p) => p.id).toSet();
    // Lorebook ids are intentionally NOT collected: we no longer strip
    // lorebook binds for "missing" books (synced collection — see the
    // note below the active-id checks).
    final presetIds = presets.map((p) => p.id).toSet();
    final creatorPresetIds = creatorPresets.map((p) => p.id).toSet();

    if (activeProviderId != null &&
        !providerIds.contains(activeProviderId)) {
      activeProviderId = null;
    }
    if (creatorProviderId != null &&
        !providerIds.contains(creatorProviderId)) {
      creatorProviderId = null;
    }
    if (visionProviderId != null &&
        !providerIds.contains(visionProviderId)) {
      visionProviderId = null;
    }
    // Wave CY.18.99: drop refusal records for providers that no longer
    // exist so the map doesn't grow unbounded across deletes.
    providerRefusals.removeWhere((id, _) => !providerIds.contains(id));
    if (activePersonaId != null &&
        !personaIds.contains(activePersonaId)) {
      activePersonaId = null;
    }
    if (activePresetId != null &&
        !presetIds.contains(activePresetId)) {
      activePresetId = lockedDefaultPresetId;
    }
    if (activeCreatorPresetId != null &&
        !creatorPresetIds.contains(activeCreatorPresetId)) {
      activeCreatorPresetId = lockedDefaultCreatorPresetId;
    }
    if (activeCreatorSessionId != null &&
        !creatorSessions.any((cs) => cs.id == activeCreatorSessionId)) {
      activeCreatorSessionId = null;
    }

    // NOTE: do NOT strip character/persona lorebook binds for "missing"
    // lorebooks. Lorebooks are a SYNCED collection — on a paired client a
    // bound book may simply not have arrived yet (LAN sync is eventual).
    // Stripping the bind here would permanently destroy a link that the
    // next pull could fill in. A dangling lorebookId is harmless: the chat
    // injection path skips ids that don't resolve.
    for (final chat in chats) {
      // Keep ids that resolve via the library OR via this chat's frozen
      // snapshot map. Snapshots are self-contained, so a snapshot-only
      // character is still usable.
      chat.characterIds.removeWhere((id) =>
          !characterIdSet.contains(id) &&
          !chat.characterSnapshots.containsKey(id));
      chat.characterSnapshots
          .removeWhere((id, _) => !chat.characterIds.contains(id));
      // Do NOT null `personaId` for a missing persona. Personas sync too;
      // on a paired client the persona this chat points at (e.g. the
      // bundled Ren persona) may not have arrived yet. Nulling it here
      // would permanently sever a link the next pull could restore. The
      // render path falls back gracefully when the persona is absent, so a
      // dormant personaId is harmless.
      if (chat.presetId != null && !presetIds.contains(chat.presetId)) {
        chat.presetId = null;
      }
      // Lorebook binds: kept even when the book is missing (synced
      // collection — see the note above). Injection skips unresolved ids.
      for (final m in chat.messages) {
        if (m.characterId != null && m.characterId!.isNotEmpty) {
          final ok = characterIdSet.contains(m.characterId) ||
              chat.characterSnapshots.containsKey(m.characterId);
          if (!ok) m.characterId = null;
        }
      }
    }
  }

  /// Wave CY.18.72: physically remove soft-deleted records whose
  /// tombstones are older than 30 days. Tombstones exist because a
  /// disconnected device needs them to learn about deletions on its
  /// next sync (without them, a "removed locally" record would just
  /// get re-pushed by any device that still has it). After 30 days,
  /// any device that's been offline that long can't be trusted to
  /// sync cleanly anyway, so we free the storage. Called from
  /// _persist() on every save — amortised cost.
  static const int _tombstoneTtlMs = 30 * 24 * 60 * 60 * 1000;

  void _gcTombstones() {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - _tombstoneTtlMs;
    characters.removeWhere((c) => c.deleted && c.mtime > 0 && c.mtime < cutoff);
    personas.removeWhere((p) => p.deleted && p.mtime > 0 && p.mtime < cutoff);
    chats.removeWhere((c) => c.deleted && c.mtime > 0 && c.mtime < cutoff);
    presets.removeWhere((p) =>
        p.deleted && !p.locked && p.mtime > 0 && p.mtime < cutoff);
    lorebooks.removeWhere((l) => l.deleted && l.mtime > 0 && l.mtime < cutoff);
    // Wave CY.18.256: prune the synced tombstone LOG to the SAME 30-day
    // window. After 30 days a device that's been offline that long can't
    // sync cleanly anyway, so dropping the deletion record is safe and
    // keeps the map from growing unbounded across deletes.
    tombstones.removeWhere((_, mtime) => mtime < cutoff);
  }

  /// Wave CY.18.256: record a deletion in the synced tombstone log. Called
  /// by every delete method so a paired peer learns the record is gone and
  /// stops re-pushing its still-live copy. [kind] is one of `character`,
  /// `persona`, `chat`, `lorebook`, `preset`.
  void recordTombstone(String kind, String id) {
    tombstones['$kind:$id'] = DateTime.now().millisecondsSinceEpoch;
  }

  /// Wave CY.18.256: true iff a tombstone for `<kind>:<id>` exists whose
  /// deletion time is `>=` [recordMtime]. Used on the sync apply path to
  /// suppress an incoming live record we deleted at-or-after the version
  /// the peer is offering — our newer (or simultaneous) delete wins over
  /// the peer's stale copy. A `>=` (not `>`) compare means a delete that
  /// shares the record's exact mtime still suppresses it.
  bool isTombstonedNewer(String kind, String id, int recordMtime) {
    final t = tombstones['$kind:$id'];
    return t != null && t >= recordMtime;
  }

  /// Wave CY.18.45: schema version stamped into every persisted blob
  /// (main state file + backup exports). Bumped when a fromJson change
  /// is incompatible with the previous shape — at which point load()
  /// runs the matching migration block.
  ///
  /// Wave CY.18.62: bumped 1 → 2. v2 adds `mtime`, `deleted` to every
  /// synced model class. The migration (in load(), gated on
  /// `fileVersion < 2`) stamps `mtime = now()` on every loaded record
  /// so the first LAN sync after upgrade treats them as "recently
  /// edited" (which is correct — the user has them locally, the
  /// server doesn't know about them yet).
  static const int schemaVersion = 2;

  // Wave CY.18.255 (FIX 1): single-flight guard around the actual disk
  // write. `_persist()` is re-entrant — several `unawaited(_persist())`
  // fire during load() (Vesna sweep, persona-defaults v2/v3, attachment
  // migration) and `flushPersist()` awaits a fresh `_persist()` without
  // checking whether one is already mid-flight. Two overlapping runs would
  // race in storage.save (shared `.tmp` path + interleaved backup
  // rotation), which can corrupt the on-disk state. We serialize behind a
  // Future chain (the same pattern as `ErrorLog._inflight`): if a save is
  // running we mark exactly ONE follow-up pending — any further requests
  // that arrive while a save is in flight coalesce into that single
  // follow-up rather than stacking. `flushPersist()` awaits the returned
  // future, which only completes once the in-flight write AND any coalesced
  // follow-up have hit disk, so the final state is durable before suspend.
  Future<void>? _persistInFlight;
  bool _persistQueued = false;

  /// Serialised persist. Never overlaps with another `_persist()`; rapid
  /// callers coalesce into at most one trailing write.
  Future<void> _persist() {
    if (_persistInFlight != null) {
      // A write is already running. Request (at most) one follow-up so the
      // very latest in-memory state is captured after the current write
      // finishes, then await the whole chain.
      _persistQueued = true;
      return _persistInFlight!;
    }
    final run = _runPersistChain();
    _persistInFlight = run;
    return run;
  }

  /// Drives the in-flight write plus any coalesced follow-up, then clears
  /// the in-flight marker. Each iteration re-serialises from CURRENT state,
  /// so a follow-up always writes the freshest snapshot.
  Future<void> _runPersistChain() async {
    try {
      await _persistOnce();
      // Drain coalesced follow-ups one at a time (a burst of N requests
      // collapses to a single trailing write). The loop terminates because
      // `_persistQueued` is only re-set by callers arriving DURING a write.
      while (_persistQueued) {
        _persistQueued = false;
        await _persistOnce();
      }
    } finally {
      _persistInFlight = null;
    }
  }

  Future<void> _persistOnce() async {
    // Wave CY.18.72: tombstone GC. Records that were soft-deleted
    // (mtime stamped, `deleted=true`) more than 30 days ago get
    // physically removed from the in-memory list before serialise.
    // Why 30 days? It's the window a disconnected device can be away
    // without losing the deletion — anything longer and the device
    // would have to re-pair anyway because the bearer-token check-in
    // cadence renews trust. Tombstones don't grow unbounded.
    _gcTombstones();

    final blob = <String, dynamic>{
      // Wave CY.18.45: version stamp lives at the top of the JSON so
      // an external tool inspecting an `app-state.json` can sniff it
      // first without parsing the whole tree.
      'schemaVersion': schemaVersion,
      'providers': providers.map((p) => p.toJson()).toList(),
      'activeProviderId': activeProviderId,
      'creatorProviderId': creatorProviderId,
      'visionProviderId': visionProviderId,
      // Wave CY.18.99: refusal history (omit when empty to keep blobs clean).
      if (providerRefusals.isNotEmpty) 'providerRefusals': providerRefusals,
      'characters': characters.map((c) => c.toJson()).toList(),
      'personas': personas.map((p) => p.toJson()).toList(),
      'activePersonaId': activePersonaId,
      // Wave BG: persist in-progress drafts so resume-after-restart works.
      'characterDrafts':
          characterDrafts.map((c) => c.toJson()).toList(),
      // Wave BC: persist the botbooru creator handle for {{creator}}
      // substitution on Save Card.
      'botbooruUsername': botbooruUsername,
      // Wave CY.18.30: persist profile picture + about-me text.
      // Avatar is data-URL string (may be null), aboutMe is plain
      // free-form text.
      if (botbooruAvatar != null) 'botbooruAvatar': botbooruAvatar,
      'botbooruAboutMe': botbooruAboutMe,
      // Wave CY.18.36: Profile expansion fields.
      'botbooruTitle': botbooruTitle,
      'botbooruPronouns': botbooruPronouns,
      if (botbooruFeaturedCharacterId != null)
        'botbooruFeaturedCharacterId': botbooruFeaturedCharacterId,
      if (installedAt != null) 'installedAt': installedAt,
      // Wave CY.18.38: folders + Characters/Personas filter state.
      'folders': folders.map((f) => f.toJson()).toList(),
      'charSortKey': charSortKey,
      'charSelectedTags': charSelectedTags,
      if (charFolderId != null) 'charFolderId': charFolderId,
      'charFavoritesExpanded': charFavoritesExpanded,
      'personaSortKey': personaSortKey,
      if (seenOnboarding) 'seenOnboarding': true,
      // Wave CY.18.121: example-seed latch (omit when false, mirroring
      // seenOnboarding, to keep fresh-install blobs clean).
      if (exampleContentSeeded) 'exampleContentSeeded': true,
      // Wave CY.18.188: stale-Vesna-persona sweep latch.
      if (vesnaExamplePersonaSwept) 'vesnaExamplePersonaSwept': true,
      // Wave CY.18.204: persona-defaults migration latch.
      if (personaDefaultsAdjustedV2) 'personaDefaultsAdjustedV2': true,
      // Wave CY.18.209: corrected persona-defaults migration latch.
      if (personaDefaultsAdjustedV3) 'personaDefaultsAdjustedV3': true,
      'chats': chats.map((c) => c.toJson()).toList(),
      'lorebooks': lorebooks.map((l) => l.toJson()).toList(),
      'presets': presets.map((p) => p.toJson()).toList(),
      'activePresetId': activePresetId,
      'creatorPresets': creatorPresets.map((p) => p.toJson()).toList(),
      'activeCreatorPresetId': activeCreatorPresetId,
      // Pyre 1.1 (F4): regex find/replace rules.
      'regexRules': regexRules.map((r) => r.toJson()).toList(),
      'modelSettings': modelSettings.toJson(),
      'chatSettings': chatSettings.toJson(),
      'memorySettings': memorySettings.toJson(),
      'liveSheetSettings': liveSheetSettings.toJson(),
      'scriptSettings': scriptSettings.toJson(),
      'uiPrefs': uiPrefs.toJson(),
      'creatorSessions':
          creatorSessions.map((s) => s.toJson()).toList(),
      'activeCreatorSessionId': activeCreatorSessionId,
      // Wave CY.18.256: deletion-propagation tombstone log (omit when
      // empty to keep fresh / never-synced blobs clean). GC'd to the
      // same 30-day window as the per-record tombstones in _gcTombstones.
      if (tombstones.isNotEmpty) 'tombstones': tombstones,
    };
    await _storage.save(blob);
  }

  // Debounced persistence: each _bump() schedules a save, but rapid-fire
  // calls (e.g. one per token while streaming a long response) collapse
  // into a single disk write at the tail. Without this, every chunk of a
  // streamed reply would re-serialize the entire app state (providers,
  // all chats, every variant tree, lorebooks, presets...) and flush it
  // to disk — that's what was freezing the UI mid-generation.
  Timer? _persistTimer;
  static const _persistDebounce = Duration(milliseconds: 600);

  void _bump() {
    notifyListeners();
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDebounce, _persist);
  }

  /// Force the pending debounced save to flush immediately. Call this at
  /// natural "the storm is over" moments — end of a streamed response,
  /// app pause/background, navigation away from the chat — so a crash or
  /// kill doesn't lose the last few seconds of state.
  Future<void> flushPersist() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _persist();
  }

  /// Public counterpart of [_bump], for callers that mutate the store
  /// in bulk (e.g. backup-restore import) and want a single notify+persist
  /// when they're done.
  void notifyAndPersist() => _bump();

  /// Wave CY.18.48: schedule a debounced save WITHOUT firing
  /// notifyListeners. Use this for state that NEEDS to land on disk
  /// but has no UI consequence — currently just window bounds (saved
  /// on every drag pixel; rebuilding the whole tree on each pixel
  /// would tank the framerate). Same 600ms debounce as `_bump`.
  void persistOnly() {
    _persistTimer?.cancel();
    _persistTimer = Timer(_persistDebounce, _persist);
  }

  // -------------------------------------------------------------------------
  // Providers

  ApiProvider? get activeProvider {
    if (activeProviderId == null) return null;
    for (final p in providers) {
      if (p.id == activeProviderId) return p;
    }
    return null;
  }

  // ── Wave CY.18.99: smart provider fallback ─────────────────────────

  /// Ordered chat fallback chain — primary first, then the rest in list
  /// order. Collapses to [primary] only when the master toggle is off.
  /// Pure ordering lives in provider_fallback.dart.
  List<ApiProvider> chatFallbackChain() => buildFallbackChain(
        all: providers,
        primaryId: activeProviderId,
        enabled: uiPrefs.askToSwitchOnFailure,
      );

  /// Bump a provider's refusal counter + persist. Called when a reply
  /// from [providerId] is classified as a content refusal.
  void bumpRefusal(String providerId) {
    providerRefusals[providerId] = (providerRefusals[providerId] ?? 0) + 1;
    _bump();
  }

  /// Suggest a provider with a clean refusal record from the chat
  /// fallback chain, skipping [nextId] itself. Searches only the FORWARD
  /// tail after [afterIndex] (the current failed provider's position) so
  /// the suggestion can never point back to an already-tried provider
  /// (audit C3). Null when none.
  ApiProvider? cleanestChatAlternative({
    required String nextId,
    required int afterIndex,
  }) {
    final chain = chatFallbackChain();
    final start = (afterIndex + 1).clamp(0, chain.length);
    final tail = chain.sublist(start);
    return pickCleanAlternative(
      candidates: tail,
      refusals: providerRefusals,
      excludeId: nextId,
    );
  }

  /// Toggle the fallback-prompt master switch.
  void setAskToSwitchOnFailure(bool v) {
    if (uiPrefs.askToSwitchOnFailure == v) return;
    uiPrefs.askToSwitchOnFailure = v;
    _bump();
  }

  /// Reorder a provider in the list — list order IS the fallback order
  /// (after the primary). Used by the API Connections drag handle.
  void reorderProvider(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= providers.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= providers.length) newIndex = providers.length - 1;
    final p = providers.removeAt(oldIndex);
    providers.insert(newIndex, p);
    _bump();
  }

  /// Provider to use for the AI character builder. Falls back to the
  /// chat provider when no creator-specific override is set.
  ApiProvider? get creatorProvider {
    if (creatorProviderId == null) return activeProvider;
    for (final p in providers) {
      if (p.id == creatorProviderId) return p;
    }
    // ID points to a deleted provider — fall back to active.
    return activeProvider;
  }

  /// Pass null to clear the override (creator will reuse the chat provider).
  void setCreatorProvider(String? id) {
    creatorProviderId = id;
    _bump();
  }

  /// Provider used for vision (image-analysis) calls. Falls back to
  /// the creator provider, then the chat provider, when no vision-
  /// specific override is set. This split is for users with a strong
  /// TEXT model (DeepSeek-V4, etc.) and a different VISION model
  /// (Qwen-VL, Pixtral, Venice qwen, Claude, GPT) — they pin each
  /// to its strength without compromising the others.
  ApiProvider? get visionProvider {
    if (visionProviderId == null) return creatorProvider;
    for (final p in providers) {
      if (p.id == visionProviderId) return p;
    }
    return creatorProvider;
  }

  /// Pass null to clear the override (vision will reuse the creator
  /// provider, which itself falls back to chat).
  void setVisionProvider(String? id) {
    visionProviderId = id;
    _bump();
  }

  ApiProvider addProvider({
    String name = 'New provider',
    ProviderKind kind = ProviderKind.external_,
    String baseUrl = '',
    String apiKey = '',
    String model = '',
  }) {
    final p = ApiProvider(
      id: newId('prov'),
      name: name,
      kind: kind,
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
    );
    // Wave CY.18.268: stamp a real mtime on create (mirrors characters /
    // personas). Without it a provider stays at mtime=0 forever, and the
    // LAN key-sync diff (`mtime > since`) would NEVER include it — the
    // opt-in key sync silently did nothing for every provider.
    p.mtime = DateTime.now().millisecondsSinceEpoch;
    providers.add(p);
    activeProviderId ??= p.id;
    // Push the API key to OS-secure storage; the JSON blob never sees it.
    // Fire-and-forget — failure here only affects the next launch's
    // hydration; in-memory state already has the key for this session.
    if (apiKey.isNotEmpty) {
      SecureKeys.write(p.id, apiKey);
    }
    _bump();
    return p;
  }

  void updateProvider(ApiProvider provider) {
    final i = providers.indexWhere((p) => p.id == provider.id);
    if (i < 0) return;
    // Wave CY.18.268: bump mtime on every edit so the change is sync-eligible
    // (LAN key-sync only ships records whose `mtime > since`). Mirrors the
    // character / persona save paths.
    provider.mtime = DateTime.now().millisecondsSinceEpoch;
    providers[i] = provider;
    // Sync the secure store with whatever the editor saved. Empty key
    // deletes the slot rather than writing an empty sentinel.
    SecureKeys.write(provider.id, provider.apiKey);
    _bump();
  }

  void removeProvider(String id) {
    providers.removeWhere((p) => p.id == id);
    // Wave CY.18.262: log a tombstone so the deletion propagates over LAN
    // key-sync (otherwise a paired native peer with sync ON re-pushes its
    // live copy and the provider resurrects on the next pull).
    recordTombstone('provider', id);
    if (activeProviderId == id) {
      activeProviderId = providers.isNotEmpty ? providers.first.id : null;
    }
    if (creatorProviderId == id) {
      // Drop the override entirely — falling back to the chat provider
      // is friendlier than silently picking some other random provider.
      creatorProviderId = null;
    }
    if (visionProviderId == id) {
      visionProviderId = null;
    }
    SecureKeys.delete(id);
    _bump();
  }

  void setActiveProvider(String id) {
    activeProviderId = id;
    _bump();
  }

  // -------------------------------------------------------------------------
  // Characters

  Character? characterById(String id) {
    for (final c in characters) {
      if (c.id == id) return c;
    }
    return null;
  }

  Character addCharacter(Character c) {
    // Wave CY.18.70: stamp mtime so the SyncEngine push picks up this
    // new record on the next tick. mirrors updatedAt for consistency.
    c.mtime = DateTime.now().millisecondsSinceEpoch;
    c.updatedAt = c.mtime;
    characters.add(c);
    _bump();
    return c;
  }

  void updateCharacter(Character c) {
    final i = characters.indexWhere((x) => x.id == c.id);
    if (i < 0) return;
    c.updatedAt = DateTime.now().millisecondsSinceEpoch;
    c.mtime = c.updatedAt; // Wave CY.18.70: sync metadata
    characters[i] = c;
    _bump();
  }

  void removeCharacter(String id) {
    characters.removeWhere((c) => c.id == id);
    // Wave CY.18.256: log a tombstone so the deletion propagates over LAN
    // sync (otherwise a paired peer re-pushes its live copy and the card
    // resurrects on the next pull).
    recordTombstone('character', id);
    // Wave CY.18.255 (FIX 6): clean up local references to the deleted
    // card. `_sweepOrphanReferences` doesn't cover these, so without this
    // a deleted character would linger in folder membership lists and the
    // profile's "featured character" pointer.
    for (final f in folders) {
      f.characterIds.remove(id);
    }
    if (botbooruFeaturedCharacterId == id) {
      botbooruFeaturedCharacterId = null;
    }
    _bump();
  }

  // ── Character drafts (Wave BG) ──────────────────────────────────
  //
  // Drafts are unsaved Character objects from the manual editor.
  // They never appear in the main `characters` list until Save
  // promotes them. The editor auto-saves via `saveDraft` on every
  // text change (debounced caller-side). Empty drafts are cleaned
  // up on back-out via `removeDraft`.

  Character? draftById(String id) {
    for (final c in characterDrafts) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Insert-or-update a draft. Bumps state so any listening UI
  /// (e.g. the Characters tab's Drafts section) repaints with the
  /// new title / tagline.
  void saveDraft(Character draft) {
    final i = characterDrafts.indexWhere((d) => d.id == draft.id);
    draft.updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (i < 0) {
      characterDrafts.add(draft);
    } else {
      characterDrafts[i] = draft;
    }
    _bump();
  }

  void removeDraft(String id) {
    characterDrafts.removeWhere((d) => d.id == id);
    _bump();
  }

  /// Promote a draft to a real Character. Removes from drafts and
  /// inserts into `characters`. Returns the promoted character (with
  /// `updatedAt` refreshed). If no draft with [id] exists, returns
  /// null and does nothing.
  Character? promoteDraftToCharacter(String id) {
    final draftIndex = characterDrafts.indexWhere((d) => d.id == id);
    if (draftIndex < 0) return null;
    final draft = characterDrafts.removeAt(draftIndex);
    draft.updatedAt = DateTime.now().millisecondsSinceEpoch;
    characters.add(draft);
    _bump();
    return draft;
  }

  /// True iff the draft has any meaningful content the user would
  /// not want auto-discarded. Used to decide whether to keep or
  /// drop the draft on back-out from the editor.
  bool isDraftMeaningful(Character d) {
    bool hasText(String s) => s.trim().isNotEmpty;
    if (hasText(d.name) && d.name.trim() != 'Untitled character') return true;
    if (hasText(d.tagline ?? '')) return true;
    if (hasText(d.description)) return true;
    if (hasText(d.scenario)) return true;
    if (hasText(d.firstMes)) return true;
    if (hasText(d.mesExample)) return true;
    if (d.alternateGreetings.any((g) => hasText(g))) return true;
    if (d.tags.isNotEmpty) return true;
    if (hasText(d.creatorNotes)) return true;
    if (hasText(d.systemPrompt)) return true;
    if (hasText(d.postHistoryInstructions)) return true;
    if (d.avatar != null && d.avatar!.isNotEmpty) return true;
    return false;
  }

  /// Snapshot a character into a Persona. Used by the long-press "Add as
  /// persona" action when the user wants to roleplay AS a character they
  /// imported.
  ///
  /// Critical detail: chara_card_v2 text uses `{{char}}` to refer to the
  /// character themselves and `{{user}}` to refer to whoever they're
  /// chatting with. When we flip the character into a persona, those
  /// references flip too — what was `{{user}}` in the card now means
  /// `{{char}}` (the other party) and vice versa. We also fold
  /// personality + mes_example into the persona description so the model
  /// has the user's voice + dialogue style on tap, since the persona
  /// description is the only thing surfaced for the user-side.
  Persona convertCharacterToPersona(Character c) =>
      addPersona(buildPersonaFromCharacter(c));


  // -------------------------------------------------------------------------
  // Personas

  Persona? get activePersona {
    if (activePersonaId == null) return null;
    for (final p in personas) {
      if (p.id == activePersonaId) return p;
    }
    return null;
  }

  Persona addPersona(Persona p) {
    p.mtime = DateTime.now().millisecondsSinceEpoch; // Wave CY.18.70
    p.updatedAt = p.mtime;
    personas.add(p);
    activePersonaId ??= p.id;
    _bump();
    return p;
  }

  void updatePersona(Persona p) {
    final i = personas.indexWhere((x) => x.id == p.id);
    if (i < 0) return;
    p.updatedAt = DateTime.now().millisecondsSinceEpoch;
    p.mtime = p.updatedAt; // Wave CY.18.70: sync metadata
    personas[i] = p;
    _bump();
  }

  void removePersona(String id) {
    personas.removeWhere((p) => p.id == id);
    // Wave CY.18.256: log a tombstone so the deletion propagates over sync.
    recordTombstone('persona', id);
    if (activePersonaId == id) {
      activePersonaId = personas.isNotEmpty ? personas.first.id : null;
    }
    // Wave CY: every chat that pinned this persona via chat.personaId
    // gets its reference cleared so the persisted JSON doesn't accumulate
    // dangling ids. The chat-screen fallback in `_chatPersona` already
    // tolerates a stale id by routing to the global default, but
    // letting them collect across deletions makes future migrations
    // harder to reason about.
    for (final c in chats) {
      if (c.personaId == id) {
        c.personaId = null;
      }
    }
    _bump();
  }

  void setActivePersona(String id) {
    activePersonaId = id;
    _bump();
  }

  /// Wave BC: update the user's botbooru creator handle. Empty string
  /// is allowed (means "no handle configured" — Save Card falls back
  /// to the active persona's name in that case).
  void setBotbooruUsername(String value) {
    botbooruUsername = value.trim();
    _bump();
  }

  /// Wave CY.18.30: update the user's decorative profile avatar.
  /// Pass null to clear the avatar back to the empty placeholder.
  /// Expected shape: `data:image/png;base64,...` data URL.
  void setBotbooruAvatar(String? dataUrl) {
    botbooruAvatar = dataUrl;
    _bump();
  }

  /// Wave CY.18.30: update the user's "about me" text. Empty string is
  /// allowed.
  /// Wave CY.18.36: scope changed — no longer feeds the architect.
  /// Purely Profile-side bio text now.
  void setBotbooruAboutMe(String value) {
    botbooruAboutMe = value;
    _bump();
  }

  /// Wave CY.18.36: update the user-editable Profile subtitle.
  void setBotbooruTitle(String value) {
    botbooruTitle = value;
    _bump();
  }

  /// Wave CY.18.36: update the optional pronouns chip on Profile.
  void setBotbooruPronouns(String value) {
    botbooruPronouns = value;
    _bump();
  }

  /// Wave CY.18.36: update the pinned "Featured character" on
  /// Profile. Pass null to clear the pin.
  void setBotbooruFeaturedCharacter(String? characterId) {
    botbooruFeaturedCharacterId = characterId;
    _bump();
  }

  /// Wave CY.18.36: stamp `installedAt` on first run if missing so the
  /// "X days on Pyre" stat starts counting from today onwards.
  /// Subsequent calls are no-ops, preserving the original timestamp
  /// (incl. across backups — if the loaded JSON had a value, it
  /// won't be clobbered).
  void ensureInstalledAt() {
    if (installedAt != null) return;
    installedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  // ---------------------------------------------------------------------------
  // Wave CY.18.38 — folders + favorites + Characters/Personas filter state

  /// Toggle the `favorite` flag on a character. Falls back to a no-op
  /// when the id doesn't exist (e.g. the character was deleted just
  /// before the tap landed).
  void toggleCharacterFavorite(String characterId) {
    final i = characters.indexWhere((c) => c.id == characterId);
    if (i < 0) return;
    characters[i].favorite = !characters[i].favorite;
    characters[i].updatedAt = DateTime.now().millisecondsSinceEpoch;
    characters[i].mtime = characters[i].updatedAt; // Wave CY.18.70
    _bump();
  }

  /// Toggle the `favorite` flag on a persona.
  void togglePersonaFavorite(String personaId) {
    final i = personas.indexWhere((p) => p.id == personaId);
    if (i < 0) return;
    personas[i].favorite = !personas[i].favorite;
    personas[i].updatedAt = DateTime.now().millisecondsSinceEpoch;
    personas[i].mtime = personas[i].updatedAt; // Wave CY.18.70
    _bump();
  }

  /// Create a new folder with the given name. Returns the new folder
  /// (already added to the list). Caller can immediately add
  /// characters to it via `addCharacterToFolder`.
  Folder createFolder(String name) {
    final f = Folder(id: newId('folder'), name: name.trim());
    folders = [...folders, f];
    _bump();
    return f;
  }

  /// Rename an existing folder. No-op when the id isn't found.
  void renameFolder(String folderId, String newName) {
    final i = folders.indexWhere((f) => f.id == folderId);
    if (i < 0) return;
    folders[i].name = newName.trim();
    folders[i].updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  /// Delete a folder. Characters inside the folder stay in the library
  /// — folders are just groupings, not containers. The deleted folder
  /// also clears from the active filter (`charFolderId`) if it was
  /// the one selected, so the user doesn't end up looking at an
  /// orphaned filter.
  void deleteFolder(String folderId) {
    folders.removeWhere((f) => f.id == folderId);
    if (charFolderId == folderId) charFolderId = null;
    _bump();
  }

  /// Add a character to a folder. Idempotent — re-adding the same
  /// character is a no-op.
  void addCharacterToFolder(String folderId, String characterId) {
    final i = folders.indexWhere((f) => f.id == folderId);
    if (i < 0) return;
    if (folders[i].characterIds.contains(characterId)) return;
    folders[i].characterIds = [...folders[i].characterIds, characterId];
    folders[i].updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  /// Remove a character from a folder. No-op if the character wasn't
  /// in the folder.
  void removeCharacterFromFolder(String folderId, String characterId) {
    final i = folders.indexWhere((f) => f.id == folderId);
    if (i < 0) return;
    folders[i].characterIds =
        folders[i].characterIds.where((id) => id != characterId).toList();
    folders[i].updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  /// Sort key for the Characters tab. Accepted values:
  /// 'recent' | 'created' | 'alpha' | 'chatted'.
  void setCharSortKey(String key) {
    charSortKey = key;
    _bump();
  }

  /// Toggle a tag in/out of the Characters tag filter (AND-logic
  /// chips at the top of the list).
  void toggleCharSelectedTag(String tag) {
    if (charSelectedTags.contains(tag)) {
      charSelectedTags = charSelectedTags.where((t) => t != tag).toList();
    } else {
      charSelectedTags = [...charSelectedTags, tag];
    }
    _bump();
  }

  /// Clear all tag filters at once.
  void clearCharSelectedTags() {
    if (charSelectedTags.isEmpty) return;
    charSelectedTags = [];
    _bump();
  }

  /// Set the active folder filter on the Characters tab. Null = "All".
  void setCharFolderId(String? folderId) {
    charFolderId = folderId;
    _bump();
  }

  /// Persisted state of the Favorites section header collapse/expand.
  void setCharFavoritesExpanded(bool expanded) {
    if (charFavoritesExpanded == expanded) return;
    charFavoritesExpanded = expanded;
    _bump();
  }

  /// Sort key for the Personas tab. Accepted values:
  /// 'recent' | 'created' | 'alpha'.
  void setPersonaSortKey(String key) {
    personaSortKey = key;
    _bump();
  }

  /// Wave CY.18.39: mark the welcome screen as seen so it doesn't pop
  /// on every cold start when no provider is configured. Called by
  /// the Get started button on `OnboardingScreen`.
  void markOnboardingSeen() {
    if (seenOnboarding) return;
    seenOnboarding = true;
    _bump();
  }

  /// Wave CY.18.121: one-time seed of the bundled example cards on a
  /// genuinely fresh install. Called once from `load()` before
  /// `notifyListeners()`.
  ///
  /// The gate ([shouldSeedExamples]) only fires when nothing's been
  /// seeded yet AND the library is empty AND onboarding hasn't been
  /// passed — so an app UPDATE (seenOnboarding=true) never re-injects
  /// the set. Whatever the outcome, [exampleContentSeeded] is set true
  /// at the end so the (slightly costly) asset load + gate runs at most
  /// once per install.
  ///
  /// Ordering matters and is deliberate (avoids the orphan sweep that
  /// runs on every load):
  ///   1. Append the world lorebook to `lorebooks` FIRST.
  ///   2. Assert the scenario + Vesna `lorebookIds` contain its id (the
  ///      JSON already carries it, but we re-assert defensively).
  ///   3. Append the three characters DIRECTLY to `characters` — NOT via
  ///      `addCharacter`, so the bundled content skips the normal
  ///      per-import side-effects (mtime stamping, individual notifies).
  ///   4. One `_persist()` at the end.
  /// Done in this synchronous pass so `_sweepOrphanReferences()` on the
  /// next load never sees a lorebookId whose book isn't in `lorebooks`.
  ///
  /// Wrapped in try/catch: a packaging mistake (missing/malformed asset)
  /// degrades to "no examples seeded" rather than crashing first launch.
  Future<void> seedExamplesIfFresh() async {
    if (shouldSeedExamples(
      alreadySeeded: exampleContentSeeded,
      charactersEmpty: characters.isEmpty,
      seenOnboarding: seenOnboarding,
    )) {
      try {
        final content = await loadExampleContent();

        // 1. Lorebook first so the bind below isn't an orphan.
        lorebooks.add(content.lorebook);

        // 2. Re-assert the world-lorebook bind on the cards that should
        //    carry it (scenario + Vesna). Idempotent — the JSON already
        //    sets it; this just guarantees it regardless of asset edits.
        for (final c in content.characters) {
          final wantsWorld = c.id == 'example-scenario-sunken-gate' ||
              c.id == 'example-char-vesna';
          if (wantsWorld &&
              !c.lorebookIds.contains(kExampleWorldLorebookId)) {
            c.lorebookIds.add(kExampleWorldLorebookId);
          }
        }

        // 3. Append characters directly — skip the addCharacter
        //    side-effects (mtime stamping, notify) since the single
        //    persist below covers the whole seed at once.
        characters.addAll(content.characters);

        // 3b. Seed Ren as a user PERSONA — the same conversion the
        //     "Add as persona" button performs (buildPersonaFromCharacter
        //     swaps {{user}}/{{char}}, folds in mes_example, inherits the
        //     avatar + bound lorebooks). Appended directly (no addPersona) so
        //     the whole seed stays a single persist, exactly like the
        //     characters above.
        //
        //     Wave CY.18.161: Ren is PERSONA-ONLY (Gui) — he is NOT in
        //     `content.characters`, so he never appears in the Characters
        //     tab. His source card comes from `content.renPersonaSource`,
        //     and his sheet is deliberately setting-neutral so he fits any
        //     scenario.
        //
        //     Wave CY.18.204 (Gui): Ren is NO LONGER favourited and NO LONGER
        //     made the default active persona — fresh installs start with no
        //     default persona, and `askPersonaOnNewChat` now defaults ON, so
        //     the user simply picks who they play as on each new chat. Vesna
        //     is now a LIBRARY CHARACTER ONLY (she is still in
        //     `content.characters`); she is no longer seeded as a persona.
        final renPersona = buildPersonaFromCharacter(content.renPersonaSource);
        // Wave CY.18.255 (FIX 3): override the random persona id with a
        // deterministic constant so two fresh installs seed the SAME Ren
        // persona id — LAN sync then de-dupes him by id instead of leaving
        // each device with its own distinct "Ren" (which also broke chats
        // that point at `personaId`). `buildPersonaFromCharacter` assigns a
        // fresh `newId('persona')`; we replace it here, before append.
        renPersona.id = kExampleRenPersonaId;
        personas.add(renPersona);

        // 3c. Stamp a real timestamp on every seeded record so LAN sync
        //     can ship them to paired devices. Seeded records would
        //     otherwise carry `mtime == 0` (their fromJson default), and
        //     the server's `/pull` only sends records where
        //     `mtime > since` — with `since == 0` on a fresh client,
        //     `0 > 0` is false, so the bundled lorebook + characters + Ren
        //     persona would NEVER sync. A synced chat then points at a Ren
        //     persona the phone doesn't have → broken link. One `now` for
        //     the whole seed keeps the batch consistent.
        final seedNow = DateTime.now().millisecondsSinceEpoch;
        content.lorebook.mtime = content.lorebook.updatedAt = seedNow;
        for (final c in content.characters) {
          c.mtime = c.updatedAt = seedNow;
        }
        renPersona.mtime = renPersona.updatedAt = seedNow;

        // 4. Latch the flag BEFORE the persist so it lands in the SAME write
        //    as the seeded content. (`charactersEmpty` already guards against
        //    re-seeding, but persisting the flag here closes the narrow
        //    "delete all examples before any later save → they resurrect on
        //    next launch" window.) The unconditional set below still covers
        //    the not-seeded / seed-failure paths.
        exampleContentSeeded = true;
        // 5. Single persist for the whole seed.
        await _persist();
      } catch (e) {
        // Asset packaging / parse failure — log for the Storage screen
        // diagnostics and carry on with an empty library.
        debugPrint('[seedExamples] failed to seed bundled examples: $e');
        loadErrors.add('example cards: failed to seed bundled content ($e).');
      }
    }
    // Always latch so the gate + asset load runs at most once per install,
    // regardless of whether seeding actually happened.
    exampleContentSeeded = true;
  }

  /// Wave CY.18.168: wipe EVERYTHING back to a brand-new-install state.
  /// The Backup & Restore screen calls this ONLY after it has written a
  /// safety backup and the user double-confirmed (typed "reset").
  ///
  /// Clears OS-secure API keys, every attachment blob, the on-disk state
  /// file + rolling backups, and resets all in-memory collections,
  /// settings and onboarding flags to defaults — then re-seeds the
  /// bundled examples exactly like a fresh launch and persists the clean
  /// slate. After this returns, the UI should pop to the root so the
  /// onboarding / fresh library is shown.
  Future<void> factoryReset() async {
    // 1. Secrets out of OS-secure storage.
    try {
      await SecureKeys.clearAll();
    } catch (_) {}
    // 2. Attachment blobs — with NO referenced hashes, GC treats every
    //    stored blob as an orphan and deletes it. Runs before the re-seed
    //    so the freshly-attached example avatars survive.
    try {
      await AttachmentStore.gcOrphans(const <String>{});
    } catch (_) {}
    // 3. On-disk state file + rolling backups + temp.
    try {
      await _storage.clear();
    } catch (_) {}

    // 4. In-memory back to defaults. Settings use fromJson({}) so the
    //    documented defaults apply regardless of constructor signatures.
    providers = [];
    activeProviderId = null;
    creatorProviderId = null;
    visionProviderId = null;
    characters = [];
    personas = [];
    activePersonaId = null;
    chats = [];
    lorebooks = [];
    presets = [buildLockedDefaultPreset()];
    activePresetId = lockedDefaultPresetId;
    creatorPresets = [buildLockedDefaultCreatorPreset()];
    activeCreatorPresetId = lockedDefaultCreatorPresetId;
    regexRules = [];
    creatorSessions = [];
    activeCreatorSessionId = null;
    modelSettings = ModelSettings.fromJson(const <String, dynamic>{});
    chatSettings = ChatSettings.fromJson(const <String, dynamic>{});
    memorySettings = MemorySettings.fromJson(const <String, dynamic>{});
    liveSheetSettings = LiveSheetSettings.fromJson(const <String, dynamic>{});
    scriptSettings = ScriptSettings.fromJson(const <String, dynamic>{});
    uiPrefs = UiPrefs.fromJson(const <String, dynamic>{});
    seenOnboarding = false;
    exampleContentSeeded = false;

    // 5. Re-seed the bundled examples like a fresh install. (On success it
    //    persists internally; the explicit persist below covers the rare
    //    asset-load-failure path where it doesn't.)
    await seedExamplesIfFresh();
    // 6. Guaranteed clean persist + rebuild the whole app.
    await _persist();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Chats

  Chat startChatWith(Character character) {
    final snapshot = Character.fromJson(character.toJson());
    final chat = Chat(
      id: newId('chat'),
      characterIds: [character.id],
      characterSnapshots: {character.id: snapshot},
      personaId: activePersonaId,
    );
    // Seed with the character's first message + alternate greetings as variants
    final firstMes = (character.firstMes).trim();
    final greetings = <String>[
      if (firstMes.isNotEmpty) firstMes,
      ...character.alternateGreetings
          .map((g) => g.trim())
          .where((g) => g.isNotEmpty),
    ];
    if (greetings.isNotEmpty) {
      chat.messages.add(Message(
        id: newId('msg'),
        kind: MessageKind.char,
        characterId: character.id,
        variants: greetings,
        selectedVariant: 0,
      ));
    }
    // Wave CY.18.70: stamp mtime on new chat so the next sync push
    // includes it. Same dance for addLorebook below.
    chat.mtime = DateTime.now().millisecondsSinceEpoch;
    chats.add(chat);
    _bump();
    return chat;
  }

  void addMessage(String chatId, Message m) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    chat.messages.add(m);
    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  /// Update the text of [messageId].
  ///
  /// By default writes to whatever variant is currently selected. Stream
  /// drivers should pass [variantIndex] with the index they pinned when
  /// the stream STARTED, so chunks keep landing on the intended variant
  /// even if the user swipes `<`/`>` mid-stream (which would otherwise
  /// overwrite the variant they just navigated to).
  void updateMessageText(
    String chatId,
    String messageId,
    String newText, {
    int? variantIndex,
  }) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    final mi = chat.messages.indexWhere((m) => m.id == messageId);
    if (mi < 0) return;
    final msg = chat.messages[mi];
    if (msg.variants.isEmpty) {
      msg.variants.add(newText);
    } else {
      // Use pinned index when provided AND still in range; fall back to
      // selectedVariant otherwise (e.g. variant was deleted while
      // streaming — extremely rare but worth defending against).
      final idx = (variantIndex != null &&
              variantIndex >= 0 &&
              variantIndex < msg.variants.length)
          ? variantIndex
          : msg.selectedVariant;
      msg.variants[idx] = newText;
    }
    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  /// Add a new (empty) variant to a message and make it the selected one.
  /// Returns the new variant index (the caller can stream into it via
  /// [updateMessageText]).
  int addVariant(String chatId, String messageId) {
    final chat = _chatById(chatId);
    if (chat == null) return -1;
    final mi = chat.messages.indexWhere((m) => m.id == messageId);
    if (mi < 0) return -1;
    final msg = chat.messages[mi];
    msg.variants.add('');
    msg.selectedVariant = msg.variants.length - 1;
    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
    return msg.selectedVariant;
  }

  /// Wave CY.8: delete a single variant from a message, preserving the
  /// other variants. Used when the user retries / regenerates and wants
  /// to drop the new variant without losing the original. The current
  /// chat tail (everything after this message) is the downstream of
  /// the variant being removed, so it goes too — same semantics as
  /// switching variants away. The new selectedVariant defaults to the
  /// one numerically before the removed index (clamped) and its stored
  /// downstream (if any) is restored.
  ///
  /// No-op when the message has only one variant — the caller should
  /// fall through to [removeMessage] in that case.
  void removeMessageVariant(String chatId, String messageId) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    final mi = chat.messages.indexWhere((m) => m.id == messageId);
    if (mi < 0) return;
    final msg = chat.messages[mi];
    if (msg.variants.length <= 1) return;
    final removed = msg.selectedVariant;
    if (removed < 0 || removed >= msg.variants.length) return;

    // Drop the chat tail that belonged to this variant. It was added
    // on this branch — keeping it under a different variant index
    // would just leak orphaned messages.
    if (mi < chat.messages.length - 1) {
      chat.messages.removeRange(mi + 1, chat.messages.length);
    }
    msg.variants.removeAt(removed);
    msg.downstreamByVariant.remove(removed);
    // Shift higher-numbered downstream snapshots down to fill the gap.
    final shifted = <int, List<Message>>{};
    msg.downstreamByVariant.forEach((k, v) {
      shifted[k > removed ? k - 1 : k] = v;
    });
    msg.downstreamByVariant
      ..clear()
      ..addAll(shifted);

    // Pick the new selected variant — prefer the one immediately
    // before the deleted index. Clamp into bounds.
    msg.selectedVariant =
        (removed - 1).clamp(0, msg.variants.length - 1);

    // Restore the new selected variant's downstream (if it has one).
    final restored = msg.downstreamByVariant.remove(msg.selectedVariant);
    if (restored != null && restored.isNotEmpty) {
      chat.messages.addAll(restored);
    }

    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  /// Switch which variant of a message is showing. Also swaps the
  /// downstream conversation tail: the chat tail that was visible under
  /// the OLD variant is stashed on the message (so coming back restores
  /// it), and the tail stored for the NEW variant (if any) is restored
  /// from the snapshot. This is what makes branching non-destructive —
  /// "going back" reveals the conversation that originally followed the
  /// other version of the message.
  void selectVariant(String chatId, String messageId, int index) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    final mi = chat.messages.indexWhere((m) => m.id == messageId);
    if (mi < 0) return;
    final msg = chat.messages[mi];
    if (index < 0 || index >= msg.variants.length) return;
    if (msg.selectedVariant == index) return;

    // 1) Snapshot the currently-visible downstream of this message and
    //    store it under the OLD variant index.
    final oldVariant = msg.selectedVariant;
    if (mi < chat.messages.length - 1) {
      final tail = chat.messages.sublist(mi + 1);
      msg.downstreamByVariant[oldVariant] = List<Message>.from(tail);
      chat.messages.removeRange(mi + 1, chat.messages.length);
    } else {
      // No tail under the old variant — clear any stale snapshot.
      msg.downstreamByVariant.remove(oldVariant);
    }

    // 2) Restore the tail stored under the NEW variant index (if any).
    msg.selectedVariant = index;
    final restored = msg.downstreamByVariant.remove(index);
    if (restored != null && restored.isNotEmpty) {
      chat.messages.addAll(restored);
    }

    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  /// Remove a single message by id. When [ChatSettings.cascadeDelete] is
  /// on, also drop every message that follows (chub-style "delete from
  /// here"). The [cascadeOverride] parameter lets callers (e.g. the
  /// "Truncate from here" action) force-enable cascade regardless of pref.
  void removeMessage(String chatId, String messageId,
      {bool? cascadeOverride}) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    final cascade = cascadeOverride ?? chatSettings.cascadeDelete;
    if (cascade) {
      final idx = chat.messages.indexWhere((m) => m.id == messageId);
      if (idx < 0) return;
      chat.messages.removeRange(idx, chat.messages.length);
    } else {
      chat.messages.removeWhere((m) => m.id == messageId);
    }
    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  /// Add another character to a chat (group chat) — freezes a snapshot.
  void addCharacterToChat(String chatId, Character character) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    if (chat.characterIds.contains(character.id)) return;
    chat.characterIds.add(character.id);
    chat.characterSnapshots[character.id] =
        Character.fromJson(character.toJson());
    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  /// Remove a character from a chat (group chat). Keeps the snapshot so
  /// past messages still resolve.
  void removeCharacterFromChat(String chatId, String characterId) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    chat.characterIds.remove(characterId);
    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  void removeChat(String id) {
    chats.removeWhere((c) => c.id == id);
    // Wave CY.18.256: log a tombstone so the deletion propagates over sync.
    recordTombstone('chat', id);
    _bump();
  }

  /// Wave CX: change the persona attached to a specific chat without
  /// touching the global active persona. Pass null to clear (falls
  /// back to the global active at runtime).
  void setChatPersona(String chatId, String? personaId) {
    final chat = _chatById(chatId);
    if (chat == null) return;
    chat.personaId = personaId;
    chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
    chat.mtime = chat.updatedAt; // Wave CY.18.70: sync metadata
    _bump();
  }

  Chat? _chatById(String id) {
    for (final c in chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Lorebooks

  Lorebook? lorebookById(String id) {
    for (final l in lorebooks) {
      if (l.id == id) return l;
    }
    return null;
  }

  Lorebook addLorebook(Lorebook l) {
    l.mtime = DateTime.now().millisecondsSinceEpoch; // Wave CY.18.70
    lorebooks.add(l);
    _bump();
    return l;
  }

  void updateLorebook(Lorebook l) {
    final i = lorebooks.indexWhere((x) => x.id == l.id);
    if (i < 0) return;
    l.updatedAt = DateTime.now().millisecondsSinceEpoch;
    l.mtime = l.updatedAt; // Wave CY.18.70: sync metadata
    lorebooks[i] = l;
    _bump();
  }

  void removeLorebook(String id) {
    lorebooks.removeWhere((l) => l.id == id);
    // Wave CY.18.256: log a tombstone so the deletion propagates over sync.
    recordTombstone('lorebook', id);
    // Also detach from any chats
    for (final c in chats) {
      c.attachedLorebookIds.remove(id);
      c.disabledInheritedLorebookIds.remove(id);
    }
    // And from any character / persona that had it bound — otherwise
    // the binding survives as a dangling reference in the UI.
    for (final ch in characters) {
      ch.lorebookIds.remove(id);
    }
    for (final p in personas) {
      p.lorebookIds.remove(id);
    }
    _bump();
  }

  /// Wave CD: opt out of an inherited lorebook for THIS chat. The book
  /// is still bound to the character or persona globally — only this
  /// specific chat will skip its entries during injection. Idempotent.
  void disableInheritedLorebookForChat(String chatId, String bookId) {
    Chat? target;
    for (final c in chats) {
      if (c.id == chatId) {
        target = c;
        break;
      }
    }
    if (target == null) return;
    if (!target.disabledInheritedLorebookIds.contains(bookId)) {
      target.disabledInheritedLorebookIds.add(bookId);
      _bump();
    }
  }

  /// Wave CD: re-enable an inherited lorebook for this chat.
  /// Idempotent — no-op when the id isn't currently disabled.
  void enableInheritedLorebookForChat(String chatId, String bookId) {
    Chat? target;
    for (final c in chats) {
      if (c.id == chatId) {
        target = c;
        break;
      }
    }
    if (target == null) return;
    if (target.disabledInheritedLorebookIds.remove(bookId)) {
      _bump();
    }
  }

  // -------------------------------------------------------------------------
  // Presets

  Preset? get activePreset {
    if (activePresetId == null) return null;
    for (final p in presets) {
      if (p.id == activePresetId) return p;
    }
    return null;
  }

  /// Visible presets — locked entries ARE shown (so the user knows the
  /// default exists and can activate it) but their content stays sealed:
  /// the editor / preview / copy / export paths all bail when `p.locked`.
  List<Preset> get visiblePresets => presets;

  Preset addPreset(Preset p) {
    p.mtime = DateTime.now().millisecondsSinceEpoch; // Wave CY.18.70
    presets.add(p);
    _bump();
    return p;
  }

  void updatePreset(Preset p) {
    if (p.locked) return; // never mutate the locked default
    final i = presets.indexWhere((x) => x.id == p.id);
    if (i < 0) return;
    p.mtime = DateTime.now().millisecondsSinceEpoch; // Wave CY.18.70
    presets[i] = p;
    _bump();
  }

  void removePreset(String id) {
    final i = presets.indexWhere((p) => p.id == id);
    if (i < 0) return;
    if (presets[i].locked) return;
    presets.removeAt(i);
    // Wave CY.18.256: log a tombstone so the deletion propagates over sync.
    // (Only non-locked presets reach here — the locked default is never
    // deleted and is rebuilt-from-build on every load anyway.)
    recordTombstone('preset', id);
    if (activePresetId == id) activePresetId = lockedDefaultPresetId;
    _bump();
  }

  void setActivePreset(String id) {
    if (!presets.any((p) => p.id == id)) return;
    activePresetId = id;
    _bump();
  }

  // -------------------------------------------------------------------------
  // Creator presets (Wave CY.18.107 — Pillar E). Mirrors the Preset CRUD.

  CreatorPreset? get activeCreatorPreset {
    if (activeCreatorPresetId == null) return null;
    for (final p in creatorPresets) {
      if (p.id == activeCreatorPresetId) return p;
    }
    return null;
  }

  CreatorPreset addCreatorPreset(CreatorPreset p) {
    creatorPresets.add(p);
    _bump();
    return p;
  }

  void updateCreatorPreset(CreatorPreset p) {
    if (p.locked) return; // never mutate the locked default
    final i = creatorPresets.indexWhere((x) => x.id == p.id);
    if (i < 0) return;
    creatorPresets[i] = p;
    _bump();
  }

  void removeCreatorPreset(String id) {
    final i = creatorPresets.indexWhere((p) => p.id == id);
    if (i < 0) return;
    if (creatorPresets[i].locked) return;
    creatorPresets.removeAt(i);
    if (activeCreatorPresetId == id) {
      activeCreatorPresetId = lockedDefaultCreatorPresetId;
    }
    _bump();
  }

  void setActiveCreatorPreset(String id) {
    if (!creatorPresets.any((p) => p.id == id)) return;
    activeCreatorPresetId = id;
    _bump();
  }

  // -------------------------------------------------------------------------
  // Regex rules (Pyre 1.1 — F4). Mirrors the Lorebook CRUD + tombstone path.

  RegexRule addRegexRule(RegexRule r) {
    r.mtime = DateTime.now().millisecondsSinceEpoch;
    regexRules.add(r);
    _bump();
    return r;
  }

  void updateRegexRule(RegexRule r) {
    final i = regexRules.indexWhere((x) => x.id == r.id);
    if (i < 0) return;
    r.mtime = DateTime.now().millisecondsSinceEpoch; // sync metadata
    regexRules[i] = r;
    _bump();
  }

  void removeRegexRule(String id) {
    final removed = regexRules.indexWhere((r) => r.id == id) >= 0;
    if (!removed) return;
    regexRules.removeWhere((r) => r.id == id);
    // Log a tombstone so the deletion propagates over LAN sync (mirrors
    // the lorebook/preset delete path).
    recordTombstone('regexRule', id);
    _bump();
  }

  // -------------------------------------------------------------------------
  // Settings + UI prefs

  void updateModelSettings(ModelSettings ms) {
    modelSettings = ms;
    _bump();
  }

  void updateChatSettings(ChatSettings cs) {
    chatSettings = cs;
    _bump();
  }

  void updateMemorySettings(MemorySettings ms) {
    memorySettings = ms;
    _bump();
  }

  void setActiveTab(String tab) {
    uiPrefs.activeTab = tab;
    _bump();
  }

  void setCharactersSegment(String seg) {
    uiPrefs.charactersSegment = seg;
    _bump();
  }

  /// Wave CY.18.46: toggle the desktop wide-layout setting. No effect
  /// on mobile (the layout decision happens at render time based on
  /// window width + this flag combined).
  void setDesktopWideLayout(bool value) {
    if (uiPrefs.desktopWideLayout == value) return;
    uiPrefs.desktopWideLayout = value;
    _bump();
  }

  /// Wave CY.18.90: persist a per-action shortcut binding override
  /// (or clear it back to the factory default when [bindingJson] is
  /// null). The binding is opaque to this setter — it's a JSON map
  /// shaped by `ShortcutBinding.toJson()` in desktop_shortcuts.dart.
  /// Centralising the persist call here means the screen doesn't
  /// have to know about _bump() or the storage backend.
  void setDesktopShortcutBinding(
    String actionId,
    Map<String, dynamic>? bindingJson,
  ) {
    final map = uiPrefs.desktopShortcuts;
    if (bindingJson == null) {
      if (!map.containsKey(actionId)) return;
      map.remove(actionId);
    } else {
      map[actionId] = bindingJson;
    }
    _bump();
  }

  /// Wave CY.18.90: drop all overrides — next render reads factory
  /// defaults again. No-op when the map is already empty.
  void restoreDesktopShortcutDefaults() {
    if (uiPrefs.desktopShortcuts.isEmpty) return;
    uiPrefs.desktopShortcuts.clear();
    _bump();
  }

  /// Wave CY.18.98: ephemeral "this screen wants the full window
  /// width" signal. Set by surfaces like the Discover Windows
  /// webview embed when they need to bypass the parent layout's
  /// 1100px (wide rail) / 480px (phone-in-window) content cap.
  ///
  /// Intentionally NOT persisted to UiPrefs — it's a runtime UI
  /// state, not a preference. The flag resets to false on app
  /// restart even if Discover was in webview mode (the screen will
  /// re-set it on rebuild).
  ///
  /// main.dart combines this with the active tab so toggling on
  /// from Discover doesn't accidentally widen other tabs when the
  /// user switches away while leaving the embed open.
  bool _wantsFullWidthContent = false;
  bool get wantsFullWidthContent => _wantsFullWidthContent;
  void setWantsFullWidthContent(bool value) {
    if (_wantsFullWidthContent == value) return;
    _wantsFullWidthContent = value;
    _bump();
  }

  // Wave CY.18.68: LAN-server prefs. Each setter is no-op when the
  // value hasn't changed so a slider/text-field that fires onChange
  // on every keystroke doesn't trigger redundant persists.
  void setLanServerEnabled(bool value) {
    if (uiPrefs.lanServerEnabled == value) return;
    uiPrefs.lanServerEnabled = value;
    _bump();
  }

  void setLanServerPort(int value) {
    if (value < 1 || value > 65535) return;
    if (uiPrefs.lanServerPort == value) return;
    uiPrefs.lanServerPort = value;
    _bump();
  }

  void setLanBindMode(String value) {
    if (value != 'lan' && value != 'localhost') return;
    if (uiPrefs.lanBindMode == value) return;
    uiPrefs.lanBindMode = value;
    _bump();
  }

  /// Wave CY.18.48: persist window bounds (only meaningful on desktop).
  /// Called by the WindowManager listener after a resize/move event.
  /// We don't `_bump()` (which would trigger a full notifyListeners +
  /// rebuild) — window-bounds changes have no UI consequence we care
  /// about; they just need to land on disk for next launch. The
  /// debounce in storage.dart absorbs the rapid-fire calls during a
  /// drag.
  void setWindowBounds(List<double> bounds) {
    if (bounds.length != 4) return;
    final existing = uiPrefs.windowBounds;
    if (existing != null &&
        existing.length == 4 &&
        (existing[0] - bounds[0]).abs() < 1 &&
        (existing[1] - bounds[1]).abs() < 1 &&
        (existing[2] - bounds[2]).abs() < 1 &&
        (existing[3] - bounds[3]).abs() < 1) {
      return; // no-op within sub-pixel tolerance
    }
    uiPrefs.windowBounds = List<double>.from(bounds);
    persistOnly();
  }

  // -------------------------------------------------------------------------
  // Creator sessions
  //
  // One session per in-progress card. The drawer shows them ordered by
  // most-recently-touched. Activation is by id; null id means "no active
  // session yet" — the screen creates one on mount if the list is empty.

  CreatorSession? get activeCreatorSession {
    if (activeCreatorSessionId == null) return null;
    for (final s in creatorSessions) {
      if (s.id == activeCreatorSessionId) return s;
    }
    return null;
  }

  /// Sessions in display order — pinned first, then by recency.
  List<CreatorSession> get creatorSessionsByRecency {
    final copy = List<CreatorSession>.from(creatorSessions);
    copy.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return copy;
  }

  void toggleCreatorSessionPin(String id) {
    final s = creatorSessions.firstWhere((s) => s.id == id,
        orElse: () => CreatorSession(id: ''));
    if (s.id.isEmpty) return;
    s.pinned = !s.pinned;
    s.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  /// Drop sessions with no user turns that haven't been touched in
  /// [maxAge]. Run at app start so the drawer doesn't fill with
  /// "Untitled" carcasses from accidental drawer-tap-new opens.
  /// Pinned sessions and sessions with a savedCharacterId stay.
  void pruneEmptyCreatorSessions({
    Duration maxAge = const Duration(days: 7),
  }) {
    final cutoff =
        DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final before = creatorSessions.length;
    creatorSessions.removeWhere((s) {
      if (s.pinned) return false;
      if (s.savedCharacterId != null) return false;
      // "Empty" = zero user messages. A session with only the assistant
      // greeting is still considered empty.
      final hasUser = s.messages.any((m) => m.role == 'user');
      if (hasUser) return false;
      return s.updatedAt < cutoff;
    });
    if (creatorSessions.length != before) {
      if (!creatorSessions.any((s) => s.id == activeCreatorSessionId)) {
        activeCreatorSessionId =
            creatorSessions.isNotEmpty ? creatorSessions.last.id : null;
      }
      _bump();
    }
  }

  CreatorSession newCreatorSession() {
    final s = CreatorSession(id: newId('creator'));
    creatorSessions.add(s);
    activeCreatorSessionId = s.id;
    _bump();
    return s;
  }

  void setActiveCreatorSession(String id) {
    if (!creatorSessions.any((s) => s.id == id)) return;
    activeCreatorSessionId = id;
    _bump();
  }

  void removeCreatorSession(String id) {
    creatorSessions.removeWhere((s) => s.id == id);
    if (activeCreatorSessionId == id) {
      activeCreatorSessionId =
          creatorSessions.isNotEmpty ? creatorSessions.last.id : null;
    }
    _bump();
  }

  /// Pass null to clear the manual title and let the UI derive one from
  /// the canvas's `name` field.
  void renameCreatorSession(String id, String? title) {
    final s = creatorSessions.firstWhere((s) => s.id == id,
        orElse: () => CreatorSession(id: ''));
    if (s.id.isEmpty) return;
    s.title = (title != null && title.trim().isNotEmpty) ? title.trim() : null;
    s.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  /// Replace the session's message list (called whenever a turn lands).
  void updateCreatorSessionMessages(
      String id, List<CreatorMessage> messages) {
    final s = creatorSessions.firstWhere((s) => s.id == id,
        orElse: () => CreatorSession(id: ''));
    if (s.id.isEmpty) return;
    s.messages = messages;
    s.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  /// Replace the canvas (called when the structured-update call returns
  /// a fresh merged canvas).
  void updateCreatorSessionCanvas(
      String id, Map<String, dynamic> canvas) {
    final s = creatorSessions.firstWhere((s) => s.id == id,
        orElse: () => CreatorSession(id: ''));
    if (s.id.isEmpty) return;
    s.canvas = canvas;
    s.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }

  void markCreatorSessionSaved(String id, String characterId) {
    final s = creatorSessions.firstWhere((s) => s.id == id,
        orElse: () => CreatorSession(id: ''));
    if (s.id.isEmpty) return;
    s.savedCharacterId = characterId;
    s.updatedAt = DateTime.now().millisecondsSinceEpoch;
    _bump();
  }
}

/// Resolve a sync `mtime` for a record that may still carry the
/// zero default. Records persisted before they were ever edited (e.g.
/// the bundled example cards) keep `mtime == 0`, which makes the
/// server's `mtime > since` pull filter skip them forever. This picks a
/// real timestamp without ever clobbering a record that already has one:
///   - `mtime != 0` → leave it untouched (LWW order preserved).
///   - `mtime == 0` & `updatedAt != 0` → adopt `updatedAt` (best signal
///     of when the record actually changed).
///   - `mtime == 0` & `updatedAt == 0` → fall back to `now`.
/// Pure + idempotent: feeding the result back in is a no-op.
int stampMtimeIfZero(int mtime, int updatedAt, int now) =>
    mtime != 0 ? mtime : (updatedAt != 0 ? updatedAt : now);

/// Build (but don't persist) a Persona from a Character.
///
/// chara_card_v2 text uses `{{char}}` for the character themselves and
/// `{{user}}` for whoever they're chatting with. When we flip the
/// character into a persona, those references flip too — what was
/// `{{user}}` now means `{{char}}` (the other party) and vice versa. We
/// also fold personality + mes_example into the persona description so
/// the model has the user's voice + dialogue style on tap.
///
/// [swap] (default true) controls that `{{user}}`↔`{{char}}` flip. Wave
/// CY.18.255 (FIX 2) added `swap: false` for re-importing a persona PNG
/// that Pyre itself exported (tagged `extensions.pyre.kind == 'persona'`):
/// that card's text is ALREADY persona-POV, so swapping again would
/// re-invert the macros — a net inversion vs the original persona.
Persona buildPersonaFromCharacter(Character c, {bool swap = true}) {
  String swapRoles(String s) {
    if (!swap) return s;
    // Two-pass swap via a sentinel — `replaceAll` would otherwise turn
    // every {{user}} into {{char}} and then immediately turn them back.
    const sentinel = ' __EMBERCHAR__ ';
    return s
        .replaceAll(
            RegExp(r'\{\{char\}\}', caseSensitive: false), sentinel)
        .replaceAll(
            RegExp(r'\{\{user\}\}', caseSensitive: false), '{{char}}')
        .replaceAll(sentinel, '{{user}}');
  }

  final parts = <String>[];
  if (c.description.trim().isNotEmpty) {
    parts.add(swapRoles(c.description));
  }
  if (c.personality.trim().isNotEmpty) {
    parts.add('## Personality\n${swapRoles(c.personality)}');
  }
  // Wave CX.1: mes_example now lands in its OWN persona field instead
  // of being folded into description with a `## Example dialogue`
  // header. The persona editor surfaces it as a dedicated input so
  // it's editable on its own.

  return Persona(
    id: newId('persona'),
    name: c.name,
    tagline:
        (c.tagline?.isNotEmpty ?? false) ? swapRoles(c.tagline!) : null,
    description: parts.join('\n\n'),
    dialogueExamples:
        c.mesExample.trim().isEmpty ? '' : swapRoles(c.mesExample),
    avatar: c.avatar,
    // Wave CB: carry over the character's bound lorebooks so the
    // converted persona keeps the same world context (especially
    // important for cards like Gine that ship with a lorebook —
    // converting her to a persona without DBZ context would be weird).
    // Direct id copy is safe: a lorebook can be bound to BOTH a
    // character and a persona without duplication; injection dedupes
    // by id.
    lorebookIds: List<String>.from(c.lorebookIds),
    // Wave CY.18.130: carry over the character's gallery as an
    // INDEPENDENT copy of the `pyre://` refs (pointers only — no blob
    // is duplicated; the shared AttachmentStore keeps one copy keyed by
    // sha256, and the GC's referenced-set now unions persona galleries).
    gallery: List<String>.from(c.gallery),
  );
}

