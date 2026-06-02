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
    final store = context.watch<AppStore>();
    final chats = [...store.chats]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    if (chats.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Pyre',
              style: TextStyle(
                  color: EmberColors.primary, fontWeight: FontWeight.w700)),
          centerTitle: true,
        ),
        body: const EmptyState(
          icon: Icons.chat_bubble_outline,
          title: 'No chats yet',
          subtitle: 'Start a chat from the Characters tab.',
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
        title: const Text(
          'Pyre',
          style: TextStyle(
            color: EmberColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                const Text(
                  'All Chats',
                  style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      letterSpacing: 0.4),
                ),
                const Spacer(),
                Text(
                  '${chats.length} ${chats.length == 1 ? "chat" : "chats"}',
                  style: const TextStyle(
                      color: EmberColors.textMid, fontSize: 12),
                ),
              ],
            ),
          ),
          const Divider(
            color: EmberColors.stroke,
            height: 1,
            indent: 16,
            endIndent: 16,
          ),
          Expanded(
            child: ListView.separated(
              itemCount: order.length,
              separatorBuilder: (context, index) => const Divider(
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
                    style: const TextStyle(
                      color: EmberColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lastText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: EmberColors.textMid,
                      fontStyle: FontStyle.italic,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: EmberColors.textDim),
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
              leading: const Icon(Icons.add_comment_outlined,
                  color: EmberColors.primary),
              title: const Text('New chat'),
              onTap: () {
                Navigator.pop(sheet);
                if (character == null) return;
                startNewChatWithPersonaPrompt(context, character!);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: EmberColors.danger),
              title: Text(
                chats.length == 1
                    ? 'Delete chat'
                    : 'Delete all ${chats.length} chats',
                style: const TextStyle(color: EmberColors.danger),
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
