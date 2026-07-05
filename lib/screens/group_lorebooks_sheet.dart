import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'chat_picker_screens.dart';

/// Wave CY.18.195: bottom sheet that hosts the group-chat MEMBER management
/// and the per-chat LOREBOOK bindings. These two sections used to live in the
/// Customize Chat sheet; they were split out so that sheet can focus on the
/// background (and, later, the scene-aware location field). The code here was
/// LIFTED verbatim from `customize_chat_sheet.dart` — behaviour is unchanged
/// (add/remove members, toggle inherited lorebooks, manage per-chat lorebooks).
class GroupAndLorebooksSheet extends StatelessWidget {
  final String chatId;
  const GroupAndLorebooksSheet({super.key, required this.chatId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    // Chat may have been deleted while this sheet was open. Auto-close
    // rather than throwing on the firstWhere lookup.
    Chat? chat;
    for (final c in store.chats) {
      if (c.id == chatId) {
        chat = c;
        break;
      }
    }
    if (chat == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.maybePop(context);
      });
      return const SizedBox.shrink();
    }
    // Local non-null alias so the rest of the build can use member access
    // without dragging null checks through every callback.
    final c = chat;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: SizedBox(
                    width: 40,
                    height: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: EmberColors.stroke,
                        borderRadius: BorderRadius.all(Radius.circular(2)),
                      ),
                    ),
                  ),
                ),
              ),
              const Text(
                'Group chat & Lorebooks',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Members',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: EmberColors.textMid,
                      fontSize: 12),
                ),
              ),
              ..._buildMembers(context, store, c),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.person_add_outlined, size: 16),
                  label: const Text('Add character to chat'),
                  onPressed: () => _showAddMember(context, chatId),
                ),
              ),
              // Party mode v1 (2026-07): only meaningful for an actual
              // group (>1 member) — a single-character chat has no "party"
              // to voice together.
              if (c.characterIds.length > 1)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeThumbColor: EmberColors.primary,
                  title: const Text('Party mode'),
                  subtitle: const Text(
                    'Everyone responds together in one scene.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: c.partyMode,
                  onChanged: (v) => store.setChatPartyMode(c.id, v),
                ),
              Divider(color: EmberColors.stroke),
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Lorebooks',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: EmberColors.textMid,
                      fontSize: 12),
                ),
              ),
              // Wave CD: three grouped sections.
              //   1. Inherited from each character in the chat (group
              //      members are all listed individually so you can see
              //      which book comes from which character).
              //   2. Inherited from the active persona.
              //   3. Other available lorebooks attachable per-chat
              //      (excludes ones already inherited above to avoid
              //      showing the same book in two sections).
              ..._buildLorebookSections(context, store, c),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wave CD: render the three Lorebook subgroups inside the Group & Lorebooks
/// sheet. Returns a flat list of widgets so it inlines into the parent Column.
List<Widget> _buildLorebookSections(
    BuildContext context, AppStore store, Chat chat) {
  // Collect "inherited" book ids from per-chat persona + each character.
  // Track WHICH source contributes each id so the UI can group them.
  //
  // Wave CY: was `store.activePersona` — the customize panel was
  // showing (and letting the user toggle) the global default's books
  // even when the chat is bound to a different persona via
  // chat.personaId. Runtime injection uses chat.personaId, so the
  // toggles were silently mismatched. Resolve via chat.personaId
  // first (matches _chatPersona in chat_screen.dart) and fall back
  // to the global default only for legacy chats.
  Persona? activePersona;
  final pid = chat.personaId;
  if (pid != null) {
    for (final p in store.personas) {
      if (p.id == pid) {
        activePersona = p;
        break;
      }
    }
  }
  activePersona ??= store.activePersona;
  final personaBooks = <Lorebook>[];
  if (activePersona != null) {
    for (final id in activePersona.lorebookIds) {
      final b = store.lorebookById(id);
      if (b != null) personaBooks.add(b);
    }
  }
  // Map of character id → list of inherited books from that character.
  final perCharacterBooks = <String, List<Lorebook>>{};
  for (final cid in chat.characterIds) {
    final snap = chat.characterSnapshots[cid] ?? store.characterById(cid);
    if (snap == null) continue;
    final list = <Lorebook>[];
    for (final id in snap.lorebookIds) {
      final b = store.lorebookById(id);
      if (b != null) list.add(b);
    }
    if (list.isNotEmpty) perCharacterBooks[cid] = list;
  }
  // Ids that are inherited (any source) — used to filter the "other"
  // per-chat list so we don't double-list.
  final inheritedIds = <String>{
    ...personaBooks.map((b) => b.id),
    ...perCharacterBooks.values.expand((l) => l).map((b) => b.id),
  };
  final perChatOther = store.lorebooks
      .where((l) => !inheritedIds.contains(l.id))
      .toList(growable: false);

  final widgets = <Widget>[];

  // Sections 1+2 — inherited books, grouped by BOOK (2026-07, owner
  // feedback): in a group chat several members often carry the SAME world
  // lorebook, and the old per-source sections listed it once per member —
  // N rows for what is ONE underlying switch (the enable/disable state is
  // keyed on the book id alone, so those rows always flipped together).
  // Now each unique book renders ONCE, with every origin (members and/or
  // persona) joined in the subtitle. The engine already dedupes injection
  // by book id (collectBoundLorebooks), so this is purely presentational.
  final inheritedBooks = <String, Lorebook>{}; // book id -> book
  final inheritedSources = <String, List<String>>{}; // book id -> origins
  for (final entry in perCharacterBooks.entries) {
    final char =
        chat.characterSnapshots[entry.key] ?? store.characterById(entry.key);
    final charName = char?.name ?? '(unknown character)';
    for (final b in entry.value) {
      inheritedBooks[b.id] = b;
      (inheritedSources[b.id] ??= []).add(charName);
    }
  }
  if (personaBooks.isNotEmpty) {
    final pname = '${activePersona!.name} (persona)';
    for (final b in personaBooks) {
      inheritedBooks[b.id] = b;
      (inheritedSources[b.id] ??= []).add(pname);
    }
  }
  if (inheritedBooks.isNotEmpty) {
    widgets.add(_subgroupLabel('Inherited'));
    for (final b in inheritedBooks.values) {
      final disabled = chat.disabledInheritedLorebookIds.contains(b.id);
      widgets.add(_inheritedTile(
        context: context,
        store: store,
        chat: chat,
        book: b,
        enabled: !disabled,
        originLabel: inheritedSources[b.id]!.join(' · '),
      ));
    }
  }

  // Section 3 — per-chat attachments. Wave CY.17: showing every
  // available book inline made the sheet unusable with sizeable
  // libraries. Now we render a summary + a button that opens a
  // dedicated full-screen attach picker with search.
  if (store.lorebooks.isEmpty) {
    widgets.add(Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'No lorebooks created. Add one from the Lorebooks section of the '
        'Characters tab.',
        style: TextStyle(color: EmberColors.textMid, fontSize: 13),
      ),
    ));
  } else {
    widgets.add(_subgroupLabel('Per-chat only'));
    // Show currently-attached per-chat books inline (small list,
    // useful at-a-glance). Then a button to add/remove from the
    // full library.
    final attachedPerChat = perChatOther
        .where((l) => chat.attachedLorebookIds.contains(l.id))
        .toList();
    if (attachedPerChat.isEmpty) {
      widgets.add(Padding(
        padding: EdgeInsets.only(top: 4, bottom: 4),
        child: Text(
          'No per-chat lorebooks attached yet.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
      ));
    } else {
      for (final l in attachedPerChat) {
        widgets.add(ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(Icons.menu_book_outlined,
              size: 18, color: EmberColors.primary),
          title: Text(l.name),
          subtitle: Text(
            '${l.entries.length} entries',
            style: TextStyle(color: EmberColors.textMid, fontSize: 12),
          ),
          trailing: IconButton(
            icon: Icon(Icons.close,
                size: 16, color: EmberColors.textMid),
            tooltip: 'Detach from this chat',
            onPressed: () {
              // Mega-audit 2026-06-05 (F5): detaching a per-chat lorebook
              // edits chat sub-state that rides a chat sync, but a bare
              // notifyAndPersist() never bumps chat.mtime — so the change
              // saved locally but never propagated. Route through touchChat
              // so the detach reaches the paired device (mirrors the
              // inherited-toggle path, which already bumps via
              // enable/disableInheritedLorebookForChat).
              if (chat.attachedLorebookIds.remove(l.id)) {
                store.touchChat(chat);
              }
            },
          ),
        ));
      }
    }
    widgets.add(Padding(
      padding: const EdgeInsets.only(top: 4),
      child: OutlinedButton.icon(
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Manage per-chat lorebooks'),
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LorebookAttachPickerScreen(
                chatId: chat.id,
                excludeInheritedIds: inheritedIds,
              ),
            ),
          );
        },
      ),
    ));
  }

  return widgets;
}

Widget _subgroupLabel(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: EmberColors.primary,
          fontWeight: FontWeight.w700,
          fontSize: 10,
          letterSpacing: 0.8,
        ),
      ),
    );

/// Wave CD: inherited-binding row. SwitchListTile so it's visually
/// distinct from the per-chat checkboxes below — the user sees at a
/// glance that the source is different (bound on the character or
/// persona vs attached just to this chat).
Widget _inheritedTile({
  required BuildContext context,
  required AppStore store,
  required Chat chat,
  required Lorebook book,
  required bool enabled,
  required String originLabel,
}) {
  return SwitchListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    activeThumbColor: EmberColors.primary,
    title: Text(
      book.name,
      style: TextStyle(
        color: enabled ? EmberColors.textHigh : EmberColors.textDim,
      ),
    ),
    subtitle: Text(
      '${book.entries.length} entries  ·  inherited from $originLabel'
      '${enabled ? "" : "  ·  DISABLED for this chat"}',
      style: TextStyle(
        color: enabled ? EmberColors.textMid : EmberColors.textDim,
        fontSize: 12,
      ),
    ),
    value: enabled,
    onChanged: (v) {
      if (v) {
        store.enableInheritedLorebookForChat(chat.id, book.id);
      } else {
        store.disableInheritedLorebookForChat(chat.id, book.id);
      }
    },
  );
}

List<Widget> _buildMembers(BuildContext context, AppStore store, Chat chat) {
  if (chat.characterIds.isEmpty) {
    return [
      Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No members yet.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 13),
        ),
      ),
    ];
  }
  return chat.characterIds.map((id) {
    final c = chat.characterSnapshots[id] ?? store.characterById(id);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: AvatarBubble(
        dataUrl: c?.avatar,
        fallback: c?.name ?? '?',
        radius: 18,
      ),
      title: Text(c?.name ?? '(missing character)'),
      subtitle: c?.tagline != null && c!.tagline!.isNotEmpty
          ? Text(c.tagline!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: EmberColors.textMid, fontSize: 12))
          : null,
      trailing: chat.characterIds.length > 1
          ? IconButton(
              icon: Icon(Icons.remove_circle_outline,
                  color: EmberColors.danger),
              tooltip: 'Remove from chat',
              onPressed: () => store.removeCharacterFromChat(chat.id, id),
            )
          : null,
    );
  }).toList();
}

Future<void> _showAddMember(BuildContext context, String chatId) async {
  final store = context.read<AppStore>();
  final chat = store.chats.firstWhere((c) => c.id == chatId);
  // Wave CY.17: full-screen picker with search instead of a cramped
  // bottom sheet. Scales for large character libraries.
  final picked = await Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => CharacterPickerScreen(
        title: 'Add character to chat',
        subtitle: 'Pick a character to add as a member of this group chat.',
        excludeIds: chat.characterIds.toSet(),
      ),
    ),
  );
  if (picked == null) return;
  final c = store.characterById(picked);
  if (c == null) return;
  final wasSolo = chat.characterIds.length == 1;
  store.addCharacterToChat(chatId, c);
  // Facilidade (owner 2026-07): the moment a chat BECOMES a group, offer
  // Party mode right here — one tap on the snackbar action instead of the
  // user having to discover the toggle further down this sheet. Only on the
  // solo→group transition (adding a 3rd+ member re-suggests nothing), and
  // only when it isn't already on.
  if (wasSolo && !chat.partyMode && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
            'Group formed! Party mode makes everyone reply in one scene.'),
        duration: const Duration(seconds: 6),
        // 2026-07-05 (Gui): see the twin snackbar in chat_picker_screens —
        // an action-carrying snackbar can persist forever under accessible
        // navigation; the close icon guarantees a way out.
        showCloseIcon: true,
        action: SnackBarAction(
          label: 'Enable',
          onPressed: () => store.setChatPartyMode(chatId, true),
        ),
      ),
    );
  }
}

/// Wave CY.18.195: opens the Group chat & Lorebooks sheet. Mirrors
/// [showCustomizeChatSheet]'s scaffolding. Wired into the chat kebab in
/// Wave CY.18.194; until then this is an as-yet-uncalled public function.
Future<void> showGroupAndLorebooksSheet(BuildContext context, String chatId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: EmberColors.bgPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => GroupAndLorebooksSheet(chatId: chatId),
  );
}
