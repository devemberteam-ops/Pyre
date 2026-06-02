import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/lorebook_import.dart';
import '../services/token_estimate.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/lorebook_binding_section.dart';

class LorebooksScreen extends StatelessWidget {
  const LorebooksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    // Wave CA: hide books with hidden=true from the management list.
    // They were created via the "embedded only" choice on character
    // import and live solely to back that character's bound list; we
    // still show their count in the empty-state copy so the user
    // doesn't think their card lost its lore.
    final visibleBooks =
        store.lorebooks.where((b) => !b.hidden).toList(growable: false);
    final hiddenCount = store.lorebooks.length - visibleBooks.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lorebooks'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Import from JSON',
            onPressed: () => _importLorebookFile(context),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New lorebook',
            onPressed: () => _editLorebook(context, null),
          ),
        ],
      ),
      body: visibleBooks.isEmpty
          ? EmptyState(
              icon: Icons.menu_book_outlined,
              title: 'No lorebooks yet',
              subtitle: hiddenCount > 0
                  ? 'You have $hiddenCount embedded lorebook${hiddenCount == 1 ? "" : "s"} '
                      'bound to characters (kept out of this list to reduce '
                      'clutter — they still inject in chat). Create or import '
                      'a new one to add it here.'
                  : 'Lorebooks let you attach world info or facts that get injected into the chat when keywords are mentioned — useful for keeping the AI consistent about places, factions, lore, etc.',
              ctaLabel: 'Create',
              ctaIcon: Icons.add,
              onCta: () => _editLorebook(context, null),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: visibleBooks.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final l = visibleBooks[i];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined,
                        color: EmberColors.textMid),
                    title: Text(l.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    // Wave CM: subtitle now includes the lorebook's
                    // token weight (sum across enabled entries) so the
                    // user can see at a glance how much of their
                    // context budget a book consumes.
                    subtitle: Builder(builder: (_) {
                      final tokenLabel =
                          formatTokenCount(approxTokensForLorebook(l));
                      final base = '${l.entries.length} entries'
                          '${l.description.isNotEmpty ? "  ·  ${l.description}" : ""}';
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              base,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: EmberColors.textMid),
                            ),
                          ),
                          if (tokenLabel != null) ...[
                            const SizedBox(width: 6),
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                tokenLabel,
                                style: const TextStyle(
                                  color: EmberColors.textDim,
                                  fontSize: 10,
                                  fontFeatures: [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      );
                    }),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert,
                          color: EmberColors.textMid),
                      tooltip: 'Lorebook actions',
                      onPressed: () => _openLorebookKebab(context, l),
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LorebookEditScreen(lorebookId: l.id),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

Future<void> _openLorebookKebab(BuildContext context, Lorebook l) async {
  final store = context.read<AppStore>();
  final messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit entries'),
            onTap: () {
              Navigator.pop(sheet);
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LorebookEditScreen(lorebookId: l.id),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename / describe'),
            onTap: () {
              Navigator.pop(sheet);
              _editLorebook(context, l);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy as new'),
            onTap: () {
              Navigator.pop(sheet);
              final clone = Lorebook(
                id: newId('lore'),
                name: '${l.name} (copy)',
                description: l.description,
                entries: l.entries
                    .map((e) => LoreEntry(
                          id: newId('lore-entry'),
                          keys: [...e.keys],
                          content: e.content,
                          constant: e.constant,
                          enabled: e.enabled,
                          order: e.order,
                        ))
                    .toList(),
              );
              store.addLorebook(clone);
              messenger.showSnackBar(
                SnackBar(content: Text('Copied as "${clone.name}".')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Export JSON'),
            onTap: () async {
              Navigator.pop(sheet);
              final json =
                  const JsonEncoder.withIndent('  ').convert(l.toJson());
              await Clipboard.setData(ClipboardData(text: json));
              messenger.showSnackBar(
                const SnackBar(content: Text('Lorebook JSON copied.')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline,
                color: EmberColors.danger),
            title: const Text('Delete',
                style: TextStyle(color: EmberColors.danger)),
            onTap: () async {
              Navigator.pop(sheet);
              final ok = await confirmDelete(
                context,
                title: 'Delete "${l.name}"?',
                message:
                    'The lorebook will be removed and detached from every chat using it.',
              );
              if (!ok) return;
              store.removeLorebook(l.id);
            },
          ),
        ],
      ),
    ),
  );
}

/// Wave CA: import a lorebook from a JSON file picked off device storage.
/// Accepts a few related shapes (see [tryParseLorebookJson]):
///   - chara_card_v2 full card (we extract `data.character_book`)
///   - bare `character_book` object
///   - SillyTavern-format `{entries: [...]}` blob
///   - Pyre's own Lorebook.toJson round-trip
Future<void> _importLorebookFile(BuildContext context) async {
  final store = context.read<AppStore>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    final bytes = f.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read the file.')),
      );
      return;
    }
    final text = utf8.decode(bytes);
    Map<String, dynamic> root;
    try {
      root = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Invalid JSON: $e')),
      );
      return;
    }
    final fallbackName = f.name.replaceAll(RegExp(r'\.json$'), '');
    final book = tryParseLorebookJson(root, nameFallback: fallbackName);
    if (book == null) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text(
                'Not a recognised lorebook format — expected chara_card_v2 character_book, SillyTavern world-info, or Pyre lorebook JSON.')),
      );
      return;
    }
    store.addLorebook(book);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
            'Imported "${book.name}" — ${book.entries.length} entries.'),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Import failed: $e')),
    );
  }
}

Future<void> _editLorebook(BuildContext context, Lorebook? existing) async {
  final store = context.read<AppStore>();
  final nameCtl =
      TextEditingController(text: existing?.name ?? 'New lorebook');
  final descCtl = TextEditingController(text: existing?.description ?? '');
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Text(existing == null ? 'New lorebook' : 'Rename lorebook'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: nameCtl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: descCtl,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = nameCtl.text.trim();
            if (name.isEmpty) return;
            if (existing == null) {
              store.addLorebook(Lorebook(
                id: newId('lore'),
                name: name,
                description: descCtl.text.trim(),
              ));
            } else {
              existing
                ..name = name
                ..description = descCtl.text.trim();
              store.updateLorebook(existing);
            }
            Navigator.pop(ctx);
          },
          child: Text(existing == null ? 'Create' : 'Save'),
        ),
      ],
    ),
  );
}

class LorebookEditScreen extends StatelessWidget {
  final String lorebookId;
  const LorebookEditScreen({super.key, required this.lorebookId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final lore = store.lorebookById(lorebookId);
    if (lore == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Lorebook not found')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(lore.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New entry',
            onPressed: () => _addEntry(context, lore),
          ),
        ],
      ),
      // Wave CC: Used-by banner pinned above the entries list so the
      // user can see which characters / personas / chats reference this
      // book without leaving the screen. Read-only on this side —
      // binding happens from the char/persona editor.
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: EmberColors.stroke, width: 0.5),
              ),
            ),
            child: LorebookUsedBySection(lorebookId: lore.id),
          ),
          Expanded(
            child: lore.entries.isEmpty
          ? const EmptyState(
              icon: Icons.format_list_bulleted,
              title: 'No entries',
              subtitle:
                  'Add an entry with one or more trigger keywords and the text to inject.',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: lore.entries.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final entry = lore.entries[i];
                return Card(
                  child: ExpansionTile(
                    title: Text(
                      entry.keys.isEmpty
                          ? (entry.constant ? '(constant)' : '(no keys)')
                          : entry.keys.join(', '),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      entry.content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: EmberColors.textMid),
                    ),
                    trailing: Switch(
                      value: entry.enabled,
                      activeThumbColor: EmberColors.primary,
                      onChanged: (v) {
                        entry.enabled = v;
                        store.updateLorebook(lore);
                      },
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CheckboxListTile(
                              title: const Text('Always inject (constant)'),
                              value: entry.constant,
                              activeColor: EmberColors.primary,
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              onChanged: (v) {
                                entry.constant = v ?? false;
                                store.updateLorebook(lore);
                              },
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () =>
                                        _editEntry(context, lore, entry),
                                    icon: const Icon(Icons.edit, size: 16),
                                    label: const Text('Edit'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: EmberColors.danger),
                                  onPressed: () {
                                    lore.entries.removeWhere(
                                        (e) => e.id == entry.id);
                                    store.updateLorebook(lore);
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _addEntry(BuildContext context, Lorebook lore) async {
  final entry = LoreEntry(id: newId('lore-entry'));
  await _editEntry(context, lore, entry, isNew: true);
}

Future<void> _editEntry(
  BuildContext context,
  Lorebook lore,
  LoreEntry entry, {
  bool isNew = false,
}) async {
  final store = context.read<AppStore>();
  final keysCtl = TextEditingController(text: entry.keys.join(', '));
  final contentCtl = TextEditingController(text: entry.content);
  bool constant = entry.constant;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: Text(isNew ? 'New entry' : 'Edit entry'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: keysCtl,
                decoration: const InputDecoration(
                  labelText: 'Trigger keywords',
                  helperText: 'Comma-separated. Ignored if "constant" is on.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentCtl,
                maxLines: 8,
                minLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Content to inject',
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                title: const Text('Always inject (constant)'),
                value: constant,
                activeColor: EmberColors.primary,
                contentPadding: EdgeInsets.zero,
                dense: true,
                onChanged: (v) => setState(() => constant = v ?? false),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              entry
                ..keys = keysCtl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList()
                ..content = contentCtl.text
                ..constant = constant;
              if (isNew) {
                lore.entries.add(entry);
              }
              store.updateLorebook(lore);
              Navigator.pop(ctx);
            },
            child: Text(isNew ? 'Add' : 'Save'),
          ),
        ],
      ),
    ),
  );
}
