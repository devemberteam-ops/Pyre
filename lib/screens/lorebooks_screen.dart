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
import '../widgets/lorebook_binding_section.dart'
    show LorebookUsedBySection, askEmbeddedChoice;
import 'lorebook_creator_screen.dart';

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
    final visibleBooks = store.lorebooks
        .where((b) => !b.hidden && !b.deleted)
        .toList(growable: false);
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
          // Wave CY.18.122: AI lorebook creator — opens the per-entry chat
          // builder with a new (unnamed-until-first-save) target book.
          // The user is asked for a book name up-front via a quick dialog
          // so the header label is meaningful from the start.
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'New lorebook with AI',
            onPressed: () => _openCreatorNew(context),
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
                    leading: Icon(Icons.menu_book_outlined,
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
                              style: TextStyle(
                                  color: EmberColors.textMid),
                            ),
                          ),
                          if (tokenLabel != null) ...[
                            const SizedBox(width: 6),
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                tokenLabel,
                                style: TextStyle(
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
                      icon: Icon(Icons.more_vert,
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
          // Wave CY.18.122: AI entry builder — opens the Creator bound to
          // this existing book, appending entries one at a time.
          ListTile(
            leading: Icon(Icons.auto_awesome, color: EmberColors.primary),
            title: const Text('Add entries with AI'),
            onTap: () {
              Navigator.pop(sheet);
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LorebookCreatorScreen(targetBook: l),
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
                          secondaryKeys: [...e.secondaryKeys],
                          selectiveLogic: e.selectiveLogic,
                          caseSensitive: e.caseSensitive,
                          matchWholeWords: e.matchWholeWords,
                          probability: e.probability,
                          useProbability: e.useProbability,
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
            leading: Icon(Icons.link, color: EmberColors.textMid),
            title: const Text('Embed into a card…'),
            onTap: () async {
              Navigator.pop(sheet);
              await _embedIntoCard(context, store, l, messenger);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline,
                color: EmberColors.danger),
            title: Text('Delete',
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

// ── Embed into a card ────────────────────────────────────────────────────────

/// Pick a character, ask shared/embedded, then bind this lorebook to
/// the chosen character. D1: always ask shared-vs-embedded.
Future<void> _embedIntoCard(
  BuildContext context,
  AppStore store,
  Lorebook l,
  ScaffoldMessengerState messenger,
) async {
  final characters = store.characters.where((c) => !c.deleted).toList();
  if (characters.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No characters found. Create one first.')),
    );
    return;
  }

  // Step 1: pick a character.
  Character? picked;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheet).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.person, color: EmberColors.primary),
                  const SizedBox(width: 10),
                  const Text(
                    'Embed into which card?',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, color: EmberColors.textMid),
                    onPressed: () => Navigator.pop(sheet),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                itemCount: characters.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (_, i) {
                  final c = characters[i];
                  final alreadyBound = c.lorebookIds.contains(l.id);
                  return Card(
                    child: ListTile(
                      enabled: !alreadyBound,
                      leading: Icon(
                        Icons.person,
                        color: alreadyBound
                            ? EmberColors.textDim
                            : EmberColors.textMid,
                      ),
                      title: Text(
                        c.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: alreadyBound
                              ? EmberColors.textDim
                              : EmberColors.textHigh,
                        ),
                      ),
                      trailing: alreadyBound
                          ? Icon(Icons.check,
                              color: EmberColors.textDim, size: 18)
                          : null,
                      onTap: alreadyBound
                          ? null
                          : () {
                              picked = c;
                              Navigator.pop(sheet);
                            },
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );

  if (picked == null) return;
  if (!context.mounted) return;

  // Step 2: D1 — ALWAYS ask shared-vs-embedded.
  // We import the helper from lorebook_binding_section.
  final embedded = await askEmbeddedChoice(context);
  if (embedded == null) return; // cancelled
  if (!context.mounted) return;

  // Apply: set hidden per choice, bind to character.
  final book = l;
  if (book.hidden != embedded) {
    book.hidden = embedded;
    store.updateLorebook(book);
  }
  final char = picked!;
  if (!char.lorebookIds.contains(book.id)) {
    char.lorebookIds.add(book.id);
    store.updateCharacter(char);
  }

  messenger.showSnackBar(
    SnackBar(
      content: Text(
        embedded
            ? 'Embedded "${l.name}" into ${char.name}. '
                'It will travel when you export that card.'
            : 'Linked "${l.name}" to ${char.name} as a shared lorebook.',
      ),
    ),
  );
}

// ── AI Creator entry point ────────────────────────────────────────────────────

/// Wave CY.18.122: ask the user for a book name, then push the AI creator.
/// The name dialog is kept minimal (one field). The creator will create the
/// actual Lorebook on first save; if the user abandons the creator before
/// saving any entry, no Lorebook object is created.
Future<void> _openCreatorNew(BuildContext context) async {
  final nameCtl = TextEditingController(text: 'New lorebook');
  String? nameError;
  String? chosenName;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('New lorebook with AI'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Give your lorebook a name — you can rename it later.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Lorebook name',
                errorText: nameError,
              ),
              onChanged: (_) {
                if (nameError != null && nameCtl.text.trim().isNotEmpty) {
                  setLocal(() => nameError = null);
                }
              },
              onSubmitted: (v) {
                final name = nameCtl.text.trim();
                if (name.isEmpty) {
                  setLocal(() => nameError = 'Name is required');
                  return;
                }
                chosenName = name;
                Navigator.pop(ctx);
              },
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
              if (name.isEmpty) {
                setLocal(() => nameError = 'Name is required');
                return;
              }
              chosenName = name;
              Navigator.pop(ctx);
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    ),
  );
  nameCtl.dispose();

  if (chosenName == null || chosenName!.isEmpty) return;
  if (!context.mounted) return;
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => LorebookCreatorScreen(
      targetBook: null,
      initialBookName: chosenName,
    ),
  ));
}

/// Wave CA: import a lorebook from a JSON file picked off device storage.
/// Accepts a few related shapes (see [tryParseLorebookJson]):
///   - chara_card_v2 full card (we extract `data.character_book`)
///   - bare `character_book` object
///   - SillyTavern World Info — standalone export `{entries: {uid: …}}`
///     (object keyed by uid) or the array form `{entries: [...]}`
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
  // Completeness-gaps: inline blank-name error (was a silent no-op). Tracked
  // via StatefulBuilder so the dialog can rebuild with the error / clear it.
  String? nameError;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: Text(existing == null ? 'New lorebook' : 'Rename lorebook'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameCtl,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: nameError,
              ),
              onChanged: (_) {
                if (nameError != null && nameCtl.text.trim().isNotEmpty) {
                  setLocal(() => nameError = null);
                }
              },
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
              if (name.isEmpty) {
                setLocal(() => nameError = 'Name is required');
                return;
              }
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
    ),
  );
  // H-3: dispose the lorebook name/description controllers on dialog close.
  nameCtl.dispose();
  descCtl.dispose();
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
          // Wave CY.18.122: AI entry builder bound to this book.
          IconButton(
            icon: Icon(Icons.auto_awesome, color: EmberColors.primary),
            tooltip: 'Add entries with AI',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => LorebookCreatorScreen(targetBook: lore),
            )),
          ),
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
            decoration: BoxDecoration(
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
                      style: TextStyle(color: EmberColors.textMid),
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
                                  icon: Icon(Icons.delete_outline,
                                      color: EmberColors.danger),
                                  tooltip: 'Delete entry',
                                  // Completeness-gaps: confirm like every other
                                  // delete in the app (was an immediate remove).
                                  onPressed: () async {
                                    final ok = await confirmDelete(
                                      context,
                                      title: 'Delete entry?',
                                      message:
                                          'This lorebook entry will be removed.',
                                    );
                                    if (!ok) return;
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
  final secondaryCtl =
      TextEditingController(text: entry.secondaryKeys.join(', '));
  final contentCtl = TextEditingController(text: entry.content);
  bool constant = entry.constant;
  // Wave 1.1 (F3): the SillyTavern-style keyword options. Defaults mirror the
  // model's pre-1.1 defaults so an unchanged entry saves with no new fields.
  LoreSelectiveLogic logic = entry.selectiveLogic;
  bool? caseSensitive = entry.caseSensitive;
  bool? matchWholeWords = entry.matchWholeWords;
  bool useProbability = entry.useProbability;
  int probability = entry.probability;

  // Tri-state (Default / On / Off) value helpers for the override toggles.
  String triLabel(bool? v) => v == null ? 'Default' : (v ? 'On' : 'Off');
  bool? triNext(bool? v) => v == null
      ? true
      : (v ? false : null); // Default -> On -> Off -> Default

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final screenSize = MediaQuery.of(ctx).size;
        final dialogWidth = (screenSize.width * 0.92).clamp(0.0, 560.0);
        final dialogMaxHeight = screenSize.height * 0.88;
        return AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: Text(isNew ? 'New entry' : 'Edit entry'),
        content: SizedBox(
          width: dialogWidth,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: dialogMaxHeight),
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: keysCtl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Trigger keywords',
                    helperText:
                        'Comma-separated. Ignored if "constant" is on.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secondaryCtl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Secondary keywords (optional)',
                    helperText:
                        'Comma-separated. Combined with the logic below.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                // The logic dropdown only matters when there are secondary
                // keywords — show it then (with a hint otherwise).
                if (secondaryCtl.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<LoreSelectiveLogic>(
                    initialValue: logic,
                    decoration: const InputDecoration(labelText: 'Logic'),
                    items: const [
                      DropdownMenuItem(
                        value: LoreSelectiveLogic.andAny,
                        child: Text('Any of these'),
                      ),
                      DropdownMenuItem(
                        value: LoreSelectiveLogic.andAll,
                        child: Text('All of these'),
                      ),
                      DropdownMenuItem(
                        value: LoreSelectiveLogic.notAny,
                        child: Text('None of these'),
                      ),
                      DropdownMenuItem(
                        value: LoreSelectiveLogic.notAll,
                        child: Text('Not all of these'),
                      ),
                    ],
                    onChanged: (v) => setState(
                        () => logic = v ?? LoreSelectiveLogic.andAny),
                  ),
                ] else
                  Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Add secondary keywords to enable AND/NOT logic.',
                      style: TextStyle(
                          color: EmberColors.textDim, fontSize: 11),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentCtl,
                  minLines: 6,
                  maxLines: 14,
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
                // Matching overrides — tri-state so "Default" keeps today's
                // behaviour (case-insensitive whole-word).
                Row(
                  children: [
                    const Expanded(child: Text('Case sensitive')),
                    TextButton(
                      onPressed: () => setState(
                          () => caseSensitive = triNext(caseSensitive)),
                      child: Text(triLabel(caseSensitive)),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(child: Text('Match whole words')),
                    TextButton(
                      onPressed: () => setState(
                          () => matchWholeWords = triNext(matchWholeWords)),
                      child: Text(triLabel(matchWholeWords)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  title: const Text('Use trigger chance'),
                  value: useProbability,
                  activeThumbColor: EmberColors.primary,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  onChanged: (v) => setState(() => useProbability = v),
                ),
                if (useProbability)
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: probability.toDouble().clamp(0, 100),
                          min: 0,
                          max: 100,
                          divisions: 100,
                          label: '$probability%',
                          activeColor: EmberColors.primary,
                          onChanged: (v) =>
                              setState(() => probability = v.round()),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '$probability%',
                          textAlign: TextAlign.end,
                          style:
                              TextStyle(color: EmberColors.textMid),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
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
                ..secondaryKeys = secondaryCtl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList()
                ..content = contentCtl.text
                ..constant = constant
                ..selectiveLogic = logic
                ..caseSensitive = caseSensitive
                ..matchWholeWords = matchWholeWords
                ..useProbability = useProbability
                ..probability = probability.clamp(0, 100);
              if (isNew) {
                lore.entries.add(entry);
              }
              store.updateLorebook(lore);
              Navigator.pop(ctx);
            },
            child: Text(isNew ? 'Add' : 'Save'),
          ),
        ],
      );
      },
    ),
  );
  // H-3: dispose the entry-editor controllers once the dialog closes.
  keysCtl.dispose();
  secondaryCtl.dispose();
  contentCtl.dispose();
}
