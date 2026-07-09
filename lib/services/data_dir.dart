// 1.2.1 item #6: let a user relocate Pyre's data directory via
// `PYRE_DATA_DIR` (desktop only), so a Syncthing-watched folder can hold
// the whole data root instead of the fixed app-documents location.
//
// Single seam for the three sites that previously built
// `<app-documents>/EmberChat[-dev]` by hand (storage.dart, attachment_store.dart,
// device_registry.dart). Web has no filesystem (callers already bail on
// `kIsWeb` before reaching this); mobile has no meaningful env var — both
// keep today's behavior (plain app-documents dir).
//
// RESILIENCE (1.2.1 audit fix): a broken override must NEVER brick the app.
// `pyreDataRoot()` is called from main()'s boot path (AttachmentStore.warmUp,
// store.load) BEFORE runApp — an uncaught FileSystemException there means the
// window never opens, on every launch, until the user hand-fixes an OS env
// var they may not remember setting. So an unusable override (illegal chars,
// quotes cmd.exe didn't strip, a path under a file, a missing drive, no
// write permission) degrades to the default documents location instead of
// throwing.

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

import '../dev_flavor.dart';

/// PURE decision. Given the raw PYRE_DATA_DIR env value (or null) and the
/// platform documents-dir path, return the PARENT directory that Pyre's data
/// root (`EmberChat/`) should sit under. A set, non-blank override wins;
/// otherwise the documents dir.
///
/// Normalisation: trims whitespace, then strips ONE pair of surrounding
/// double or single quotes — `cmd.exe` does NOT strip quotes from
/// `set PYRE_DATA_DIR="C:\Sync\Pyre"` (unlike PowerShell), and `"` is an
/// illegal NTFS filename character, so the raw value would be unusable.
/// Blank/whitespace/quotes-only is treated as unset.
String resolveDataParentPath(String? envDataDir, String documentsPath) {
  var override = envDataDir?.trim();
  if (override != null && override.length >= 2) {
    final first = override[0];
    final last = override[override.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      override = override.substring(1, override.length - 1).trim();
    }
  }
  if (override != null && override.isNotEmpty) return override;
  return documentsPath;
}

/// Resolve Pyre's data root given an override value and the documents path,
/// creating the directory if missing. NEVER throws for a bad override: any
/// failure to create/use the override root falls back to the default
/// `<documents>/EmberChat[-dev]` location (which is today's behavior when no
/// override is set). Kept separate from [pyreDataRoot] so the fallback is
/// unit-testable without Platform.environment / path_provider.
Future<Directory> dataRootFor(String? envDataDir, String documentsPath) async {
  final name = pyreDataDirName();
  final parent = resolveDataParentPath(envDataDir, documentsPath);
  if (parent != documentsPath) {
    try {
      final root = Directory('$parent${Platform.pathSeparator}$name');
      if (!await root.exists()) {
        await root.create(recursive: true);
      }
      return root;
    } catch (e) {
      // Unusable override — degrade to the default location rather than
      // failing app boot forever. (Reaching the error log this early in
      // boot isn't safe; the debug line at least aids `flutter run`.)
      debugPrint('[DataDir] PYRE_DATA_DIR override "$parent" is unusable '
          '($e) — falling back to the default data directory.');
    }
  }
  final root = Directory('$documentsPath${Platform.pathSeparator}$name');
  if (!await root.exists()) {
    await root.create(recursive: true);
  }
  return root;
}

/// Parent dir for Pyre's data root. Honors PYRE_DATA_DIR on desktop only.
Future<Directory> pyreDataParent() async {
  final docs = await getApplicationDocumentsDirectory();
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return Directory(
        resolveDataParentPath(Platform.environment['PYRE_DATA_DIR'], docs.path));
  }
  return docs;
}

/// Pyre's data root: `<parent>/EmberChat`. Created (recursively) if missing,
/// so a fresh PYRE_DATA_DIR path works on first run. Resilient: a broken
/// override falls back to the default documents location (see [dataRootFor]).
Future<Directory> pyreDataRoot() async {
  final docs = await getApplicationDocumentsDirectory();
  final env = (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
      ? Platform.environment['PYRE_DATA_DIR']
      : null;
  return dataRootFor(env, docs.path);
}
