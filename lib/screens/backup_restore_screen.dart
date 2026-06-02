import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../services/secure_keys.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  // Wave CY.18.169: selective backup. Each category can be toggled out of
  // the export. The matching IMPORT is a MERGE — only categories present
  // in the file are replaced, so a partial backup restores just its
  // categories without nuking the rest.
  static const String _catCharacters = 'characters';
  static const String _catPersonas = 'personas';
  static const String _catChats = 'chats';
  static const String _catLorebooks = 'lorebooks';
  static const String _catPresets = 'presets';
  static const String _catProviders = 'providers';
  static const String _catSettings = 'settings';
  static const String _catCreatorSessions = 'creatorSessions';
  static const Set<String> _allCategories = {
    _catCharacters,
    _catPersonas,
    _catChats,
    _catLorebooks,
    _catPresets,
    _catProviders,
    _catSettings,
    _catCreatorSessions,
  };

  /// What the next export will include. Everything EXCEPT Connections is on
  /// by default; Connections (API providers) is OPT-IN because including it
  /// writes your API keys in PLAIN TEXT — there is no separate "include keys"
  /// switch any more; checking Connections IS the consent (warned on the row
  /// + a confirm dialog). The user toggles any of these.
  final Set<String> _include = {
    _catCharacters,
    _catPersonas,
    _catChats,
    _catLorebooks,
    _catPresets,
    _catSettings,
    _catCreatorSessions,
  };

  /// Hard cap on imports — anything larger than this is almost certainly
  /// either a corrupt file or a JSON bomb. Refusing early avoids OOM /
  /// pathological `jsonDecode` runs that would freeze the UI.
  static const int _maxImportBytes = 50 * 1024 * 1024; // 50 MB

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Export',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Save your data to a single JSON file. Pick what to '
                    'include below. Compatible with the HTML prototype '
                    'backup format.',
                    style:
                        TextStyle(color: EmberColors.textMid, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'What to include',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  _catCheck(_catCharacters, 'Characters',
                      '${store.characters.length} cards'),
                  _catCheck(_catPersonas, 'Personas',
                      '${store.personas.length}'),
                  _catCheck(_catChats, 'Chats',
                      '${store.chats.length} conversations + memory'),
                  _catCheck(_catLorebooks, 'Lorebooks',
                      '${store.lorebooks.length}'),
                  _catCheck(_catPresets, 'Presets',
                      'chat + creator prompt presets'),
                  _catCheck(_catProviders, 'Connections',
                      '${store.providers.length} providers · ⚠ saved WITH your API keys in plain text'),
                  _catCheck(
                      _catSettings, 'App settings', 'model / chat / memory / UI'),
                  _catCheck(_catCreatorSessions, 'Creator drafts',
                      '${store.creatorSessions.length} in progress'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.ios_share, size: 16),
                          label: const Text('Share…'),
                          onPressed: () => _shareBackup(context, store),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy'),
                          onPressed: () => _copyJson(context, store),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.save_alt, size: 16),
                          label: const Text('Save'),
                          onPressed: () => _saveToFile(context, store),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Import',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Load a backup JSON. Only the categories present in the '
                    'file are replaced — anything not in the backup is left '
                    'untouched. (A full backup replaces everything.)',
                    style:
                        TextStyle(color: EmberColors.textMid, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.file_open_outlined, size: 16),
                    label: const Text('Choose file…'),
                    onPressed: () => _pickAndImport(context, store),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Wave CY.18.168: factory reset, tucked under Advanced so it's
          // out of the way. Auto-backs-up + double-confirms before wiping.
          Card(
            child: Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                title: const Text(
                  'Advanced',
                  style:
                      TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                children: [
                  // Wave CY.18.191: explicit scope + cross-link to
                  // Storage "Clear library". Copy only — no logic change.
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Full wipe: returns Pyre to a brand-new install — '
                      'characters, personas, chats, lorebooks, presets, '
                      'settings AND API keys. A full backup is saved first.\n\n'
                      'To delete only your library and keep your settings, '
                      'use Storage → Clear library.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('Reset to factory settings'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: EmberColors.danger,
                        side:
                            const BorderSide(color: EmberColors.danger),
                      ),
                      onPressed: () => _factoryReset(context, store),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Wave CY.18.168: in-app factory reset. Three gates + an auto-backup:
  /// (1) a warning confirm, (2) a type-"reset" confirm, (3) after writing
  /// a FULL backup (incl. keys) it shows where the backup landed and asks
  /// one last time — only then does it wipe. Aborts (without wiping) if
  /// the safety backup can't be written.
  Future<void> _factoryReset(BuildContext context, AppStore store) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmDelete(
      context,
      title: 'Reset Pyre to factory settings?',
      message:
          'This permanently deletes ALL data — every character, persona, '
          'chat, lorebook, preset, setting and API key — and returns the '
          'app to a brand-new install. '
          'A full backup is saved first so you can restore.\n\n'
          'To delete only your library and keep your settings, cancel and '
          'use Storage → Clear library. Continue?',
      confirmLabel: 'Continue',
    );
    if (!ok || !context.mounted) return;

    final typed = await _typeToConfirmReset(context);
    if (!typed || !context.mounted) return;

    // Write the safety backup: EVERYTHING except API keys (Gui's call —
    // the auto-file shouldn't carry plaintext keys; you re-enter them after
    // restore). Abort the whole reset if this fails: never wipe without a
    // net.
    String? backupPath;
    try {
      final json = const JsonEncoder.withIndent('  ').convert(
          _exportBlob(store, include: _allCategories, includeApiKeys: false));
      if (kIsWeb) {
        await Clipboard.setData(ClipboardData(text: json));
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final ts = DateTime.now()
            .toIso8601String()
            .replaceAll(':', '-')
            .split('.')
            .first;
        final file =
            File('${dir.path}/pyre-pre-reset-backup-$ts.json');
        await file.writeAsString(json);
        backupPath = file.path;
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text('Backup failed — reset aborted to keep your '
              'data safe: $e')));
      return;
    }
    if (!context.mounted) return;

    final reset = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Backup saved'),
        content: Text(
          backupPath != null
              ? 'A full backup (everything except API keys) was saved to:\n\n'
                  '$backupPath\n\n'
                  "You'll re-enter API keys after restoring. If you want a "
                  'totally clean slate afterwards, you can delete that file '
                  'yourself. Reset now?'
              : 'Web: the full backup JSON (no API keys) was copied to your '
                  'clipboard — paste it into a file to keep it. Reset now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: EmberColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Reset now'),
          ),
        ],
      ),
    );
    if (reset != true || !context.mounted) return;

    try {
      await store.factoryReset();
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text('Reset failed: $e')));
      return;
    }
    if (!context.mounted) return;
    // Back to the root so the fresh-install state (onboarding + seeded
    // examples) shows instead of this now-stale screen.
    Navigator.of(context).popUntil((r) => r.isFirst);
    messenger.showSnackBar(const SnackBar(
        content: Text('Pyre has been reset to factory settings.')));
  }

  /// Second gate: require the user to literally type "reset". The button
  /// stays disabled until the field matches (case-insensitive, trimmed).
  Future<bool> _typeToConfirmReset(BuildContext context) async {
    final ctl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setSt) {
          final canReset = ctl.text.trim().toLowerCase() == 'reset';
          return AlertDialog(
            title: const Text('Type to confirm'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'This cannot be undone except from the backup. Type '
                    '"reset" below to confirm.'),
                const SizedBox(height: 12),
                TextField(
                  controller: ctl,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'reset'),
                  onChanged: (_) => setSt(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: EmberColors.danger),
                onPressed: canReset ? () => Navigator.pop(c, true) : null,
                child: const Text('Reset'),
              ),
            ],
          );
        },
      ),
    );
    ctl.dispose();
    return result ?? false;
  }

  /// Wave CY.18.169: one include/exclude checkbox row for the export.
  Widget _catCheck(String key, String label, String sub) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      visualDensity: VisualDensity.compact,
      value: _include.contains(key),
      activeColor: EmberColors.primary,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      subtitle: sub.isEmpty
          ? null
          : Text(sub,
              style: const TextStyle(
                  fontSize: 11.5, color: EmberColors.textMid)),
      onChanged: (v) => setState(() {
        if (v == true) {
          _include.add(key);
        } else {
          _include.remove(key);
        }
      }),
    );
  }

  /// Build the export blob. Only the categories in [include] are written;
  /// each category's "active…" pointer rides along with it. When
  /// [includeApiKeys] is false (or providers aren't included) the bearer
  /// tokens are stripped so the file is safe to share. A partial blob
  /// imports as a MERGE (see [_applyImport]).
  Map<String, dynamic> _exportBlob(
    AppStore s, {
    required Set<String> include,
    required bool includeApiKeys,
  }) {
    final keysIncluded = includeApiKeys && include.contains(_catProviders);
    final blob = <String, dynamic>{
      // Wave CY.18.45: stamp the schema version into every backup so a
      // future Pyre can detect "older/newer than me" and migrate (or warn).
      'schemaVersion': AppStore.schemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'exportedFrom': 'emberchat-flutter',
      'containsApiKeys': keysIncluded,
    };
    if (include.contains(_catProviders)) {
      blob['providers'] = s.providers
          .map((p) => p.toJson(includeApiKey: includeApiKeys))
          .toList();
      blob['activeProviderId'] = s.activeProviderId;
      blob['creatorProviderId'] = s.creatorProviderId;
      blob['visionProviderId'] = s.visionProviderId;
    }
    if (include.contains(_catCharacters)) {
      blob['characters'] = s.characters.map((c) => c.toJson()).toList();
    }
    if (include.contains(_catPersonas)) {
      blob['personas'] = s.personas.map((p) => p.toJson()).toList();
      blob['activePersonaId'] = s.activePersonaId;
    }
    if (include.contains(_catChats)) {
      blob['chats'] = s.chats.map((c) => c.toJson()).toList();
    }
    if (include.contains(_catLorebooks)) {
      blob['lorebooks'] = s.lorebooks.map((l) => l.toJson()).toList();
    }
    if (include.contains(_catPresets)) {
      blob['presets'] = s.presets.map((p) => p.toJson()).toList();
      blob['activePresetId'] = s.activePresetId;
      // Wave CY.18.107: forkable Creator architect prompts ride with presets.
      blob['creatorPresets'] =
          s.creatorPresets.map((p) => p.toJson()).toList();
      blob['activeCreatorPresetId'] = s.activeCreatorPresetId;
    }
    if (include.contains(_catSettings)) {
      blob['modelSettings'] = s.modelSettings.toJson();
      blob['chatSettings'] = s.chatSettings.toJson();
      blob['memorySettings'] = s.memorySettings.toJson();
      blob['uiPrefs'] = s.uiPrefs.toJson();
    }
    if (include.contains(_catCreatorSessions)) {
      blob['creatorSessions'] =
          s.creatorSessions.map((cs) => cs.toJson()).toList();
      blob['activeCreatorSessionId'] = s.activeCreatorSessionId;
    }
    return blob;
  }

  Future<bool> _confirmKeyExport() async {
    if (!_include.contains(_catProviders)) return true;
    return confirmDelete(
      context,
      title: 'Export with API keys?',
      message:
          'The backup will contain your bearer tokens in plain text. Anyone who gets this file can spend on your provider accounts. Continue?',
      confirmLabel: 'Export anyway',
    );
  }

  /// Wave CY.18.169: block an export with nothing selected.
  bool _ensureSelection(BuildContext context) {
    if (_include.isNotEmpty) return true;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Pick at least one category to back up.')));
    return false;
  }

  Future<void> _copyJson(BuildContext context, AppStore store) async {
    if (!_ensureSelection(context)) return;
    if (!await _confirmKeyExport()) return;
    final json = const JsonEncoder.withIndent('  ').convert(
        _exportBlob(store, include: _include, includeApiKeys: _include.contains(_catProviders)));
    await Clipboard.setData(ClipboardData(text: json));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _include.contains(_catProviders)
              ? 'Copied — backup includes API keys.'
              : 'Copied — backup is key-free.',
        ),
      ),
    );
  }

  /// Write the backup to a temp file and hand it off to the OS share
  /// sheet — the user picks the transport (Quick Share for device-to-
  /// device, WhatsApp/Telegram/Signal for sending to someone, Drive/
  /// Dropbox/email for cloud storage, etc.). Replaces a hypothetical
  /// NFC transfer with something that actually works for multi-MB
  /// payloads and gives the user a transport they already trust.
  Future<void> _shareBackup(BuildContext context, AppStore store) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_ensureSelection(context)) return;
    if (!await _confirmKeyExport()) return;
    if (!context.mounted) return;
    try {
      final json = const JsonEncoder.withIndent('  ')
          .convert(_exportBlob(store,
              include: _include, includeApiKeys: _include.contains(_catProviders)));
      if (kIsWeb) {
        // Web has no share sheet — fall back to clipboard.
        await Clipboard.setData(ClipboardData(text: json));
        messenger.showSnackBar(
          const SnackBar(
              content: Text(
                  'Web: copied JSON to clipboard. Paste into a file to save.')),
        );
        return;
      }
      // Write to a temp file so the share sheet can pass a path to the
      // chosen transport. Wave CY.18.255 (audit FIX 5a): the backup can
      // carry API keys in plaintext, so we DELETE the temp file once the
      // share future completes rather than leaving it in the temp dir.
      final tmp = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filename = 'pyre-backup-$ts.json';
      final file = File('${tmp.path}/$filename');
      await file.writeAsString(json);

      final subject = _include.contains(_catProviders)
          ? 'Pyre backup (contains API keys — handle with care)'
          : 'Pyre backup';
      try {
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/json')],
          subject: subject,
          text: _include.contains(_catProviders)
              ? 'Pyre backup with API keys. Don\'t share this file with anyone you wouldn\'t hand your credit card to.'
              : 'Pyre backup (no API keys included — safe to share).',
        );
      } finally {
        // Best-effort cleanup — the chosen transport copies the bytes
        // synchronously before this future resolves, so deleting now is
        // safe. Swallow any error (file already gone / locked).
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {/* best-effort */}
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Share failed: $e')));
    }
  }

  Future<void> _saveToFile(BuildContext context, AppStore store) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!_ensureSelection(context)) return;
    if (!await _confirmKeyExport()) return;
    if (!context.mounted) return;
    try {
      final json = const JsonEncoder.withIndent('  ')
          .convert(_exportBlob(store,
              include: _include, includeApiKeys: _include.contains(_catProviders)));
      if (kIsWeb) {
        // Web cannot write arbitrary files — fall back to clipboard.
        await Clipboard.setData(ClipboardData(text: json));
        messenger.showSnackBar(
          const SnackBar(
              content: Text(
                  'Web: copied JSON to clipboard. Paste into a file to save.')),
        );
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/emberchat-backup-$ts.json');
      await file.writeAsString(json);
      messenger.showSnackBar(
        SnackBar(content: Text('Saved to ${file.path}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _pickAndImport(BuildContext context, AppStore store) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Could not read file bytes.')));
        return;
      }
      // Hard size cap — a malicious backup could otherwise OOM or freeze
      // the app inside jsonDecode + Message.fromJson recursion.
      if (bytes.length > _maxImportBytes) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Backup is too large (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB). Max 50 MB.',
            ),
          ),
        );
        return;
      }
      final text = utf8.decode(bytes);
      // Wave CY.18.42: try a full parse, then a salvage parse on
      // truncated tail. Pre-Wave the salvage path was only in
      // JsonStorage — a user with a corrupted backup file (typical
      // failure mode: app crashed mid-export pre-CY.18.42) got a
      // bare "Import failed: FormatException" with no recovery. Now
      // we try harder: walk back through closing braces on the raw
      // text and accept the longest prefix that parses cleanly.
      Map<String, dynamic>? blob = _tryDecodeBackup(text);
      var salvaged = false;
      if (blob == null) {
        blob = _salvageBackup(text);
        salvaged = blob != null;
      }
      if (blob == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(
              'Backup is not a parseable JSON object — the file may be '
              'corrupted. ${text.length} bytes read.')),
        );
        return;
      }
      // Wave CY.18.255 (audit FIX 5b): if the backup carries API keys,
      // confirm before adding/overwriting the user's saved keys.
      // Importing keys silently would let a shared/old backup clobber the
      // user's current credentials without warning.
      var importKeys = false;
      final hasKeys = _backupHasApiKeys(blob);
      if (hasKeys) {
        if (!context.mounted) return;
        importKeys = await confirmDelete(
          context,
          title: 'Import API keys?',
          message:
              'This backup contains API keys. Add/overwrite your saved keys with them? Choose "Keep mine" to import everything else and leave your current keys untouched.',
          confirmLabel: 'Use backup keys',
          cancelLabel: 'Keep mine',
        );
      }
      await _applyImport(store, blob, importKeys: importKeys);
      messenger.showSnackBar(
        SnackBar(
          content: Text(salvaged
              ? 'Backup imported with salvage — some recent edits in '
                  'the backup tail may be missing.'
              : (hasKeys && !importKeys)
                  ? 'Backup imported — your saved API keys were kept.'
                  : 'Backup imported.'),
          duration: Duration(seconds: salvaged ? 5 : 2),
        ),
      );
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  /// Wave CY.18.42: try jsonDecode; only accept a top-level
  /// `Map<String, dynamic>`. Returns null on any failure.
  Map<String, dynamic>? _tryDecodeBackup(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return null;
  }

  /// Wave CY.18.42: prefix-truncation salvage for backup files. Same
  /// algorithm as `JsonStorage._salvageParse` — walks back through
  /// closing braces until a parse succeeds. Capped at 4096 iterations.
  Map<String, dynamic>? _salvageBackup(String raw) {
    var prefix = raw;
    var iterations = 0;
    while (prefix.length > 2 && iterations < 4096) {
      iterations++;
      final lastBrace = prefix.lastIndexOf('}');
      if (lastBrace <= 0) return null;
      prefix = prefix.substring(0, lastBrace + 1);
      final decoded = _tryDecodeBackup(prefix);
      if (decoded != null) return decoded;
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return null;
  }

  /// Wave CY.18.255 (audit FIX 5b): does the backup carry any non-empty
  /// `providers[].apiKey`? Drives the import-keys confirm prompt. Tolerant
  /// of a malformed blob (returns false rather than throwing).
  bool _backupHasApiKeys(Map<String, dynamic> raw) {
    final providers = raw['providers'];
    if (providers is! List) return false;
    for (final p in providers) {
      if (p is Map) {
        final key = p['apiKey'];
        if (key is String && key.isNotEmpty) return true;
      }
    }
    return false;
  }

  /// Apply an imported backup blob. Wrapped in try/catch so a partial
  /// failure leaves the previous state untouched rather than half-applied.
  ///
  /// [importKeys] gates whether API keys carried in `providers[].apiKey`
  /// are written into SecureKeys (Wave CY.18.255, audit FIX 5b). The
  /// caller confirms with the user first; when false the keys are dropped
  /// from the imported providers in memory and the user's existing saved
  /// keys are left untouched.
  Future<void> _applyImport(
    AppStore s,
    Map<String, dynamic> raw, {
    required bool importKeys,
  }) async {
    // Wave CY.18.45: schema-version sniff on restore. A backup made by
    // a future Pyre build (user downgraded the APK + tried to restore
    // a newer file) gets a console warning here — we still attempt the
    // load because the fromJson layer is defensively tolerant, but a
    // user-visible diagnostic via loadErrors would also be ideal once
    // the restore flow has a place to surface it. For now print + let
    // the integrity sweep catch any straggler refs.
    final rawVer = raw['schemaVersion'];
    final fileVersion = rawVer is int
        ? rawVer
        : (rawVer is num ? rawVer.toInt() : 0);
    if (fileVersion > AppStore.schemaVersion) {
      debugPrint('[BackupRestore] file is schema v$fileVersion, '
          'current build understands v${AppStore.schemaVersion} — '
          'unknown fields will be ignored.');
    }

    // Wave CY.18.169: MERGE import. A backup can now be SELECTIVE (only
    // some categories present — see _exportBlob). Parse + REPLACE only the
    // categories whose key is PRESENT in the file; leave everything else in
    // the store untouched. A full backup (every key present) behaves
    // exactly as before. Parse into nullable locals first so a crafted
    // entry that throws doesn't half-apply.
    List<ApiProvider>? providers;
    List<Character>? characters;
    List<Persona>? personas;
    List<Chat>? chats;
    List<Lorebook>? lorebooks;
    List<Preset>? presets;
    List<CreatorPreset>? creatorPresets;
    List<CreatorSession>? creatorSessions;
    try {
      if (raw.containsKey('providers')) {
        providers = ((raw['providers'] as List?) ?? [])
            .map(
                (p) => ApiProvider.fromJson((p as Map).cast<String, dynamic>()))
            .toList();
      }
      if (raw.containsKey('characters')) {
        characters = ((raw['characters'] as List?) ?? [])
            .map((c) => Character.fromJson((c as Map).cast<String, dynamic>()))
            .toList();
      }
      if (raw.containsKey('personas')) {
        personas = ((raw['personas'] as List?) ?? [])
            .map((p) => Persona.fromJson((p as Map).cast<String, dynamic>()))
            .toList();
      }
      if (raw.containsKey('chats')) {
        chats = ((raw['chats'] as List?) ?? [])
            .map((c) => Chat.fromJson((c as Map).cast<String, dynamic>()))
            .toList();
      }
      if (raw.containsKey('lorebooks')) {
        lorebooks = ((raw['lorebooks'] as List?) ?? [])
            .map((l) => Lorebook.fromJson((l as Map).cast<String, dynamic>()))
            .toList();
      }
      if (raw.containsKey('presets')) {
        presets = ((raw['presets'] as List?) ?? [])
            .map((p) => Preset.fromJson((p as Map).cast<String, dynamic>()))
            .toList();
      }
      if (raw.containsKey('creatorPresets')) {
        creatorPresets = ((raw['creatorPresets'] as List?) ?? [])
            .map((p) =>
                CreatorPreset.fromJson((p as Map).cast<String, dynamic>()))
            .toList();
      }
      if (raw.containsKey('creatorSessions')) {
        creatorSessions = ((raw['creatorSessions'] as List?) ?? [])
            .map((cs) =>
                CreatorSession.fromJson((cs as Map).cast<String, dynamic>()))
            .toList();
      }
    } catch (e) {
      throw FormatException('Backup parse failed (likely corrupted): $e');
    }

    if (providers != null) {
      s.providers = providers;
      s.activeProviderId = raw['activeProviderId'] as String?;
      s.creatorProviderId = raw['creatorProviderId'] as String?;
      s.visionProviderId = raw['visionProviderId'] as String?;
    }
    if (characters != null) s.characters = characters;
    if (personas != null) {
      s.personas = personas;
      s.activePersonaId = raw['activePersonaId'] as String?;
    }
    if (chats != null) s.chats = chats;
    if (lorebooks != null) s.lorebooks = lorebooks;
    if (presets != null) {
      s.presets = presets;
      s.activePresetId = raw['activePresetId'] as String?;
    }
    if (creatorPresets != null) {
      s.creatorPresets = creatorPresets;
      s.activeCreatorPresetId = raw['activeCreatorPresetId'] as String?;
    }
    final ms = raw['modelSettings'];
    if (ms is Map) {
      s.modelSettings = ModelSettings.fromJson(ms.cast<String, dynamic>());
    }
    // Previously dropped — restore so users don't lose their chat/memory prefs.
    final cs = raw['chatSettings'];
    if (cs is Map) {
      s.chatSettings = ChatSettings.fromJson(cs.cast<String, dynamic>());
    }
    final mem = raw['memorySettings'];
    if (mem is Map) {
      s.memorySettings =
          MemorySettings.fromJson(mem.cast<String, dynamic>());
    }
    final ui = raw['uiPrefs'];
    if (ui is Map) s.uiPrefs = UiPrefs.fromJson(ui.cast<String, dynamic>());

    if (creatorSessions != null) {
      s.creatorSessions = creatorSessions;
      s.activeCreatorSessionId = raw['activeCreatorSessionId'] as String?;
    }

    // Migrate any API keys carried in the backup into OS-secure storage,
    // then strip them from the in-memory ApiProvider so they're not in the
    // next persist's JSON blob.
    //
    // Wave CY.18.255 (audit FIX 5b): only write keys when [importKeys] is
    // true (the caller got explicit user confirmation). When false, we
    // DON'T overwrite the user's saved keys — we just clear the plaintext
    // keys the backup carried out of the in-memory providers so they don't
    // linger in the next persist; runtime falls back to whatever's already
    // in SecureKeys for matching provider ids.
    for (final p in s.providers) {
      if (p.apiKey.isNotEmpty) {
        if (importKeys) {
          await SecureKeys.write(p.id, p.apiKey);
        }
        p.apiKey = '';
      }
    }

    // Always re-seed the canonical locked default AFTER applying — this
    // prevents a malicious backup from substituting our system prompt by
    // including a preset with the lockedDefaultPresetId.
    s.presets.removeWhere((p) => p.id == lockedDefaultPresetId);
    s.presets.insert(0, buildLockedDefaultPreset());
    s.activePresetId ??= lockedDefaultPresetId;

    // Wave CY.18.107: same hardening for the Creator preset — re-seed the
    // canonical locked default so a backup can't substitute the shipped
    // architect prompts via the locked id.
    s.creatorPresets
        .removeWhere((p) => p.id == lockedDefaultCreatorPresetId);
    s.creatorPresets.insert(0, buildLockedDefaultCreatorPreset());
    s.activeCreatorPresetId ??= lockedDefaultCreatorPresetId;

    // Wave CY.18.42: reference integrity sweep. A backup can carry
    // `activePersonaId`, `activeProviderId`, etc. pointing at ids that
    // weren't included in (or got filtered out of) the restored
    // collections. Leaving those dangling crashes downstream code
    // (chat screen tries to resolve the persona, gets null, blanks
    // out the chat header — at best). Null out any id that doesn't
    // actually resolve to an item that survived the restore.
    if (s.activeProviderId != null &&
        !s.providers.any((p) => p.id == s.activeProviderId)) {
      s.activeProviderId = null;
    }
    if (s.creatorProviderId != null &&
        !s.providers.any((p) => p.id == s.creatorProviderId)) {
      s.creatorProviderId = null;
    }
    if (s.visionProviderId != null &&
        !s.providers.any((p) => p.id == s.visionProviderId)) {
      s.visionProviderId = null;
    }
    if (s.activePersonaId != null &&
        !s.personas.any((p) => p.id == s.activePersonaId)) {
      s.activePersonaId = null;
    }
    if (s.activePresetId != null &&
        !s.presets.any((p) => p.id == s.activePresetId)) {
      s.activePresetId = lockedDefaultPresetId;
    }
    if (s.activeCreatorPresetId != null &&
        !s.creatorPresets.any((p) => p.id == s.activeCreatorPresetId)) {
      s.activeCreatorPresetId = lockedDefaultCreatorPresetId;
    }
    if (s.activeCreatorSessionId != null &&
        !s.creatorSessions
            .any((cs) => cs.id == s.activeCreatorSessionId)) {
      s.activeCreatorSessionId = null;
    }

    // Wave CY.18.43: deeper integrity sweep — sub-references inside
    // collections. Wave CY.18.42 only swept top-level singletons
    // (`activeProviderId`, etc.) but a backup can also contain:
    //   - chat.personaId / chat.presetId pointing at items that
    //     weren't included
    //   - chat.message.characterId pointing at a character missing
    //     from this backup (group-chat attribution silently breaks)
    //   - Character.lorebookIds / Persona.lorebookIds with dangling
    //     book ids (chat injection silently skips them)
    //   - Chat.attachedLorebookIds / disabledInheritedLorebookIds
    //     with dangling ids (inheritance behaviour goes sideways)
    //   - Chat.characterIds containing ids missing from
    //     characterSnapshots OR from the characters collection
    //
    // Each dangling id either gets nulled (single-value refs) or
    // filtered out of its list (multi-value refs). Lossy on purpose:
    // the alternative is the chat opening to a blank header / no
    // injection / no attribution and the user not knowing why.
    final providerIds = s.providers.map((p) => p.id).toSet();
    final characterIds = s.characters.map((c) => c.id).toSet();
    final personaIds = s.personas.map((p) => p.id).toSet();
    final lorebookIds = s.lorebooks.map((b) => b.id).toSet();
    final presetIds = s.presets.map((p) => p.id).toSet();

    for (final c in s.characters) {
      c.lorebookIds
          .removeWhere((id) => !lorebookIds.contains(id));
    }
    for (final p in s.personas) {
      p.lorebookIds
          .removeWhere((id) => !lorebookIds.contains(id));
    }
    for (final chat in s.chats) {
      // characterIds — keep only ones we still have in the library
      // OR that have a snapshot frozen on this chat (a snapshot is
      // self-contained, the library entry is optional).
      chat.characterIds.removeWhere((id) =>
          !characterIds.contains(id) &&
          !chat.characterSnapshots.containsKey(id));
      // Snapshot map: prune entries whose id was dropped above.
      chat.characterSnapshots
          .removeWhere((id, _) => !chat.characterIds.contains(id));
      // personaId — null if missing.
      if (chat.personaId != null &&
          !personaIds.contains(chat.personaId)) {
        chat.personaId = null;
      }
      // presetId — null if missing (chat falls back to the active
      // preset / locked default at runtime).
      if (chat.presetId != null &&
          !presetIds.contains(chat.presetId)) {
        chat.presetId = null;
      }
      // Lorebook bindings — filter dangling ids in both lists.
      chat.attachedLorebookIds
          .removeWhere((id) => !lorebookIds.contains(id));
      chat.disabledInheritedLorebookIds
          .removeWhere((id) => !lorebookIds.contains(id));
      // Per-message characterId references (group chat attribution).
      for (final m in chat.messages) {
        if (m.characterId != null && m.characterId!.isNotEmpty) {
          final stillResolves = characterIds.contains(m.characterId) ||
              chat.characterSnapshots.containsKey(m.characterId);
          if (!stillResolves) {
            m.characterId = null;
          }
        }
      }
    }
    // Unused locals guard — `providerIds` is computed for symmetry /
    // future extension (provider override fields on chats / sessions
    // aren't currently per-collection but might land here later).
    providerIds.length;

    s.notifyAndPersist();
  }
}
