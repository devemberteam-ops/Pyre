import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import 'chat_picker_screens.dart';
import 'chat_screen.dart';
import 'chats_of_character_screen.dart';

class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // BATCH P2-ui (F): read (not watch). Hosted inside an `ActiveTabGate` that
    // rebuilds this screen on every store notify while it's the active tab and
    // freezes it while off-screen. A root `context.watch` would re-subscribe
    // and rebuild even when off-screen (defeating the gate), so we read and let
    // the gate govern rebuilds.
    final store = context.read<AppStore>();
    // Filter out tombstoned (deleted:true) records so a stray synced-in
    // tombstone can't render as a phantom chat (mirrors regex_rules_screen).
    final chats = store.chats.where((c) => !c.deleted).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    // 2026-07-03 (Gui): chats (including GROUP chats) can start right here —
    // the tab used to have no create affordance at all (library-only).
    final newChatButton = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: ElevatedButton.icon(
        icon: const Icon(Icons.add, size: 16),
        label: const Text('New chat'),
        onPressed: () => startNewChatFlow(context),
      ),
    );

    if (chats.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Pyre',
              style: TextStyle(
                  color: EmberColors.primary, fontWeight: FontWeight.w700)),
          centerTitle: true,
          actions: [newChatButton],
        ),
        body: EmptyState(
          icon: Icons.chat_bubble_outline,
          title: 'No chats yet',
          subtitle: 'Start one here — solo or a whole group — or tap a '
              'character in the Library tab.',
          ctaLabel: 'New chat',
          ctaIcon: Icons.add,
          onCta: () => startNewChatFlow(context),
        ),
      );
    }

    // Build per-character groups in most-recent order.
    final order = <String>[];
    final groups = <String, List<Chat>>{};
    for (final c in chats) {
      final key = c.primaryCharacterId ?? '__orphan_${c.id}';
      if (!groups.containsKey(key)) {
        order.add(key);
        groups[key] = [];
      }
      groups[key]!.add(c);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Pyre',
          style: TextStyle(
            color: EmberColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        actions: [newChatButton],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text(
                  'All Chats',
                  style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      letterSpacing: 0.4),
                ),
                const Spacer(),
                Text(
                  '${chats.length} ${chats.length == 1 ? "chat" : "chats"}',
                  style: TextStyle(
                      color: EmberColors.textMid, fontSize: 12),
                ),
              ],
            ),
          ),
          Divider(
            color: EmberColors.stroke,
            height: 1,
            indent: 16,
            endIndent: 16,
          ),
          Expanded(
            child: ListView.separated(
              itemCount: order.length,
              separatorBuilder: (context, index) => Divider(
                color: EmberColors.stroke,
                height: 1,
                indent: 72,
                endIndent: 16,
              ),
              itemBuilder: (context, i) {
                final key = order[i];
                final list = groups[key]!;
                final character = list.first.primaryCharacterId == null
                    ? null
                    : (list.first.characterSnapshots[list.first.primaryCharacterId] ??
                        store.characterById(list.first.primaryCharacterId!));
                return _CharacterChatsRow(
                  characterId: list.first.primaryCharacterId,
                  character: character,
                  chats: list,
                  store: store,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacterChatsRow extends StatelessWidget {
  final String? characterId;
  final Character? character;
  final List<Chat> chats;
  final AppStore store;
  const _CharacterChatsRow({
    required this.characterId,
    required this.character,
    required this.chats,
    required this.store,
  });

  void _open(BuildContext context) {
    if (chats.length == 1) {
      // Single chat — open it directly, matching the HTML.
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chats.first.id),
      ));
      return;
    }
    // Multiple chats with this character — go to the drilldown.
    if (characterId == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatsOfCharacterScreen(characterId: characterId!),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final latest = chats.first;
    final lastText = latest.messages.isEmpty
        ? 'No messages yet.'
        : latest.messages.last.text;
    final count = chats.length;
    // 2026-07-05 (Gui): the list gave NO hint a chat is a group / party.
    // Build a compact info line from the LATEST chat: member roster (+ Party
    // mode) and the persona party ("as A, B").
    final infoParts = <String>[];
    if (latest.characterIds.length > 1) {
      final names = latest.characterIds
          .map((id) =>
              (latest.characterSnapshots[id] ?? store.characterById(id))?.name)
          .whereType<String>()
          .toList();
      infoParts.add(
          'Group: ${names.join(', ')}${latest.partyMode ? ' · Party mode' : ''}');
    }
    if (latest.personaIds.length > 1) {
      final names = latest.personaIds
          .map((id) => store.personaById(id)?.name)
          .whereType<String>()
          .toList();
      if (names.isNotEmpty) infoParts.add('as ${names.join(', ')}');
    }
    return InkWell(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AvatarBubble(
              dataUrl: character?.avatar,
              fallback: character?.name ?? '?',
              radius: 20,
              tappableLightbox: true,
              // Non-destructive Recrop: tap opens the whole original, not the crop.
              fullImageUrl: character?.avatarOriginal,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    character?.name ?? 'Chat',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count ${count == 1 ? "chat" : "chats"} · ${_relative(latest.updatedAt)}',
                    style: TextStyle(
                      color: EmberColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (infoParts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      infoParts.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    lastText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontStyle: FontStyle.italic,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.more_vert, color: EmberColors.textDim),
              tooltip: 'Actions',
              onPressed: () => _showGroupKebab(context),
            ),
          ],
        ),
      ),
    );
  }

  void _showGroupKebab(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chats.length > 1 && characterId != null)
              ListTile(
                leading: const Icon(Icons.list_alt_outlined),
                title: const Text('Open chat list'),
                onTap: () {
                  Navigator.pop(sheet);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        ChatsOfCharacterScreen(characterId: characterId!),
                  ));
                },
              ),
            ListTile(
              leading: Icon(Icons.add_comment_outlined,
                  color: EmberColors.primary),
              title: const Text('New chat'),
              onTap: () {
                Navigator.pop(sheet);
                if (character == null) return;
                startNewChatWithPersonaPrompt(context, character!);
              },
            ),
            // 2026-07-04 (Gui): renaming is a list-organization act — it
            // lives on the chat rows now, not inside the conversation's own
            // menu. With ONE chat this kebab IS that chat's row (with more,
            // the per-chat rename lives in the drilldown list).
            if (chats.length == 1)
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Rename chat'),
                onTap: () {
                  Navigator.pop(sheet);
                  renameChatPrompt(context, store, chats.first);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: EmberColors.danger),
              title: Text(
                chats.length == 1
                    ? 'Delete chat'
                    : 'Delete all ${chats.length} chats',
                style: TextStyle(color: EmberColors.danger),
              ),
              onTap: () async {
                Navigator.pop(sheet);
                final ok = await confirmDelete(
                  context,
                  title: chats.length == 1
                      ? 'Delete chat?'
                      : 'Delete all ${chats.length} chats?',
                  message: chats.length == 1
                      ? 'This conversation and all its messages will be lost forever.'
                      : 'All ${chats.length} conversations with this character will be lost forever.',
                );
                if (!ok) return;
                for (final c in chats) {
                  store.removeChat(c.id);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _relative(int ms) {
  final now = DateTime.now();
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return '${d.day}/${d.month}/${d.year}';
}
