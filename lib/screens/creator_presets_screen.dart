// Wave CY.18.107 — Pillar E. Forkable Creator architect prompts.
//
// Mirrors `presets_screen.dart` (the chat-preset list) for the AI Creator's
// three base architect prompts (Character / Scenario / Edit). The locked
// "Pyre Default" is read-only — View details + Copy (editable) only. Unlocked
// presets get Edit + Delete. "New from scratch" creates a blank editable one.
//
// Deliberately minimal (spec §8): the editor is RAW multiline text fields,
// one per mode. No syntax help, no validator, no marker buttons. A broken
// custom preset degrades to the normal cascade error paths.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';

class CreatorPresetsScreen extends StatelessWidget {
  const CreatorPresetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final visible = store.creatorPresets;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Architect Prompts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New from scratch',
            onPressed: () => _editCreatorPreset(context, null),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: visible.length,
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final p = visible[i];
          final active = p.id == store.activeCreatorPresetId;
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                radius: 20,
                backgroundColor: p.locked
                    ? EmberColors.primary.withValues(alpha: 0.22)
                    : EmberColors.bgElevated,
                child: Icon(
                  p.locked ? Icons.lock_outline : Icons.layers_outlined,
                  size: 18,
                  color: p.locked
                      ? EmberColors.primary
                      : (active ? EmberColors.primary : EmberColors.textMid),
                ),
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(p.name,
                        style:
                            const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  if (active) ...[
                    const SizedBox(width: 6),
                    const _Pill(label: 'ACTIVE'),
                  ],
                  if (p.locked) ...[
                    const SizedBox(width: 6),
                    const _Pill(label: 'DEFAULT'),
                  ],
                ],
              ),
              subtitle: Text(
                p.locked
                    ? 'Built-in architect prompts · the shipped Creator'
                    : _previewLine(p),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: EmberColors.textMid),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.more_vert,
                    color: EmberColors.textMid),
                tooltip: 'Preset actions',
                onPressed: () => _openCreatorPresetKebab(context, p),
              ),
              onTap: () => store.setActiveCreatorPreset(p.id),
            ),
          );
        },
      ),
    );
  }
}

String _previewLine(CreatorPreset p) {
  final src = p.characterPrompt.trim();
  if (src.isEmpty) return '(no character prompt)';
  return src.replaceAll(RegExp(r'\s+'), ' ');
}

class _Pill extends StatelessWidget {
  final String label;
  const _Pill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: EmberColors.primary.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: EmberColors.primary.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: EmberColors.primary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

Future<void> _openCreatorPresetKebab(
    BuildContext context, CreatorPreset p) async {
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
            leading: const Icon(Icons.check_circle_outline,
                color: EmberColors.primary),
            title: const Text('Select (activate now)'),
            onTap: () {
              Navigator.pop(sheet);
              store.setActiveCreatorPreset(p.id);
              messenger.showSnackBar(
                SnackBar(content: Text('"${p.name}" is now active.')),
              );
            },
          ),
          // The locked default exposes its contents via read-only View and
          // is clonable so users can fork it. Edit + Delete stay unlocked-only
          // so the original always survives as a known-good reference.
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('View details'),
            onTap: () {
              Navigator.pop(sheet);
              _showCreatorPresetDetails(context, p);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy (editable)'),
            onTap: () {
              Navigator.pop(sheet);
              final clone = CreatorPreset(
                id: newId('creatorpreset'),
                name: '${p.name} (copy)',
                locked: false,
                characterPrompt: p.characterPrompt,
                scenarioPrompt: p.scenarioPrompt,
                editPrompt: p.editPrompt,
              );
              store.addCreatorPreset(clone);
              messenger.showSnackBar(
                const SnackBar(content: Text('Copied as editable preset.')),
              );
            },
          ),
          if (!p.locked)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(sheet);
                _editCreatorPreset(context, p);
              },
            ),
          if (!p.locked)
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: EmberColors.danger),
              title: const Text('Delete',
                  style: TextStyle(color: EmberColors.danger)),
              onTap: () async {
                Navigator.pop(sheet);
                final ok = await confirmDelete(
                  context,
                  title: 'Delete "${p.name}"?',
                  message:
                      'The preset will be removed. The Creator will fall back to the default prompts.',
                );
                if (!ok) return;
                store.removeCreatorPreset(p.id);
              },
            ),
        ],
      ),
    ),
  );
}

/// Read-only viewer for any Creator preset (especially the locked default,
/// which has no other surface to expose its contents). Reads the live preset
/// from the store by id so external mutations refresh in place.
Future<void> _showCreatorPresetDetails(
    BuildContext context, CreatorPreset p) async {
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => _CreatorPresetDetailsScreen(preset: p)),
  );
}

class _CreatorPresetDetailsScreen extends StatelessWidget {
  final CreatorPreset preset;
  const _CreatorPresetDetailsScreen({required this.preset});

  CreatorPreset _live(AppStore store) {
    for (final p in store.creatorPresets) {
      if (p.id == preset.id) return p;
    }
    return preset;
  }

  Widget _section(String title, String? value) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: EmberColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: EmberColors.bgElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: EmberColors.stroke, width: 1),
            ),
            child: SelectableText(
              value,
              style: const TextStyle(
                color: EmberColors.textHigh,
                fontSize: 12,
                height: 1.45,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final live = _live(store);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Creator preset details'),
        actions: [
          if (live.locked)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline,
                        size: 14, color: EmberColors.primary),
                    SizedBox(width: 4),
                    Text(
                      'READ-ONLY',
                      style: TextStyle(
                        color: EmberColors.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  live.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              if (live.locked)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: EmberColors.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'DEFAULT',
                    style: TextStyle(
                      color: EmberColors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
            ],
          ),
          if (live.locked) ...[
            const SizedBox(height: 6),
            const Text(
              'The shipped Creator architect prompts — read-only so they stay '
              'as a known-good fallback. Use "Copy (editable)" from the kebab '
              'to fork them into a preset you can modify freely.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 18),
          _section('Character prompt', live.characterPrompt),
          _section('Scenario prompt', live.scenarioPrompt),
          _section('Edit prompt', live.editPrompt),
        ],
      ),
    );
  }
}

/// Editor for an unlocked Creator preset (or a new-from-scratch one). Raw
/// multiline text fields, one per mode. No syntax help, no validator.
Future<void> _editCreatorPreset(
    BuildContext context, CreatorPreset? existing) async {
  final store = context.read<AppStore>();
  final nameCtl =
      TextEditingController(text: existing?.name ?? 'New creator preset');
  final charCtl =
      TextEditingController(text: existing?.characterPrompt ?? '');
  final scenCtl =
      TextEditingController(text: existing?.scenarioPrompt ?? '');
  final editCtl = TextEditingController(text: existing?.editPrompt ?? '');

  Widget sectionHeader(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: EmberColors.primary,
            fontWeight: FontWeight.w700,
            fontSize: 11,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget promptField(TextEditingController ctl) => TextField(
        controller: ctl,
        maxLines: 10,
        minLines: 4,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(isDense: true),
      );

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Text(existing == null
          ? 'New creator preset'
          : 'Edit creator preset'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sectionHeader('Name'),
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              sectionHeader('Character prompt'),
              promptField(charCtl),
              sectionHeader('Scenario prompt'),
              promptField(scenCtl),
              sectionHeader('Edit prompt'),
              promptField(editCtl),
            ],
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
            final name = nameCtl.text.trim().isEmpty
                ? 'Creator preset'
                : nameCtl.text.trim();
            if (existing == null) {
              store.addCreatorPreset(CreatorPreset(
                id: newId('creatorpreset'),
                name: name,
                characterPrompt: charCtl.text,
                scenarioPrompt: scenCtl.text,
                editPrompt: editCtl.text,
              ));
            } else {
              existing
                ..name = name
                ..characterPrompt = charCtl.text
                ..scenarioPrompt = scenCtl.text
                ..editPrompt = editCtl.text;
              store.updateCreatorPreset(existing);
            }
            Navigator.pop(ctx);
          },
          child: Text(existing == null ? 'Create' : 'Save'),
        ),
      ],
    ),
  );
}
