// Wave CY.18.58: extracted from main.dart so the More screen can also
// open the same palette (without dragging a private `_class` import).
//
// The palette is a small modal listing every desktop keyboard shortcut
// Pyre exposes. Each row is also a button — mouse users can discover
// + execute commands without memorising keybindings. Triggered by
// Ctrl+K (registered in main.dart's RootShell) and from the
// "Keyboard shortcuts" row in the More screen on desktop.

import 'package:flutter/material.dart';

import '../services/desktop_shortcuts.dart';
import '../services/focus_bus.dart';
import '../state/app_store.dart';

/// Shows the command palette modal. Returns immediately if `context`
/// is no longer mounted.
Future<void> showCommandPalette(BuildContext context, AppStore store) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => CommandPaletteDialog(store: store),
  );
}

class CommandPaletteDialog extends StatelessWidget {
  final AppStore store;
  const CommandPaletteDialog({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    // Wave CY.18.90: shortcut labels read live from the effective
    // bindings so if the user remaps Ctrl+, → Alt+P, this palette
    // shows "Alt + P" without a separate update path.
    String shortcutFor(String actionId) =>
        effectiveBinding(actionId, store.uiPrefs).label();

    final entries = <_PaletteEntry>[
      _PaletteEntry(
        label: 'Open Settings',
        shortcut: shortcutFor(ShortcutAction.openSettings),
        icon: Icons.settings_outlined,
        run: () => store.setActiveTab('more'),
      ),
      _PaletteEntry(
        label: 'New chat — pick a character',
        shortcut: shortcutFor(ShortcutAction.newChat),
        icon: Icons.chat_bubble_outline,
        run: () => store.setActiveTab('characters'),
      ),
      _PaletteEntry(
        label: 'Search characters',
        shortcut: shortcutFor(ShortcutAction.searchCharacters),
        icon: Icons.search,
        run: () {
          store.setActiveTab('characters');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            FocusBus.focusCharactersSearch();
          });
        },
      ),
      _PaletteEntry(
        label: 'Open chats list',
        shortcut: null,
        icon: Icons.forum_outlined,
        run: () => store.setActiveTab('chats'),
      ),
      _PaletteEntry(
        label: 'Discover (BotBooru)',
        shortcut: null,
        icon: Icons.explore_outlined,
        run: () => store.setActiveTab('discover'),
      ),
      _PaletteEntry(
        label: 'Show this palette',
        shortcut: shortcutFor(ShortcutAction.commandPalette),
        icon: Icons.search,
        run: null, // already open
      ),
      _PaletteEntry(
        label: 'Send message (in chat input)',
        shortcut: 'Enter',
        icon: Icons.send_outlined,
        run: null,
      ),
      _PaletteEntry(
        label: 'New line (in chat input)',
        shortcut: 'Shift + Enter',
        icon: Icons.subdirectory_arrow_left,
        run: null,
      ),
    ];

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 60, vertical: 80),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Pyre — commands',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    iconSize: 18,
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: entries.length,
                itemBuilder: (ctx, i) {
                  final e = entries[i];
                  return ListTile(
                    leading: Icon(e.icon),
                    title: Text(e.label),
                    trailing: e.shortcut == null
                        ? null
                        : Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              e.shortcut!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                    onTap: e.run == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            e.run!();
                          },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaletteEntry {
  final String label;
  final String? shortcut;
  final IconData icon;
  final VoidCallback? run;
  _PaletteEntry({
    required this.label,
    required this.shortcut,
    required this.icon,
    required this.run,
  });
}
