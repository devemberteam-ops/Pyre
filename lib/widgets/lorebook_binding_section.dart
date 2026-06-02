// Reusable UI for managing a list of bound lorebook ids on a
// character or persona. Two modes:
//
//   - read-only: shows chips of bound books with no actions
//   - edit:      same chips with × to remove + an "Add lorebook"
//                button that opens a picker modal
//
// The widget is dumb on purpose — it takes a `selectedIds` list and
// `onChanged` callback. The caller owns the state and persistence
// (e.g. character_edit_screen commits on save, persona_editor on
// commit, character_details_sheet just passes onChanged=null).
//
// Wave CC.
//
// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';

class LorebookBindingSection extends StatelessWidget {
  /// Currently bound book ids (a copy of `character.lorebookIds` or
  /// `persona.lorebookIds`). Order is preserved for display.
  final List<String> selectedIds;

  /// Called whenever the user adds or removes a binding. The widget
  /// passes a NEW list (not a mutation of the old one) so the caller
  /// can use it directly with `setState`. Pass `null` to render the
  /// widget in read-only mode (used on the details sheet).
  final ValueChanged<List<String>>? onChanged;

  /// Section header — defaults to "Linked lorebooks". Pass something
  /// different if it makes sense in context (e.g. on a persona screen
  /// you might want "Persona lorebooks").
  final String label;

  /// Subtitle / explanation under the header. Defaults to a short
  /// description of what binding does.
  final String? sublabel;

  const LorebookBindingSection({
    super.key,
    required this.selectedIds,
    this.onChanged,
    this.label = 'Linked lorebooks',
    this.sublabel,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final readOnly = onChanged == null;
    // Resolve ids → Lorebook (drops stale ids silently). Include hidden
    // books too so embedded-only ones (from card import) show up here —
    // they're invisible in the main Lorebooks list but binding is the
    // whole point of their existence.
    final boundBooks = selectedIds
        .map(store.lorebookById)
        .whereType<Lorebook>()
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.menu_book_outlined,
                size: 16, color: EmberColors.textMid),
            const SizedBox(width: 6),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
        if (sublabel != null) ...[
          const SizedBox(height: 4),
          Text(
            sublabel!,
            style: const TextStyle(
              color: EmberColors.textDim,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (boundBooks.isEmpty && readOnly)
          const Text(
            'No linked lorebooks.',
            style:
                TextStyle(color: EmberColors.textDim, fontStyle: FontStyle.italic),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in boundBooks)
                Chip(
                  backgroundColor:
                      EmberColors.primary.withValues(alpha: 0.12),
                  side: BorderSide(
                    color: EmberColors.primary.withValues(alpha: 0.30),
                  ),
                  avatar: const Icon(
                    Icons.menu_book_outlined,
                    size: 14,
                    color: EmberColors.primary,
                  ),
                  label: Text(
                    '${b.name} · ${b.entries.length}',
                    style: const TextStyle(
                      color: EmberColors.textHigh,
                      fontSize: 12,
                    ),
                  ),
                  deleteIcon: readOnly
                      ? null
                      : const Icon(Icons.close, size: 16),
                  onDeleted: readOnly
                      ? null
                      : () {
                          final next = List<String>.from(selectedIds)
                            ..remove(b.id);
                          onChanged!(next);
                        },
                ),
              if (!readOnly)
                ActionChip(
                  backgroundColor: EmberColors.bgDeep,
                  side: BorderSide(color: EmberColors.stroke),
                  avatar: const Icon(Icons.add,
                      size: 14, color: EmberColors.textMid),
                  label: const Text(
                    'Add lorebook',
                    style:
                        TextStyle(color: EmberColors.textMid, fontSize: 12),
                  ),
                  onPressed: () => _openPicker(context, store),
                ),
            ],
          ),
      ],
    );
  }

  Future<void> _openPicker(BuildContext context, AppStore store) async {
    // Picker shows ALL books, even hidden ones — the hidden flag is
    // about decluttering the main Lorebooks list, not about preventing
    // reuse. The selected check disables already-bound entries.
    final all = store.lorebooks;
    if (all.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'You don\'t have any lorebooks yet. Create or import one in More → Lorebooks first.')),
      );
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    const Icon(Icons.menu_book_outlined,
                        color: EmberColors.primary),
                    const SizedBox(width: 10),
                    const Text(
                      'Pick a lorebook',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: EmberColors.textMid),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
                  itemCount: all.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (_, i) {
                    final b = all[i];
                    final alreadyBound = selectedIds.contains(b.id);
                    return Card(
                      child: ListTile(
                        enabled: !alreadyBound,
                        leading: Icon(
                          Icons.menu_book_outlined,
                          color: alreadyBound
                              ? EmberColors.textDim
                              : EmberColors.textMid,
                        ),
                        title: Text(
                          b.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: alreadyBound
                                ? EmberColors.textDim
                                : EmberColors.textHigh,
                          ),
                        ),
                        subtitle: Text(
                          '${b.entries.length} entries'
                          '${b.hidden ? "  ·  embedded" : ""}'
                          '${b.description.isNotEmpty ? "  ·  ${b.description}" : ""}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: EmberColors.textDim, fontSize: 11),
                        ),
                        trailing: alreadyBound
                            ? const Icon(Icons.check,
                                color: EmberColors.textDim, size: 18)
                            : null,
                        onTap: alreadyBound
                            ? null
                            : () => Navigator.pop(ctx, b.id),
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
    if (picked != null) {
      onChanged!([...selectedIds, picked]);
    }
  }
}

/// Reverse "Used by" indicator for a lorebook editor / detail screen.
/// Read-only — binding flows from char/persona to book, not the other
/// way, so the user can't add/remove a binding from this side. It DOES
/// link tap → character/persona screen for quick navigation.
///
/// Wave CC.
class LorebookUsedBySection extends StatelessWidget {
  /// The lorebook to look up references for.
  final String lorebookId;

  const LorebookUsedBySection({super.key, required this.lorebookId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chars = store.characters
        .where((c) => c.lorebookIds.contains(lorebookId))
        .toList(growable: false);
    final personas = store.personas
        .where((p) => p.lorebookIds.contains(lorebookId))
        .toList(growable: false);
    final perChatRefs = store.chats.fold<int>(
      0,
      (n, c) => n + (c.attachedLorebookIds.contains(lorebookId) ? 1 : 0),
    );
    final totalRefs = chars.length + personas.length + perChatRefs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.link, size: 16, color: EmberColors.textMid),
            const SizedBox(width: 6),
            const Text(
              'USED BY',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(width: 6),
            if (totalRefs > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: EmberColors.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$totalRefs',
                  style: const TextStyle(
                    color: EmberColors.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'To bind or unbind, edit the character or persona. Per-chat '
          'attachments are managed from the chat\'s Customize panel.',
          style: TextStyle(
            color: EmberColors.textDim,
            fontSize: 11,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        if (chars.isEmpty && personas.isEmpty && perChatRefs == 0)
          const Text(
            'Not bound to any character, persona, or chat.',
            style: TextStyle(
                color: EmberColors.textDim, fontStyle: FontStyle.italic),
          )
        else ...[
          if (chars.isNotEmpty) ...[
            const Text(
              'Characters',
              style: TextStyle(
                  color: EmberColors.textDim, fontSize: 11, height: 1.6),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in chars)
                  Chip(
                    avatar: const Icon(Icons.person,
                        size: 14, color: EmberColors.primary),
                    label: Text(c.name,
                        style:
                            const TextStyle(color: EmberColors.textHigh)),
                    backgroundColor:
                        EmberColors.primary.withValues(alpha: 0.10),
                  ),
              ],
            ),
          ],
          if (personas.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Personas',
              style: TextStyle(
                  color: EmberColors.textDim, fontSize: 11, height: 1.6),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in personas)
                  Chip(
                    avatar: const Icon(Icons.face,
                        size: 14, color: EmberColors.primary),
                    label: Text(p.name,
                        style:
                            const TextStyle(color: EmberColors.textHigh)),
                    backgroundColor:
                        EmberColors.primary.withValues(alpha: 0.10),
                  ),
              ],
            ),
          ],
          if (perChatRefs > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Plus $perChatRefs per-chat attachment'
              '${perChatRefs == 1 ? "" : "s"}.',
              style: const TextStyle(
                color: EmberColors.textDim,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ],
    );
  }
}
