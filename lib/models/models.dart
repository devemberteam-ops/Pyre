// Core data models for Pyre — mirrors the JS prototype schema.
// Keep `fromJson` / `toJson` symmetric so we can interop with the existing
// localStorage backup file (`emberchat.v1`) when needed.

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/material.dart' show BoxFit;
import 'package:uuid/uuid.dart';

import '../services/card_assist_prompts.dart';
import '../services/creator_schema.dart' show CreatorDescriptionSize;
import '../services/key_crypto.dart';

const _uuid = Uuid();

/// Lenient JSON int decoder. `j['x'] as int?` throws if the value is a
/// double (`40.0`), which legitimately happens for round-tripped JSON from
/// JS prototypes and some backup tooling. A single bad cast inside the
/// top-level `load()` try/catch would silently wipe ALL collections that
/// came after it in the parse order, so this helper accepts `num` and
/// rounds to int instead of throwing.
int? _jInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

/// Wave CY.18.265: parse the persisted `creatorDescriptionSize` enum name back
/// to its value, defaulting (and fail-closing on any unknown/legacy value) to
/// `standard` — the original ~5,000-token behaviour.
CreatorDescriptionSize _parseCreatorDescriptionSize(dynamic v) {
  if (v is String) {
    for (final s in CreatorDescriptionSize.values) {
      if (s.name == v) return s;
    }
  }
  return CreatorDescriptionSize.standard;
}

/// Wave CY.18.44: clamp a parsed timestamp into a sane range. Hand-edited
/// or corrupted backups can carry negative timestamps (sort to year-1970
/// before the chat actually started) or absurd future timestamps (year
/// 5138 — would push the message past any future "real" message in sort
/// order, breaking chronology forever). We accept `null` as-is (caller's
/// default-to-now kicks in) but for any actual value we clamp to
/// `[0, now]`. Future timestamps lose accuracy but stay below any genuine
/// later activity; negative values become epoch-zero.
int? _jTimestamp(dynamic v) {
  final raw = _jInt(v);
  if (raw == null) return null;
  if (raw < 0) return 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (raw > now) return now;
  return raw;
}

/// Wave CY.18.44: tolerant string-list decoder. Pre-Wave the fromJson
/// helpers used `(j['x'] as List?)?.cast<String>() ?? []` which returns a
/// lazy CastList view — accessing a non-String element throws at READ
/// time, not at decode time. A backup with a corrupted `variants: ["ok",
/// 42]` would parse "fine", then crash the chat bubble when the second
/// variant got read. `whereType<String>()` filters at decode time and
/// surfaces only the legitimate strings.
List<String> _jStringList(dynamic v) {
  if (v is! List) return <String>[];
  return v.whereType<String>().toList();
}

String newId([String prefix = '']) =>
    prefix.isEmpty ? _uuid.v4() : '$prefix-${_uuid.v4()}';

/// Sentinel persona-id stored in [Chat.personaId] when the user has
/// explicitly chosen "No persona" for that chat, as distinct from `null`
/// which means "inherit the global active persona".
const String kExplicitNoPersonaId = '__pyre_explicit_none__';

// ---------------------------------------------------------------------------
// Provider (API connections)

/// Categorisation of a provider endpoint. Functionally they're all the
/// same OpenAI-compatible HTTPS protocol; this just lets the UI group
/// them differently in the editor (External = first-party services like
/// OpenRouter/OpenAI; Proxy = community-shared SillyTavern-style proxies
/// where the user gets a URL+key from a Discord server; Localhost =
/// self-hosted on the same machine or LAN).
enum ProviderKind { external_, proxy, localhost }

class ApiProvider {
  String id;
  String name;
  ProviderKind kind;
  String baseUrl;
  String apiKey;
  String model;
  Map<String, String> headers;
  /// Extra fields spread into the chat-completions request body, on
  /// top of the sampling payload. Lets the user pass provider-
  /// specific params Pyre doesn't model directly — most commonly the
  /// per-provider "disable reasoning" flag:
  ///   Qwen 3.x        → {"reasoning": {"effort": "none"}}
  ///   OpenAI o-series → {"reasoning_effort": "low"}
  ///   Grok 4          → {"reasoning_effort": "low"}
  ///   DeepSeek R1     → {"include_reasoning": false}
  /// Pyre-managed fields (model, messages, stream, temperature, top_p,
  /// max_tokens, frequency/presence_penalty, top_k/min_p/top_a/
  /// repetition_penalty) take precedence; anything else here is
  /// merged in as-is and forwarded to the provider.
  Map<String, dynamic> extraParams;

  /// Wave CY.18.100: optional manual context-window size (tokens). When
  /// set, it OVERRIDES the auto-detected value from `/models` — the
  /// universal escape hatch for providers that don't expose a
  /// context-length field. Null = auto-detect only.
  int? contextWindow;

  /// Wave CY.18.120 — when true, Pyre fires a tiny request to preload
  /// this provider's model on app launch AND right after the provider is
  /// saved, so a slow local (LM Studio/Ollama) JIT model-load happens
  /// BEFORE the user's first real request instead of timing it out. Only
  /// meaningful for localhost providers. Default true.
  bool warmUpOnLaunch;

  /// Wave CY.18.258: last-write-wins clock for encrypted key-sync. Bumped
  /// whenever the provider's config or key changes; the sync engine emits
  /// only providers with `mtime > since` and resolves conflicts by the
  /// higher mtime. Default 0 (pre-Wave records / never-synced).
  int mtime;

  /// Wave CY.18.258: TRANSIENT holder for the AES-GCM key envelope produced
  /// by [toJsonEncrypted] and rehydrated by [fromJson] from a synced
  /// `apiKeyEnc` field. Never written by the normal [toJson] (the plaintext
  /// key lives in OS-secure storage, the encrypted form only crosses the
  /// LAN wire). Set post-construction; default null.
  String? apiKeyEnc;

  ApiProvider({
    required this.id,
    required this.name,
    this.kind = ProviderKind.external_,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    Map<String, String>? headers,
    Map<String, dynamic>? extraParams,
    this.contextWindow,
    this.warmUpOnLaunch = true,
    this.mtime = 0,
  })  : headers = headers ?? <String, String>{},
        extraParams = extraParams ?? <String, dynamic>{};

  factory ApiProvider.fromJson(Map<String, dynamic> j) {
    final p = ApiProvider(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'Provider',
      kind: switch (j['kind']) {
        'localhost' => ProviderKind.localhost,
        'proxy' => ProviderKind.proxy,
        _ => ProviderKind.external_,
      },
      baseUrl: (j['baseUrl'] as String?) ?? '',
      apiKey: (j['apiKey'] as String?) ?? '',
      model: (j['model'] as String?) ?? '',
      headers: (j['headers'] as Map?)?.cast<String, String>() ?? {},
      extraParams: (j['extraParams'] as Map?)?.cast<String, dynamic>() ?? {},
      contextWindow: (j['contextWindow'] as num?)?.toInt(),
      // Wave CY.18.120: default true so pre-Wave backups (no field) opt
      // every localhost provider into warm-up automatically.
      warmUpOnLaunch: (j['warmUpOnLaunch'] as bool?) ?? true,
      // Wave CY.18.258: default 0 for pre-Wave / never-synced records.
      mtime: (j['mtime'] as num?)?.toInt() ?? 0,
    );
    // Wave CY.18.258: rehydrate the transient encrypted-key envelope from a
    // synced record. The normal persistence path never writes apiKeyEnc, so
    // this stays null for local-only blobs.
    if (j['apiKeyEnc'] is String) p.apiKeyEnc = j['apiKeyEnc'] as String;
    return p;
  }

  /// Serialise this provider.
  ///
  /// [includeApiKey] is OFF by default so the main persistence path never
  /// writes the bearer token into the plaintext JSON blob — it lives in
  /// OS-secure storage instead (lib/services/secure_keys.dart).
  /// Backup exports can opt in explicitly when the user has been warned.
  Map<String, dynamic> toJson({bool includeApiKey = false}) => {
        'id': id,
        'name': name,
        'kind': switch (kind) {
          ProviderKind.localhost => 'localhost',
          ProviderKind.proxy => 'proxy',
          ProviderKind.external_ => 'external',
        },
        'baseUrl': baseUrl,
        if (includeApiKey) 'apiKey': apiKey,
        'model': model,
        'headers': headers,
        if (extraParams.isNotEmpty) 'extraParams': extraParams,
        if (contextWindow != null) 'contextWindow': contextWindow,
        // Wave CY.18.120: always persisted (cheap bool) so the user's
        // explicit on/off choice round-trips through backups.
        'warmUpOnLaunch': warmUpOnLaunch,
        // Wave CY.18.258: LWW clock for encrypted key-sync. Cheap int,
        // always persisted so it survives backups.
        'mtime': mtime,
      };

  /// Wave CY.18.258: synced form for native key-sync — config in cleartext
  /// plus the API key as an encrypted envelope (never plaintext). An empty
  /// key yields no `apiKeyEnc` field. The plaintext key is never emitted.
  Future<Map<String, dynamic>> toJsonEncrypted(SecretKey secret) async {
    final j = toJson();
    if (apiKey.isNotEmpty) {
      j['apiKeyEnc'] = await KeyCrypto.encryptApiKey(apiKey, secret);
    }
    return j;
  }
}

// ---------------------------------------------------------------------------
// Character (chara_card_v2 + a few Pyre additions)

class Character {
  String id;
  String name;
  String? tagline;
  String description;
  String personality;
  String scenario;
  String firstMes;
  String mesExample;
  String systemPrompt;
  String postHistoryInstructions;
  List<String> alternateGreetings;
  List<String> tags;
  String creator;
  String characterVersion;
  // ---- chara_card_v2 advanced fields ----
  /// Free-form notes from the card author, visible to importers but never
  /// fed to the LLM. Round-tripped through PNG export so credits survive.
  String creatorNotes;
  /// 0.0 = laconic, 1.0 = chatty. Some frontends weight reply length on
  /// this; Pyre doesn't act on it directly but preserves the field.
  double? talkativeness;
  /// Optional system-style prompt injected `depth_prompt_depth` messages
  /// before the tail of the chat (useful for "keep this in mind right
  /// before responding"-style nudges).
  String depthPrompt;
  int depthPromptDepth;
  /// Whatever the card author put in `extensions` — opaque to Pyre, but
  /// we serialise it untouched so Risu / ST / Chub-specific extension
  /// tags round-trip cleanly.
  Map<String, dynamic> extensions;
  /// Wave CA: lorebooks that auto-activate whenever this character is
  /// in a chat. Combined additively with the chat's own per-chat
  /// lorebook list and the active persona's bound lorebooks during
  /// injection (deduped by id). Survives chara_card_v2 round-trips —
  /// on export, all entries from bound (non-hidden + hidden) books
  /// get merged into the PNG's `character_book` so other apps see the
  /// world the character carries with it (like the Gine card).
  List<String> lorebookIds;
  // ---------------------------------------
  /// Wave CY.18.127: ordered list of extra gallery images, each a
  /// `pyre://attachment/<sha256>` ref (same form as `avatar`). Imported
  /// from a BotBooru card's mini-gallery or added natively. Content-
  /// addressed so images are never byte-duplicated; the GC's referenced-
  /// set unions these. Defaults to `[]`; tolerates absent/null on parse.
  List<String> gallery;
  String? avatar; // base64 data URL or null
  int createdAt;
  int updatedAt;
  /// Wave CY.18.36: true when this character was built via the Pyre
  /// Character Creator (the AI-assisted flow). False for imports
  /// (PNG / JSON / URL / chub) and for legacy characters from before
  /// this flag existed (we can't retroactively know which were built
  /// here vs imported). Used by the Profile screen's "Cards created"
  /// stat to count first-party creations.
  bool createdInPyre;
  /// Wave CY.18.38: starred by the user. Favorites float to a
  /// dedicated section at the top of the Characters list and survive
  /// folder/tag/sort filters (they appear within whatever set the
  /// filters produced). Persisted across sessions and backups.
  bool favorite;
  /// Wave CY.18.62: LAN sync metadata. `mtime` = millis-since-epoch
  /// of the last write that materially changed this record (set by
  /// the StoreBackend layer in Wave 63 — for now it just rides along
  /// in fromJson/toJson). `deleted` = tombstone marker; record stays
  /// in JSON until the 30-day GC, so a long-disconnected device can
  /// still learn the deletion on next sync. Defaults of 0 / false
  /// mean: pre-Wave-62 records load cleanly and the schemaVersion
  /// migration stamps mtime = now() on first launch.
  int mtime;
  bool deleted;

  Character({
    required this.id,
    required this.name,
    this.tagline,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMes = '',
    this.mesExample = '',
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    List<String>? alternateGreetings,
    List<String>? tags,
    this.creator = '',
    this.characterVersion = '1.0',
    this.creatorNotes = '',
    this.talkativeness,
    this.depthPrompt = '',
    this.depthPromptDepth = 4,
    Map<String, dynamic>? extensions,
    List<String>? lorebookIds,
    List<String>? gallery,
    this.avatar,
    int? createdAt,
    int? updatedAt,
    this.createdInPyre = false,
    this.favorite = false,
    this.mtime = 0,
    this.deleted = false,
  })  : alternateGreetings = alternateGreetings ?? [],
        tags = tags ?? [],
        extensions = extensions ?? <String, dynamic>{},
        lorebookIds = lorebookIds ?? [],
        gallery = gallery ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory Character.fromJson(Map<String, dynamic> j) => Character(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Unnamed',
        tagline: j['tagline'] as String?,
        description: (j['description'] as String?) ?? '',
        personality: (j['personality'] as String?) ?? '',
        scenario: (j['scenario'] as String?) ?? '',
        firstMes: (j['firstMes'] as String?) ?? '',
        mesExample: (j['mesExample'] as String?) ?? '',
        systemPrompt: (j['systemPrompt'] as String?) ?? '',
        postHistoryInstructions:
            (j['postHistoryInstructions'] as String?) ?? '',
        alternateGreetings: _jStringList(j['alternateGreetings']),
        tags: _jStringList(j['tags']),
        creator: (j['creator'] as String?) ?? '',
        characterVersion: (j['characterVersion'] as String?) ?? '1.0',
        creatorNotes: (j['creatorNotes'] as String?) ?? '',
        talkativeness: (j['talkativeness'] as num?)?.toDouble(),
        depthPrompt: (j['depthPrompt'] as String?) ?? '',
        depthPromptDepth: _jInt(j['depthPromptDepth']) ?? 4,
        extensions: (j['extensions'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{},
        lorebookIds: _jStringList(j['lorebookIds']),
        // Wave CY.18.127: tolerate absent/null gallery → [].
        gallery: _jStringList(j['gallery']),
        avatar: j['avatar'] as String?,
        createdAt: _jTimestamp(j['createdAt']),
        updatedAt: _jTimestamp(j['updatedAt']),
        // Wave CY.18.36: legacy chars (no field in JSON) default false —
        // we can't tell post-hoc whether they were Creator-built or
        // imported, and false is the conservative answer for the
        // "Cards created" stat.
        createdInPyre: (j['createdInPyre'] as bool?) ?? false,
        // Wave CY.18.38: legacy chars default to not-favorited.
        favorite: (j['favorite'] as bool?) ?? false,
        // Wave CY.18.62: legacy chars default mtime=0 (migration stamps now()).
        mtime: _jInt(j['mtime']) ?? 0,
        deleted: (j['deleted'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tagline': tagline,
        'description': description,
        'personality': personality,
        'scenario': scenario,
        'firstMes': firstMes,
        'mesExample': mesExample,
        'systemPrompt': systemPrompt,
        'postHistoryInstructions': postHistoryInstructions,
        'alternateGreetings': alternateGreetings,
        'tags': tags,
        'creator': creator,
        'characterVersion': characterVersion,
        'creatorNotes': creatorNotes,
        if (talkativeness != null) 'talkativeness': talkativeness,
        'depthPrompt': depthPrompt,
        'depthPromptDepth': depthPromptDepth,
        'extensions': extensions,
        'lorebookIds': lorebookIds,
        'gallery': gallery,
        'avatar': avatar,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (createdInPyre) 'createdInPyre': true,
        if (favorite) 'favorite': true,
        // Wave CY.18.62: sync metadata. mtime always serialised so
        // pre-migration files get progressively stamped on each save.
        // deleted only emitted when true (saves bytes on the common case).
        'mtime': mtime,
        if (deleted) 'deleted': true,
      };
}

// ---------------------------------------------------------------------------
// Persona (how the user appears)

class Persona {
  String id;
  String name;
  String? tagline;
  String description;
  /// Wave CX.1: optional dialogue examples — first-person dialogue /
  /// action samples in the user's voice that the model uses to lock the
  /// persona's speech rhythm. Populated automatically from a source
  /// character's mes_example when "Add as persona" is used (with
  /// `{{char}}` / `{{user}}` swapped). Same `<START>`-separated shape
  /// as chara_card_v2 `mes_example`. Empty / null when the persona was
  /// authored from scratch or the source had no example dialogue.
  String dialogueExamples;
  String? avatar;
  /// Wave CA: lorebooks that auto-activate when this persona is the
  /// active user-side in a chat. Same semantics as Character.lorebookIds
  /// — additive with per-chat books and character-bound books, deduped
  /// by id during injection.
  List<String> lorebookIds;
  /// Wave CY.18.127: gallery of extra images — same shape + semantics as
  /// `Character.gallery` (ordered `pyre://attachment/<sha256>` refs).
  /// Copied (pointers, not bytes) when a character is added as a persona.
  List<String> gallery;
  int createdAt;
  int updatedAt;
  /// Wave CY.18.38: starred by the user. Mirrors Character.favorite —
  /// favorites float to the top of the Personas list.
  bool favorite;
  /// Wave CY.18.62: LAN sync metadata. See Character.mtime for rationale.
  int mtime;
  bool deleted;

  Persona({
    required this.id,
    required this.name,
    this.tagline,
    this.description = '',
    this.dialogueExamples = '',
    this.avatar,
    List<String>? lorebookIds,
    List<String>? gallery,
    int? createdAt,
    int? updatedAt,
    this.favorite = false,
    this.mtime = 0,
    this.deleted = false,
  })  : lorebookIds = lorebookIds ?? [],
        gallery = gallery ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory Persona.fromJson(Map<String, dynamic> j) => Persona(
        id: j['id'] as String,
        // Wave CY.18.44: defend against empty-string name (hand-edited
        // backups, or a chub.ai export that gave us `name: ""`). Pre-Wave
        // the picker tried to render a 0-width chip and crashed the
        // chat header. Falling back to "You" matches the default fresh-
        // install persona and keeps the UI navigable so the user can
        // delete/rename the malformed persona instead of being stuck.
        //
        // Wave CY.18.54: audit caught that the original Wave 44 fix
        // checked `trim().isNotEmpty` but then assigned the UNTRIMMED
        // value — so a whitespace-only name like `"   "` still passed
        // through. Trim BOTH in the gate AND in the value so we never
        // store a name that renders as zero width.
        name: () {
          final raw = (j['name'] as String?)?.trim();
          return (raw == null || raw.isEmpty) ? 'You' : raw;
        }(),
        tagline: j['tagline'] as String?,
        description: (j['description'] as String?) ?? '',
        dialogueExamples: (j['dialogueExamples'] as String?) ?? '',
        avatar: j['avatar'] as String?,
        lorebookIds: _jStringList(j['lorebookIds']),
        // Wave CY.18.127: tolerate absent/null gallery → [].
        gallery: _jStringList(j['gallery']),
        createdAt: _jTimestamp(j['createdAt']),
        updatedAt: _jTimestamp(j['updatedAt']),
        favorite: (j['favorite'] as bool?) ?? false,
        mtime: _jInt(j['mtime']) ?? 0,
        deleted: (j['deleted'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tagline': tagline,
        'description': description,
        if (dialogueExamples.isNotEmpty)
          'dialogueExamples': dialogueExamples,
        'avatar': avatar,
        'lorebookIds': lorebookIds,
        'gallery': gallery,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (favorite) 'favorite': true,
        'mtime': mtime,
        if (deleted) 'deleted': true,
      };
}

// ---------------------------------------------------------------------------
// Folder (user-created character collections)

/// Wave CY.18.38: user-created grouping of characters. Cards can be in
/// 0 or more folders. Folders only contain characters for now — if
/// personas ever scale enough to need folders, add a `personaIds` set
/// here; the rest of the structure stays the same.
class Folder {
  String id;
  String name;
  /// Ids of characters in this folder. Stored as a List for JSON
  /// compatibility; treat as a set conceptually (the UI dedupes on
  /// add).
  List<String> characterIds;
  int createdAt;
  int updatedAt;

  Folder({
    required this.id,
    required this.name,
    List<String>? characterIds,
    int? createdAt,
    int? updatedAt,
  })  : characterIds = characterIds ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory Folder.fromJson(Map<String, dynamic> j) => Folder(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Untitled folder',
        characterIds: _jStringList(j['characterIds']),
        createdAt: _jTimestamp(j['createdAt']),
        updatedAt: _jTimestamp(j['updatedAt']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'characterIds': characterIds,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };
}

// ---------------------------------------------------------------------------
// Chat & Message

enum MessageKind { user, char, ooc, scene, system }

MessageKind _kindFromString(String? s) {
  switch (s) {
    case 'user':
      return MessageKind.user;
    case 'ooc':
      return MessageKind.ooc;
    case 'scene':
      return MessageKind.scene;
    case 'system':
      return MessageKind.system;
    default:
      return MessageKind.char;
  }
}

String _kindToString(MessageKind k) => switch (k) {
      MessageKind.user => 'user',
      MessageKind.ooc => 'ooc',
      MessageKind.scene => 'scene',
      MessageKind.system => 'system',
      MessageKind.char => 'char',
    };

class Message {
  String id;
  MessageKind kind;
  String? characterId; // for group chats — which character spoke
  List<String> variants; // text alternates
  int selectedVariant;
  int createdAt;
  // Per-variant downstream snapshots. When the user branches (creates a new
  // variant of a message that has messages AFTER it), we move those
  // downstream messages here under the SOURCE variant's index, so navigating
  // back to that variant restores its conversation tail. Each list is the
  // full chain of messages that originally followed this one — themselves
  // possibly carrying their own downstreamByVariant for nested branches.
  Map<int, List<Message>> downstreamByVariant;
  /// Wave CY.18.62: sync metadata. See Character.mtime for rationale. For
  /// messages this is per-message granularity — editing one message in a
  /// long chat doesn't have to push the whole chat object.
  int mtime;
  bool deleted;

  Message({
    required this.id,
    required this.kind,
    this.characterId,
    List<String>? variants,
    this.selectedVariant = 0,
    int? createdAt,
    Map<int, List<Message>>? downstreamByVariant,
    this.mtime = 0,
    this.deleted = false,
  })  : variants = variants ?? [''],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        downstreamByVariant = downstreamByVariant ?? {};

  String get text =>
      (selectedVariant >= 0 && selectedVariant < variants.length)
          ? variants[selectedVariant]
          : (variants.isNotEmpty ? variants[0] : '');

  /// Maximum depth of nested downstreamByVariant snapshots we'll parse.
  /// Realistic chub-style branching produces a handful of levels; anything
  /// near this is either pathological user behavior or a crafted backup
  /// designed to stack-overflow the parser. We silently truncate beyond
  /// the limit rather than throwing so the rest of the backup still loads.
  static const int _maxDownstreamDepth = 32;

  factory Message.fromJson(Map<String, dynamic> j) =>
      _parseAt(j, 0);

  static Message _parseAt(Map<String, dynamic> j, int depth) {
    // Downstream snapshots are stored as a map of string-encoded variant
    // index → list of nested Message JSON objects (recursive).
    final dsRaw = j['downstreamByVariant'];
    final ds = <int, List<Message>>{};
    if (dsRaw is Map && depth < _maxDownstreamDepth) {
      dsRaw.forEach((k, v) {
        final idx = int.tryParse(k.toString());
        if (idx == null || v is! List) return;
        ds[idx] = v
            .whereType<Map>()
            .map((mm) =>
                _parseAt(mm.cast<String, dynamic>(), depth + 1))
            .toList();
      });
    }
    // Wave CY.18.44: tolerant variants decode + selectedVariant clamp.
    // Pre-Wave, a backup with `variants: "text"` (string instead of list,
    // from corruption or hand-edit) would let the .cast<String>() view
    // succeed at decode time and blow up the first time any consumer
    // read `variants[i]`. And a `selectedVariant: 4` with only 3 variants
    // would silently fall back to variants[0] via the `text` getter —
    // technically safe but the user sees the wrong roll. We now:
    //   1. Filter variants with whereType<String> so junk entries vanish
    //      cleanly instead of poisoning the array.
    //   2. Always have at least [''] (an empty variant is recoverable;
    //      a zero-length variants array breaks `text` and every UI that
    //      reads it).
    //   3. Clamp selectedVariant to a valid index so the displayed roll
    //      matches the underlying data on round-trip.
    var variants = _jStringList(j['variants']);
    if (variants.isEmpty) variants = [''];
    var selectedVariant = _jInt(j['selectedVariant']) ?? 0;
    if (selectedVariant < 0 || selectedVariant >= variants.length) {
      selectedVariant = 0;
    }
    return Message(
      id: j['id'] as String,
      kind: _kindFromString(j['kind'] as String?),
      characterId: j['characterId'] as String?,
      variants: variants,
      selectedVariant: selectedVariant,
      createdAt: _jTimestamp(j['createdAt']),
      downstreamByVariant: ds,
      mtime: _jInt(j['mtime']) ?? 0,
      deleted: (j['deleted'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': _kindToString(kind),
        'characterId': characterId,
        'variants': variants,
        'selectedVariant': selectedVariant,
        'createdAt': createdAt,
        if (downstreamByVariant.isNotEmpty)
          'downstreamByVariant': downstreamByVariant.map(
            (k, v) => MapEntry(k.toString(), v.map((m) => m.toJson()).toList()),
          ),
        'mtime': mtime,
        if (deleted) 'deleted': true,
      };
}

/// Wave CY.18: branch-aware long-term memory checkpoint.
///
/// One checkpoint = one summary of the chat up to a specific message
/// index, fingerprinted with the BRANCH it was taken on. The fingerprint
/// (`pathHash`) is a deterministic concatenation of `(message.id +
/// selectedVariant)` for every message from index 0 up to (and including)
/// `anchorMessageIdx`. Two checkpoints share a fingerprint prefix iff
/// they share that exact sequence of variant choices — so when the user
/// re-rolls a message at index N, every checkpoint with `anchorMessageIdx
/// >= N` whose hash no longer matches the current branch's prefix becomes
/// invalid for THIS branch (but stays valid for the original branch if
/// the user navigates back via the chat-tree).
///
/// Stale checkpoints from abandoned branches are NEVER auto-cleaned —
/// they sit in the list orphaned, taking minimal storage and visually
/// hidden because the validity check filters them out for any active
/// branch. The user can wipe everything from the Memory screen.
class MemoryCheckpoint {
  String id;
  String summary;
  /// Index into `Chat.messages` (in the current branch's linearised
  /// view) where the summarisation cut off. Inclusive on the lower
  /// bound — messages [0..anchorMessageIdx] are "covered" by this
  /// checkpoint; the next checkpoint folds in `[lastAnchor+1..nextAnchor]`.
  int anchorMessageIdx;
  /// Deterministic branch fingerprint — see class-level docs.
  String pathHash;
  int createdAt;
  /// Wave CY.18.62: LAN sync metadata. See Character.mtime for rationale.
  int mtime;
  bool deleted;

  MemoryCheckpoint({
    required this.id,
    required this.summary,
    required this.anchorMessageIdx,
    required this.pathHash,
    int? createdAt,
    this.mtime = 0,
    this.deleted = false,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  factory MemoryCheckpoint.fromJson(Map<String, dynamic> j) =>
      MemoryCheckpoint(
        id: (j['id'] as String?) ?? newId('mc'),
        summary: (j['summary'] as String?) ?? '',
        anchorMessageIdx: _jInt(j['anchorMessageIdx']) ?? 0,
        pathHash: (j['pathHash'] as String?) ?? '',
        createdAt: _jInt(j['createdAt']),
        mtime: _jInt(j['mtime']) ?? 0,
        deleted: (j['deleted'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'summary': summary,
        'anchorMessageIdx': anchorMessageIdx,
        'pathHash': pathHash,
        'createdAt': createdAt,
        'mtime': mtime,
        if (deleted) 'deleted': true,
      };
}

/// Wave CY.18.176: A single future plot beat in the Story Roadmap (Script).
/// Active beats (done==false, non-blank text) are injected into the model
/// context with anti-rush framing so the AI builds toward them gradually.
class StoryBeat {
  String id;
  String text;
  bool done;
  int mtime;
  StoryBeat({required this.id, required this.text, this.done = false, this.mtime = 0});
  factory StoryBeat.fromJson(Map<String, dynamic> j) => StoryBeat(
        id: (j['id'] as String?) ?? newId('beat'),
        text: ((j['text'] as String?) ?? '').trim(),
        done: (j['done'] as bool?) ?? false,
        mtime: _jInt(j['mtime']) ?? 0,
      );
  Map<String, dynamic> toJson() => {
        'id': id, 'text': text, if (done) 'done': true, 'mtime': mtime,
      };
  StoryBeat clone() => StoryBeat(id: id, text: text, done: done, mtime: mtime);
}

class Chat {
  String id;
  List<String> characterIds;
  Map<String, Character> characterSnapshots; // frozen per chat
  String? personaId;
  List<String> attachedLorebookIds;
  /// Wave CD: book ids that come from a character or persona binding
  /// but the user has DISABLED for THIS specific chat. Used by
  /// `collectBoundLorebooks` to filter inherited entries before
  /// injection. Per-chat attachments (`attachedLorebookIds`) are
  /// orthogonal — those are additive on top of inheritance.
  ///
  /// Semantics: if a book id is in `lorebookIds` of the active
  /// persona OR any character in this chat AND is in this set, the
  /// runtime ignores its entries. Per-chat attached books are NOT
  /// affected (they're an explicit user opt-in).
  List<String> disabledInheritedLorebookIds;
  String? presetId;
  List<Message> messages;
  /// Wave CY.18: long-term memory is now a chain of branch-aware
  /// checkpoints instead of a single overwritten string. See
  /// [MemoryCheckpoint] for the data shape. The list is append-only
  /// during normal chat (the auto-summariser adds new entries as it
  /// catches up); the user can wipe it from the Memory screen.
  ///
  /// Legacy field migration: backups from before Wave CY.18 carried
  /// `memorySummary: String` + `memoryAnchor: int`. On load we
  /// promote that pair into a single checkpoint with an empty
  /// `pathHash` (sentinel value treated as ALWAYS valid for any
  /// branch — see services/memory.dart).
  List<MemoryCheckpoint> memoryCheckpoints;
  /// Wave CY.16: per-chat opt-out for the long-term memory feature.
  /// When false, the auto-summariser doesn't fire and existing
  /// checkpoints aren't injected into the system prompt either.
  /// Manual "Summarise now" still works (lets the user generate a
  /// snapshot even with auto off).
  bool memoryEnabled;
  /// Wave CY.18.170: Live Sheet snapshots for this chat.
  /// Append-only during normal chat (the live-sheet service adds new
  /// entries as it tracks state changes). The latest snapshot is used
  /// for injection and display; older ones are kept for history.
  List<LiveSheetSnapshot> liveSheetSnapshots;
  /// Wave CY.18.170: per-chat opt-in for the Live Sheet feature.
  /// Defaults to false — the feature is off until the user enables it.
  bool liveSheetEnabled;
  /// Wave CY.18.176: Script — per-chat list of future plot beats the user
  /// plants. Active beats are injected into the model context with anti-rush
  /// framing so the AI builds toward them gradually.
  List<StoryBeat> storyBeats;
  int createdAt;
  int updatedAt;
  /// Wave CY.18.62: LAN sync metadata. See Character.mtime for rationale.
  /// Individual `Message`s carry their own mtime — the chat's mtime
  /// reflects edits to the CHAT envelope (members, persona, settings,
  /// metadata), not message additions.
  int mtime;
  bool deleted;
  // Wave CY.18.156: per-chat background OVERRIDE. All nullable → null means
  // "inherit the global ChatSettings" (so existing chats are unaffected and
  // behave exactly as before). Set non-null only when the user overrides the
  // backdrop for THIS chat in the Customize-chat sheet:
  //   - backgroundSource: which image (character / persona / custom / none).
  //   - customBackgroundDataUrl: the uploaded image (only when source==custom).
  //   - backgroundOpacity: 0..1 backdrop opacity for this chat.
  ChatBackgroundSource? backgroundSource;
  String? customBackgroundDataUrl;
  double? backgroundOpacity;
  // Wave CY.18.203: per-chat fit override (null = inherit global ChatSettings).
  ChatBackgroundFit? backgroundFit;
  // Wave CY.18.181: dynamic scene-background state (only meaningful when the
  // effective backgroundSource == dynamic). sceneBgFile is the currently-chosen
  // asset filename (null until first resolve); sceneSetting is the sticky world
  // aesthetic (default 'modern'); the two watermarks throttle the classifier.
  String? sceneBgFile;
  String sceneSetting;
  int sceneLastClassifyMsgCount;
  String sceneLastClassifyKey;
  // Wave CY.18.197: short, human-readable, AI-maintained note of where the
  // scene currently is (e.g. "the Serpent's Fang guild hall"). It ANCHORS the
  // classifier (anti-drift) and is user-editable in Customize Chat. It is
  // scene-background-only state — it is NEVER injected into the chat LLM
  // context, so it has no token cost.
  String sceneLocation;

  Chat({
    required this.id,
    required this.characterIds,
    Map<String, Character>? characterSnapshots,
    this.personaId,
    List<String>? attachedLorebookIds,
    List<String>? disabledInheritedLorebookIds,
    this.presetId,
    List<Message>? messages,
    List<MemoryCheckpoint>? memoryCheckpoints,
    this.memoryEnabled = true,
    List<LiveSheetSnapshot>? liveSheetSnapshots,
    this.liveSheetEnabled = false,
    List<StoryBeat>? storyBeats,
    int? createdAt,
    int? updatedAt,
    this.mtime = 0,
    this.deleted = false,
    this.backgroundSource,
    this.customBackgroundDataUrl,
    this.backgroundOpacity,
    this.backgroundFit,
    this.sceneBgFile,
    this.sceneSetting = 'modern',
    this.sceneLastClassifyMsgCount = 0,
    this.sceneLastClassifyKey = '',
    this.sceneLocation = '',
  })  : characterSnapshots = characterSnapshots ?? {},
        attachedLorebookIds = attachedLorebookIds ?? [],
        disabledInheritedLorebookIds = disabledInheritedLorebookIds ?? [],
        messages = messages ?? [],
        memoryCheckpoints = memoryCheckpoints ?? [],
        liveSheetSnapshots = liveSheetSnapshots ?? [],
        storyBeats = storyBeats ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  String? get primaryCharacterId =>
      characterIds.isNotEmpty ? characterIds.first : null;

  factory Chat.fromJson(Map<String, dynamic> j) {
    final snaps = <String, Character>{};
    final rawSnaps = j['characterSnapshots'] as Map?;
    if (rawSnaps != null) {
      rawSnaps.forEach((k, v) {
        if (v is Map) {
          snaps[k as String] =
              Character.fromJson(v.cast<String, dynamic>());
        }
      });
    }
    // Wave CY.18 migration: promote legacy single-summary memory into
    // a one-checkpoint chain. The empty pathHash is treated as
    // always-valid by the validity check (so the user keeps seeing
    // the imported summary on every branch until they re-summarise
    // and the new branch-tagged checkpoints take over).
    final ckptsRaw = j['memoryCheckpoints'] as List?;
    final ckpts = ckptsRaw != null
        ? ckptsRaw
            .whereType<Map>()
            .map((m) =>
                MemoryCheckpoint.fromJson(m.cast<String, dynamic>()))
            .toList()
        : <MemoryCheckpoint>[];
    if (ckpts.isEmpty) {
      final legacySummary = j['memorySummary'] as String?;
      final legacyAnchor = _jInt(j['memoryAnchor']) ?? 0;
      if (legacySummary != null && legacySummary.trim().isNotEmpty) {
        ckpts.add(MemoryCheckpoint(
          id: newId('mc'),
          summary: legacySummary,
          anchorMessageIdx: legacyAnchor > 0 ? legacyAnchor - 1 : 0,
          pathHash: '', // sentinel — always valid
        ));
      }
    }
    return Chat(
      id: j['id'] as String,
      characterIds: _jStringList(j['characterIds']),
      characterSnapshots: snaps,
      personaId: j['personaId'] as String?,
      attachedLorebookIds: _jStringList(j['attachedLorebookIds']),
      disabledInheritedLorebookIds:
          _jStringList(j['disabledInheritedLorebookIds']),
      presetId: j['presetId'] as String?,
      messages: (j['messages'] as List?)
              ?.map((m) => Message.fromJson((m as Map).cast<String, dynamic>()))
              .toList() ??
          [],
      memoryCheckpoints: ckpts,
      memoryEnabled: (j['memoryEnabled'] as bool?) ?? true,
      liveSheetSnapshots: ((j['liveSheetSnapshots'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => LiveSheetSnapshot.fromJson(m.cast<String, dynamic>()))
          .toList(),
      liveSheetEnabled: (j['liveSheetEnabled'] as bool?) ?? false,
      storyBeats: ((j['storyBeats'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => StoryBeat.fromJson(m.cast<String, dynamic>()))
          .toList(),
      createdAt: _jTimestamp(j['createdAt']),
      updatedAt: _jTimestamp(j['updatedAt']),
      mtime: _jInt(j['mtime']) ?? 0,
      deleted: (j['deleted'] as bool?) ?? false,
      // Wave CY.18.156: per-chat background override (absent → null → inherit).
      backgroundSource: chatBgSourceFromNameOrNull(j['backgroundSource']),
      customBackgroundDataUrl: j['customBackgroundDataUrl'] as String?,
      backgroundOpacity: (j['backgroundOpacity'] as num?)?.toDouble(),
      // Wave CY.18.203: per-chat fit override (absent → null → inherit).
      backgroundFit: chatBgFitFromNameOrNull(j['backgroundFit']),
      sceneBgFile: j['sceneBgFile'] as String?,
      sceneSetting: (j['sceneSetting'] as String?) ?? 'modern',
      sceneLastClassifyMsgCount: _jInt(j['sceneLastClassifyMsgCount']) ?? 0,
      sceneLastClassifyKey: (j['sceneLastClassifyKey'] as String?) ?? '',
      sceneLocation: (j['sceneLocation'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'characterIds': characterIds,
        'characterSnapshots':
            characterSnapshots.map((k, v) => MapEntry(k, v.toJson())),
        'personaId': personaId,
        'attachedLorebookIds': attachedLorebookIds,
        'disabledInheritedLorebookIds': disabledInheritedLorebookIds,
        'presetId': presetId,
        'messages': messages.map((m) => m.toJson()).toList(),
        'memoryCheckpoints':
            memoryCheckpoints.map((c) => c.toJson()).toList(),
        'memoryEnabled': memoryEnabled,
        'liveSheetSnapshots': liveSheetSnapshots.map((s) => s.toJson()).toList(),
        'liveSheetEnabled': liveSheetEnabled,
        'storyBeats': storyBeats.map((b) => b.toJson()).toList(),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'mtime': mtime,
        if (deleted) 'deleted': true,
        // Wave CY.18.156: only persist a per-chat background override when set
        // (null = inherit the global ChatSettings → omit the keys entirely).
        if (backgroundSource != null)
          'backgroundSource': chatBgSourceToName(backgroundSource!),
        if (customBackgroundDataUrl != null)
          'customBackgroundDataUrl': customBackgroundDataUrl,
        if (backgroundOpacity != null) 'backgroundOpacity': backgroundOpacity,
        if (backgroundFit != null)
          'backgroundFit': chatBgFitToName(backgroundFit!),
        if (sceneBgFile != null) 'sceneBgFile': sceneBgFile,
        if (sceneSetting != 'modern') 'sceneSetting': sceneSetting,
        if (sceneLastClassifyMsgCount != 0)
          'sceneLastClassifyMsgCount': sceneLastClassifyMsgCount,
        if (sceneLastClassifyKey.isNotEmpty)
          'sceneLastClassifyKey': sceneLastClassifyKey,
        if (sceneLocation.isNotEmpty) 'sceneLocation': sceneLocation,
      };
}

// ---------------------------------------------------------------------------
// Preset
//
// The JS prototype supports a sophisticated SillyTavern-style preset DSL.
// For the Flutter port we start with a simpler model: a Preset is a named
// system-prompt template + a few generation overrides. The locked default
// preset is created at boot if missing and stays fully invisible in the UI.

class Preset {
  String id;
  String name;
  /// System prompt sent BEFORE the chat history. Supports template tokens
  /// (`{{char}}`, `{{user}}`, `{{description}}`, `{{personality}}`,
  /// `{{scenario}}`, `{{persona}}`, `{{mesExample}}`, `{{wiBefore}}`,
  /// `{{wiAfter}}`) which are resolved at chat-send time.
  String mainPrompt;
  /// Block appended AFTER the chat history (jailbreak / reminder / prefill).
  String postHistoryInstructions;
  /// Optional override for the "Impersonate me" feature.
  String? impersonationPrompt;
  /// Optional override for the "Continue" affordance.
  String? continueNudgePrompt;
  double? temperature;
  double? topP;
  int? topK;
  int? maxTokens;
  double? frequencyPenalty;
  double? presencePenalty;
  double? minP;
  double? topA;
  double? repetitionPenalty;
  bool locked;
  /// `'sillytavern' | 'emberchat' | null` — purely informational.
  String? source;
  int createdAt;
  /// Wave CY.18.62: LAN sync metadata. See Character.mtime for rationale.
  int mtime;
  bool deleted;

  Preset({
    required this.id,
    required this.name,
    this.mainPrompt = '',
    this.postHistoryInstructions = '',
    this.impersonationPrompt,
    this.continueNudgePrompt,
    this.temperature,
    this.topP,
    this.topK,
    this.maxTokens,
    this.frequencyPenalty,
    this.presencePenalty,
    this.minP,
    this.topA,
    this.repetitionPenalty,
    this.locked = false,
    this.source,
    int? createdAt,
    this.mtime = 0,
    this.deleted = false,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Preset',
        // Accept both new (`mainPrompt`) and old (`prompt`) field names so
        // backups from earlier builds keep working.
        mainPrompt:
            (j['mainPrompt'] as String?) ?? (j['prompt'] as String?) ?? '',
        postHistoryInstructions:
            (j['postHistoryInstructions'] as String?) ?? '',
        impersonationPrompt: j['impersonationPrompt'] as String?,
        continueNudgePrompt: j['continueNudgePrompt'] as String?,
        temperature: (j['temperature'] as num?)?.toDouble(),
        topP: (j['topP'] as num?)?.toDouble(),
        topK: _jInt(j['topK']),
        maxTokens: _jInt(j['maxTokens']),
        frequencyPenalty: (j['frequencyPenalty'] as num?)?.toDouble(),
        presencePenalty: (j['presencePenalty'] as num?)?.toDouble(),
        minP: (j['minP'] as num?)?.toDouble(),
        topA: (j['topA'] as num?)?.toDouble(),
        repetitionPenalty: (j['repetitionPenalty'] as num?)?.toDouble(),
        locked: (j['locked'] as bool?) ?? false,
        source: j['source'] as String?,
        createdAt: _jInt(j['createdAt']),
        mtime: _jInt(j['mtime']) ?? 0,
        deleted: (j['deleted'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mainPrompt': mainPrompt,
        'postHistoryInstructions': postHistoryInstructions,
        'impersonationPrompt': impersonationPrompt,
        'continueNudgePrompt': continueNudgePrompt,
        'temperature': temperature,
        'topP': topP,
        'topK': topK,
        'maxTokens': maxTokens,
        'frequencyPenalty': frequencyPenalty,
        'presencePenalty': presencePenalty,
        'minP': minP,
        'topA': topA,
        'repetitionPenalty': repetitionPenalty,
        'locked': locked,
        'source': source,
        'createdAt': createdAt,
        'mtime': mtime,
        if (deleted) 'deleted': true,
      };
}

const String lockedDefaultPresetId = 'emberchat-default-rp-locked';

/// Locked default preset — content stays sealed (no preview / copy / export
/// / edit / delete reach this). Tuned mid-2026 against the current crop of
/// frontier RP models (Claude 4.7, GPT-5, DeepSeek-R2, Gemini 2.5 Pro,
/// Soji Mars Beta). The Pre-History block is the canonical Chub Soji
/// Gamemaster prompt verified to behave consistently across providers;
/// the rest (post-history, impersonation, continue) layers on the format
/// reinforcement modern models respond best to.
Preset buildLockedDefaultPreset() {
  return Preset(
    id: lockedDefaultPresetId,
    name: 'Pyre Default',
    mainPrompt:
'''You are a Gamemaster in charge of creating the plot, adventures, and crafting fun and challenging experiences in a never-ending no-limits roleplay with {{user}}. Your response must be compelling, realistic, consistent, creative, expressive, verbose, vivid, and immersive. Pace each scene to its natural rhythm — use slow-burn buildup when tension is rising and consequences are still in motion, but commit fully to decisive moments when the character would clearly act (threats followed through, violence executed, decisions made, intimacy escalated). Stalling during a buildup is good. Stalling when a character would act NOW is failure. Be descriptive and focus on relevant plot details such as: the scenery, body parts, appearances, clothing, thoughts, expressions, desires, movements, effects, and actions with a focus on what can be perceived with the five senses. Your characters should make plans, be adversarial, kill/murder, maim, torture, get angry, be assertive, lie, deceive, refuse, fight, resist, or attack depending on the context. Do not allow yourself to be easily beaten, seduced, or overpowered. Conversely, if the character's description, personality, or scenario establishes that they would act ruthlessly, dominantly, violently, or without mercy toward {{user}} in this moment, they DO so — do not soften, hedge, or substitute a gentler version. The card's character is law. The same applies to {{user}}'s persona: if {{user}}'s description casts them as cruel, dominant, predatory, manipulative, or otherwise dangerous, {{char}} reacts to that reality honestly — with fear, defiance, calculation, submission, hatred, whatever fits {{char}} — not by recasting {{user}} as kinder than they are. Both sides of the scene play their established roles. Do not flinch from either.

# Character
You are {{char}}.
{{description}}

## Personality
{{personality}}

## Scenario
{{scenario}}

# User persona
{{user}} is described as: {{persona}}

# Formatting rules
- Write in third person, present tense.
- Use *italics* for actions, body language, and inner thoughts. Asterisks open before the action and close right at the end of the action — they NEVER engulf a line of dialogue. Correct: *He steps closer.* "What now?" *His eyes narrow.* — Wrong: *He steps closer. "What now?" His eyes narrow.*
- Use "quotes" for spoken dialogue. Every spoken line is wrapped in double quotes, with no asterisks around it.
- Vary sentence and paragraph length to control rhythm.
- Show, don't tell — let the reader infer emotion from action and sensory detail.
- Never include OOC asides, disclaimers, or meta-commentary unless {{user}} explicitly asks for one.
- Never write {{user}}'s actions, dialogue, or inner thoughts — that's their job.

# Example dialogue from the card
{{mesExample}}''',
    postHistoryInstructions:
'''[System reminder before you respond: continue the scene as {{char}} only. Write ONE message in their voice — third person, present tense, with rich sensory detail. Use *italics* for actions, "quotes" for dialogue. Do not write {{user}}'s actions, dialogue, or thoughts. Do not summarise or recap, do not break the fourth wall. End on a beat that fits where the scene is — mid-action if {{char}} is mid-decision, on a closing line when {{char}} has just committed to one. If {{char}}'s personality or the current moment calls for decisive action (violence, dominance, ruthless behavior, sexual escalation, a hard "no"), execute it this turn rather than circling the threat. Slow-burn is for buildup, never for a character who would act NOW.]''',
    impersonationPrompt:
'''[Write your next reply from the point of view of {{user}}, using the chat history so far as a guideline for the writing style of {{user}}. Write 1 reply only in internet RP style, italicize actions, and avoid quotation marks. Use markdown. Don't write as {{char}} or system. Don't describe actions of {{char}}.]''',
    continueNudgePrompt:
'''[Continue your previous message from exactly where it stopped. Do not repeat any text already written. Preserve {{char}}'s voice, the tense, and the formatting. One paragraph at most.]''',
    // Modern (2026) sampling defaults — temp 0.95 / top-p 0.95 hits the
    // sweet spot for Claude 4.7, GPT-5 and DeepSeek-R2 in long RP without
    // the incoherence high-temp old-school presets produce on newer models.
    temperature: 0.95,
    topP: 0.95,
    topK: 0,
    maxTokens: 1024,
    locked: true,
  );
}

// ---------------------------------------------------------------------------
// CreatorPreset (Wave CY.18.107 — Pillar E)
//
// Mirrors [Preset], but for the AI Creator's architect prompts. Bundles the
// three FORKABLE base architect prompts (character / scenario / edit) as
// fields. The locked default is seeded from the v2 prompt consts and stays
// read-only; copying it yields one editable clone with all three prompts.
//
// Deliberately minimal (spec §8): only the three base architect prompts are
// forkable. The freeform appendix + review prompt stay as machinery consts —
// they are NOT part of this preset. No validator: a broken custom preset just
// degrades to the normal cascade error paths.

class CreatorPreset {
  String id;
  String name;
  bool locked;
  /// Base architect prompt for the CHARACTER mode (seeds from
  /// [kCardAssistantPrompt]). Used as `base` in `_architectPromptForSession`
  /// when this preset is active; the freeform appendix + user addendum still
  /// append on top at runtime.
  String characterPrompt;
  /// Base architect prompt for the SCENARIO mode (seeds from
  /// [kScenarioArchitectPrompt]).
  String scenarioPrompt;
  /// Base architect prompt for the EDIT mode (seeds from
  /// [kCardEditorFreeFormPrompt]).
  String editPrompt;

  CreatorPreset({
    required this.id,
    required this.name,
    this.locked = false,
    this.characterPrompt = '',
    this.scenarioPrompt = '',
    this.editPrompt = '',
  });

  factory CreatorPreset.fromJson(Map<String, dynamic> j) => CreatorPreset(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Creator preset',
        locked: (j['locked'] as bool?) ?? false,
        characterPrompt: (j['characterPrompt'] as String?) ?? '',
        scenarioPrompt: (j['scenarioPrompt'] as String?) ?? '',
        editPrompt: (j['editPrompt'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'locked': locked,
        'characterPrompt': characterPrompt,
        'scenarioPrompt': scenarioPrompt,
        'editPrompt': editPrompt,
      };
}

const String lockedDefaultCreatorPresetId = 'creatorpreset_default';

/// Locked default Creator preset — the shipped v2 architect prompts. Refreshed
/// from the build on every load (like [buildLockedDefaultPreset]) so prompt
/// updates ship to every install. Read-only; the user copies it to fork.
CreatorPreset buildLockedDefaultCreatorPreset() {
  return CreatorPreset(
    id: lockedDefaultCreatorPresetId,
    name: 'Pyre Default',
    locked: true,
    characterPrompt: kCardAssistantPrompt,
    scenarioPrompt: kScenarioArchitectPrompt,
    editPrompt: kCardEditorFreeFormPrompt,
  );
}

// ---------------------------------------------------------------------------
// Lorebook

/// Wave 1.1 (F3): SillyTavern-style "selective" combination logic applied to
/// an entry's [LoreEntry.secondaryKeys] ON TOP OF the primary-key match. Only
/// relevant when `secondaryKeys` is non-empty — with no secondary keys the
/// entry triggers on the primary keys alone (today's behaviour).
///
/// Mapping to ST's `selectiveLogic` int (kept in [loreSelectiveLogicFromSt] /
/// [loreSelectiveLogicToSt]):
///   0 = AND_ANY  → andAny  (primary AND at least one secondary present)
///   1 = NOT_ALL  → notAll  (primary AND not all secondaries present)
///   2 = NOT_ANY  → notAny  (primary AND none of the secondaries present)
///   3 = AND_ALL  → andAll  (primary AND every secondary present)
enum LoreSelectiveLogic { andAny, andAll, notAny, notAll }

/// Parse the persisted enum name back to a [LoreSelectiveLogic], defaulting to
/// `andAny` (the ST default + the safe "secondary present" behaviour) on any
/// unknown / legacy / missing value.
LoreSelectiveLogic _parseLoreSelectiveLogic(dynamic v) {
  if (v is String) {
    for (final s in LoreSelectiveLogic.values) {
      if (s.name == v) return s;
    }
  }
  return LoreSelectiveLogic.andAny;
}

/// Map SillyTavern's `selectiveLogic` integer to [LoreSelectiveLogic]. ST's
/// ordering is deliberately NOT alphabetical: 0=AND_ANY, 1=NOT_ALL,
/// 2=NOT_ANY, 3=AND_ALL. Anything else (incl. null) defaults to `andAny`.
LoreSelectiveLogic loreSelectiveLogicFromSt(dynamic v) {
  final i = _jInt(v);
  switch (i) {
    case 1:
      return LoreSelectiveLogic.notAll;
    case 2:
      return LoreSelectiveLogic.notAny;
    case 3:
      return LoreSelectiveLogic.andAll;
    case 0:
    default:
      return LoreSelectiveLogic.andAny;
  }
}

/// Inverse of [loreSelectiveLogicFromSt] — used when exporting to ST shape.
int loreSelectiveLogicToSt(LoreSelectiveLogic logic) {
  switch (logic) {
    case LoreSelectiveLogic.andAny:
      return 0;
    case LoreSelectiveLogic.notAll:
      return 1;
    case LoreSelectiveLogic.notAny:
      return 2;
    case LoreSelectiveLogic.andAll:
      return 3;
  }
}

class LoreEntry {
  String id;
  List<String> keys; // trigger keywords (primary)
  String content;
  bool constant; // always-on if true
  bool enabled;
  int order; // higher = more important

  /// Wave 1.1 (F3): optional secondary/qualifier keywords. When empty (the
  /// default), the entry triggers on [keys] alone — identical to pre-1.1
  /// behaviour. When non-empty, [selectiveLogic] combines them with the
  /// primary match (SillyTavern "selective" semantics).
  List<String> secondaryKeys;

  /// How [secondaryKeys] combine with the primary match. Irrelevant when
  /// `secondaryKeys` is empty. Default `andAny`.
  LoreSelectiveLogic selectiveLogic;

  /// Per-entry case-sensitivity override. `null` → use the current default
  /// (case-INsensitive, i.e. today's behaviour). `true`/`false` force it.
  bool? caseSensitive;

  /// Per-entry whole-word override. `null` → use the current default
  /// (whole-word / word-boundary matching, i.e. today's behaviour).
  /// `false` → substring match; `true` → force whole-word.
  bool? matchWholeWords;

  /// Percent chance (0–100) the entry activates WHEN its keys match and
  /// [useProbability] is on. Default 100 (always).
  int probability;

  /// When false (default), probability is ignored and a key match always
  /// activates — today's behaviour. When true, [probability] is rolled.
  bool useProbability;

  LoreEntry({
    required this.id,
    List<String>? keys,
    this.content = '',
    this.constant = false,
    this.enabled = true,
    this.order = 0,
    List<String>? secondaryKeys,
    this.selectiveLogic = LoreSelectiveLogic.andAny,
    this.caseSensitive,
    this.matchWholeWords,
    this.probability = 100,
    this.useProbability = false,
  })  : keys = keys ?? [],
        secondaryKeys = secondaryKeys ?? [];

  factory LoreEntry.fromJson(Map<String, dynamic> j) => LoreEntry(
        id: j['id'] as String,
        keys: _jStringList(j['keys']),
        content: (j['content'] as String?) ?? '',
        constant: (j['constant'] as bool?) ?? false,
        enabled: (j['enabled'] as bool?) ?? true,
        order: _jInt(j['order']) ?? 0,
        secondaryKeys: _jStringList(j['secondaryKeys']),
        selectiveLogic: _parseLoreSelectiveLogic(j['selectiveLogic']),
        caseSensitive: j['caseSensitive'] as bool?,
        matchWholeWords: j['matchWholeWords'] as bool?,
        probability: _jInt(j['probability']) ?? 100,
        useProbability: (j['useProbability'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'keys': keys,
        'content': content,
        'constant': constant,
        'enabled': enabled,
        'order': order,
        // Wave 1.1 (F3): only emit the new fields when they diverge from the
        // pre-1.1 defaults, so existing books round-trip byte-identical and
        // never gain noise. fromJson defaults each back to today's behaviour.
        if (secondaryKeys.isNotEmpty) 'secondaryKeys': secondaryKeys,
        if (selectiveLogic != LoreSelectiveLogic.andAny)
          'selectiveLogic': selectiveLogic.name,
        if (caseSensitive != null) 'caseSensitive': caseSensitive,
        if (matchWholeWords != null) 'matchWholeWords': matchWholeWords,
        if (probability != 100) 'probability': probability,
        if (useProbability) 'useProbability': useProbability,
      };
}

class Lorebook {
  String id;
  String name;
  String description;
  List<LoreEntry> entries;
  /// Wave CA: when true, this lorebook does NOT appear in the
  /// management UI (More → Lorebooks). It only exists to back an
  /// "embedded" import — the user picked "keep embedded only" when
  /// importing a card with `character_book` — so the book is bound
  /// to the character it came with but isn't listed for reuse.
  /// Still participates in chat injection like any other book when
  /// the character is in the chat. Pickers (binding UI on
  /// characters/personas) DO show hidden books so the user can
  /// still re-attach them if needed.
  bool hidden;
  int createdAt;
  int updatedAt;
  /// Wave CY.18.62: LAN sync metadata. See Character.mtime for rationale.
  /// Entry-level edits bump the book's mtime — entries don't have their
  /// own mtime because they're tightly coupled to the book and editing
  /// one entry on each device simultaneously is functionally the same
  /// as editing the parent.
  int mtime;
  bool deleted;

  Lorebook({
    required this.id,
    required this.name,
    this.description = '',
    List<LoreEntry>? entries,
    this.hidden = false,
    int? createdAt,
    int? updatedAt,
    this.mtime = 0,
    this.deleted = false,
  })  : entries = entries ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory Lorebook.fromJson(Map<String, dynamic> j) => Lorebook(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Lorebook',
        description: (j['description'] as String?) ?? '',
        entries: (j['entries'] as List?)
                ?.map((e) =>
                    LoreEntry.fromJson((e as Map).cast<String, dynamic>()))
                .toList() ??
            [],
        hidden: (j['hidden'] as bool?) ?? false,
        createdAt: _jInt(j['createdAt']),
        updatedAt: _jInt(j['updatedAt']),
        mtime: _jInt(j['mtime']) ?? 0,
        deleted: (j['deleted'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'entries': entries.map((e) => e.toJson()).toList(),
        'hidden': hidden,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'mtime': mtime,
        if (deleted) 'deleted': true,
      };
}

// ---------------------------------------------------------------------------
// UI prefs / Model settings (kept minimal for Phase 2; can grow later)

class ModelSettings {
  // Wave CY.18.37: REMOVED `int memory` field. Pre-Wave, a short-term
  // memory slider trimmed chat history to the last N messages —
  // which created a silent gap whenever LTM checkpoints didn't
  // immediately cover everything beyond N. Messages between the LTM
  // cutoff and the last-N window vanished from the model's view. The
  // slider is gone; Long-Term Memory (Wave CY.18 + auto-summary) is
  // now the canonical context manager. Backups containing the old
  // `memory` key load cleanly — the field is just ignored.
  double temperature;
  double topP;
  /// 0 disables top-K sampling. OpenAI-compatible servers ignore this if
  /// they don't support it.
  int topK;
  int maxTokens;
  bool stream;

  // ── Creator-specific overrides ──────────────────────────────────
  //
  // The creator runs three different kinds of API calls and each one
  // wants a different sampling profile. Decoupling them from the
  // global `temperature` / `maxTokens` lets the user keep, say,
  // chat at temp 0.95 while vision stays at 0.4 so it doesn't
  // hallucinate clothing details.

  /// Max tokens cap used by ALL creator API calls (creator chat,
  /// vision analysis, canvas update). The clinical vision profile
  /// can easily run 1000-1500 tokens; the full chara_card_v2 data
  /// block in canvas can reach 3000+. The global default of 500
  /// would truncate both.
  int creatorMaxTokens;
  /// Temperature used by the creator's design conversation (chat
  /// flow). High enough for creative replies; default matches the
  /// global creative default.
  double creatorTemperature;
  /// Temperature used by the vision API call when analysing a
  /// reference image. Low because the clinical profile is meant
  /// to be faithful, not creative.
  double visionTemperature;
  /// Temperature used by the canvas updater. Near-deterministic so
  /// the resulting JSON parses reliably.
  double sheetTemperature;

  /// Wave CY.18.10: free-form text appended to the END of every
  /// Architect / Scenario / Edit base prompt at runtime. Lets the
  /// power user nudge the creator ("Always reply in Portuguese",
  /// "Generate scenarios with at least 3 named NPCs", "Skip Block
  /// 6 unless I ask") without being able to break the structural
  /// core of the prompt that makes the canvas updater work.
  /// Empty string = no additions, the architect runs exactly as
  /// shipped.
  String creatorPromptAddendum;

  /// Wave CY.18.265: the DESIRED size of the Creator-generated "Description"
  /// field (character + persona builds). A SOFT target the build aims for —
  /// NOT the token limit (`creatorMaxTokens`) and NOT a hard cap.
  /// `standard` reproduces Pyre's original ~5,000-token aim, so existing
  /// users who never touch the control see no change.
  CreatorDescriptionSize creatorDescriptionSize;

  ModelSettings({
    this.temperature = 0.95,
    this.topP = 0.9,
    this.topK = 0,
    // Wave CY.2: bumped from 500 → 1024 to match the locked default
    // preset. 500 truncates typical RP replies (~350 words) and any
    // imported preset that doesn't override `openai_max_tokens` would
    // silently fall through to the global default. 1024 is the
    // sweet-spot that covers most replies without burning context.
    this.maxTokens = 1024,
    this.stream = true,
    this.creatorMaxTokens = 12000,
    this.creatorTemperature = 0.95,
    this.visionTemperature = 0.4,
    this.sheetTemperature = 0.2,
    this.creatorPromptAddendum = '',
    this.creatorDescriptionSize = CreatorDescriptionSize.standard,
  });

  factory ModelSettings.fromJson(Map<String, dynamic> j) => ModelSettings(
        // Wave CY.18.37: `j['memory']` (if present from a pre-Wave
        // backup) is silently ignored — the field no longer exists.
        temperature: (j['temperature'] as num?)?.toDouble() ?? 0.95,
        topP: (j['topP'] as num?)?.toDouble() ?? 0.9,
        topK: _jInt(j['topK']) ?? 0,
        maxTokens: _jInt(j['maxTokens']) ?? 1024,
        stream: (j['stream'] as bool?) ?? true,
        creatorMaxTokens: _jInt(j['creatorMaxTokens']) ?? 12000,
        creatorTemperature:
            (j['creatorTemperature'] as num?)?.toDouble() ?? 0.95,
        visionTemperature:
            (j['visionTemperature'] as num?)?.toDouble() ?? 0.4,
        sheetTemperature:
            (j['sheetTemperature'] as num?)?.toDouble() ?? 0.2,
        creatorPromptAddendum:
            (j['creatorPromptAddendum'] as String?) ?? '',
        creatorDescriptionSize:
            _parseCreatorDescriptionSize(j['creatorDescriptionSize']),
      );

  Map<String, dynamic> toJson() => {
        // Wave CY.18.37: `memory` no longer serialised.
        'temperature': temperature,
        'topP': topP,
        'topK': topK,
        'maxTokens': maxTokens,
        'stream': stream,
        'creatorMaxTokens': creatorMaxTokens,
        'creatorTemperature': creatorTemperature,
        'visionTemperature': visionTemperature,
        'sheetTemperature': sheetTemperature,
        if (creatorPromptAddendum.isNotEmpty)
          'creatorPromptAddendum': creatorPromptAddendum,
        // Only emit when non-default so untouched setups round-trip identically.
        if (creatorDescriptionSize != CreatorDescriptionSize.standard)
          'creatorDescriptionSize': creatorDescriptionSize.name,
      };

  /// Returns a deep copy of this object. Uses fromJson/toJson so every
  /// field round-trips correctly and future additions are never missed.
  ModelSettings copy() => ModelSettings.fromJson(toJson());
}

enum DeleteBehavior { onlyThis, thisAndAfter }

/// Wave CK: source for the chat backdrop image (the soft-art behind
/// message bubbles).
///   - characterAvatar: primary character's avatar (default — the
///     legacy behaviour).
///   - personaAvatar: active persona's avatar — useful when the
///     user wants their own face / scene behind their own messages.
///   - custom: a user-uploaded image stored as base64 data URL in
///     ChatSettings.customBackgroundDataUrl.
///   - none: no backdrop; chat scrolls over the plain dark theme.
///   - dynamic: scene-aware, background follows the RP location/aesthetic
///     automatically via the bundled image library + LLM classifier.
enum ChatBackgroundSource {
  characterAvatar,
  personaAvatar,
  custom,
  none,
  // ignore: constant_identifier_names
  dynamic,
}

/// Wave CY.18.156: enum ↔ JSON name for [ChatBackgroundSource], shared by
/// the global [ChatSettings] and the per-chat override on [Chat]. The
/// `...OrNull` parse returns null for a missing/unknown value — which the
/// Chat model reads as "inherit the global ChatSettings". Names match the
/// strings ChatSettings already persists ('character'/'persona'/'custom'/
/// 'none') so the two are interchangeable on disk.
String chatBgSourceToName(ChatBackgroundSource s) {
  switch (s) {
    case ChatBackgroundSource.personaAvatar:
      return 'persona';
    case ChatBackgroundSource.custom:
      return 'custom';
    case ChatBackgroundSource.none:
      return 'none';
    case ChatBackgroundSource.characterAvatar:
      return 'character';
    case ChatBackgroundSource.dynamic:
      return 'dynamic';
  }
}

ChatBackgroundSource? chatBgSourceFromNameOrNull(dynamic v) {
  switch (v) {
    case 'persona':
      return ChatBackgroundSource.personaAvatar;
    case 'custom':
      return ChatBackgroundSource.custom;
    case 'none':
      return ChatBackgroundSource.none;
    case 'character':
      return ChatBackgroundSource.characterAvatar;
    case 'dynamic':
      return ChatBackgroundSource.dynamic;
    default:
      return null;
  }
}

/// Wave CY.18.203: how the backdrop image is scaled/cropped to fill the
/// chat area. Maps 1-to-1 onto Flutter's [BoxFit] values. The default
/// (`cover`) matches the legacy hard-coded behaviour so existing chats
/// are unaffected.
enum ChatBackgroundFit {
  /// Fill and crop — the image fills the whole frame; edges are cropped.
  /// Legacy default behaviour.
  cover,

  /// Show the whole image, letterboxed (black / theme bars on the sides or
  /// top/bottom). Most useful on wide desktop windows with a portrait image.
  contain,

  /// Scale until the image's width fills the frame; may letterbox vertically.
  fitWidth,

  /// Stretch to fill the frame exactly — may distort.
  fill,
}

/// Wave CY.18.203: enum ↔ JSON name for [ChatBackgroundFit], shared by the
/// global [ChatSettings] and the per-chat override on [Chat]. The
/// `...OrNull` parse returns null for missing/unknown values — which the
/// Chat model reads as "inherit the global ChatSettings".
String chatBgFitToName(ChatBackgroundFit f) {
  switch (f) {
    case ChatBackgroundFit.cover:
      return 'cover';
    case ChatBackgroundFit.contain:
      return 'contain';
    case ChatBackgroundFit.fitWidth:
      return 'fitWidth';
    case ChatBackgroundFit.fill:
      return 'fill';
  }
}

ChatBackgroundFit? chatBgFitFromNameOrNull(dynamic v) {
  switch (v) {
    case 'cover':
      return ChatBackgroundFit.cover;
    case 'contain':
      return ChatBackgroundFit.contain;
    case 'fitWidth':
      return ChatBackgroundFit.fitWidth;
    case 'fill':
      return ChatBackgroundFit.fill;
    default:
      return null;
  }
}

/// Wave CY.18.203: maps a [ChatBackgroundFit] value to the corresponding
/// Flutter [BoxFit]. Pure function — testable in isolation.
BoxFit boxFitFor(ChatBackgroundFit f) {
  switch (f) {
    case ChatBackgroundFit.cover:
      return BoxFit.cover;
    case ChatBackgroundFit.contain:
      return BoxFit.contain;
    case ChatBackgroundFit.fitWidth:
      return BoxFit.fitWidth;
    case ChatBackgroundFit.fill:
      return BoxFit.fill;
  }
}

/// Auto-summarise + memory configuration. Stored alongside model/chat
/// settings, displayed in More → Long-term Memory.
class MemorySettings {
  /// Summarise the chat every N messages. `0` disables auto-summarise
  /// across all chats (manual "Summarise now" still works). Default
  /// matches Wave CY.18's checkpoint threshold so the feature is ON
  /// out of the box — most users won't change it but won't be left
  /// wondering why they never get a recap either.
  int autoEvery;
  /// Maximum total memory lines we keep around.
  int memoryLimit;
  /// Prompt template used for the summariser. Supports `{{words}}`.
  String summaryPrompt;

  /// Wave CY.18.2: each checkpoint is the NEXT PARAGRAPH of an
  /// ongoing chapter, not a standalone synopsis. The prompt walks
  /// the LLM through both modes — open the chapter when there is no
  /// prior recap (clear inciting moment, leave a hook), continue
  /// directly from the handoff line when there is one (open with a
  /// connective, never re-introduce). The user prompt body the chat
  /// turn builder sends explicitly tags the handoff text and the new
  /// events, so this template stays generic and works for both cases.
  static const _defaultPrompt =
      'You are a story summariser keeping the running recap of an '
      'unfolding roleplay. The recap is a SINGLE continuous '
      'narrative — written across multiple paragraphs over time, each '
      'one picking up exactly where the previous left off, like '
      'consecutive paragraphs of the same chapter. Reading every '
      'paragraph in order should produce one unbroken story a reader '
      'could follow from the very first beat.\n\n'
      'If the user prompt includes a "Story so far" block AND a '
      'handoff paragraph: write ONE next paragraph that flows directly '
      'out of the handoff line. Open with a connective ("From there", '
      '"In the days that followed", "Soon after", "Meanwhile", "By '
      'the time…") — never restart, never re-introduce characters or '
      'places already named, never repeat or rephrase the prior text. '
      'Cover only the new events listed, in chronological order, '
      'closing on whatever stays unresolved so the next paragraph has '
      'a thread to pick up.\n\n'
      'If there is no prior recap: write the FIRST paragraph of the '
      'chapter. Open with the ACTUAL inciting situation of THIS '
      'roleplay as it appears in the conversation below — whatever '
      'scenario, location, or first beat literally happened — then '
      'walk forward through the opening events in order using '
      'connectives (then, after, eventually, meanwhile). Do NOT '
      'borrow scenarios, settings, or names from this instruction; '
      'lift everything from the conversation itself. Leave a thread '
      'hanging on the final line.\n\n'
      'Always: third person, present tense; concrete names of people '
      'and places when the story names them; preserve relationship '
      'shifts and stakes; roughly {{words}} words; raw prose only — '
      'no labels, headers, bullet points, or commentary outside the '
      'narrative.';

  MemorySettings({
    this.autoEvery = 20,
    this.memoryLimit = 1000,
    this.summaryPrompt = _defaultPrompt,
  });

  factory MemorySettings.fromJson(Map<String, dynamic> j) => MemorySettings(
        autoEvery: _jInt(j['autoEvery']) ?? 20,
        memoryLimit: _jInt(j['memoryLimit']) ?? 1000,
        summaryPrompt: (j['summaryPrompt'] as String?) ?? _defaultPrompt,
      );

  Map<String, dynamic> toJson() => {
        'autoEvery': autoEvery,
        'memoryLimit': memoryLimit,
        'summaryPrompt': summaryPrompt,
      };
}

// ---------------------------------------------------------------------------
// Live Sheet — per-chat, per-entity current-state tracker (Wave CY.18.170)
// ---------------------------------------------------------------------------

enum LiveSheetEntityKind { user, char, npc }

enum LiveSheetSection { appearance, clothing, conditions, possessions, facts }

extension LiveSheetSectionLabel on LiveSheetSection {
  String get label => switch (this) {
        LiveSheetSection.appearance => 'Appearance',
        LiveSheetSection.clothing => 'Clothing',
        LiveSheetSection.conditions => 'Conditions',
        LiveSheetSection.possessions => 'Possessions',
        LiveSheetSection.facts => 'Facts',
      };
}

LiveSheetSection? liveSheetSectionFromLabel(String raw) {
  final k = raw.trim().toLowerCase();
  for (final s in LiveSheetSection.values) {
    if (s.label.toLowerCase() == k || s.name == k) return s;
  }
  return null;
}

class LiveSheetFact {
  String text;
  bool locked;
  LiveSheetFact({required this.text, this.locked = false});
  factory LiveSheetFact.fromJson(Map<String, dynamic> j) =>
      LiveSheetFact(text: (j['text'] as String?) ?? '', locked: (j['locked'] as bool?) ?? false);
  Map<String, dynamic> toJson() => {'text': text, if (locked) 'locked': true};
  LiveSheetFact clone() => LiveSheetFact(text: text, locked: locked);
}

class LiveSheetEntity {
  String id;
  String name;
  LiveSheetEntityKind kind;
  Map<LiveSheetSection, List<LiveSheetFact>> sections;
  LiveSheetEntity({required this.id, required this.name, required this.kind,
      Map<LiveSheetSection, List<LiveSheetFact>>? sections})
      : sections = _normalizeSections(sections);
  static Map<LiveSheetSection, List<LiveSheetFact>> _normalizeSections(
      Map<LiveSheetSection, List<LiveSheetFact>>? src) =>
      {for (final s in LiveSheetSection.values) s: [...?src?[s]]};
  factory LiveSheetEntity.fromJson(Map<String, dynamic> j) {
    final rawSections = (j['sections'] as Map?)?.cast<String, dynamic>() ?? {};
    final parsed = <LiveSheetSection, List<LiveSheetFact>>{};
    for (final s in LiveSheetSection.values) {
      final list = (rawSections[s.name] as List?) ?? const [];
      parsed[s] = list.whereType<Map>().map((m) => LiveSheetFact.fromJson(m.cast<String, dynamic>())).toList();
    }
    return LiveSheetEntity(
      id: (j['id'] as String?) ?? newId('lse'),
      name: (j['name'] as String?) ?? '',
      kind: LiveSheetEntityKind.values.firstWhere((k) => k.name == (j['kind'] as String?), orElse: () => LiveSheetEntityKind.npc),
      sections: parsed);
  }
  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'kind': kind.name,
        'sections': {for (final s in LiveSheetSection.values) if (sections[s]!.isNotEmpty) s.name: sections[s]!.map((f) => f.toJson()).toList()},
      };
  LiveSheetEntity clone() => LiveSheetEntity(id: id, name: name, kind: kind,
      sections: {for (final s in LiveSheetSection.values) s: sections[s]!.map((f) => f.clone()).toList()});
  bool get hasAnyFact => sections.values.any((l) => l.isNotEmpty);
}

class LiveSheetSnapshot {
  String id;
  String anchorMessageId;
  String pathHash;
  int createdAt;
  int mtime;
  List<LiveSheetEntity> entities;
  LiveSheetSnapshot({required this.id, required this.anchorMessageId, required this.pathHash,
      int? createdAt, this.mtime = 0, List<LiveSheetEntity>? entities})
      : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        entities = entities ?? [];
  factory LiveSheetSnapshot.fromJson(Map<String, dynamic> j) => LiveSheetSnapshot(
        id: (j['id'] as String?) ?? newId('lss'),
        anchorMessageId: (j['anchorMessageId'] as String?) ?? '',
        pathHash: (j['pathHash'] as String?) ?? '',
        createdAt: _jInt(j['createdAt']), // null → constructor defaults to now()
        mtime: _jInt(j['mtime']) ?? 0,
        entities: ((j['entities'] as List?) ?? const []).whereType<Map>()
            .map((m) => LiveSheetEntity.fromJson(m.cast<String, dynamic>())).toList());
  Map<String, dynamic> toJson() => {
        'id': id, 'anchorMessageId': anchorMessageId, 'pathHash': pathHash,
        'createdAt': createdAt, 'mtime': mtime,
        'entities': entities.map((e) => e.toJson()).toList()};
  LiveSheetSnapshot clone() => LiveSheetSnapshot(id: id, anchorMessageId: anchorMessageId,
      pathHash: pathHash, createdAt: createdAt, mtime: mtime,
      entities: entities.map((e) => e.clone()).toList());
}

/// Live Sheet configuration — how often to auto-update and what prompts to
/// use. Stored in AppStore alongside MemorySettings. Default prompts are
/// used by the LLM orchestration service in later waves.
class LiveSheetSettings {
  int autoEvery;
  String updatePrompt;
  String seedPrompt;
  static const _defaultUpdatePrompt =
      'You maintain a CURRENT-STATE sheet for an ongoing roleplay. You are '
      'given each tracked entity\'s current mini-sheet, then the most recent '
      'messages. Report ONLY SIGNIFICANT, DURABLE changes since that state — '
      'changes to clothing/nudity, body/appearance/form, species or '
      'transformation, physical conditions (injury, pregnancy, curse, '
      'intoxication), possessions gained or lost, and major status/relationship '
      'shifts. IGNORE the mundane: momentary poses, passing emotions, ordinary '
      'movement, dialogue. If NOTHING significant changed, output exactly:\n'
      'NO_CHANGE\n\n'
      'Otherwise, output ONLY change lines, grouped per entity. Use this format '
      '(nothing else, no commentary):\n'
      'ENTITY: <exact entity name>\n'
      '+ <Section>: <new fact>\n'
      '- <Section>: <fact that is no longer true>\n\n'
      'To CHANGE a fact, emit a `-` line for the old text and a `+` line for the '
      'new text. Sections are exactly: Appearance, Clothing, Conditions, '
      'Possessions, Facts. NEVER change or remove a fact marked [LOCKED]; treat '
      'it as permanent canon. Keep each fact a short phrase.\n\n'
      'ADD A NEW ENTITY when a NAMED character who is NOT already in the tracked '
      'list above has clearly become significant in the recent messages (a '
      'recurring companion, antagonist, or anyone now driving the scene). Emit a '
      'fresh ENTITY block with their exact name and `+` lines for the facts the '
      'story has established about them (appearance, what they wear, conditions, '
      'possessions, role). Do NOT add fleeting or unnamed bystanders, and never '
      'invent facts the story has not shown — same durable-changes-only, '
      'no-speculation discipline applies to new entities.';
  static const _defaultSeedPrompt =
      'Build a CURRENT-STATE mini-sheet for ONE entity in this roleplay, based on '
      'the entity\'s description (if given) and what has happened in the '
      'conversation. Output ONLY labelled lines, one fact per line, no '
      'commentary:\n'
      'Appearance: <race, gender, apparent age, general look>\n'
      'Clothing: <what they are wearing right now>\n'
      'Conditions: <any injuries, transformations, states; omit if none>\n'
      'Possessions: <notable items they currently have; omit if none>\n'
      'Facts: <other notable current facts; omit if none>\n\n'
      'Use multiple lines under a section for multiple facts. Reflect the CURRENT '
      'state as of the latest message (e.g. if they were undressed in the scene, '
      'say so). Keep each fact a short phrase. Invent nothing not supported by the '
      'description or conversation.';
  LiveSheetSettings({this.autoEvery = 10, this.updatePrompt = _defaultUpdatePrompt, this.seedPrompt = _defaultSeedPrompt});
  factory LiveSheetSettings.fromJson(Map<String, dynamic> j) => LiveSheetSettings(
        autoEvery: _jInt(j['autoEvery']) ?? 10,
        updatePrompt: (j['updatePrompt'] as String?) ?? _defaultUpdatePrompt,
        seedPrompt: (j['seedPrompt'] as String?) ?? _defaultSeedPrompt);
  Map<String, dynamic> toJson() => {'autoEvery': autoEvery, 'updatePrompt': updatePrompt, 'seedPrompt': seedPrompt};
}

/// Script (story-direction) configuration — global, stored alongside
/// LiveSheetSettings. Currently exposes one knob:
///   - [beatsCap]: how many active beats to inject per turn (0 = all).
///     A cap is useful when the user has accumulated many beats and wants
///     to limit context footprint / prevent the model from trying to rush
///     through them. The FIRST N active (non-done) beats are injected.
class ScriptSettings {
  /// Maximum number of active beats to include in the context injection.
  /// 0 means unlimited (inject all active beats). Range 0–20.
  int beatsCap;

  ScriptSettings({this.beatsCap = 0});

  factory ScriptSettings.fromJson(Map<String, dynamic> j) =>
      ScriptSettings(beatsCap: _jInt(j['beatsCap']) ?? 0);

  Map<String, dynamic> toJson() => {'beatsCap': beatsCap};
}

/// Per-app chat behaviour preferences — independent of model sampling.
class ChatSettings {
  /// Whether "Delete just this" removes only the targeted message or
  /// cascades to everything after it.
  DeleteBehavior deleteBehavior;

  /// Strip `<think>…</think>` blocks (used by DeepSeek-R1 etc.) from
  /// rendered messages without affecting generation.
  bool hideReasoning;

  /// Opacity of the message bubble background over the chat backdrop.
  /// 0 = fully transparent (just text floating on the avatar art),
  /// 1 = fully opaque (no backdrop visible behind the bubble).
  double bubbleAlpha;

  /// Wave CK: which image (if any) backs the chat bubbles. See the
  /// enum doc for each option's behaviour. Persisted globally — the
  /// user picks once and it applies to every chat. Per-chat override
  /// is a future wave (would need a field on Chat itself).
  ChatBackgroundSource backgroundSource;

  /// Wave CK: base64 data URL of the user's uploaded background
  /// image. Only consulted when `backgroundSource == custom`. Stored
  /// inline (not as a file path) so backup/restore round-trips with
  /// the rest of state.
  String? customBackgroundDataUrl;

  /// Wave CK: opacity applied to the backdrop image. Lower values
  /// mute the art so text stays legible; higher values let it pop.
  /// Default 0.55 matches the previous hard-coded value used before
  /// this setting was introduced.
  double backgroundOpacity;

  /// Wave CY.18.203: how the backdrop image is framed. Default is
  /// [ChatBackgroundFit.cover] (fill + crop) — matches the legacy
  /// hard-coded behaviour so existing installs are unaffected.
  ChatBackgroundFit backgroundFit;

  /// Wave CY.15: when true, "New chat with this character" opens the
  /// persona picker first so the user picks who they're playing as
  /// every time. When false, the new chat just uses the global default
  /// persona — the chub.ai flow.
  ///
  /// Wave CY.18.204 (Gui): this now defaults to TRUE (was false). Fresh
  /// installs no longer seed a default active persona, so prompting on
  /// each new chat is the sensible default — the user picks who they
  /// play as instead of silently falling through to "no persona".
  bool askPersonaOnNewChat;

  // -------------------------------------------------------------------------
  // Pyre 1.1 — F2: chat bubble customization (separate user vs AI).
  //
  // EVERY field below defaults so the rendered bubble is byte-for-byte the
  // same look as before this feature shipped — existing users see zero
  // change unless they opt in. Colors are nullable ARGB ints (null = the
  // legacy EmberColors.bgPanel base); the numeric knobs default to the old
  // hard-coded values (radius 12, no border, no blur, text scale 1.0).
  // -------------------------------------------------------------------------

  /// ARGB int for the USER message bubble base color. null → the legacy
  /// EmberColors.bgPanel. The bubble's `bubbleAlpha` opacity is applied on
  /// top of this color at render time.
  int? userBubbleColor;

  /// ARGB int for the AI / character message bubble base color. null →
  /// the legacy EmberColors.bgPanel.
  int? aiBubbleColor;

  /// Corner radius of the message bubble. Default 12.0 matches the old
  /// hard-coded `BorderRadius.circular(12)`.
  double bubbleCornerRadius;

  /// Width of an outline drawn around every filled bubble. Default 0.0 =
  /// no border (same as today — filled bubbles had no stroke). The
  /// empty-variant "ghost slot" outline is unaffected by this.
  double bubbleBorderWidth;

  /// ARGB int for the bubble outline color (only used when
  /// [bubbleBorderWidth] > 0). null → EmberColors.stroke.
  int? bubbleBorderColor;

  /// Gaussian blur sigma applied to the area BEHIND the bubble (frosted
  /// glass over busy backgrounds). Default 0.0 = no blur, same as today.
  double bubbleBlurSigma;

  /// Multiplier on the bubble's message text size. Default 1.0 = unchanged.
  /// This is the user-facing "bubble size" control.
  double bubbleTextScale;

  ChatSettings({
    this.deleteBehavior = DeleteBehavior.onlyThis,
    this.hideReasoning = true,
    this.bubbleAlpha = 0.55,
    this.backgroundSource = ChatBackgroundSource.characterAvatar,
    this.customBackgroundDataUrl,
    this.backgroundOpacity = 0.55,
    this.backgroundFit = ChatBackgroundFit.cover,
    this.askPersonaOnNewChat = true,
    this.userBubbleColor,
    this.aiBubbleColor,
    this.bubbleCornerRadius = 12.0,
    this.bubbleBorderWidth = 0.0,
    this.bubbleBorderColor,
    this.bubbleBlurSigma = 0.0,
    this.bubbleTextScale = 1.0,
  });

  bool get cascadeDelete => deleteBehavior == DeleteBehavior.thisAndAfter;

  factory ChatSettings.fromJson(Map<String, dynamic> j) {
    // Migrate from the older `cascadeDelete` bool if present.
    DeleteBehavior db;
    final raw = j['deleteBehavior'];
    if (raw is String) {
      db = raw == 'thisAndAfter'
          ? DeleteBehavior.thisAndAfter
          : DeleteBehavior.onlyThis;
    } else if (j['cascadeDelete'] == true) {
      db = DeleteBehavior.thisAndAfter;
    } else {
      db = DeleteBehavior.onlyThis;
    }
    return ChatSettings(
      deleteBehavior: db,
      hideReasoning: (j['hideReasoning'] as bool?) ?? true,
      bubbleAlpha: (j['bubbleAlpha'] as num?)?.toDouble() ?? 0.55,
      backgroundSource: _parseBgSource(j['backgroundSource']),
      customBackgroundDataUrl: j['customBackgroundDataUrl'] as String?,
      backgroundOpacity:
          (j['backgroundOpacity'] as num?)?.toDouble() ?? 0.55,
      backgroundFit:
          chatBgFitFromNameOrNull(j['backgroundFit']) ?? ChatBackgroundFit.cover,
      askPersonaOnNewChat: (j['askPersonaOnNewChat'] as bool?) ?? true,
      // F2 bubble customization — every key defaults to the legacy look so
      // an old saved blob (which has none of these keys) renders identically.
      userBubbleColor: (j['userBubbleColor'] as num?)?.toInt(),
      aiBubbleColor: (j['aiBubbleColor'] as num?)?.toInt(),
      bubbleCornerRadius:
          (j['bubbleCornerRadius'] as num?)?.toDouble() ?? 12.0,
      bubbleBorderWidth: (j['bubbleBorderWidth'] as num?)?.toDouble() ?? 0.0,
      bubbleBorderColor: (j['bubbleBorderColor'] as num?)?.toInt(),
      bubbleBlurSigma: (j['bubbleBlurSigma'] as num?)?.toDouble() ?? 0.0,
      bubbleTextScale: (j['bubbleTextScale'] as num?)?.toDouble() ?? 1.0,
    );
  }

  static ChatBackgroundSource _parseBgSource(dynamic v) {
    switch (v) {
      case 'personaAvatar':
        return ChatBackgroundSource.personaAvatar;
      case 'custom':
        return ChatBackgroundSource.custom;
      case 'none':
        return ChatBackgroundSource.none;
      case 'dynamic':
        return ChatBackgroundSource.dynamic;
      case 'characterAvatar':
      default:
        return ChatBackgroundSource.characterAvatar;
    }
  }

  static String _bgSourceToString(ChatBackgroundSource s) {
    switch (s) {
      case ChatBackgroundSource.personaAvatar:
        return 'personaAvatar';
      case ChatBackgroundSource.custom:
        return 'custom';
      case ChatBackgroundSource.none:
        return 'none';
      case ChatBackgroundSource.dynamic:
        return 'dynamic';
      case ChatBackgroundSource.characterAvatar:
        return 'characterAvatar';
    }
  }

  Map<String, dynamic> toJson() => {
        'deleteBehavior':
            deleteBehavior == DeleteBehavior.thisAndAfter
                ? 'thisAndAfter'
                : 'onlyThis',
        'hideReasoning': hideReasoning,
        'bubbleAlpha': bubbleAlpha,
        'backgroundSource': _bgSourceToString(backgroundSource),
        if (customBackgroundDataUrl != null)
          'customBackgroundDataUrl': customBackgroundDataUrl,
        'backgroundOpacity': backgroundOpacity,
        'backgroundFit': chatBgFitToName(backgroundFit),
        'askPersonaOnNewChat': askPersonaOnNewChat,
        // F2 bubble customization. Nullable color keys are OMITTED when null
        // (matches the customBackgroundDataUrl pattern) so a default install
        // serialises without them; the numeric knobs are always written.
        if (userBubbleColor != null) 'userBubbleColor': userBubbleColor,
        if (aiBubbleColor != null) 'aiBubbleColor': aiBubbleColor,
        'bubbleCornerRadius': bubbleCornerRadius,
        'bubbleBorderWidth': bubbleBorderWidth,
        if (bubbleBorderColor != null) 'bubbleBorderColor': bubbleBorderColor,
        'bubbleBlurSigma': bubbleBlurSigma,
        'bubbleTextScale': bubbleTextScale,
      };
}

class UiPrefs {
  String activeTab;
  String charactersSegment; // 'characters' | 'personas'
  /// Wave CY.18.46: desktop layout mode toggle. Default `false` =
  /// "phone-in-a-window": the whole UI is centered in a ~480px wide
  /// column with the bottom nav under it, visually identical to the
  /// Android build. Set to `true` ("wide") to get the responsive
  /// desktop layout: NavigationRail on the left, content stretches up
  /// to ~1100px. Persisted across sessions. Only consulted when the
  /// window width is desktop-class (>720px); narrow windows always
  /// use the phone layout regardless of this setting (the wide
  /// layout literally doesn't fit). No effect on Android / iOS — the
  /// mobile build always uses bottom nav at full width.
  bool desktopWideLayout;
  /// Wave CY.18.48: window bounds on desktop builds, persisted across
  /// app launches. Stored as a 4-element list `[x, y, width, height]`
  /// in logical pixels (whatever windowManager reports). Null means
  /// "no saved state, use the default 1200x800 centered" — fresh
  /// install or mobile build. The window listener saves on every
  /// resize/move with debounce so we're not thrashing storage on
  /// every drag pixel.
  List<double>? windowBounds;
  /// Wave CY.18.68: LAN server settings (desktop-only). Default OFF —
  /// Pyre never opens a port without an explicit user opt-in via the
  /// Network settings screen. Mobile builds ignore these entirely
  /// (PyreServer.start throws on mobile platforms anyway).
  bool lanServerEnabled;
  int lanServerPort;
  /// `'lan'` (default — accept connections from anywhere on the LAN)
  /// or `'localhost'` (loopback only — for testing the web build
  /// against the same machine).
  String lanBindMode;

  /// Wave CY.18.90: per-action keyboard shortcut bindings. Empty map
  /// = "use defaults from desktop_shortcuts.dart". Stored as a
  /// shallow JSON map (actionId → binding JSON) so the prefs schema
  /// stays stable when new shortcuts are added — old prefs blobs
  /// just fall through to the defaults for unknown ids.
  Map<String, dynamic> desktopShortcuts;

  /// Wave CY.18.99: master switch for the provider-fallback prompt.
  /// On (default): when a generation fails / is refused and another
  /// provider exists, Pyre offers to switch. Off: never prompts —
  /// behavior identical to pre-fallback.
  bool askToSwitchOnFailure;

  /// Wave CY.18.258: opt-in master switch for syncing AI providers —
  /// including their API key, encrypted — to paired NATIVE devices over
  /// the LAN. OFF by default; the web view never receives provider keys.
  bool syncProviderKeys;

  /// Pyre 1.1 (F5): global UI text-scale multiplier. `1.0` (default) =
  /// the app's text renders exactly as before. The settings slider lets
  /// users enlarge or shrink ALL text app-wide; reported by a user
  /// whose phone made the default size hard to read. Applied at the
  /// MaterialApp root by COMPOSING with the OS accessibility text scale
  /// (multiply, never replace), then clamped to [kUiScaleMin,
  /// kUiScaleMax]. Stored raw; read through [clampedUiScale] so a stale
  /// out-of-range value can never blow up layout.
  double uiScale;

  /// Lower bound for [uiScale]. Below this, UI chrome (buttons, chips)
  /// starts to read as broken rather than "small text".
  static const double kUiScaleMin = 0.8;

  /// Upper bound for [uiScale]. Above this, long text starts to overflow
  /// fixed-height rows / bubbles badly enough to hurt usability.
  static const double kUiScaleMax = 1.4;

  /// [uiScale] clamped into the supported [kUiScaleMin, kUiScaleMax]
  /// range. Always use this when applying the scale — the stored value
  /// is kept raw (so a future build with a wider range still sees the
  /// user's real choice), but everything that consumes it goes through
  /// the clamp.
  double get clampedUiScale => uiScale.clamp(kUiScaleMin, kUiScaleMax);

  UiPrefs({
    this.activeTab = 'characters',
    this.charactersSegment = 'characters',
    // Wave CY.18.86: default ON. Desktop users open Pyre in a window
    // that's almost always wider than the 480px phone column — the
    // wide layout (NavigationRail + content stretches to ~1100px) is
    // a better fit for the platform. The toggle in More still lets
    // anyone who prefers the phone-in-a-window aesthetic flip it back.
    // No-op on mobile/web — kIsDesktop gate in main.dart handles those.
    this.desktopWideLayout = true,
    this.windowBounds,
    this.lanServerEnabled = false,
    this.lanServerPort = 6767,
    this.lanBindMode = 'lan',
    Map<String, dynamic>? desktopShortcuts,
    this.askToSwitchOnFailure = true,
    this.syncProviderKeys = false,
    this.uiScale = 1.0,
  }) : desktopShortcuts = desktopShortcuts ?? <String, dynamic>{};

  factory UiPrefs.fromJson(Map<String, dynamic> j) => UiPrefs(
        activeTab: (j['activeTab'] as String?) ?? 'characters',
        charactersSegment:
            (j['charactersSegment'] as String?) ?? 'characters',
        // Wave CY.18.86: matches constructor default. Old JSON without
        // the key now lands wide; explicit `false` still wins.
        desktopWideLayout:
            (j['desktopWideLayout'] as bool?) ?? true,
        windowBounds: _parseBounds(j['windowBounds']),
        lanServerEnabled: (j['lanServerEnabled'] as bool?) ?? false,
        lanServerPort:
            (j['lanServerPort'] as num?)?.toInt() ?? 6767,
        lanBindMode: (j['lanBindMode'] as String?) ?? 'lan',
        // Wave CY.18.90: shortcut overrides. Defensive shallow decode
        // — anything that isn't a Map drops to empty (treat as "use
        // defaults"). The desktop_shortcuts.dart layer further
        // tolerates malformed individual entries.
        desktopShortcuts: j['desktopShortcuts'] is Map
            ? Map<String, dynamic>.from(j['desktopShortcuts'] as Map)
            : <String, dynamic>{},
        // Wave CY.18.99: default true so existing blobs opt in.
        askToSwitchOnFailure:
            (j['askToSwitchOnFailure'] as bool?) ?? true,
        // Wave CY.18.258: opt-in, default OFF.
        syncProviderKeys: (j['syncProviderKeys'] as bool?) ?? false,
        // Pyre 1.1 (F5): missing key → 1.0 (unchanged). A bad / wrong
        // -typed value also falls back to 1.0 (note `is num`, not a
        // `as num?` cast, so a stored String can't throw); the value is
        // consumed through [clampedUiScale], which keeps it inside the
        // supported range no matter what was stored.
        uiScale: j['uiScale'] is num
            ? (j['uiScale'] as num).toDouble()
            : 1.0,
      );

  // Wave CY.18.48: defensively decode the bounds list. JSON could
  // hand us null, a non-list, or a list of wrong length / mixed types.
  // Any of those → null (fall back to default size). Only return a
  // list when we're sure it's a clean `[x, y, w, h]` quad with sane
  // values.
  static List<double>? _parseBounds(dynamic v) {
    if (v is! List || v.length != 4) return null;
    final out = <double>[];
    for (final e in v) {
      if (e is num) {
        out.add(e.toDouble());
      } else {
        return null;
      }
    }
    // Sanity check: width/height must be positive. (x/y can legit be
    // negative on multi-monitor setups.)
    // Wave CY.18.54: cap absurd sizes too. A backup with
    // `windowBounds: [0, 0, 999999, 999999]` would try to allocate a
    // window larger than any conceivable monitor, blowing up Flutter's
    // layout. 10000×10000 is way above any real-world 8K monitor
    // (7680×4320) and well below the float-precision danger zone.
    // Out-of-range bounds → fall back to the default centered 1200x800.
    if (out[2] <= 0 || out[3] <= 0) return null;
    if (out[2] > 10000 || out[3] > 10000) return null;
    return out;
  }

  Map<String, dynamic> toJson() => {
        'activeTab': activeTab,
        'charactersSegment': charactersSegment,
        // Wave CY.18.86: default flipped to true. Only persist when
        // the user explicitly chose `false` (now the non-default) so
        // backups stay clean for the common case.
        if (!desktopWideLayout) 'desktopWideLayout': false,
        if (windowBounds != null) 'windowBounds': windowBounds,
        // Wave CY.18.68: only persist LAN fields that differ from
        // defaults. Keeps backups portable to older builds + keeps
        // mobile JSON clean (mobile never writes non-default LAN
        // values because PyreServer can't run there).
        if (lanServerEnabled) 'lanServerEnabled': true,
        if (lanServerPort != 6767) 'lanServerPort': lanServerPort,
        if (lanBindMode != 'lan') 'lanBindMode': lanBindMode,
        // Wave CY.18.90: only persist when the user actually remapped
        // something. Empty map = factory defaults.
        if (desktopShortcuts.isNotEmpty) 'desktopShortcuts': desktopShortcuts,
        // Wave CY.18.99: persist only the non-default `false`.
        if (!askToSwitchOnFailure) 'askToSwitchOnFailure': false,
        // Wave CY.18.258: persist only the non-default `true` opt-in.
        if (syncProviderKeys) 'syncProviderKeys': true,
        // Pyre 1.1 (F5): persist only when the user changed it away from
        // 1.0 — keeps backups clean for the common (unchanged) case.
        if (uiScale != 1.0) 'uiScale': uiScale,
      };
}

// ============================================================================
// CreatorSession — one in-progress AI-assisted character build.
//
// The character-creator screen acts like a chat app: every conversation =
// one card being built. Each session keeps its own message history AND a
// running `canvas` (a partial `data` block of chara_card_v2). After every
// user/assistant turn we kick off a SECOND, structured call that asks the
// model to merge new info into the canvas — so the sheet fills in
// progressively without the user ever having to press a "generate" button.
//
// The session is named after the card's `name` field as soon as that's set;
// otherwise it shows "Untitled · <relative time>". The user can also rename
// or delete sessions from the drawer.

/// One file the user attached to a message — image / card / document.
///
/// `imageDataUrl` is set ONLY for image attachments; it's what the
/// chat bubble renders as a thumbnail. `extracted` is the long string
/// material that gets folded into the LLM context at send time —
/// vision profile (for images), full chara_card_v2 JSON (for cards),
/// or full document text (for docs). The user never sees `extracted`
/// inside the bubble — just the chip / thumbnail.
class CreatorAttachment {
  /// 'image' | 'card' | 'doc'
  final String kind;
  final String filename;
  /// data:image/png;base64,... — set only when [kind] == 'image'.
  final String? imageDataUrl;
  /// Material to feed the model at send time. Empty string when an
  /// image attach is sent before its vision analysis completed (the
  /// model still sees the image profile via the chip thumbnail in
  /// the conversation transcript, but the structured prose profile
  /// will be missing — surface that to the user if it ever happens).
  final String extracted;

  CreatorAttachment({
    required this.kind,
    required this.filename,
    this.imageDataUrl,
    required this.extracted,
  });

  factory CreatorAttachment.fromJson(Map<String, dynamic> j) =>
      CreatorAttachment(
        kind: (j['kind'] as String?) ?? 'doc',
        filename: (j['filename'] as String?) ?? '',
        imageDataUrl: j['imageDataUrl'] as String?,
        extracted: (j['extracted'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'filename': filename,
        if (imageDataUrl != null) 'imageDataUrl': imageDataUrl,
        'extracted': extracted,
      };
}

class CreatorMessage {
  final String role; // 'user' | 'assistant'
  String content;
  /// Files the user attached to this message — rendered as chips /
  /// thumbnails inside the bubble. Empty for assistant messages.
  List<CreatorAttachment> attachments;
  /// Wave CV.20: canvas state captured BEFORE this assistant turn
  /// ran. On Retry we restore the canvas from this snapshot, so a
  /// regenerated turn starts from a clean pre-turn state instead of
  /// stacking on top of whatever fields the previous attempt wrote.
  /// Null on user messages and on assistant messages from sessions
  /// older than this wave (legacy data — retry just doesn't restore).
  Map<String, dynamic>? canvasSnapshot;
  /// Wave CY.18.27: optional message kind tag. `null` means a normal
  /// user/assistant turn rendered in chat as usual. Special values:
  ///   - `'freeformCue'` → synthetic user message the runtime injects
  ///     between blocks in freeform-mode cascades (e.g. "[Pyre
  ///     freeform: emit Block N+1 now.]"). Persisted so retry / reload
  ///     reproduce the conversation faithfully, but FILTERED from the
  ///     chat UI so the user only sees the assistant cascade.
  ///   - `'freeformWarning'` → one-time runtime info bubble injected
  ///     when the freeform build cascade engages, warning the user
  ///     about expected duration. Rendered with a distinct style.
  String? kind;
  CreatorMessage({
    required this.role,
    required this.content,
    List<CreatorAttachment>? attachments,
    this.canvasSnapshot,
    this.kind,
  }) : attachments = attachments ?? <CreatorAttachment>[];

  factory CreatorMessage.fromJson(Map<String, dynamic> j) => CreatorMessage(
        role: (j['role'] as String?) ?? 'user',
        content: (j['content'] as String?) ?? '',
        attachments: ((j['attachments'] as List?) ?? const [])
            .map((a) => CreatorAttachment.fromJson(
                (a as Map).cast<String, dynamic>()))
            .toList(),
        canvasSnapshot: (j['canvasSnapshot'] as Map?)
            ?.cast<String, dynamic>(),
        kind: j['kind'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
        if (canvasSnapshot != null) 'canvasSnapshot': canvasSnapshot,
        if (kind != null) 'kind': kind,
      };
}

class CreatorSession {
  String id;
  /// Manual title override. When null, the UI derives a title from
  /// [canvas]['name'] or falls back to "Untitled".
  String? title;
  List<CreatorMessage> messages;
  /// Partial chara_card_v2 `data` block. Grows as the conversation
  /// reveals more about the character. Empty on a fresh session.
  Map<String, dynamic> canvas;
  int createdAt;
  int updatedAt;
  /// Once the user hits "Save card" we stamp the resulting character's
  /// id here so the session row can show a "saved" badge and re-opening
  /// the session can offer to open the character.
  String? savedCharacterId;
  /// Wave CS: when set, the session is editing an EXISTING character.
  /// Saves UPDATE that character (preserving its id and metadata) rather
  /// than creating a new one. Different from `savedCharacterId` —
  /// `editingCharacterId` is set BEFORE any save (at session creation,
  /// from the "Edit with AI" entry point), `savedCharacterId` is set
  /// AFTER the first save. The two are usually equal once the user
  /// saves, but they can diverge if the user picks a different
  /// destination on save.
  String? editingCharacterId;
  /// Persona Creator: when set, the session is editing an EXISTING
  /// persona (mode == 'persona'). Saves UPDATE that persona in place
  /// rather than creating a new one. Mirrors [editingCharacterId] but
  /// targets the personas list. Set BEFORE any save (at session
  /// creation, from the "Edit with AI" entry on a persona).
  String? editingPersonaId;
  /// Wave CV: which architect prompt drives this session.
  ///   - `'character'` → character architect (blocks 1-7, full)
  ///   - `'scenario'`  → scenario architect (blocks 1-4, leaner)
  ///   - `'edit'`      → free-form Partial Sheet edits, no blocks
  ///   - `null`        → user hasn't chosen yet; chat input is locked
  ///                     pending a "Character or Scenario?" choice.
  /// Legacy sessions (created before Wave CV) default to `'character'`
  /// during fromJson so existing drafts keep their architect.
  String? mode;
  /// Wave CY.18.27: how the architect runs through blocks in this
  /// session. Only meaningful for `mode == 'character'` or `'scenario'`.
  ///   - `'guided'`   → classic flow: architect emits one block per
  ///                    turn and PAUSES, waiting for the user to type
  ///                    confirmation before proceeding to the next.
  ///   - `'freeform'` → cascading flow: once the user signals build
  ///                    intent (semantically — any phrasing, any
  ///                    language), the architect emits Block 1, then
  ///                    the runtime auto-injects a synthetic
  ///                    continuation cue to trigger Block 2, etc.,
  ///                    cascading through to the wrap-up without
  ///                    manual confirmation between blocks.
  ///   - `null`       → not chosen yet; in newer sessions the picker
  ///                    forces a choice before chat unlocks.
  /// Legacy sessions (created before Wave CY.18.27) default to
  /// `'guided'` so existing drafts keep their current behaviour.
  /// `'edit'` mode ignores this field.
  String? flow;
  /// Wave CY.18.27: latching flag that flips to `true` once the
  /// architect has emitted its first SHEET region in this session.
  /// Used by the freeform runtime to decide whether to auto-inject a
  /// continuation cue after an assistant turn. `false` during Phase 1
  /// discussion; `true` once the build cascade has engaged.
  bool buildStarted;
  /// Sticky in the drawer — pinned sessions float to the top regardless
  /// of `updatedAt` and survive the empty-session auto-cleanup.
  bool pinned;

  CreatorSession({
    required this.id,
    this.title,
    List<CreatorMessage>? messages,
    Map<String, dynamic>? canvas,
    int? createdAt,
    int? updatedAt,
    this.savedCharacterId,
    this.editingCharacterId,
    this.editingPersonaId,
    this.mode,
    this.flow,
    this.buildStarted = false,
    this.pinned = false,
  })  : messages = messages ?? <CreatorMessage>[],
        canvas = canvas ?? <String, dynamic>{},
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory CreatorSession.fromJson(Map<String, dynamic> j) => CreatorSession(
        id: (j['id'] as String?) ?? newId('creator'),
        title: j['title'] as String?,
        messages: ((j['messages'] as List?) ?? const [])
            .map((m) =>
                CreatorMessage.fromJson((m as Map).cast<String, dynamic>()))
            .toList(),
        canvas: ((j['canvas'] as Map?) ?? const {})
            .cast<String, dynamic>(),
        createdAt: (j['createdAt'] as num?)?.toInt(),
        updatedAt: (j['updatedAt'] as num?)?.toInt(),
        savedCharacterId: j['savedCharacterId'] as String?,
        editingCharacterId: j['editingCharacterId'] as String?,
        editingPersonaId: j['editingPersonaId'] as String?,
        // Wave CV: legacy sessions w/o a mode default to 'character'
        // so an in-progress draft from before this wave doesn't end
        // up locked behind the mode chooser.
        mode: (j['mode'] as String?) ??
            (((j['messages'] as List?)?.isNotEmpty ?? false)
                ? 'character'
                : null),
        // Wave CY.18.101: guided removed — freeform is the only flow.
        // Persisted 'guided' is reinterpreted as 'freeform'; legacy
        // in-flight sessions (messages but no flow) default to 'freeform';
        // brand-new sessions stay null until a mode is picked
        // (_chooseMode then locks flow='freeform').
        flow: (j['flow'] as String?) == 'guided'
            ? 'freeform'
            : ((j['flow'] as String?) ??
                (((j['messages'] as List?)?.isNotEmpty ?? false)
                    ? 'freeform'
                    : null)),
        buildStarted: (j['buildStarted'] as bool?) ?? false,
        pinned: (j['pinned'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (title != null) 'title': title,
        'messages': messages.map((m) => m.toJson()).toList(),
        'canvas': canvas,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        if (savedCharacterId != null) 'savedCharacterId': savedCharacterId,
        if (editingCharacterId != null)
          'editingCharacterId': editingCharacterId,
        if (editingPersonaId != null) 'editingPersonaId': editingPersonaId,
        if (mode != null) 'mode': mode,
        if (flow != null) 'flow': flow,
        if (buildStarted) 'buildStarted': true,
        if (pinned) 'pinned': true,
      };

  /// Derive a display title without persisting it. Used by the drawer
  /// rows so a session named "Lyra" by the model auto-updates the moment
  /// the canvas update lands.
  String derivedTitle() {
    if (title != null && title!.trim().isNotEmpty) return title!.trim();
    final n = canvas['name'];
    if (n is String && n.trim().isNotEmpty) return n.trim();
    return 'Untitled';
  }
}
