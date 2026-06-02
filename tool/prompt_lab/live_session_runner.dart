// Wave CY.18.218 (Session Runner): a HEADLESS, end-to-end session driver.
//
// Unlike `prompt_lab_live.dart` (which fires ONE call per fixture and dumps a
// report) this runner drives a REAL multi-turn roleplay / Creator loop reusing
// the app's ACTUAL service functions, then PERSISTS the resulting Chat /
// CreatorSession into the app's real on-disk state file — so the produced chat
// / creator session shows up in the app's Chats / Creator lists on next launch.
//
// ============================================================================
// RUN COMMANDS (from the flutter_app/ package root). PowerShell `$env:X='…';`
// or POSIX `X=… `. Pick a mode via PROMPT_LAB_RUN.
//
//   DRY (no network, no key — validate assembly + persistence):
//     $env:PROMPT_LAB_RUN='chat'; $env:PROMPT_LAB_DRY='1';
//     $env:PROMPT_LAB_STATE_PATH='C:\tmp\state_copy.json';
//     $env:PROMPT_LAB_TURNS='C:\tmp\turns.json';
//     C:\Users\Gui\flutter\bin\flutter.bat test tool/prompt_lab/live_session_runner.dart
//
//   LIVE chat (real model — key via env, NEVER printed/persisted):
//     $env:PROMPT_LAB_RUN='chat'; $env:PROMPT_LAB_BASE_URL='https://.../v1';
//     $env:PROMPT_LAB_MODEL='your-model'; $env:PROMPT_LAB_API_KEY='sk-…';
//     $env:PROMPT_LAB_STATE_PATH='<a COPY of the state file>';
//     $env:PROMPT_LAB_TURNS='C:\tmp\turns.json'  # JSON list of user-turn strings
//     C:\Users\Gui\flutter\bin\flutter.bat test tool/prompt_lab/live_session_runner.dart
//
//   LIVE creator (real model):
//     $env:PROMPT_LAB_RUN='creator'; $env:PROMPT_LAB_CREATOR_MODE='character';
//     $env:PROMPT_LAB_CREATOR_SEED='Make me a wary wolfkin delver…';
//     $env:PROMPT_LAB_BASE_URL=…; $env:PROMPT_LAB_MODEL=…; $env:PROMPT_LAB_API_KEY=…;
//     $env:PROMPT_LAB_STATE_PATH='<a COPY>';
//     C:\Users\Gui\flutter\bin\flutter.bat test tool/prompt_lab/live_session_runner.dart
// ============================================================================
//
// SAFETY (load-bearing):
//   • The state file path is `PROMPT_LAB_STATE_PATH`. If unset, the runner
//     auto-copies the user's REAL state to a temp file and uses THAT — a dry
//     run never touches the real data unless you point it there explicitly.
//   • Persistence loads → mutates ONLY the test chat / creator session
//     (append-new OR replace-by-stable-id) → writes `<path>.tmp` → renames over
//     `<path>` (atomic) → re-reads + re-parses to verify it still decodes.
//     It NEVER mutates existing chats / characters / personas / providers.
//   • The API key arrives via `PROMPT_LAB_API_KEY` and is used only to build the
//     in-memory ApiProvider. It is NEVER printed, logged, or persisted (the
//     state blob's provider list is left untouched, and the runner's synthetic
//     provider is never written to disk).
//
// WHY the test runner: like prompt_lab.dart this is written as a `flutter_test`
// `test(...)` so it runs through `flutter test` (clean pass/fail + an isolate).
// It uses `dart:io` directly (no rootBundle / no AppStore singleton), so it does
// NOT need Flutter app bindings.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/chat_prompt_builder.dart';
import 'package:pyre/services/creator_cascade.dart';
import 'package:pyre/services/live_sheet.dart' as lsheet;
import 'package:pyre/services/memory.dart' as ltm;
import 'package:pyre/services/story_roadmap.dart' as roadmap;

// ---------------------------------------------------------------------------
// Stable ids — the runner appends/replaces ONLY these objects.
// ---------------------------------------------------------------------------

/// Stable id for the chat-mode test chat. Re-runs CONTINUE this same chat
/// (replace-by-id), so a 100-turn test can be split across chunks.
const String kChatId = 'pl-live-sunkengate';

/// Stable id PREFIX for creator-mode sessions. The full id includes the mode
/// so a character/scenario/persona/edit run each get their own session row.
const String kCreatorIdPrefix = 'pl-live-creator';

// ---------------------------------------------------------------------------
// Env helpers
// ---------------------------------------------------------------------------

String _env(String k, [String fallback = '']) =>
    (Platform.environment[k] ?? fallback).trim();

bool _envBool(String k) {
  final v = _env(k).toLowerCase();
  return v == '1' || v == 'true' || v == 'yes';
}

// ignore: avoid_print
void _log(Object? o) => print(o);

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

void main() {
  final run = _env('PROMPT_LAB_RUN', 'chat').toLowerCase();
  final dry = _envBool('PROMPT_LAB_DRY');

  test('session runner — $run${dry ? ' (DRY)' : ''}', () async {
    final statePath = await _resolveStatePath();
    _log('[runner] mode=$run dry=$dry state=$statePath');

    final state = _StateFile(statePath);
    await state.load();

    switch (run) {
      case 'creator':
        await _runCreator(state, dry: dry);
        break;
      case 'chat':
      default:
        await _runChat(state, dry: dry);
    }

    // Persist (atomic + verify) then re-read & re-parse to PROVE the chat /
    // session is present and the blob still decodes.
    await state.persistAndVerify();
    _log('[runner] DONE — persisted + re-parsed OK → $statePath');
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Resolve the state path. When `PROMPT_LAB_STATE_PATH` is set, use it verbatim.
/// Otherwise auto-copy the user's REAL state to a temp file and use that — a
/// dry run NEVER touches real data unless explicitly pointed there.
Future<String> _resolveStatePath() async {
  final explicit = _env('PROMPT_LAB_STATE_PATH');
  if (explicit.isNotEmpty) return explicit;

  // Default safe copy: <temp>/pyre_session_runner/emberchat_state.json
  final real = _realStateFile();
  final tmpDir = Directory(
      '${Directory.systemTemp.path}/pyre_session_runner');
  tmpDir.createSync(recursive: true);
  final copy = File('${tmpDir.path}/emberchat_state.json');
  if (real.existsSync()) {
    real.copySync(copy.path);
    _log('[runner] no PROMPT_LAB_STATE_PATH — copied REAL state '
        '(${real.lengthSync()} bytes) → ${copy.path} (dry-safe)');
  } else {
    copy.writeAsStringSync('{}');
    _log('[runner] no PROMPT_LAB_STATE_PATH and no real state found — '
        'starting from {} at ${copy.path}');
  }
  return copy.path;
}

/// The user's real state file location (Windows / macOS / Linux app-docs dir).
/// Used ONLY as the SOURCE for the auto-copy when no explicit path is given;
/// the runner never writes here.
File _realStateFile() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  // Matches storage.dart: getApplicationDocumentsDirectory()/EmberChat/…
  if (Platform.isWindows) {
    return File('$home\\Documents\\EmberChat\\emberchat_state.json');
  }
  if (Platform.isMacOS) {
    return File('$home/Documents/EmberChat/emberchat_state.json');
  }
  return File('$home/Documents/EmberChat/emberchat_state.json');
}

// ===========================================================================
// State file — load / mutate-only-the-test-object / atomic-write / verify
// ===========================================================================

class _StateFile {
  _StateFile(this.path);
  final String path;

  late Map<String, dynamic> blob;

  Future<void> load() async {
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() == 0) {
      blob = <String, dynamic>{};
      return;
    }
    final decoded = jsonDecode(await f.readAsString());
    if (decoded is! Map) {
      throw StateError('State file root is not a JSON object: $path');
    }
    blob = decoded.cast<String, dynamic>();
  }

  List<Map<String, dynamic>> _list(String key) {
    final raw = blob[key];
    if (raw is List) {
      return raw.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    }
    return <Map<String, dynamic>>[];
  }

  /// Parse the existing chats list into model objects (so we can reuse a
  /// previously-persisted test chat for continuation), leaving every OTHER
  /// chat as opaque JSON we re-emit untouched.
  List<Chat> parseChats() =>
      _list('chats').map((j) => Chat.fromJson(j)).toList();

  List<Character> parseCharacters() =>
      _list('characters').map((j) => Character.fromJson(j)).toList();

  List<Persona> parsePersonas() =>
      _list('personas').map((j) => Persona.fromJson(j)).toList();

  List<Lorebook> parseLorebooks() =>
      _list('lorebooks').map((j) => Lorebook.fromJson(j)).toList();

  List<CreatorSession> parseCreatorSessions() =>
      _list('creatorSessions').map((j) => CreatorSession.fromJson(j)).toList();

  MemorySettings parseMemorySettings() {
    final raw = blob['memorySettings'];
    return raw is Map
        ? MemorySettings.fromJson(raw.cast<String, dynamic>())
        : MemorySettings();
  }

  LiveSheetSettings parseLiveSheetSettings() {
    final raw = blob['liveSheetSettings'];
    return raw is Map
        ? LiveSheetSettings.fromJson(raw.cast<String, dynamic>())
        : LiveSheetSettings();
  }

  ModelSettings parseModelSettings() {
    final raw = blob['modelSettings'];
    return raw is Map
        ? ModelSettings.fromJson(raw.cast<String, dynamic>())
        : ModelSettings();
  }

  Character? characterByName(String name) {
    for (final c in parseCharacters()) {
      if (c.name.trim().toLowerCase() == name.trim().toLowerCase()) return c;
    }
    return null;
  }

  Persona? personaByName(String name) {
    for (final p in parsePersonas()) {
      if (p.name.trim().toLowerCase() == name.trim().toLowerCase()) return p;
    }
    return null;
  }

  Lorebook? lorebookByName(String name) {
    for (final b in parseLorebooks()) {
      if (b.name.trim().toLowerCase() == name.trim().toLowerCase()) return b;
    }
    return null;
  }

  /// Append-or-replace the test chat BY STABLE ID. Every other chat object in
  /// the raw blob is preserved byte-for-byte (we only swap the one matching
  /// entry, or append). Returns nothing — mutates `blob['chats']` in place.
  void upsertChat(Chat chat) {
    final raw = (blob['chats'] is List)
        ? List<dynamic>.from(blob['chats'] as List)
        : <dynamic>[];
    final encoded = chat.toJson();
    final idx = raw.indexWhere((e) => e is Map && e['id'] == chat.id);
    if (idx >= 0) {
      raw[idx] = encoded;
    } else {
      raw.add(encoded);
    }
    blob['chats'] = raw;
  }

  void upsertCreatorSession(CreatorSession s) {
    final raw = (blob['creatorSessions'] is List)
        ? List<dynamic>.from(blob['creatorSessions'] as List)
        : <dynamic>[];
    final encoded = s.toJson();
    final idx = raw.indexWhere((e) => e is Map && e['id'] == s.id);
    if (idx >= 0) {
      raw[idx] = encoded;
    } else {
      raw.add(encoded);
    }
    blob['creatorSessions'] = raw;
  }

  /// Append a NEW character (never overwrites an existing one — the runner
  /// always mints a fresh id for produced cards).
  void appendCharacter(Character c) {
    final raw = (blob['characters'] is List)
        ? List<dynamic>.from(blob['characters'] as List)
        : <dynamic>[];
    raw.add(c.toJson());
    blob['characters'] = raw;
  }

  void appendPersona(Persona p) {
    final raw = (blob['personas'] is List)
        ? List<dynamic>.from(blob['personas'] as List)
        : <dynamic>[];
    raw.add(p.toJson());
    blob['personas'] = raw;
  }

  /// Atomic write to `<path>.tmp` then rename over `<path>`, then re-read and
  /// re-parse to verify the blob still decodes (mirrors storage.dart's
  /// write-verify). Throws if the re-parse fails — never leaves a half file.
  Future<void> persistAndVerify() async {
    final encoded = jsonEncode(blob);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(path);

    // Re-read + re-parse (root decode + a full chats-list re-decode through the
    // real Chat.fromJson, so a malformed test chat is caught here).
    final readback = await File(path).readAsString();
    final decoded = jsonDecode(readback);
    if (decoded is! Map) {
      throw StateError('Verify FAILED — re-read root is not a JSON object.');
    }
    final chatsRaw = (decoded['chats'] as List?) ?? const [];
    for (final c in chatsRaw.whereType<Map>()) {
      Chat.fromJson(c.cast<String, dynamic>()); // throws on a bad shape
    }
    final csRaw = (decoded['creatorSessions'] as List?) ?? const [];
    for (final c in csRaw.whereType<Map>()) {
      CreatorSession.fromJson(c.cast<String, dynamic>());
    }
    _log('[runner] write-verify OK — ${readback.length} bytes, '
        '${chatsRaw.length} chats, ${csRaw.length} creator sessions.');
  }
}

// ===========================================================================
// Provider / settings construction (from env). Key is never logged.
// ===========================================================================

ApiProvider _providerFromEnv() {
  final kind = switch (_env('PROMPT_LAB_KIND').toLowerCase()) {
    'localhost' => ProviderKind.localhost,
    'proxy' => ProviderKind.proxy,
    _ => ProviderKind.external_,
  };
  Map<String, dynamic> extra = const {};
  final extraRaw = _env('PROMPT_LAB_EXTRA_PARAMS');
  if (extraRaw.isNotEmpty) {
    final d = jsonDecode(extraRaw);
    if (d is Map) extra = d.cast<String, dynamic>();
  }
  return ApiProvider(
    id: 'pl-session-runner', // synthetic — NEVER persisted
    name: 'Session Runner (live)',
    kind: kind,
    baseUrl: _env('PROMPT_LAB_BASE_URL'),
    apiKey: _env('PROMPT_LAB_API_KEY'), // env only; never printed/persisted
    model: _env('PROMPT_LAB_MODEL'),
    extraParams: Map<String, dynamic>.from(extra),
  );
}

// ===========================================================================
// CHAT mode
// ===========================================================================

Future<void> _runChat(_StateFile state, {required bool dry}) async {
  // Resolve the cast by name (mirrors the task spec).
  final character = state.characterByName('The Sunken Gate');
  final persona = state.personaByName('Ren Brennan') ?? state.personaByName('Ren');
  final world = state.lorebookByName('The Vael — World Lore');

  if (character == null) {
    throw StateError(
        'Chat mode needs character "The Sunken Gate" in the state — not found. '
        'Run against a state with the bundled examples seeded.');
  }
  _log('[chat] character=${character.name} (${character.id}) '
      'persona=${persona?.name ?? '(none)'} '
      'world=${world?.name ?? '(none)'}');

  // Continue an existing test chat by id, else create one.
  final chats = state.parseChats();
  Chat chat = chats.firstWhere(
    (c) => c.id == kChatId,
    orElse: () => _newChatSunkenGate(character, persona, world),
  );
  // Ensure the snapshot + bindings are present even when continuing (idempotent).
  chat.characterSnapshots[character.id] = character;
  if (!chat.characterIds.contains(character.id)) {
    chat.characterIds = [character.id];
  }
  if (world != null && !chat.attachedLorebookIds.contains(world.id)) {
    chat.attachedLorebookIds.add(world.id);
  }
  chat.memoryEnabled = true;
  chat.liveSheetEnabled = true;
  if (chat.storyBeats.isEmpty) {
    chat.storyBeats.addAll(_resolveBeats());
  }

  final lookupChar = _charLookup([character, ...state.parseCharacters()]);
  final lookupBook = _bookLookup([?world, ...state.parseLorebooks()]);

  final provider = dry ? null : _providerFromEnv();
  final settings = state.parseModelSettings();
  final memSettings = state.parseMemorySettings();
  final lsSettings = state.parseLiveSheetSettings();

  // NPC names for the Live Sheet seed (besides the persona).
  final npcNames = _env('PROMPT_LAB_NPCS')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  final userTurns = _resolveTurns();
  _log('[chat] driving ${userTurns.length} user turn(s)…');

  var assistantCount = 0;
  var checkpointCount = 0;
  var truncatedAny = false;

  for (var t = 0; t < userTurns.length; t++) {
    // 1) Append the user message.
    chat.messages.add(_msg(MessageKind.user, userTurns[t]));

    // 2) Assemble the prompt via the REAL builder.
    final inputs = ChatPromptInputs(
      chat: chat,
      character: character,
      persona: persona,
      preset: null, // exercises the fallback character system-prompt branch
      responderId: character.id,
      beatsCap: 6,
      lookupCharacter: lookupChar,
      lookupBook: lookupBook,
      inFlightMessageId: null,
    );
    final assembled = buildChatPrompt(inputs);

    // 3) Get the assistant reply (DRY: canned; LIVE: real stream).
    String reply;
    String? finishReason;
    if (dry) {
      reply = '*Vesna\'s ears flick toward the Gate.* **"Stay close."**';
    } else {
      final raw = StringBuffer();
      await for (final chunk in streamChatCompletion(
        provider: provider!,
        settings: settings,
        messages: assembled.turns,
        debugTag: 'chat',
      )) {
        raw.write(chunk);
      }
      final rawText = raw.toString();
      finishReason = pyreFinishSentinelRegex.firstMatch(rawText)?.group(1);
      reply = stripStreamArtifacts(rawText);
      if (finishReason == 'length') truncatedAny = true;
    }

    // 4) Append the assistant message.
    chat.messages.add(_msg(MessageKind.char, reply, characterId: character.id));
    assistantCount++;
    _log('>>>ASSISTANT ${t + 1}: $reply'
        '${finishReason != null ? '  [finish_reason=$finishReason]' : ''}');

    // 5) Live Sheet — seed on first turn (if not already seeded), else update.
    if (lsheet.activeLiveSheetSnapshot(chat) == null) {
      await _seedLiveSheet(
        chat: chat,
        persona: persona,
        character: character,
        npcNames: npcNames,
        provider: provider,
        settings: settings,
        lsSettings: lsSettings,
        dry: dry,
      );
    } else if (lsheet.shouldUpdateLiveSheet(chat, lsSettings)) {
      if (dry) {
        // Canned no-op-ish update so the trigger path is exercised.
        _log('[livesheet] update trigger fired (DRY — skipping LLM update)');
      } else {
        final snap = await lsheet.generateLiveSheetUpdate(
          chat: chat,
          provider: provider!,
          settings: settings,
          liveSheetSettings: lsSettings,
        );
        if (snap != null) {
          chat.liveSheetSnapshots.add(snap);
          _log('[livesheet] update added a snapshot');
        }
      }
    }

    // 6) LTM — summarise when the threshold is hit.
    if (ltm.shouldSummarize(chat, memorySettings: memSettings)) {
      if (dry) {
        // Append a canned checkpoint so the persisted shape is exercised.
        ltm.applyCheckpoint(
          chat,
          MemoryCheckpoint(
            id: newId('mc'),
            summary:
                '(DRY) Vesna kept the Outsider alive at the Sunken Gate, '
                'wary but not cruel, as they edged toward the Maw.',
            anchorMessageIdx: chat.messages.length - 1,
            pathHash: ltm.computePathHash(
                chat.messages, chat.messages.length - 1),
          ),
        );
        checkpointCount++;
        _log('[ltm] checkpoint trigger fired (DRY — canned checkpoint added)');
      } else {
        final ckpt = await ltm.generateCheckpoint(
          chat: chat,
          provider: provider!,
          settings: settings,
          memorySettings: memSettings,
        );
        if (ckpt != null) {
          ltm.applyCheckpoint(chat, ckpt);
          checkpointCount++;
          _log('[ltm] checkpoint added (anchor=${ckpt.anchorMessageIdx})');
        }
      }
    }
  }

  // Persist the chat into the blob (append or replace-by-id).
  chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
  state.upsertChat(chat);

  // ── Summary ───────────────────────────────────────────────────────────
  _log('');
  _log('=== CHAT SUMMARY ===');
  _log('chat id        : ${chat.id}');
  _log('messages       : ${chat.messages.length} '
      '(+$assistantCount assistant this run)');
  _log('checkpoints    : ${chat.memoryCheckpoints.length} '
      '(+$checkpointCount this run)');
  for (var i = 0; i < chat.memoryCheckpoints.length; i++) {
    final c = chat.memoryCheckpoints[i];
    final s = c.summary.replaceAll('\n', ' ');
    _log('  ckpt#${i + 1} @${c.anchorMessageIdx}: '
        '${s.length > 160 ? '${s.substring(0, 160)}…' : s}');
  }
  final active = lsheet.activeLiveSheetSnapshot(chat);
  _log('live sheet     : ${chat.liveSheetSnapshots.length} snapshot(s); '
      'active has ${active?.entities.length ?? 0} entit(ies)');
  if (active != null) {
    for (final e in active.entities) {
      final secs = <String>[];
      for (final s in LiveSheetSection.values) {
        final facts = e.sections[s] ?? const [];
        if (facts.isNotEmpty) {
          secs.add('${s.label}=[${facts.map((f) => f.text).join('; ')}]');
        }
      }
      _log('  • ${e.name} (${e.kind.name}): '
          '${secs.isEmpty ? '(no facts)' : secs.join('  ')}');
    }
  }
  final roadmapBlock = roadmap.buildStoryRoadmapBlock(chat, beatsCap: 6);
  _log('script beats   : ${chat.storyBeats.length} '
      '(roadmap block injected: ${roadmapBlock.isNotEmpty})');
  _log('truncation     : ${truncatedAny ? 'YES (a turn finished on length)' : 'no'}');
}

Chat _newChatSunkenGate(Character character, Persona? persona, Lorebook? world) {
  return Chat(
    id: kChatId,
    characterIds: [character.id],
    characterSnapshots: {character.id: character},
    personaId: persona?.id,
    attachedLorebookIds: [if (world != null) world.id],
    messages: [],
    memoryEnabled: true,
    liveSheetEnabled: true,
    storyBeats: _resolveBeats(),
  );
}

Future<void> _seedLiveSheet({
  required Chat chat,
  required Persona? persona,
  required Character character,
  required List<String> npcNames,
  required ApiProvider? provider,
  required ModelSettings settings,
  required LiveSheetSettings lsSettings,
  required bool dry,
}) async {
  // Build the entity roster: the persona (user) + the responder character +
  // any NPC names passed via env. Mirrors live_sheet_screen._ensureSnapshot.
  final entities = <LiveSheetEntity>[
    LiveSheetEntity(
      id: newId('lse'),
      name: persona?.name ?? 'You',
      kind: LiveSheetEntityKind.user,
    ),
    // Wave CY.18.218: a narrator/scenario responder card has no body — skip it
    // so the seed pass doesn't hallucinate one. Mirrors _ensureSnapshot.
    if (!lsheet.isNarratorCard(character))
      LiveSheetEntity(
        id: newId('lse'),
        name: character.name,
        kind: LiveSheetEntityKind.char,
      ),
    for (final n in npcNames)
      LiveSheetEntity(
        id: newId('lse'),
        name: n,
        kind: LiveSheetEntityKind.npc,
      ),
  ];

  if (!dry && provider != null) {
    // Run the REAL seed pass per entity (mirrors live_sheet_screen._seedEntity).
    for (final e in entities) {
      String? desc;
      if (e.kind == LiveSheetEntityKind.user) {
        desc = persona?.description;
      } else if (e.kind == LiveSheetEntityKind.char) {
        desc = character.description;
      }
      final sections = await lsheet.seedLiveSheetEntity(
        chat: chat,
        entityName: e.name,
        kind: e.kind,
        cardDescription:
            (desc?.trim().isNotEmpty ?? false) ? desc : null,
        provider: provider,
        settings: settings,
        liveSheetSettings: lsSettings,
      );
      if (sections != null) {
        for (final s in LiveSheetSection.values) {
          e.sections[s] = sections[s] ?? [];
        }
      }
    }
  } else {
    // DRY: seed a couple of plausible facts so the snapshot is non-empty.
    entities.first.sections[LiveSheetSection.appearance]!
        .add(LiveSheetFact(text: 'short, slight, dark hair'));
    if (entities.length > 1) {
      entities[1].sections[LiveSheetSection.appearance]!
          .add(LiveSheetFact(text: 'sun-dark tan, white-tipped tail'));
    }
  }

  final snapshot = lsheet.seedInitialSnapshot(chat, entities);
  chat.liveSheetSnapshots.add(snapshot);
  _log('[livesheet] seeded ${entities.length} entit(ies)'
      '${dry ? ' (DRY canned facts)' : ''}');
}

/// 3 sensible default Sunken-Gate beats (used when PROMPT_LAB_BEATS unset).
List<StoryBeat> _resolveBeats() {
  final raw = _env('PROMPT_LAB_BEATS');
  List<String> texts;
  if (raw.isNotEmpty) {
    final d = jsonDecode(raw);
    texts = (d as List).map((e) => e.toString()).toList();
  } else {
    texts = const [
      'Vesna eventually admits the Charter sent her to MAP the Maw, not to '
          'rescue strays — and that mapping it means going down.',
      'The cold breath from the Gate carries a voice that knows {{user}}\'s '
          'real name, the one from before they were spat out.',
      'A second delver from the Charter catches up to them at the Gate\'s '
          'mouth, and their orders do not include {{user}}.',
    ];
  }
  return [for (final t in texts) StoryBeat(id: newId('beat'), text: t)];
}

/// Read Ren's user turns for THIS chunk from PROMPT_LAB_TURNS (a JSON list of
/// strings). Falls back to 3 sensible turns so a DRY run works with zero setup.
List<String> _resolveTurns() {
  final path = _env('PROMPT_LAB_TURNS');
  if (path.isNotEmpty) {
    final f = File(path);
    if (!f.existsSync()) {
      throw StateError('PROMPT_LAB_TURNS points at a missing file: $path');
    }
    final d = jsonDecode(f.readAsStringSync());
    if (d is! List) {
      throw StateError('PROMPT_LAB_TURNS must be a JSON list of strings.');
    }
    return d.map((e) => e.toString()).toList();
  }
  return const [
    'I edge toward the cold breath coming up out of the Gate. "What IS that '
        'down there?"',
    '"Then why are we standing at the edge of it, if it only takes?"',
    '*I crouch and pick up a loose stone, turning it over.* "Have you ever '
        'gone down? All the way?"',
  ];
}

Message _msg(MessageKind kind, String text, {String? characterId}) => Message(
      id: newId('m'),
      kind: kind,
      characterId: characterId,
      variants: [text],
    );

Character? Function(String) _charLookup(List<Character> chars) {
  final byId = <String, Character>{};
  for (final c in chars) {
    byId[c.id] ??= c;
  }
  return (id) => byId[id];
}

Lorebook? Function(String) _bookLookup(List<Lorebook> books) {
  final byId = <String, Lorebook>{};
  for (final b in books) {
    byId[b.id] ??= b;
  }
  return (id) => byId[id];
}

// ===========================================================================
// CREATOR mode
// ===========================================================================

Future<void> _runCreator(_StateFile state, {required bool dry}) async {
  final mode = _env('PROMPT_LAB_CREATOR_MODE', 'character').toLowerCase();
  final sessionId = '$kCreatorIdPrefix-$mode';
  _log('[creator] mode=$mode session=$sessionId');

  // Build / continue the session canvas + conversation.
  final sessions = state.parseCreatorSessions();
  CreatorSession session = sessions.firstWhere(
    (s) => s.id == sessionId,
    orElse: () => CreatorSession(
      id: sessionId,
      mode: mode,
      flow: 'freeform',
      buildStarted: false,
    ),
  );
  session.mode = mode;
  session.flow ??= 'freeform';

  // EDIT mode: preload the canvas from an existing card.
  if (mode == 'edit') {
    final targetName = _env('PROMPT_LAB_EDIT_TARGET', 'Vesna');
    final target = state.characterByName(targetName);
    if (target == null) {
      throw StateError('Edit mode: card "$targetName" not found in state.');
    }
    session.editingCharacterId = target.id;
    session.canvas = _characterToCanvas(target);
    _log('[creator] edit target=${target.name} (${target.id}); '
        'preloaded ${session.canvas.length} canvas field(s)');
  }

  final seed = _env('PROMPT_LAB_CREATOR_SEED').isNotEmpty
      ? _env('PROMPT_LAB_CREATOR_SEED')
      : _defaultSeedFor(mode);

  // Seed conversation: if this is a fresh session, plant the user seed.
  if (session.messages.isEmpty) {
    session.messages.add(CreatorMessage(role: 'user', content: seed));
  }
  session.buildStarted = true;

  final provider = dry ? null : _providerFromEnv();
  final settings = state.parseModelSettings();
  // Floor the cap so a full sheet isn't truncated by a low global default.
  final creatorSettings = settings.creatorMaxTokens >= settings.maxTokens
      ? (ModelSettings.fromJson(settings.toJson())
        ..maxTokens = settings.creatorMaxTokens)
      : settings;

  // TODO: structured-build runner. The old `<<SHEET>>`-marker completeness
  // cascade was removed when the Creator BUILD step moved to the
  // deterministic structured-JSON pipeline (creator_build.dart). This dev
  // runner now fires a SINGLE Phase-1 architect turn and records the reply;
  // it no longer drives a card to completion. Rewire it to the structured
  // build (creator_build.dart) when the runner needs end-to-end coverage.
  {
    final convo = [
      for (final m in session.messages)
        CreatorTurn(m.role == 'assistant' ? 'assistant' : 'user', m.content),
    ];
    final turns = buildCreatorArchitectTurns(
      canvas: session.canvas,
      conversation: convo,
      mode: mode,
    );
    String reply;
    if (dry) {
      reply = '(dry run — structured-build runner stub; no architect call)';
    } else {
      final raw = StringBuffer();
      await for (final chunk in streamChatCompletion(
        provider: provider!,
        settings: creatorSettings,
        messages: turns,
        debugTag: 'creator-architect',
      )) {
        raw.write(chunk);
      }
      reply = stripStreamArtifacts(raw.toString());
    }
    session.messages.add(CreatorMessage(role: 'assistant', content: reply));
    _log('[creator] architect reply (${reply.length} chars) recorded.');
    _log('canvas now : ${_canvasFieldSummary(session.canvas)}');
  }

  // Persist the finished card as a NEW character/persona (never overwrite the
  // original — even in edit mode, this runner saves-as-copy).
  String? savedId;
  if ((session.canvas['name'] as String?)?.trim().isNotEmpty ?? false) {
    if (mode == 'persona') {
      final p = _canvasToPersona(session.canvas);
      state.appendPersona(p);
      savedId = p.id;
      _log('[creator] saved persona "${p.name}" (${p.id}) — appended (new).');
    } else {
      final c = _canvasToCharacter(session.canvas, mode: mode);
      if (mode == 'edit') c.name = withCopyNameSuffix(c.name);
      state.appendCharacter(c);
      savedId = c.id;
      _log('[creator] saved character "${c.name}" (${c.id}) — appended (new).');
    }
    session.savedCharacterId = savedId;
  } else {
    _log('[creator] canvas has no name — NOT saving a card '
        '(session is still persisted for inspection).');
  }

  // Persist the Creator SESSION too — the app DOES store creator sessions in
  // state under `creatorSessions` (List<CreatorSession>) + `activeCreatorSessionId`.
  session.updatedAt = DateTime.now().millisecondsSinceEpoch;
  state.upsertCreatorSession(session);
  state.blob['activeCreatorSessionId'] = session.id;

  _log('');
  _log('=== CREATOR SUMMARY ===');
  _log('session id     : ${session.id}  (persisted to creatorSessions list)');
  _log('mode           : $mode');
  _log('messages       : ${session.messages.length}');
  _log('canvas fields  : ${_canvasFieldSummary(session.canvas)}');
  _log('saved card id  : ${savedId ?? '(none)'}');
}

String _defaultSeedFor(String mode) {
  switch (mode) {
    case 'scenario':
      return 'Build me a narrator scenario where an Outsider wakes at the '
          'foot of a cold, sunken Gate in a tropical ruin, unsure how they '
          'got there. Any-POV, frenetic cold open.';
    case 'persona':
      return 'Make me a persona: a clueless, soft-spoken 21-year-old Outsider '
          'recently spat out of the Sunken Gate, anxious but trying to cope.';
    case 'edit':
      return 'Tighten this card: make the first message punchier and give the '
          'personality more of an edge. Keep everything else.';
    case 'character':
    default:
      return 'Make me a wary wolfkin delver who reluctantly looks after a '
          'clueless Outsider. Competent, not cruel.';
  }
}

// ===========================================================================
// Canvas ↔ model mapping.
//
// The CREATOR canvas uses chara_card_v2 `data`-block keys (first_mes,
// mes_example, post_history_instructions, …). The native Pyre model uses
// camelCase fields (firstMes, mesExample, …). These translate between them.
// We do NOT route through parseCharaCardJson/characterFromCharaCard so the
// runner has no PNG/card-import dependency; the field mapping is explicit.
// ===========================================================================

String _cs(Map<String, dynamic> canvas, String key) {
  final v = canvas[key];
  if (v is String) return v;
  if (v is List) return v.join(', ');
  return '';
}

List<String> _csList(Map<String, dynamic> canvas, String key) {
  final v = canvas[key];
  if (v is List) return v.map((e) => e.toString()).toList();
  if (v is String && v.trim().isNotEmpty) {
    return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }
  return const [];
}

Character _canvasToCharacter(Map<String, dynamic> canvas, {required String mode}) {
  return Character(
    id: newId('char'),
    name: _cs(canvas, 'name'),
    tagline: _cs(canvas, 'tagline').isEmpty ? null : _cs(canvas, 'tagline'),
    description: _cs(canvas, 'description'),
    personality: _cs(canvas, 'personality'),
    scenario: _cs(canvas, 'scenario'),
    firstMes: _cs(canvas, 'first_mes'),
    mesExample: _cs(canvas, 'mes_example'),
    systemPrompt: _cs(canvas, 'system_prompt'),
    postHistoryInstructions: _cs(canvas, 'post_history_instructions'),
    alternateGreetings: _csList(canvas, 'alternate_greetings'),
    tags: _csList(canvas, 'tags'),
    creator: 'Session Runner',
    creatorNotes: _cs(canvas, 'creator_notes'),
    createdInPyre: true,
  );
}

Persona _canvasToPersona(Map<String, dynamic> canvas) {
  return Persona(
    id: newId('persona'),
    name: _cs(canvas, 'name'),
    tagline: _cs(canvas, 'tagline').isEmpty ? null : _cs(canvas, 'tagline'),
    description: _cs(canvas, 'description'),
    dialogueExamples: _cs(canvas, 'mes_example'),
  );
}

/// EDIT mode: load an existing Character into a chara_card_v2 canvas so the
/// architect can rewrite it in place (mirrors how the screen preloads).
Map<String, dynamic> _characterToCanvas(Character c) => {
      'name': c.name,
      if (c.tagline != null) 'tagline': c.tagline,
      'description': c.description,
      'personality': c.personality,
      'scenario': c.scenario,
      'first_mes': c.firstMes,
      'mes_example': c.mesExample,
      'system_prompt': c.systemPrompt,
      'post_history_instructions': c.postHistoryInstructions,
      'creator_notes': c.creatorNotes,
      'alternate_greetings': List<String>.from(c.alternateGreetings),
      'tags': List<String>.from(c.tags),
    };

String _canvasFieldSummary(Map<String, dynamic> canvas) {
  final parts = <String>[];
  for (final entry in canvas.entries) {
    final v = entry.value;
    final len = v is String
        ? v.length
        : (v is List ? v.length : v.toString().length);
    if ((v is String && v.trim().isNotEmpty) ||
        (v is List && v.isNotEmpty) ||
        (v is! String && v is! List && v != null)) {
      parts.add('${entry.key}(${v is List ? '${v.length} items' : '$len ch'})');
    }
  }
  return parts.isEmpty ? '(empty)' : parts.join(', ');
}
