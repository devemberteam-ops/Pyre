// 1.2.1 item #6: let a user relocate Pyre's data directory via
// `PYRE_DATA_DIR` (desktop only), so a Syncthing-watched folder can hold
// the whole data root instead of the fixed app-documents location.
//
// Single seam for the three sites that previously built
// `<app-documents>/EmberChat[-dev]` by hand (storage.dart, attachment_store.dart,
// device_registry.dart). Web has no filesystem (callers already bail on
// `kIsWeb` before reaching this); mobile has no meaningful env var — both
// keep today's behavior (plain app-documents dir).

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

import '../dev_flavor.dart';

/// PURE decision. Given the raw PYRE_DATA_DIR env value (or null) and the
/// platform documents-dir path, return the PARENT directory that Pyre's data
/// root (`EmberChat/`) should sit under. A set, non-blank override wins;
/// otherwise the documents dir. (Trims; blank/whitespace is treated as unset.)
String resolveDataParentPath(String? envDataDir, String documentsPath) {
  final override = envDataDir?.trim();
  if (override != null && override.isNotEmpty) return override;
  return documentsPath;
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
/// so a fresh PYRE_DATA_DIR path works on first run.
Future<Directory> pyreDataRoot() async {
  final parent = await pyreDataParent();
  final root = Directory('${parent.path}/${pyreDataDirName()}');
  if (!await root.exists()) {
    await root.create(recursive: true);
  }
  return root;
}
