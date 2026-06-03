// Cross-platform JSON storage for the Pyre state blob.
//
// NOTE on the directory/file name: the on-disk path still says
// "EmberChat" / "emberchat_state.json". Pyre was previously called
// EmberChat; keeping the legacy path means existing test installs don't
// silently lose their state on rename. Users never see this path.
// - Web: uses `shared_preferences` (LocalStorage under the hood)
// - Other platforms: writes a JSON file under the app documents dir
// Same key the JS prototype uses, so backups remain portable.
//
// Wave CY.18.40: hardening pass after a user-reported total-wipe bug.
// The previous implementation was a 30-line wrapper around
// File.writeAsString — fast path, but vulnerable to two failure modes
// that observably happened in the wild:
//
//   1. Mid-write crash → file truncated → jsonDecode throws on next
//      load → load() returns null → app boots fresh, USER'S DATA
//      LOOKS GONE (still on disk, but app can't read it).
//
//   2. A single malformed field in the JSON → jsonDecode succeeds but
//      AppStore.load throws halfway through parsing → silent catch
//      leaves remaining fields at defaults.
//
// Fixes here address layer 1 (atomic IO + rolling backups + salvage
// loader). Layer 2 is fixed in AppStore.load itself (per-model
// isolation, same wave). The class also exposes a `LoadResult` so the
// UI can show diagnostics in Storage screen instead of leaving the
// user wondering "did Pyre eat my data?"

import 'dart:convert';
import 'dart:io' show File, Directory;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:pyre/dev_flavor.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String storageKey = 'emberchat.v1';
const String stateFileName = 'emberchat_state.json';

/// Status of the last load attempt. Surfaced in the Storage screen so
/// the user knows whether they're seeing the real state, a recovered
/// state, or a fresh start.
enum LoadStatus {
  /// Brand-new install — there was no state file or it was empty.
  freshInstall,

  /// Main state file parsed cleanly.
  ok,

  /// Main file was corrupt; fell back to a rotated backup.
  recoveredFromBackup,

  /// Main + backups failed; the salvage parser pulled what it could
  /// from a truncated main file.
  salvagedPartial,

  /// Everything failed. App boots with default state but the file
  /// might still hold recoverable data — the user should look at the
  /// diagnostics in Storage screen before doing anything destructive.
  failed,
}

class LoadResult {
  final LoadStatus status;
  final Map<String, dynamic>? data;
  /// Human-readable description of what happened — shown verbatim in
  /// the Storage screen. Empty when nothing notable.
  final String diagnostics;
  const LoadResult({
    required this.status,
    required this.data,
    this.diagnostics = '',
  });
}

class JsonStorage {
  /// Last load result — read by the Storage screen for the diagnostics
  /// panel. Held statically because there's a single JsonStorage
  /// instance per app and the screen needs to see it after AppStore.load
  /// has long since returned.
  static LoadResult lastLoad =
      const LoadResult(status: LoadStatus.freshInstall, data: null);

  /// Backward-compatible entry point. Returns the parsed map (any
  /// origin: main / backup / salvage) or null when truly nothing
  /// loadable exists. AppStore continues to call this. Diagnostics go
  /// into [lastLoad].
  Future<Map<String, dynamic>?> load() async {
    final result = await loadWithStatus();
    lastLoad = result;
    return result.data;
  }

  /// Wave CY.18.40: full load pipeline with status reporting.
  ///   1. Try the main state file.
  ///   2. If main is missing/empty → freshInstall.
  ///   3. If main fails to parse → walk rotated backups newest-to-oldest.
  ///   4. If backups also fail → run the salvage parser on the main file.
  ///   5. If salvage also fails → return failed (data null).
  Future<LoadResult> loadWithStatus() async {
    final mainRaw = await _readRaw(stateFileName);
    if (mainRaw == null || mainRaw.isEmpty) {
      return const LoadResult(
        status: LoadStatus.freshInstall,
        data: null,
        diagnostics: 'No state file on disk — fresh install path.',
      );
    }
    // Strategy 1: main file parses cleanly.
    final mainParsed = _tryDecode(mainRaw);
    if (mainParsed != null) {
      return LoadResult(
        status: LoadStatus.ok,
        data: mainParsed,
        diagnostics:
            'Main state loaded (${mainRaw.length} bytes).',
      );
    }
    debugPrint('[storage] main file failed to parse, trying backups…');

    // Strategy 2: rotated backups, newest first.
    // Wave CY.18.41: bumped 3 → 5 slots for extra recovery headroom.
    for (final suffix in const [
      '.bak.0',
      '.bak.1',
      '.bak.2',
      '.bak.3',
      '.bak.4',
    ]) {
      final bakRaw = await _readRaw('$stateFileName$suffix');
      if (bakRaw == null || bakRaw.isEmpty) continue;
      final parsed = _tryDecode(bakRaw);
      if (parsed != null) {
        debugPrint('[storage] recovered from $suffix');
        return LoadResult(
          status: LoadStatus.recoveredFromBackup,
          data: parsed,
          diagnostics:
              'Main state was corrupt (${mainRaw.length} bytes, '
              'unparseable JSON). Recovered from rotated backup '
              '$suffix (${bakRaw.length} bytes). The bad main file '
              'will be overwritten by the next save.',
        );
      }
    }

    // Strategy 3: salvage parser — try increasingly aggressive
    // prefix-truncation of the main file to find a parseable JSON
    // object hiding behind a truncated tail.
    final salvaged = _salvageParse(mainRaw);
    if (salvaged != null) {
      return LoadResult(
        status: LoadStatus.salvagedPartial,
        data: salvaged,
        diagnostics:
            'Main + backups all failed. The salvage parser pulled a '
            'parseable prefix from the main file (${mainRaw.length} '
            'bytes raw). Some recent edits may be missing — they were '
            'in the truncated tail. Recommend exporting a backup '
            '(More → Backup and Restore) before doing anything else.',
      );
    }

    // Total failure.
    return LoadResult(
      status: LoadStatus.failed,
      data: null,
      diagnostics:
          'Main file (${mainRaw.length} bytes) could not be parsed '
          'and no rotated backup was available. Salvage parser '
          'also failed. The raw file is still on disk at '
          'app-documents-dir/EmberChat/$stateFileName — manual '
          'recovery may be possible. Do NOT use the "Wipe local '
          'data" action until you\'ve copied that file off the '
          'device.',
    );
  }

  /// Attempts to jsonDecode and confirm a `Map<String,dynamic>`.
  /// Returns null on any failure; never throws.
  Map<String, dynamic>? _tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  /// Wave CY.18.40 salvage: when the raw blob can't parse end-to-end
  /// (typical: app crashed mid-write, file is truncated), try parsing
  /// progressively-shorter prefixes that end at the last `}` boundary
  /// we can find. Walks back through closing braces until either a
  /// parse succeeds or we run out of file. Capped at 4096 iterations
  /// so a pathological input can't spin forever.
  Map<String, dynamic>? _salvageParse(String raw) {
    var prefix = raw;
    var iterations = 0;
    while (prefix.length > 2 && iterations < 4096) {
      iterations++;
      final lastBrace = prefix.lastIndexOf('}');
      if (lastBrace <= 0) return null;
      // Trim everything after this brace (closing the top-level object
      // even if the inner state is incomplete).
      prefix = prefix.substring(0, lastBrace + 1);
      final decoded = _tryDecode(prefix);
      if (decoded != null) {
        debugPrint('[storage] salvage succeeded at ${prefix.length} '
            'bytes (${raw.length - prefix.length} discarded)');
        return decoded;
      }
      // Step inside this brace so the next iteration finds a SHORTER
      // closing brace (otherwise lastIndexOf returns the same position
      // every loop and we'd hang on a comma/quote mismatch).
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return null;
  }

  /// Atomic write — write to `.tmp`, then rename. Rename is atomic on
  /// POSIX filesystems and Android-internal storage, so a crash mid-
  /// write never leaves the main file truncated. Backups rotate
  /// BEFORE the write so a successful save preserves the previous
  /// good state in `state.bak.0`, the one before in `.bak.1`, etc.
  ///
  /// Wave CY.18.40: replaces the old non-atomic File.writeAsString
  /// that allowed mid-flight crashes to truncate the main file.
  Future<void> save(Map<String, dynamic> data) async {
    final encoded = jsonEncode(data);
    if (kIsWeb) {
      // SharedPreferences on web is effectively atomic at the JS
      // localStorage layer — no temp file dance needed.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, encoded);
      return;
    }
    await _writeAtomicFile(encoded);
  }

  Future<void> _writeAtomicFile(String raw) async {
    final mainFile = await _stateFile();
    await mainFile.parent.create(recursive: true);

    // Rotate backups first. Only rotate if the current main file is
    // non-empty (don't overwrite good backups with stale empty state).
    if (await mainFile.exists()) {
      final mainLen = await mainFile.length();
      if (mainLen > 0) {
        await _rotateBackups(mainFile);
      }
    }

    // Write to .tmp, then atomic rename. If the app dies between
    // `writeAsString` and `rename`, the main file is untouched and
    // .tmp is harmless garbage that we clean up on next save.
    final tmpFile = File('${mainFile.path}.tmp');
    try {
      await tmpFile.writeAsString(raw, flush: true);
    } catch (e) {
      debugPrint('[storage] tmp write failed: $e');
      // Clean up partial tmp so it doesn't accumulate.
      if (await tmpFile.exists()) {
        try { await tmpFile.delete(); } catch (_) {}
      }
      rethrow;
    }
    // Wave CY.18.41: REMOVED the `mainFile.delete()` before rename.
    // File.rename overwrites the target atomically on POSIX (Linux /
    // Android internal storage) and on Windows when the source and
    // destination are on the same volume — which is always true here
    // (we're inside the app's documents directory). The explicit
    // delete created a brief sub-millisecond window where main
    // didn't exist; a power loss or process kill in that window
    // would have left no main file at all. Rename-overwrite skips
    // that gap.
    await tmpFile.rename(mainFile.path);

    // Wave CY.18.41: verify the just-written file actually parses.
    // Catches the rare case where atomic rename succeeded but the
    // resulting bytes are somehow corrupt (filesystem bug, hardware
    // glitch, jsonEncode produced something jsonDecode can't reload).
    // If verify fails, restore main from bak.0 — which we just rotated
    // a few steps up and is the previous known-good state.
    final readback = await _readRaw(stateFileName);
    final parsed = readback == null ? null : _tryDecode(readback);
    if (parsed == null) {
      debugPrint('[storage] write-verify FAILED — restoring from bak.0');
      final bak0 = File('${mainFile.path}.bak.0');
      if (await bak0.exists()) {
        try {
          await bak0.copy(mainFile.path);
        } catch (e) {
          debugPrint('[storage] bak.0 restore also failed: $e');
        }
      }
    }
  }

  /// Wave CY.18.41: rotate the 5-slot backup chain. Oldest first:
  ///   bak.3 → bak.4   (oldest gets pushed out, becomes the new oldest)
  ///   bak.2 → bak.3
  ///   bak.1 → bak.2
  ///   bak.0 → bak.1
  ///   main  → bak.0   (via copy — main needs to stay readable until
  ///                    the atomic rename of the new .tmp lands)
  /// Each step wrapped individually so a single fs hiccup doesn't
  /// abort the chain.
  Future<void> _rotateBackups(File mainFile) async {
    final basePath = mainFile.path;
    // Slide each older slot one step further back. Order matters:
    // start from the oldest so we don't overwrite a slot we still
    // need to read.
    for (var i = 3; i >= 0; i--) {
      final from = File('$basePath.bak.$i');
      final to = File('$basePath.bak.${i + 1}');
      try {
        if (await from.exists()) {
          if (await to.exists()) await to.delete();
          await from.rename(to.path);
        }
      } catch (e) {
        debugPrint('[storage] rotate bak.$i→bak.${i + 1} failed: $e');
      }
    }
    // Newest: main → bak.0 via copy (we'll overwrite main right after,
    // so rename would break the atomic-write contract above).
    try {
      await mainFile.copy('$basePath.bak.0');
    } catch (e) {
      debugPrint('[storage] copy main→bak.0 failed: $e');
    }
  }

  /// Wave CY.18.41: file names of every slot we manage — main +
  /// backups + the temp file used during atomic writes. Centralised
  /// so `approximateSize` and `clear` stay in sync with the rotation
  /// code above (don't have to remember to bump magic-number lists
  /// when we change the backup count).
  static const List<String> _allManagedFiles = [
    stateFileName,
    '$stateFileName.bak.0',
    '$stateFileName.bak.1',
    '$stateFileName.bak.2',
    '$stateFileName.bak.3',
    '$stateFileName.bak.4',
    '$stateFileName.tmp',
  ];

  /// Approximate size of the stored blob in bytes. Used by the Storage
  /// screen. Sums main + backups so the user sees what's actually
  /// occupying space.
  Future<int> approximateSize() async {
    if (kIsWeb) {
      final raw = await _readRaw(stateFileName);
      return raw?.length ?? 0;
    }
    var total = 0;
    for (final name in _allManagedFiles) {
      final raw = await _readRaw(name);
      if (raw != null) total += raw.length;
    }
    return total;
  }

  /// Erase the blob — used by the "Wipe local data" action. Wipes
  /// main file + all rotated backups so a wipe is actually a wipe.
  Future<void> clear() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
      return;
    }
    for (final name in _allManagedFiles) {
      final file = File('${(await _appDir()).path}/$name');
      if (await file.exists()) {
        try { await file.delete(); } catch (_) {}
      }
    }
  }

  Future<String?> _readRaw(String fileName) async {
    if (kIsWeb) {
      // Web only has one slot. Backups n/a there.
      if (fileName != stateFileName) return null;
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(storageKey);
    }
    final file = File('${(await _appDir()).path}/$fileName');
    if (!await file.exists()) return null;
    return await file.readAsString();
  }

  Future<Directory> _appDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/${pyreDataDirName()}');
  }

  Future<File> _stateFile() async {
    final emberDir = await _appDir();
    return File('${emberDir.path}/$stateFileName');
  }
}
