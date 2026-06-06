// SillyTavern full-backup (.zip) import.
//
// ST's "Download Backup" produces a `.zip` of the whole `data/<user>/`
// directory (47+ MB, hundreds of files). Pyre only cares about a handful of
// folders; the bulk (backgrounds, backups, thumbnails, sprite sheets,
// provider-settings dirs) is irrelevant or unrepresentable.
//
// This module UNPACKS + ROUTES a backup into Pyre objects WITHOUT mutating any
// store. It REUSES the existing per-type parsers via `routeStFile`
// (st_bulk_import.dart) for cards / worlds / presets, the settings-embedded
// regex via `parseStRegexScripts` (regex_rules.dart), and the genuinely-new
// chat `.jsonl` parser `chatFromStJsonl` (st_chat_import.dart).
//
// SECURITY: `secrets.json` holds live API keys — it is HARD-SKIPPED by name,
// its bytes are NEVER read and it is NEVER logged.
//
// SPLIT for testability + responsiveness:
//   - [planStBackupCore] is PURE + synchronous (no Flutter bindings, no
//     isolate) — directly unit-testable. It filters entries by their top-level
//     path segment BEFORE inflating content (the `archive` package decompresses
//     each entry's bytes lazily on `.content` access, so skipped folders are
//     never materialized), enforces a per-file size cap, and returns an
//     [StBackupPlan].
//   - [planStBackup] is the thin UI wrapper that runs the core in a `compute()`
//     isolate so a 47 MB zip doesn't jank the UI thread.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'regex_rules.dart';
import 'st_bulk_import.dart';
import 'st_chat_import.dart' show StPersonaHint, stPersonaHintFromJsonl;

/// Per-file cap, mirroring the 25 MB card-fetch cap used elsewhere. An entry
/// whose declared uncompressed size exceeds this is skipped (never inflated) —
/// a zip-bomb / pathological file can't blow up memory.
const int kStBackupMaxFileBytes = 25 * 1024 * 1024;

/// One imported chat, paired with the character-folder name it lived under so
/// the UI layer can bind it to the matching imported [Character] AFTER the
/// cards are parsed. (We can't bind during planning because the chat's parent
/// folder name — ST's character file stem — must be matched against the parsed
/// card names, which the UI assembles into a map.)
class StBackupChat {
  /// The `chats/<CharName>/` folder name (the character's ST file stem).
  final String characterFolder;

  /// The chat log filename (for the summary / diagnostics).
  final String fileName;

  /// The raw `.jsonl` lines (already UTF-8 decoded + split on newlines). The UI
  /// layer feeds these to `chatFromStJsonl` once it has the matching Character.
  final List<String> lines;

  /// The persona this chat was role-played with, inferred from the FIRST
  /// `is_user: true` message (its `name` = DisplayName, its `force_avatar`
  /// `file=` param = avatar filename). The UI layer matches this against the
  /// imported personas (avatarFile first, then DisplayName) to set
  /// `chat.personaId`. Empty when no user message carried persona identity.
  final StPersonaHint personaHint;

  StBackupChat({
    required this.characterFolder,
    required this.fileName,
    required this.lines,
    this.personaHint = const StPersonaHint(),
  });
}

/// The result of planning a backup: the parsed Pyre objects (no store
/// mutation), per-type counts, and diagnostics. Chats are returned RAW (lines +
/// folder) for the UI to bind to characters; everything else is fully parsed.
class StBackupPlan {
  final List<Character> characters;
  final List<Lorebook> lorebooks;
  final List<Preset> presets;
  final List<RegexRule> regexRules;

  /// User personas parsed from `settings.json` (`power_user.personas` +
  /// `power_user.persona_descriptions`). Each carries a fresh id and a null
  /// `avatar` — the UI layer externalises the bytes from [personaAvatarBytes]
  /// (matched via [personaAvatarFileById]) and stamps the resulting
  /// `pyre://attachment/<hash>` ref onto the persona before persisting.
  final List<Persona> personas;

  /// Raw avatar image bytes for personas, keyed by the bare avatar filename
  /// (e.g. `Serena.png`) — the SAME key as `power_user.personas` and the
  /// `force_avatar` `file=` param. Collected from the `User Avatars/` zip
  /// folder. The UI layer feeds these to `AttachmentStore.store`.
  final Map<String, Uint8List> personaAvatarBytes;

  /// Maps a parsed persona's id → its avatar filename, so the UI layer can
  /// look up the right bytes in [personaAvatarBytes] for each persona.
  final Map<String, String> personaAvatarFileById;

  /// Maps a parsed persona's id → the ST `persona_descriptions[file].lorebook`
  /// name (a world name), when non-empty. The UI layer OPTIONALLY binds the
  /// matching imported lorebook's id onto the persona. Absent for personas
  /// with no associated lorebook.
  final Map<String, String> personaLorebookNameById;

  /// Raw chats keyed/collected by their `chats/<CharName>/` folder name. The UI
  /// binds each to its matching imported character (orphans → skipped + counted
  /// there).
  final List<StBackupChat> chats;

  /// Count of entries that failed to parse (a bad card / world / preset / chat
  /// file). One bad file never aborts the plan.
  final int parseErrors;

  /// Count of entries skipped purely because they're out of scope (themes,
  /// backgrounds, secrets, etc.) or oversized. Informational only.
  final int skippedEntries;

  StBackupPlan({
    required this.characters,
    required this.lorebooks,
    required this.presets,
    required this.regexRules,
    required this.personas,
    required this.personaAvatarBytes,
    required this.personaAvatarFileById,
    required this.personaLorebookNameById,
    required this.chats,
    required this.parseErrors,
    required this.skippedEntries,
  });

  /// A short "skipped by design" note for the summary UI. Static phrasing — we
  /// always skip the same out-of-scope categories.
  static const String skippedNote =
      'Skipped (by design): API keys, app settings, themes, backgrounds, '
      'sprite sheets, and other unsupported folders.';
}

/// PURE, synchronous core. Decode [zipBytes], route each entry by its top-level
/// path segment (NOT a content sniff), and return an [StBackupPlan]. Never
/// mutates a store; never reads `secrets.json`. Resilient — a single bad entry
/// is counted as a parse error and skipped, never aborting the plan.
StBackupPlan planStBackupCore(Uint8List zipBytes) {
  final characters = <Character>[];
  final lorebooks = <Lorebook>[];
  final presets = <Preset>[];
  final regexRules = <RegexRule>[];
  final personas = <Persona>[];
  final personaAvatarFileById = <String, String>{};
  final personaLorebookNameById = <String, String>{};
  final personaAvatarBytes = <String, Uint8List>{};
  final chats = <StBackupChat>[];
  var parseErrors = 0;
  var skipped = 0;

  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (_) {
    // A corrupt / non-zip blob → an empty plan (the UI reports "nothing
    // imported"). We don't throw so the caller's isolate completes cleanly.
    return StBackupPlan(
      characters: const [],
      lorebooks: const [],
      presets: const [],
      regexRules: const [],
      personas: const [],
      personaAvatarBytes: const {},
      personaAvatarFileById: const {},
      personaLorebookNameById: const {},
      chats: const [],
      parseErrors: 0,
      skippedEntries: 0,
    );
  }

  for (final entry in archive) {
    if (!entry.isFile) continue;
    final path = _normalizePath(entry.name);
    if (path.isEmpty) {
      skipped++;
      continue;
    }
    final segments = path.split('/');
    final top = segments.first;
    final isTopLevel = segments.length == 1;

    // ---- SECURITY: hard-skip secrets.json by name. Never read its bytes. ----
    if (isTopLevel && _eq(top, 'secrets.json')) {
      skipped++;
      continue;
    }

    // ---- settings.json (root) → extension_settings.regex + power_user
    //      personas (avatar bytes come from the User Avatars/ folder below) ----
    if (isTopLevel && _eq(top, 'settings.json')) {
      if (entry.size > kStBackupMaxFileBytes) {
        skipped++;
        continue;
      }
      try {
        final decoded = jsonDecode(utf8.decode(entry.content));
        regexRules.addAll(regexRulesFromSettings(decoded));
        for (final p in personasFromSettings(decoded)) {
          personas.add(p.persona);
          personaAvatarFileById[p.persona.id] = p.avatarFile;
          if (p.lorebookName.isNotEmpty) {
            personaLorebookNameById[p.persona.id] = p.lorebookName;
          }
        }
      } catch (_) {
        // Defensive: malformed settings.json → no regex/personas, never throw.
        parseErrors++;
      }
      continue;
    }

    // ---- User Avatars/<file>.png → collect raw bytes (keyed by bare filename)
    //      so the UI can externalise them onto the matching persona. We do NOT
    //      import these as cards; they're only persona portraits. ----
    if (_eq(top, 'User Avatars')) {
      // Expect User Avatars/<file> (the filename matches the personas-map key).
      if (segments.length != 2) {
        skipped++; // nested / unexpected
        continue;
      }
      if (entry.size > kStBackupMaxFileBytes) {
        skipped++;
        continue;
      }
      try {
        personaAvatarBytes[segments[1]] = Uint8List.fromList(entry.content);
      } catch (_) {
        parseErrors++;
      }
      continue;
    }

    // ---- characters/<Name>.png|.json (top-level ONLY) ----
    // Nested subfolders like `characters/Seraphina/...` are expression sprites,
    // not cards — skip them.
    if (_eq(top, 'characters')) {
      if (segments.length != 2) {
        skipped++; // nested sprite folder
        continue;
      }
      final ext = _ext(segments[1]);
      if (ext != 'png' && ext != 'json') {
        skipped++;
        continue;
      }
      if (entry.size > kStBackupMaxFileBytes) {
        skipped++;
        continue;
      }
      final r = routeStFile(segments[1], entry.content);
      if (r.ok && r.character != null) {
        characters.add(r.character!);
      } else {
        parseErrors++;
      }
      continue;
    }

    // ---- worlds/*.json → Lorebook ----
    if (_eq(top, 'worlds')) {
      if (_ext(segments.last) != 'json') {
        skipped++;
        continue;
      }
      if (entry.size > kStBackupMaxFileBytes) {
        skipped++;
        continue;
      }
      final r = routeStFile(segments.last, entry.content);
      if (r.ok && r.lorebook != null) {
        lorebooks.add(r.lorebook!);
      } else {
        parseErrors++;
      }
      continue;
    }

    // ---- OpenAI Settings/*.json → Preset (chat-completion) ----
    if (_eq(top, 'OpenAI Settings')) {
      if (_ext(segments.last) != 'json') {
        skipped++;
        continue;
      }
      if (entry.size > kStBackupMaxFileBytes) {
        skipped++;
        continue;
      }
      final r = routeStFile(segments.last, entry.content);
      if (r.ok && r.preset != null) {
        presets.add(r.preset!);
      } else {
        // Sampler-only / textgen presets don't parse via the chat-completion
        // importer — that's an expected miss, not a hard error, but we count
        // it so the summary stays honest.
        parseErrors++;
      }
      continue;
    }

    // ---- chats/<CharName>/*.jsonl → collect raw (bound to a card later) ----
    if (_eq(top, 'chats')) {
      // Expect chats/<CharName>/<file>.jsonl. Anything shallower / not a
      // jsonl is skipped.
      if (segments.length < 3 || _ext(segments.last) != 'jsonl') {
        skipped++;
        continue;
      }
      if (entry.size > kStBackupMaxFileBytes) {
        skipped++;
        continue;
      }
      try {
        final text = utf8.decode(entry.content);
        final lines = const LineSplitter().convert(text);
        chats.add(StBackupChat(
          characterFolder: segments[1],
          fileName: segments.last,
          lines: lines,
          // Infer the persona from the first is_user message so the UI can
          // link this chat to its imported persona.
          personaHint: stPersonaHintFromJsonl(lines),
        ));
      } catch (_) {
        parseErrors++;
      }
      continue;
    }

    // ---- everything else: out of scope, skip ----
    skipped++;
  }

  return StBackupPlan(
    characters: characters,
    lorebooks: lorebooks,
    presets: presets,
    regexRules: regexRules,
    personas: personas,
    personaAvatarBytes: personaAvatarBytes,
    personaAvatarFileById: personaAvatarFileById,
    personaLorebookNameById: personaLorebookNameById,
    chats: chats,
    parseErrors: parseErrors,
    skippedEntries: skipped,
  );
}

/// A persona parsed from `settings.json` paired with the bare avatar filename
/// (the `power_user.personas` map key) so the UI layer can match it to the
/// raw bytes collected from the `User Avatars/` folder.
class StParsedPersona {
  final Persona persona;
  final String avatarFile;

  /// The ST `persona_descriptions[file].lorebook` name (a world name, or ''),
  /// surfaced so the UI layer can OPTIONALLY bind a matching imported lorebook.
  final String lorebookName;

  StParsedPersona({
    required this.persona,
    required this.avatarFile,
    this.lorebookName = '',
  });
}

/// Parse SillyTavern user personas out of a decoded `settings.json` blob.
///
/// ST stores personas under `power_user`:
///   - `personas` = `{ "&lt;avatarFile&gt;.png": "&lt;DisplayName&gt;", ... }`
///   - `persona_descriptions` = `{ "&lt;avatarFile&gt;.png": { description,
///     ..., lorebook }, ... }`
///
/// For each `avatarFile → DisplayName` entry we build a [Persona] with a fresh
/// id, the DisplayName, the matching description (or ''), and a null avatar
/// (the bytes are externalised by the UI layer from the `User Avatars/`
/// folder). Returns an empty list when `power_user` / `personas` is
/// missing or not a map. NEVER throws on a missing / wrong-typed sub-block.
List<StParsedPersona> personasFromSettings(dynamic settingsRoot) {
  if (settingsRoot is! Map) return const [];
  final powerUser = settingsRoot['power_user'];
  if (powerUser is! Map) return const [];
  final personasMap = powerUser['personas'];
  if (personasMap is! Map) return const [];
  final descriptions = powerUser['persona_descriptions'];
  final descMap = descriptions is Map ? descriptions : const {};

  final out = <StParsedPersona>[];
  personasMap.forEach((file, displayName) {
    if (file is! String || file.isEmpty) return;
    final name = displayName is String ? displayName.trim() : '';
    if (name.isEmpty) return; // a nameless persona isn't usable
    var description = '';
    var lorebookName = '';
    final desc = descMap[file];
    if (desc is Map) {
      final d = desc['description'];
      if (d is String) description = d;
      final lb = desc['lorebook'];
      if (lb is String) lorebookName = lb.trim();
    }
    out.add(StParsedPersona(
      persona: Persona(
        id: newId('persona'),
        name: name,
        description: description,
      ),
      avatarFile: file,
      lorebookName: lorebookName,
    ));
  });
  return out;
}

/// Pull `extension_settings.regex` (an array of ST regex scripts) out of a
/// decoded `settings.json` blob and parse it into [RegexRule]s. Returns an
/// empty list when the field is missing or not an array; NEVER throws on a
/// missing / wrong-typed sub-block.
List<RegexRule> regexRulesFromSettings(dynamic settingsRoot) {
  if (settingsRoot is! Map) return const [];
  final ext = settingsRoot['extension_settings'];
  if (ext is! Map) return const [];
  final regex = ext['regex'];
  if (regex is! List) return const [];
  return parseStRegexScripts(regex);
}

/// UI wrapper: run the pure core in a `compute()` isolate so decoding a large
/// backup doesn't block the UI thread.
Future<StBackupPlan> planStBackup(Uint8List zipBytes) =>
    compute(_planStBackupEntry, zipBytes);

/// Top-level isolate entry point (must be a top-level / static function for
/// `compute`).
StBackupPlan _planStBackupEntry(Uint8List zipBytes) =>
    planStBackupCore(zipBytes);

/// Normalize a zip entry path: backslashes → forward slashes, strip a leading
/// slash, drop a trailing slash. (Zip paths are usually `/`-delimited, but be
/// tolerant.)
String _normalizePath(String name) {
  var p = name.replaceAll('\\', '/');
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// Case-insensitive segment compare (ST folder names like `OpenAI Settings`
/// are stable, but a few are capitalized inconsistently across versions).
bool _eq(String a, String b) => a.toLowerCase() == b.toLowerCase();

String _ext(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return '';
  return filename.substring(dot + 1).toLowerCase();
}
