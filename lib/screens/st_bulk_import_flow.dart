// Pyre 1.1 (F7) — UI flow for the bulk "Import from SillyTavern" entry.
//
// One entry where the user multi-selects a pile of mixed ST `.json` files (and
// `.png` cards). The PURE classifier + parser layer lives in
// services/st_bulk_import.dart; this file is the thin UI shell:
//   1. file_picker (allowMultiple, .json + .png),
//   2. routeStFile per file (pure → parsed Pyre objects, no store mutation),
//   3. the store-add loop here, calling the SAME add methods each per-type
//      screen uses (store.addCharacter / addLorebook / addRegexRule /
//      addPreset) so analytics / persistence / sync behave identically,
//   4. a summary sheet: a one-line rollup + a scrollable per-file ✓/✗ list.
//
// ignore_for_file: use_build_context_synchronously

import 'dart:convert' show base64Encode;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/attachment_store.dart';
import '../services/card_import.dart' show externalizeCharacterImages;
import '../services/lorebook_import.dart' show handleEmbeddedBookForCharacter;
import '../services/st_backup_import.dart';
import '../services/st_bulk_import.dart';
import '../services/st_chat_import.dart';
import '../services/st_classify.dart';
import '../state/app_store.dart';
import '../theme.dart';

/// Entry point wired from the More screen. Picks files, routes + persists them,
/// then shows the summary. Safe to call with a stale context — every async gap
/// is guarded.
Future<void> runStBulkImport(BuildContext context, AppStore store) async {
  final messenger = ScaffoldMessenger.of(context);

  final FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(
      // Also accept a full ST "Download Backup" `.zip` (handled by the backup
      // path below); loose `.json` / `.png` keep the existing multi-file path.
      type: FileType.custom,
      allowedExtensions: const ['json', 'png', 'zip'],
      allowMultiple: true,
      withData: true,
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open picker: $e')));
    return;
  }
  if (result == null || result.files.isEmpty) return;

  // If the user picked a `.zip`, treat the FIRST zip as a full SillyTavern
  // backup and run the dedicated unpack flow (a backup is a single archive —
  // multi-selecting several backups isn't a supported workflow). Loose
  // `.json` / `.png` files fall through to the existing per-file path.
  final zip = _firstZip(result.files);
  if (zip != null) {
    await _runBackupImport(context, store, zip);
    return;
  }

  // Route every file through the PURE layer first (no store mutation yet).
  final routed = <StRouteResult>[];
  for (final f in result.files) {
    final bytes = f.bytes;
    final name = f.name;
    if (bytes == null) {
      // No bytes (rare — e.g. a path-only pick). Record a skip; don't abort.
      routed.add(_byteslessResult(name));
      continue;
    }
    routed.add(routeStFile(name, Uint8List.fromList(bytes)));
  }

  // Apply in TWO phases so the store mutations coalesce into one notify +
  // one persist (perf-at-scale, audit 2026-06-05 #3):
  //   A) async PRE-pass — run the interactive embedded-character_book dialog
  //      per card (it can't be batched: it awaits the user, and mutates the
  //      character's lorebookIds + adds the embedded book). This is the only
  //      async work.
  //   B) sync ADD-pass — every store.add* for the prepared results, wrapped in
  //      a single store.runBatch (one rebuild, one re-encode instead of N).
  final prepared = <StRouteResult>[];
  for (final r in routed) {
    prepared.add(await _prepareRouted(context, store, r));
  }

  final applied = <StRouteResult>[];
  store.runBatch(() {
    for (final r in prepared) {
      applied.add(_addRouted(store, r));
    }
  });

  if (!context.mounted) return;
  await _showSummary(context, applied);
}

/// The first picked file whose name ends in `.zip`, or null when none is a
/// zip. Used to decide between the backup path and the loose-file path.
PlatformFile? _firstZip(List<PlatformFile> files) {
  for (final f in files) {
    if (f.name.toLowerCase().endsWith('.zip')) return f;
  }
  return null;
}

/// Full SillyTavern backup (.zip) import: decode (in an isolate) → bind chats
/// to their imported characters → persist everything via the SAME store
/// add-methods the loose-file path uses → show a summary dialog. Resilient:
/// every add is best-effort; one bad object never aborts the import.
Future<void> _runBackupImport(
  BuildContext context,
  AppStore store,
  PlatformFile file,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final bytes = file.bytes;
  if (bytes == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not read the backup file.')),
    );
    return;
  }

  // Decode + route in a compute() isolate so the 47 MB zip doesn't jank the UI.
  final StBackupPlan plan;
  try {
    plan = await planStBackup(Uint8List.fromList(bytes));
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Could not read the backup: $e')),
    );
    return;
  }
  if (!context.mounted) return;

  // Perf-at-scale (audit 2026-06-05 #3): a real backup is "hundreds of files".
  // Adding each via store.add* fires one notifyListeners() + one debounced
  // persist PER record — hundreds of full-library rebuilds and a re-encode of
  // the growing blob each time. The ONLY async work is externalising persona
  // avatars into the AttachmentStore, so we do that FIRST (outside the batch),
  // then run every synchronous store mutation inside a single store.runBatch
  // → exactly ONE notify + ONE persist for the whole import.

  // Pre-store persona avatars (the sole async step) so the add-loop is pure.
  final personaAvatarRef = <String, String>{}; // persona.id → avatar ref/data
  for (final p in plan.personas) {
    final avatarFile = plan.personaAvatarFileById[p.id];
    if (avatarFile == null) continue;
    final bytes = plan.personaAvatarBytes[avatarFile];
    if (bytes == null || bytes.isEmpty) continue;
    try {
      // Externalise → pyre://attachment/<hash> (web has no fs → null, so fall
      // back to an inline data URL, matching the card path).
      final ref = await AttachmentStore.store(bytes, mime: 'image/png');
      personaAvatarRef[p.id] =
          ref ?? 'data:image/png;base64,${base64Encode(bytes)}';
    } catch (_) {
      // best-effort — a persona that fails to externalise keeps its prior
      // avatar (if any) and still imports below.
    }
  }

  // B-2 / H-6: externalise each imported card's INLINE avatar + gallery into
  // the AttachmentStore BEFORE the synchronous batch (the only async step for
  // characters, mirroring the persona pre-store above). `routeStFile` builds
  // characters with inline `data:` avatars; without this they'd persist as
  // inline base64 forever (re-encoded on every save, copied into all backups).
  for (final c in plan.characters) {
    await externalizeCharacterImages(c);
  }

  // Persist cards FIRST and build the name→Character map so chats can bind. We
  // run the embedded-character_book flow per card exactly like a single import.
  final byName = <String, Character>{};
  var addedCharacters = 0;
  var addedLorebooks = 0;
  // Lorebook id by lowercased name, so a persona's ST `lorebook` reference can
  // (optionally) be bound to the matching imported book.
  final lorebookIdByName = <String, String>{};
  var addedPresets = 0;
  var addedRegex = 0;
  var addedPersonas = 0;
  final personaIdByAvatarFile = <String, String>{};
  final personaIdByName = <String, String>{};
  var addedChats = 0;
  var orphanChats = 0;

  store.runBatch(() {
    for (final c in plan.characters) {
      try {
        // A backup card may carry an embedded character_book in its data; the
        // loose-file path offers it interactively, but a backup can hold many
        // cards (and worlds are imported separately from `worlds/`), so we
        // DON'T prompt here — the card imports with its inline `extensions`
        // intact and any standalone worlds land via the worlds/ folder. (No
        // data is lost; the embedded book simply isn't auto-extracted into a
        // separate Lorebook in the bulk path, mirroring how the bulk loose-file
        // path treats a card with no user present to answer the dialog when run
        // unattended.)
        store.addCharacter(c);
        byName[c.name.toLowerCase()] = c;
        addedCharacters++;
      } catch (_) {
        // best-effort — skip a card that fails to save.
      }
    }

    for (final l in plan.lorebooks) {
      try {
        store.addLorebook(l);
        lorebookIdByName[l.name.toLowerCase()] = l.id;
        addedLorebooks++;
      } catch (_) {}
    }

    for (final p in plan.presets) {
      try {
        store.addPreset(p);
        addedPresets++;
      } catch (_) {}
    }

    for (final r in plan.regexRules) {
      try {
        store.addRegexRule(r);
        addedRegex++;
      } catch (_) {}
    }

    // Persist personas using the avatars pre-stored above. Build lookups
    // (avatarFile→id AND DisplayName→id) so imported chats can be linked to the
    // persona they were role-played with. We do NOT touch store.activePersonaId
    // — importing a backup shouldn't hijack the user's current active persona
    // (addPersona only sets it when there is no active persona yet, mirroring
    // fresh-install seeding).
    for (final p in plan.personas) {
      try {
        final ref = personaAvatarRef[p.id];
        if (ref != null) p.avatar = ref;
        // OPTIONAL: bind a matching imported lorebook by name (ST's
        // persona_descriptions[file].lorebook). Skip silently when no match.
        final lbName = plan.personaLorebookNameById[p.id];
        if (lbName != null && lbName.isNotEmpty) {
          final lbId = lorebookIdByName[lbName.toLowerCase()];
          if (lbId != null && !p.lorebookIds.contains(lbId)) {
            p.lorebookIds.add(lbId);
          }
        }
        store.addPersona(p);
        final avatarFile = plan.personaAvatarFileById[p.id];
        if (avatarFile != null && avatarFile.isNotEmpty) {
          personaIdByAvatarFile[avatarFile.toLowerCase()] = p.id;
        }
        personaIdByName[p.name.toLowerCase()] = p.id;
        addedPersonas++;
      } catch (_) {
        // best-effort — skip a persona that fails to save.
      }
    }

    // Bind chats to their matching imported character by folder name; orphans
    // (no matching card) are skipped + counted. Also link each chat to the
    // persona it was role-played with (avatarFile match first, DisplayName
    // fallback) BEFORE persisting.
    for (final c in plan.chats) {
      final character = byName[c.characterFolder.toLowerCase()];
      if (character == null) {
        orphanChats++;
        continue;
      }
      try {
        final chat = chatFromStJsonl(c.lines, character: character);
        if (chat == null) {
          orphanChats++; // nothing usable parsed out of the log
          continue;
        }
        // Resolve the persona: prefer the avatar filename, fall back to the
        // DisplayName. Leave personaId null when neither matches an import.
        final hint = c.personaHint;
        String? personaId;
        if (hint.avatarFile.isNotEmpty) {
          personaId = personaIdByAvatarFile[hint.avatarFile.toLowerCase()];
        }
        personaId ??= hint.name.isNotEmpty
            ? personaIdByName[hint.name.toLowerCase()]
            : null;
        chat.personaId = personaId;
        store.addImportedChat(chat);
        addedChats++;
      } catch (_) {
        orphanChats++;
      }
    }
  });

  if (!context.mounted) return;
  await _showBackupSummary(
    context,
    characters: addedCharacters,
    lorebooks: addedLorebooks,
    presets: addedPresets,
    regexRules: addedRegex,
    personas: addedPersonas,
    chats: addedChats,
    orphanChats: orphanChats,
    parseErrors: plan.parseErrors,
  );
}

/// Summary dialog for a backup import. Plain count rollup + the explicit
/// "skipped by design" note, plus orphan-chat / parse-error counts when any.
Future<void> _showBackupSummary(
  BuildContext context, {
  required int characters,
  required int lorebooks,
  required int presets,
  required int regexRules,
  required int personas,
  required int chats,
  required int orphanChats,
  required int parseErrors,
}) async {
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';

  final lines = <String>[
    'Imported ${plural(characters, 'character')}, '
        '${plural(lorebooks, 'lorebook')}, '
        '${plural(presets, 'preset')}, '
        '${plural(regexRules, 'regex rule')}, '
        '${plural(personas, 'persona')}, '
        'and ${plural(chats, 'chat')}.',
  ];
  if (orphanChats > 0) {
    lines.add('${plural(orphanChats, 'chat')} skipped (no matching card or '
        'empty log).');
  }
  if (parseErrors > 0) {
    lines.add('${plural(parseErrors, 'file')} could not be parsed.');
  }
  lines.add(StBackupPlan.skippedNote);

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Row(
        children: const [
          Icon(Icons.download_done, color: EmberColors.primary, size: 22),
          SizedBox(width: 10),
          Expanded(child: Text('SillyTavern backup imported')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              Text(
                lines[i],
                style: TextStyle(
                  color: i == lines.length - 1
                      ? EmberColors.textMid
                      : EmberColors.textHigh,
                  fontSize: 14,
                  height: 1.4,
                  fontWeight:
                      i == 0 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// Phase A (async, interactive): run the per-card embedded-`character_book`
/// dialog (exactly like a single-card import) BEFORE the batched add-pass, so
/// the card's `lorebookIds` are settled and the prepared result can be added
/// synchronously inside [store.runBatch]. Non-card artifacts pass through
/// unchanged. Never adds the artifact itself — that's [_addRouted].
Future<StRouteResult> _prepareRouted(
  BuildContext context,
  AppStore store,
  StRouteResult r,
) async {
  if (!r.ok) return r; // already a failure / skip — nothing to prepare.
  if (r.artifact == StArtifact.card &&
      r.cardData != null &&
      r.character != null &&
      context.mounted) {
    try {
      // Offer the embedded character_book (if any). This may add a (hidden or
      // visible) lorebook to the store and append to character.lorebookIds;
      // those few lorebook adds happen here (outside the batch) because they're
      // gated on the user's per-card dialog answer.
      await handleEmbeddedBookForCharacter(
        context: context,
        store: store,
        character: r.character!,
        charaCardData: r.cardData!,
      );
    } catch (e) {
      return _failedCopy(r, 'Failed to save: $e');
    }
  }
  return r;
}

/// Phase B (sync): persist ONE prepared result via the matching real AppStore
/// add method. Returns the same result on success, or a failure-flavoured copy
/// if the add threw. Runs inside [store.runBatch] so the whole loose-file batch
/// is one notify + one persist.
StRouteResult _addRouted(AppStore store, StRouteResult r) {
  if (!r.ok) return r; // already a failure / skip — nothing to add.
  try {
    switch (r.artifact) {
      case StArtifact.card:
        store.addCharacter(r.character!);
      case StArtifact.lorebook:
        store.addLorebook(r.lorebook!);
      case StArtifact.regex:
        for (final rule in r.regexRules!) {
          store.addRegexRule(rule);
        }
      case StArtifact.preset:
        store.addPreset(r.preset!);
      case StArtifact.unknown:
        break; // never ok=true with unknown, but keep the switch total.
    }
    return r;
  } catch (e) {
    return _failedCopy(r, 'Failed to save: $e');
  }
}

StRouteResult _failedCopy(StRouteResult r, String detail) => StRouteResult(
      name: r.name,
      artifact: r.artifact,
      ok: false,
      detail: detail,
    );

StRouteResult _byteslessResult(String name) => StRouteResult(
      name: name,
      artifact: StArtifact.unknown,
      ok: false,
      detail: 'Failed: could not read file bytes',
    );

/// Bottom-sheet summary: a bold one-line rollup + a scrollable per-file list
/// with ✓/✗ and the detail string. Failures stay legible (filename + reason).
Future<void> _showSummary(
  BuildContext context,
  List<StRouteResult> results,
) async {
  final summary = summariseStBatch(results);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    builder: (sheet) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        builder: (ctx, scrollController) {
          return Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: EmberColors.stroke,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    const Icon(Icons.download_done,
                        color: EmberColors.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Import from SillyTavern',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    summary,
                    style: const TextStyle(
                      color: EmberColors.textHigh,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(color: EmberColors.stroke, height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  itemCount: results.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (_, i) => _ResultRow(results[i]),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('Done'),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class _ResultRow extends StatelessWidget {
  final StRouteResult r;
  const _ResultRow(this.r);

  @override
  Widget build(BuildContext context) {
    final ok = r.ok;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: EmberColors.bgElevated,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.cancel,
            size: 18,
            color: ok ? EmberColors.success : EmberColors.danger,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.name,
                  style: const TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  r.detail,
                  style: TextStyle(
                    color: ok ? EmberColors.textMid : EmberColors.danger,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
