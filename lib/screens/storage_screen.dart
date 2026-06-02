import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/error_log.dart';
import '../services/llm_debug_log.dart';
import '../services/secure_keys.dart';
import '../services/storage.dart';
import '../state/app_store.dart';
import '../theme.dart';

class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final size = await JsonStorage().approximateSize();
    if (!mounted) return;
    setState(() => _bytes = size);
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final used = _bytes == null ? '…' : _fmtBytes(_bytes!);
    final loadResult = JsonStorage.lastLoad;
    final loadErrors = store.loadErrors;
    // Wave CY.18.42: secure-storage failures get their own visible
    // log. Pre-Wave these were swallowed; the user lost an API key
    // set without ever seeing a warning. Now we surface them right
    // next to the load diagnostics.
    final secureKeyErrors = List<String>.from(SecureKeys.lastErrors);

    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Wave CY.18.40: load-status diagnostic banner. Stays
          // discreet on the happy path (status == ok) and gets loud
          // when recovery / partial / failure happened so the user
          // knows their state isn't pristine.
          _LoadStatusBanner(
            result: loadResult,
            errors: loadErrors,
          ),
          if (loadResult.status != LoadStatus.freshInstall)
            const SizedBox(height: 12),
          // Wave CY.18.42: secure-storage failure banner. Only shows
          // when SecureKeys has accumulated any errors since the last
          // clear. Dismissable so the user can acknowledge & move on
          // once they've re-pasted the affected provider keys.
          if (secureKeyErrors.isNotEmpty) ...[
            _SecureKeyErrorBanner(
              errors: secureKeyErrors,
              onClear: () {
                SecureKeys.clearErrorLog();
                setState(() {});
              },
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Local data',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text('$used used (main + rotated backups)',
                      style:
                          const TextStyle(color: EmberColors.textMid)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _StatTile(
            icon: Icons.person_outline,
            label: 'Characters',
            value: store.characters.length.toString(),
          ),
          _StatTile(
            icon: Icons.face_outlined,
            label: 'Personas',
            value: store.personas.length.toString(),
          ),
          _StatTile(
            icon: Icons.chat_bubble_outline,
            label: 'Chats',
            value: store.chats.length.toString(),
          ),
          _StatTile(
            icon: Icons.menu_book_outlined,
            label: 'Lorebooks',
            value: store.lorebooks.length.toString(),
          ),
          _StatTile(
            icon: Icons.layers_outlined,
            label: 'Presets (visible)',
            value: store.visiblePresets.length.toString(),
          ),
          _StatTile(
            icon: Icons.api,
            label: 'Providers',
            value: store.providers.length.toString(),
          ),
          const SizedBox(height: 16),
          // Wave CY.18.41: manual freeze — force a flush of any
          // pending writes + write-verify, so the user can ensure
          // current state is on disk before doing something risky
          // (heavy creator session, big import, etc.). Bumps a
          // backup slot in the rotation chain so the just-saved
          // state becomes recoverable from bak.0 on next save.
          OutlinedButton.icon(
            icon: const Icon(Icons.save_outlined,
                color: EmberColors.primary),
            label: const Text(
              'Save snapshot now',
              style: TextStyle(color: EmberColors.primary),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: EmberColors.primary),
            ),
            onPressed: () => _saveSnapshot(context),
          ),
          const SizedBox(height: 16),
          // Wave CY.18.45: error-log card. When a user reports a bug
          // they almost never have useful info beyond "it crashed".
          // These buttons hand them the EXACT crash data — captured
          // locally by ErrorLog (FlutterError + PlatformDispatcher) —
          // so the GitHub issue arrives with a real stack trace
          // instead of the back-and-forth.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Diagnostics',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text(
                    'Crashes and uncaught exceptions are logged to a '
                    'file on this device only. Nothing leaves your '
                    'phone unless you tap one of the buttons below.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy_outlined,
                            color: EmberColors.primary, size: 18),
                        label: const Text(
                          'Copy error log',
                          style:
                              TextStyle(color: EmberColors.primary),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                              color: EmberColors.primary),
                        ),
                        onPressed: () => _copyErrorLog(context),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.ios_share,
                            color: EmberColors.primary, size: 18),
                        label: const Text(
                          'Share error log',
                          style:
                              TextStyle(color: EmberColors.primary),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                              color: EmberColors.primary),
                        ),
                        onPressed: () => _shareErrorLog(context),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.delete_sweep_outlined,
                            color: EmberColors.textMid, size: 18),
                        label: const Text(
                          'Clear log',
                          style: TextStyle(color: EmberColors.textMid),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(
                              color: EmberColors.stroke),
                        ),
                        onPressed: () => _clearErrorLog(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Wave CY.18.214: Developer / Diagnostics — opt-in raw LLM
          // request+response log (export-only, no in-app viewer in v1).
          // OFF by default. When ON, every real LLM call is appended to a
          // local JSONL the user can export to debug a session (or hand to
          // an agent). NEVER contains the API key (it rides the auth
          // header, not the request body).
          _LlmDebugLogCard(),
          const SizedBox(height: 16),
          // Wave CY.18.191: wrap the bare button in a card with a
          // description so users can distinguish it from the factory
          // reset in Backup & Restore. Copy only — no logic change.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Clear library',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Removes every character, chat, persona, preset, lorebook '
                    'and API connection stored on this device. '
                    'Your settings (temperature, chat behaviour, etc.) are kept. '
                    'There is no undo.\n\n'
                    'For a full factory reset that also wipes settings, '
                    'use Backup & Restore → Advanced → Reset to factory settings.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline,
                        color: EmberColors.danger),
                    label: const Text(
                      'Clear library',
                      style: TextStyle(color: EmberColors.danger),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: EmberColors.danger),
                    ),
                    onPressed: () => _confirmWipe(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Wave CY.18.41: forces a flush of any pending debounced writes
  /// + walks through the full atomic-write + verify pipeline once.
  /// Result: the latest in-memory state lands on disk AS THE MAIN
  /// FILE, the previous main rotates into bak.0, and the file is
  /// read-back-verified before this returns. Surfaces success/failure
  /// in a snackbar.
  Future<void> _saveSnapshot(BuildContext context) async {
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    await store.flushPersist();
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
            'Snapshot saved. Previous state rotated into bak.0.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Wave CY.18.45: copy the JSONL crash log to the clipboard so the
  /// user can paste it into a bug report. Shows the byte count in a
  /// snackbar so they know if it's empty (= no crashes captured yet,
  /// which is the happy path) or substantial.
  Future<void> _copyErrorLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await ErrorLog.copyToClipboard();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          bytes == 0
              ? 'Error log is empty — no crashes recorded.'
              : 'Copied $bytes B of error log to clipboard.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Wave CY.18.45: open the OS share sheet pointing at the actual log
  /// file. Lets the user send it via WhatsApp / Telegram / Drive / etc.
  /// without copy-paste friction (the log can be huge after a chatty
  /// session of errors).
  Future<void> _shareErrorLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await ErrorLog.logPath();
      // Check it actually exists — if it doesn't, share_plus would
      // throw "file not found" with no helpful context.
      final body = await ErrorLog.readAll();
      if (body.isEmpty) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content:
                Text('Error log is empty — no crashes recorded.'),
          ),
        );
        return;
      }
      await Share.shareXFiles(
        [XFile(path)],
        subject: 'Pyre error log',
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not share log: $e')),
      );
    }
  }

  /// Wave CY.18.45: wipe the captured log. Useful after the user has
  /// already filed the bug report so the next session starts clean
  /// and any new entry is unambiguously from the issue they're
  /// re-creating for the maintainer.
  Future<void> _clearErrorLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await ErrorLog.clear();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Error log cleared.')),
    );
  }

  Future<void> _confirmWipe(BuildContext context) async {
    // Capture context-derived objects before the awaits so the lint stays
    // happy and so we don't have to dance with `mounted` checks.
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Clear library?'),
        content: const Text(
          'This permanently deletes all characters, chats, personas, presets, '
          'lorebooks and API connections. Your settings are kept. '
          'There is no undo.\n\n'
          'To also wipe settings, use Backup & Restore → Advanced → '
          'Reset to factory settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: EmberColors.danger,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await JsonStorage().clear();
    // Wipe API keys from OS-secure storage too — they're not in the JSON
    // blob anymore, so clearing JsonStorage alone would leave them behind.
    await SecureKeys.clearAll();
    store
      ..providers.clear()
      ..characters.clear()
      ..personas.clear()
      ..chats.clear()
      ..lorebooks.clear()
      ..presets.clear()
      ..activeProviderId = null
      ..activePersonaId = null
      ..activePresetId = null;
    await store.load();
    if (!mounted) return;
    _refresh();
    messenger.showSnackBar(
      const SnackBar(content: Text('Library cleared.')),
    );
  }
}

/// Wave CY.18.214: Developer / Diagnostics card — opt-in raw LLM
/// request+response log (export-only). The toggle is bound to
/// [LlmDebugLog.instance.enabled] (persisted, OFF by default); when ON,
/// every real LLM call (chat, LTM, Live Sheet, Creator, vision, scene) is
/// appended to a local JSONL the user can export to debug a session. The
/// log NEVER contains the API key.
class _LlmDebugLogCard extends StatefulWidget {
  @override
  State<_LlmDebugLogCard> createState() => _LlmDebugLogCardState();
}

class _LlmDebugLogCardState extends State<_LlmDebugLogCard> {
  bool _enabled = LlmDebugLog.instance.enabled;

  Future<void> _toggle(bool value) async {
    await LlmDebugLog.instance.setEnabled(value);
    if (!mounted) return;
    setState(() => _enabled = value);
  }

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final files = await LlmDebugLog.instance.logFiles();
      if (files.isEmpty) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
                'No LLM diagnostics logged yet — turn the switch on, then '
                'reproduce the issue.'),
          ),
        );
        return;
      }
      await Share.shareXFiles(
        [for (final f in files) XFile(f.path)],
        subject: 'Pyre LLM diagnostics log',
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export diagnostics: $e')),
      );
    }
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await LlmDebugLog.instance.copyToClipboard();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(bytes == 0
            ? 'No LLM diagnostics logged yet.'
            : 'Copied $bytes B of LLM diagnostics to clipboard.'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _clear(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await LlmDebugLog.instance.clear();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('LLM diagnostics log cleared.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Developer',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              'Stored locally on this device; contains your chat text; '
              'never your API key. For debugging.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeThumbColor: EmberColors.primary,
              title: const Text('Log raw LLM calls (debug)'),
              subtitle: const Text(
                'Records every request + response, tagged per feature, '
                'to a JSONL file you can export.',
                style: TextStyle(fontSize: 12),
              ),
              value: _enabled,
              onChanged: _toggle,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.ios_share,
                      color: EmberColors.primary, size: 18),
                  label: const Text(
                    'Export logs',
                    style: TextStyle(color: EmberColors.primary),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: EmberColors.primary),
                  ),
                  onPressed: () => _export(context),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_outlined,
                      color: EmberColors.primary, size: 18),
                  label: const Text(
                    'Copy logs',
                    style: TextStyle(color: EmberColors.primary),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: EmberColors.primary),
                  ),
                  onPressed: () => _copy(context),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_sweep_outlined,
                      color: EmberColors.textMid, size: 18),
                  label: const Text(
                    'Clear logs',
                    style: TextStyle(color: EmberColors.textMid),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: EmberColors.stroke),
                  ),
                  onPressed: () => _clear(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Wave CY.18.40: diagnostic banner shown at the top of the Storage
/// screen. Hidden on the happy path (status == ok with zero per-model
/// errors); loud and informative when recovery happened or models
/// failed to parse, so the user can:
///   - Know that some data may have been salvaged (and may be
///     incomplete)
///   - See which model collections lost items
///   - Decide whether to immediately export a backup before risking
///     more state changes
class _LoadStatusBanner extends StatelessWidget {
  final LoadResult result;
  final List<String> errors;
  const _LoadStatusBanner({required this.result, required this.errors});

  @override
  Widget build(BuildContext context) {
    // Pristine state (clean parse, no per-model errors) → no banner.
    // We could show a green "all good" pill but it adds visual noise
    // on the 99% case where everything's fine.
    final isClean = result.status == LoadStatus.ok && errors.isEmpty;
    if (isClean || result.status == LoadStatus.freshInstall) {
      return const SizedBox.shrink();
    }
    final (color, icon, title) = _styleFor(result.status);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          if (result.diagnostics.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              result.diagnostics,
              style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
          if (errors.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Per-collection issues:',
              style: TextStyle(
                color: EmberColors.textHigh,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            for (final e in errors)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 2),
                child: Text(
                  '• $e',
                  style: const TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  (Color, IconData, String) _styleFor(LoadStatus s) {
    switch (s) {
      case LoadStatus.ok:
        // Reached here means there were per-model errors but the main
        // parse succeeded — render as a warning, not an error.
        return (
          const Color(0xFFE9A35A),
          Icons.warning_amber_outlined,
          'Loaded with warnings',
        );
      case LoadStatus.recoveredFromBackup:
        return (
          const Color(0xFFE9A35A),
          Icons.history,
          'Recovered from backup',
        );
      case LoadStatus.salvagedPartial:
        return (
          const Color(0xFFE57373),
          Icons.health_and_safety_outlined,
          'Partial salvage — some recent data may be lost',
        );
      case LoadStatus.failed:
        return (
          EmberColors.danger,
          Icons.error_outline,
          'Load failed — raw file still on disk',
        );
      case LoadStatus.freshInstall:
        return (
          EmberColors.textMid,
          Icons.fiber_new,
          'Fresh install',
        );
    }
  }
}

/// Wave CY.18.42: visible banner for OS-secure-storage failures.
/// Pre-Wave these were swallowed with `catch (_)` and a user lost
/// their entire API key set without any in-app diagnostic. Now
/// every failure in [SecureKeys] is collected into [SecureKeys.lastErrors]
/// and rendered here, so the user knows to re-paste the affected
/// provider keys in API Connections.
class _SecureKeyErrorBanner extends StatelessWidget {
  final List<String> errors;
  final VoidCallback onClear;
  const _SecureKeyErrorBanner({
    required this.errors,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    const color = EmberColors.danger;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.key_off_outlined,
                  color: color, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'API key storage errors',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Dismiss',
                  style: TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'One or more API keys failed to read/write from OS-secure '
            'storage. If a provider is missing its key, re-paste it '
            'in API Connections.',
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Recent failures:',
            style: TextStyle(
              color: EmberColors.textHigh,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          for (final e in errors.take(8))
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 2),
              child: Text(
                '• $e',
                style: const TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ),
          if (errors.length > 8)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 4),
              child: Text(
                '…and ${errors.length - 8} more',
                style: const TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 11.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: EmberColors.textMid),
      title: Text(label),
      trailing: Text(
        value,
        style: const TextStyle(
          color: EmberColors.textMid,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
