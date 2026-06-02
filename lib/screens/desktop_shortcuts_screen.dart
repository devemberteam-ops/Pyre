// Wave CY.18.90: Desktop Shortcuts screen.
//
// Replaces the previous "Keyboard shortcuts" row in More (which just
// opened the command palette) with a full configuration surface.
// Three responsibilities:
//
//   1. Show each remappable shortcut with its current binding chip
//      and let the user tap to capture a new key combo.
//   2. Show the un-remappable Enter / Shift+Enter chat-input bindings
//      as read-only rows (for discoverability — chat input handles
//      them directly via raw key events, not through the global
//      Shortcuts map).
//   3. Host the "Wide desktop layout" toggle that used to live in
//      the main More card — the user asked to bundle layout +
//      shortcuts under one desktop-tweaks screen.
//
// Capture UX: tap a row → modal opens with a single instruction
// ("Press a key combination, or Esc to cancel"). A KeyboardListener
// with autofocus reads the next non-modifier keydown, reads
// HardwareKeyboard.instance for the modifier state, builds a
// ShortcutBinding, checks for conflicts against the OTHER actions'
// effective bindings, then either saves or shows an inline conflict
// warning with an "Use anyway" option. Esc cancels without saving.
//
// Restore defaults: AppStore.restoreDesktopShortcutDefaults() empties
// the overrides map; the next render reads from
// kDefaultShortcutBindings.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/desktop_shortcuts.dart';
import '../state/app_store.dart';
import '../theme.dart';

class DesktopShortcutsScreen extends StatelessWidget {
  const DesktopShortcutsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Desktop Shortcuts'),
        actions: [
          // Wave CY.18.90: visible Restore defaults action up in the
          // bar so the user doesn't have to scroll past a long list
          // to find it after a chain of remaps.
          TextButton.icon(
            onPressed: store.uiPrefs.desktopShortcuts.isEmpty
                ? null
                : () => _confirmRestore(context, store),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Restore defaults'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              'Remappable',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: EmberColors.textDim,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < ShortcutAction.all.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      color: EmberColors.stroke,
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                    ),
                  _ShortcutRow(actionId: ShortcutAction.all[i]),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              'Fixed (chat input)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: EmberColors.textDim,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: const [
                _ReadOnlyShortcutRow(
                  label: 'Send message',
                  binding: 'Enter',
                ),
                Divider(
                  color: EmberColors.stroke,
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                ),
                _ReadOnlyShortcutRow(
                  label: 'Insert newline in input',
                  binding: 'Shift + Enter',
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              'Layout',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: EmberColors.textDim,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: SwitchListTile(
              value: store.uiPrefs.desktopWideLayout,
              onChanged: store.setDesktopWideLayout,
              title: const Text(
                'Wide desktop layout',
                style:
                    TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Off: same mobile layout, centered in a narrow column '
                '(phone-in-a-window).\n'
                'On: side rail + wider content. Recommended for larger '
                'windows.',
                style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              activeThumbColor: EmberColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRestore(BuildContext context, AppStore store) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Restore default shortcuts?'),
        content: const Text(
          'Every shortcut goes back to the factory binding. Your '
          'wide-layout preference is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok == true) {
      store.restoreDesktopShortcutDefaults();
    }
  }
}

/// One remappable row. Shows the current effective binding chip and
/// opens the capture modal on tap.
class _ShortcutRow extends StatelessWidget {
  final String actionId;
  const _ShortcutRow({required this.actionId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final binding = effectiveBinding(actionId, store.uiPrefs);
    final label = kShortcutActionLabels[actionId] ?? actionId;
    final isOverridden = store.uiPrefs.desktopShortcuts.containsKey(actionId);

    return InkWell(
      onTap: () => _capture(context, store),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  if (isOverridden) ...[
                    const SizedBox(height: 2),
                    const Text(
                      'Custom',
                      style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: EmberColors.bgPanel,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: EmberColors.stroke),
              ),
              child: Text(
                binding.label(),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: EmberColors.textHigh,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.edit, size: 16, color: EmberColors.textDim),
          ],
        ),
      ),
    );
  }

  Future<void> _capture(BuildContext context, AppStore store) async {
    final captured = await showDialog<ShortcutBinding>(
      context: context,
      builder: (_) => _CaptureDialog(actionId: actionId),
    );
    if (captured == null) return;
    final conflictId =
        conflictingAction(captured, actionId, store.uiPrefs);
    if (conflictId != null) {
      if (!context.mounted) return;
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: EmberColors.bgPanel,
          title: const Text('Shortcut already in use'),
          content: Text(
            '${captured.label()} is currently bound to '
            '"${kShortcutActionLabels[conflictId] ?? conflictId}".\n\n'
            'Use it anyway? The other action will be reset to its '
            'default binding.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Use anyway'),
            ),
          ],
        ),
      );
      if (replace != true) return;
      // Reset the conflicting action to its default by clearing its
      // override — then save the new binding. (If we kept the user's
      // override on the conflicting action, the next render would
      // overwrite our save again because CallbackShortcuts dedupes
      // on activator equality.)
      store.setDesktopShortcutBinding(conflictId, null);
    }
    store.setDesktopShortcutBinding(actionId, captured.toJson());
  }
}

class _ReadOnlyShortcutRow extends StatelessWidget {
  final String label;
  final String binding;
  const _ReadOnlyShortcutRow({required this.label, required this.binding});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: EmberColors.bgPanel,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: EmberColors.stroke),
            ),
            child: Text(
              binding,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: EmberColors.textHigh,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal that listens for a key combo. Returns the captured
/// [ShortcutBinding] on the first non-modifier press, null on Esc /
/// dismiss.
class _CaptureDialog extends StatefulWidget {
  final String actionId;
  const _CaptureDialog({required this.actionId});

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  final FocusNode _focus = FocusNode();
  String _liveLabel = '—';

  // Keys that are "modifier only" — pressing one of these alone is
  // never a valid binding, we wait for a real key.
  static final Set<int> _modifierKeyIds = {
    LogicalKeyboardKey.controlLeft.keyId,
    LogicalKeyboardKey.controlRight.keyId,
    LogicalKeyboardKey.shiftLeft.keyId,
    LogicalKeyboardKey.shiftRight.keyId,
    LogicalKeyboardKey.altLeft.keyId,
    LogicalKeyboardKey.altRight.keyId,
    LogicalKeyboardKey.metaLeft.keyId,
    LogicalKeyboardKey.metaRight.keyId,
    LogicalKeyboardKey.fn.keyId,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    // Esc → cancel.
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_modifierKeyIds.contains(key.keyId)) {
      // Update the live preview so the user sees modifier state.
      setState(() => _liveLabel = _previewLabel(null));
      return KeyEventResult.handled;
    }
    final binding = ShortcutBinding(
      keyId: key.keyId,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      meta: HardwareKeyboard.instance.isMetaPressed,
    );
    Navigator.of(context).pop(binding);
    return KeyEventResult.handled;
  }

  String _previewLabel(int? keyId) {
    final parts = <String>[];
    if (HardwareKeyboard.instance.isControlPressed) parts.add('Ctrl');
    if (HardwareKeyboard.instance.isAltPressed) parts.add('Alt');
    if (HardwareKeyboard.instance.isShiftPressed) parts.add('Shift');
    if (HardwareKeyboard.instance.isMetaPressed) parts.add('Meta');
    if (parts.isEmpty) return '— press a combination —';
    return '${parts.join(' + ')} + …';
  }

  @override
  Widget build(BuildContext context) {
    final label =
        kShortcutActionLabels[widget.actionId] ?? widget.actionId;
    return AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Text('Bind: $label'),
      content: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Press a key combination, or Esc to cancel.',
                style: TextStyle(
                    color: EmberColors.textMid, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: EmberColors.bgDeep,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: EmberColors.stroke),
                ),
                child: Text(
                  _liveLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                    color: EmberColors.textHigh,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Esc to cancel · Modifiers alone won\'t save — they '
                'need a key.',
                style: TextStyle(
                    color: EmberColors.textDim, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
