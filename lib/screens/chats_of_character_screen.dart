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

/// Drilldown screen reached by tapping a character in the Chats list.
/// Shows every chat the user has had with that character, with persona
/// badge, message count, time ago, and a preview of the last message.
class ChatsOfCharacterScreen extends StatelessWidget {
  final String characterId;
  const ChatsOfCharacterScreen({super.key, required this.characterId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final character = store.characterById(characterId);
    final chats = store.chats
        .where((c) => c.primaryCharacterId == characterId)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Scaffold(
      appBar: AppBar(
        title: Text(character?.name ?? 'Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New chat',
            onPressed: character == null
                ? null
                : () => startNewChatWithPersonaPrompt(
                      context,
                      character,
                      replace: true,
                    ),
          ),
        ],
      ),
      body: chats.isEmpty
          ? const EmptyState(
              icon: Icons.chat_bubble_outline,
              title: 'No chats with this character',
              subtitle: 'Tap + to start one.',
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text(
                        'Chats with ${character?.name ?? "this character"}',
                        style: const TextStyle(
                          color: EmberColors.textMid,
                          fontSize: 12,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        chats.length.toString(),
                        style: const TextStyle(
                          color: EmberColors.textMid,
                          fontSize: 12,
                        ),
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
                    itemCount: chats.length,
                    separatorBuilder: (context, index) => const Divider(
                      color: EmberColors.stroke,
                      height: 1,
                      indent: 72,
                      endIndent: 16,
                    ),
                    itemBuilder: (context, i) {
                      final chat = chats[i];
                      return _ChatRow(
                        chat: chat,
                        store: store,
                        character: character,
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  final Chat chat;
  final AppStore store;
  final Character? character;
  const _ChatRow({
    required this.chat,
    required this.store,
    required this.character,
  });

  @override
  Widget build(BuildContext context) {
    final lastMsg = chat.messages.isEmpty ? null : chat.messages.last;
    final lastText = lastMsg?.text ?? 'No messages yet.';
    final persona = chat.personaId == null
        ? null
        : store.personas.firstWhere(
            (p) => p.id == chat.personaId,
            orElse: () => Persona(id: '?', name: ''),
          );
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chat.id),
      )),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AvatarBubble(
              dataUrl: character?.avatar,
              fallback: character?.name ?? '?',
              radius: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '${chat.messages.length} ${chat.messages.length == 1 ? "msg" : "msgs"} · ${_relative(chat.updatedAt)}',
                          style: const TextStyle(
                            color: EmberColors.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (persona != null &&
                          (persona.name).isNotEmpty &&
                          persona.id != '?') ...[
                        const SizedBox(width: 6),
                        _PersonaBadge(persona: persona),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lastText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: EmberColors.textMid,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: EmberColors.textDim),
              tooltip: 'Chat actions',
              onPressed: () => _showRowKebab(context, store, chat),
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonaBadge extends StatelessWidget {
  final Persona persona;
  const _PersonaBadge({required this.persona});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(2, 2, 8, 2),
      decoration: BoxDecoration(
        color: EmberColors.primary.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: EmberColors.primary.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AvatarBubble(
            dataUrl: persona.avatar,
            fallback: persona.name,
            radius: 9,
          ),
          const SizedBox(width: 5),
          Text(
            persona.name,
            style: const TextStyle(
              color: EmberColors.primary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

void _showRowKebab(BuildContext context, AppStore store, Chat chat) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('Open chat'),
            onTap: () {
              Navigator.pop(sheet);
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChatScreen(chatId: chat.id),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline,
                color: EmberColors.danger),
            title: const Text('Delete chat',
                style: TextStyle(color: EmberColors.danger)),
            onTap: () async {
              Navigator.pop(sheet);
              final ok = await confirmDelete(
                context,
                title: 'Delete chat?',
                message:
                    'This conversation and all its messages will be lost forever.',
              );
              if (!ok) return;
              store.removeChat(chat.id);
            },
          ),
        ],
      ),
    ),
  );
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
