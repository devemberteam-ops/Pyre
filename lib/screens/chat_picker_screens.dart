// Wave CY.17: full-screen pickers for chat customization actions
// that used to be cramped bottom sheets.
//
// The original sheets tried to inline every choice — every persona,
// every character not in the chat, every lorebook — into a 70%-tall
// modal. Users with sizeable libraries reported these as basically
// unusable past a dozen entries: searching meant scrolling a narrow
// strip of items with no way to filter.
//
// These pickers fix that by pushing a real Scaffold-with-AppBar route,
// adding search/filter, and using the full screen. Each picker returns
// its choice via Navigator.pop; the caller wires the result into the
// store.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/empty_state.dart';
import 'chat_screen.dart' show ChatScreen;

/// Sentinel value pushed back via `Navigator.pop` to indicate the
/// user explicitly chose "No persona" in [PersonaPickerScreen].
/// Distinct from a `null` pop (sheet dismissed without picking) and
/// distinct from a real persona id.
const String pickerNoPersonaSentinel = '__pyre_picker_no_persona__';

/// Wave CY.18.1: shared entry point for "start a new chat with this
/// character". Honours [ChatSettings.askPersonaOnNewChat] uniformly
/// — when on, opens the full-screen [PersonaPickerScreen] first and
/// records the user's pick (or the explicit "No persona" sentinel)
/// on the freshly created chat. When off, just snaps to the chat
/// with whatever the global default persona is (chub-style flow).
///
/// Used by every "New chat" affordance across the app — the
/// characters list, character details, chats-of-character screen,
/// the in-chat "fresh chat" kebab, the character assistant. Don't
/// call `AppStore.startChatWith` directly anymore; route through
/// this helper so the per-chat persona prompt actually fires.
///
/// `replace` controls whether the chat opens via `pushReplacement`
/// (true — common when navigating from inside another chat) or a
/// plain `push` (default — keeps the previous screen on the stack).
Future<void> startNewChatWithPersonaPrompt(
  BuildContext context,
  Character primary, {
  bool replace = false,
}) async {
  final store = context.read<AppStore>();
  if (!store.chatSettings.askPersonaOnNewChat) {
    final fresh = store.startChatWith(primary);
    if (!context.mounted) return;
    final route = MaterialPageRoute(
      builder: (_) => ChatScreen(chatId: fresh.id),
    );
    if (replace) {
      Navigator.of(context).pushReplacement(route);
    } else {
      Navigator.of(context).push(route);
    }
    return;
  }
  final picked = await Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => PersonaPickerScreen(
        title: 'Persona for new chat with ${primary.name}',
        subtitle:
            'Pick the persona to play as. "No persona" means no {{user}} identity for this chat.',
        // Wave CY.18.13: this is a fresh chat — no "current" persona
        // exists yet, so don't pre-mark "No persona" (or any other
        // row) as if it were the active state. The user is making an
        // active pick, not changing one.
        showCurrentSelection: false,
      ),
    ),
  );
  if (!context.mounted || picked == null) return;
  final fresh = store.startChatWith(primary);
  if (picked == pickerNoPersonaSentinel) {
    store.setChatPersona(fresh.id, kExplicitNoPersonaId);
  } else {
    store.setChatPersona(fresh.id, picked);
  }
  if (!context.mounted) return;
  final route = MaterialPageRoute(
    builder: (_) => ChatScreen(chatId: fresh.id),
  );
  if (replace) {
    Navigator.of(context).pushReplacement(route);
  } else {
    Navigator.of(context).push(route);
  }
}

/// Full-screen persona picker. Returns:
///   - persona.id  → user picked that persona
///   - [pickerNoPersonaSentinel] → user picked "No persona"
///   - null        → user dismissed without choosing
class PersonaPickerScreen extends StatefulWidget {
  final String? selectedPersonaId;
  final String title;
  final String subtitle;
  /// Wave CY.18.13: whether to draw the ✓ checkmark on the row that
  /// matches [selectedPersonaId]. The "current persona" semantics make
  /// sense in the in-chat switcher flow (you're looking at what's
  /// active right now, possibly to change it), but in a fresh new-chat
  /// flow there's no "current" yet — pre-marking "No persona" makes
  /// the picker look like it has a default and the user has to opt out
  /// rather than opt in. Set to false in that case for a clean pick.
  final bool showCurrentSelection;
  const PersonaPickerScreen({
    super.key,
    this.selectedPersonaId,
    required this.title,
    required this.subtitle,
    this.showCurrentSelection = true,
  });

  @override
  State<PersonaPickerScreen> createState() => _PersonaPickerScreenState();
}

class _PersonaPickerScreenState extends State<PersonaPickerScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final q = _query.trim().toLowerCase();
    // M-4: exclude soft-deleted (tombstoned) personas — a synced-in tombstone
    // would otherwise show in the picker and, if selected, pin a deleted
    // persona whose text keeps injecting until GC. Mirrors the main list in
    // characters_screen (`_applyFiltersAndSort`).
    final live = store.personas.where((p) => !p.deleted);
    final filtered = q.isEmpty
        ? live.toList()
        : live.where((p) {
            final hay = '${p.name} ${p.tagline ?? ''} ${p.description}'
                .toLowerCase();
            return hay.contains(q);
          }).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              widget.subtitle,
              style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search personas…',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          // Perf-at-scale (audit 2026-06-05 #9): virtualized with
          // ListView.builder — the "No persona" tile + divider are the fixed
          // header (indices 0/1), an optional empty-state is index 2, then the
          // persona rows build lazily. Mirrors the sibling character/lorebook
          // pickers in this file. Avoids building every persona row up-front
          // for users with hundreds of personas (seed flow + "Add as persona").
          Expanded(
            child: Builder(
              builder: (context) {
                final noPersonaTile = ListTile(
                  leading: const Icon(Icons.person_off_outlined,
                      color: EmberColors.textDim),
                  title: const Text('No persona'),
                  subtitle: const Text(
                    'Send messages without a {{user}} identity.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  trailing: (widget.showCurrentSelection &&
                          widget.selectedPersonaId == null)
                      ? const Icon(Icons.check, color: EmberColors.primary)
                      : null,
                  onTap: () =>
                      Navigator.pop(context, pickerNoPersonaSentinel),
                );
                const divider =
                    Divider(color: EmberColors.stroke, height: 1);
                // Optional empty-state shown right under the header.
                Widget? emptyState;
                if (store.personas.isEmpty) {
                  emptyState = const Padding(
                    padding: EdgeInsets.all(32),
                    child: EmptyState(
                      icon: Icons.face_outlined,
                      title: 'No personas yet',
                      subtitle:
                          'Create one from the Personas tab to play as a specific identity.',
                    ),
                  );
                } else if (filtered.isEmpty) {
                  emptyState = const Padding(
                    padding: EdgeInsets.all(32),
                    child: EmptyState(
                      icon: Icons.search_off,
                      title: 'No matches',
                      subtitle: 'Nothing matches your search.',
                    ),
                  );
                }
                final headerCount = emptyState != null ? 3 : 2;
                return ListView.builder(
                  itemCount: headerCount + filtered.length,
                  itemBuilder: (context, i) {
                    if (i == 0) return noPersonaTile;
                    if (i == 1) return divider;
                    if (emptyState != null && i == 2) return emptyState;
                    final p = filtered[i - headerCount];
                    return ListTile(
                      leading: AvatarBubble(
                        dataUrl: p.avatar,
                        fallback: p.name,
                        radius: 18,
                      ),
                      title: Text(p.name),
                      subtitle: p.tagline != null && p.tagline!.isNotEmpty
                          ? Text(
                              p.tagline!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: EmberColors.textMid, fontSize: 12),
                            )
                          : null,
                      trailing: (widget.showCurrentSelection &&
                              p.id == widget.selectedPersonaId)
                          ? const Icon(Icons.check,
                              color: EmberColors.primary)
                          : null,
                      onTap: () => Navigator.pop(context, p.id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen character picker — returns the picked Character id, or
/// null if dismissed. Excludes ids already in [excludeIds].
class CharacterPickerScreen extends StatefulWidget {
  final Set<String> excludeIds;
  final String title;
  final String subtitle;
  const CharacterPickerScreen({
    super.key,
    this.excludeIds = const {},
    required this.title,
    required this.subtitle,
  });

  @override
  State<CharacterPickerScreen> createState() =>
      _CharacterPickerScreenState();
}

class _CharacterPickerScreenState extends State<CharacterPickerScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final q = _query.trim().toLowerCase();
    final candidates = store.characters
        .where((c) => !widget.excludeIds.contains(c.id))
        .where((c) {
      if (q.isEmpty) return true;
      final hay = '${c.name} ${c.tagline ?? ''} ${c.description}'
          .toLowerCase();
      return hay.contains(q);
    }).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              widget.subtitle,
              style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search characters…',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: candidates.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: EmptyState(
                      icon: store.characters.isEmpty
                          ? Icons.person_outline
                          : Icons.search_off,
                      title: store.characters.isEmpty
                          ? 'No characters yet'
                          : (widget.excludeIds.length ==
                                  store.characters.length
                              ? 'Every character is already in this chat'
                              : 'No matches'),
                      subtitle: store.characters.isEmpty
                          ? 'Import or create one from the Characters tab.'
                          : 'Try a different search term.',
                    ),
                  )
                : ListView.separated(
                    itemCount: candidates.length,
                    separatorBuilder: (_, _) => const Divider(
                        color: EmberColors.stroke, height: 1),
                    itemBuilder: (_, i) {
                      final c = candidates[i];
                      return ListTile(
                        leading: AvatarBubble(
                          dataUrl: c.avatar,
                          fallback: c.name,
                          radius: 18,
                        ),
                        title: Text(c.name),
                        subtitle:
                            c.tagline != null && c.tagline!.isNotEmpty
                                ? Text(
                                    c.tagline!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: EmberColors.textMid,
                                        fontSize: 12),
                                  )
                                : null,
                        onTap: () => Navigator.pop(context, c.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen per-chat lorebook attachment picker. Toggles books
/// in `chat.attachedLorebookIds` directly. Excludes books that are
/// already INHERITED from a character or persona (those have their
/// own toggle in the Customize chat sheet via the "From character /
/// From persona" sections).
class LorebookAttachPickerScreen extends StatefulWidget {
  final String chatId;
  final Set<String> excludeInheritedIds;
  const LorebookAttachPickerScreen({
    super.key,
    required this.chatId,
    required this.excludeInheritedIds,
  });

  @override
  State<LorebookAttachPickerScreen> createState() =>
      _LorebookAttachPickerScreenState();
}

class _LorebookAttachPickerScreenState
    extends State<LorebookAttachPickerScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    Chat? chat;
    for (final c in store.chats) {
      if (c.id == widget.chatId) {
        chat = c;
        break;
      }
    }
    if (chat == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.maybePop(context);
      });
      return const Scaffold(body: SizedBox.shrink());
    }
    final q = _query.trim().toLowerCase();
    final available = store.lorebooks
        .where((l) => !widget.excludeInheritedIds.contains(l.id))
        .where((l) {
      if (q.isEmpty) return true;
      return l.name.toLowerCase().contains(q);
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Attach lorebooks to this chat')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Books toggled here are injected ONLY in this chat. '
              'Books bound to a character or persona aren\'t listed '
              'here — manage those from the previous screen.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search lorebooks…',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: available.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: EmptyState(
                      icon: Icons.menu_book_outlined,
                      title: 'No lorebooks available',
                      subtitle:
                          'Create or import lorebooks from More → Lorebooks.',
                    ),
                  )
                : ListView.separated(
                    itemCount: available.length,
                    separatorBuilder: (_, _) => const Divider(
                        color: EmberColors.stroke, height: 1),
                    itemBuilder: (_, i) {
                      final l = available[i];
                      final attached =
                          chat!.attachedLorebookIds.contains(l.id);
                      return CheckboxListTile(
                        activeColor: EmberColors.primary,
                        title: Text(l.name),
                        subtitle: Text(
                          '${l.entries.length} entries',
                          style: const TextStyle(
                              color: EmberColors.textMid, fontSize: 12),
                        ),
                        value: attached,
                        onChanged: (v) {
                          if (v == true) {
                            if (!chat!.attachedLorebookIds
                                .contains(l.id)) {
                              chat.attachedLorebookIds.add(l.id);
                            }
                          } else {
                            chat!.attachedLorebookIds.remove(l.id);
                          }
                          store.notifyAndPersist();
                          setState(() {});
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
