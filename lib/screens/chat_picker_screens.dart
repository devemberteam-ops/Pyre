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
import 'characters_screen.dart' show topLevelVisibleCharacters;
import 'chat_screen.dart' show ChatScreen;

/// Sentinel value pushed back via `Navigator.pop` to indicate the
/// user explicitly chose "No persona" in [PersonaPickerScreen].
/// Distinct from a `null` pop (sheet dismissed without picking) and
/// distinct from a real persona id.
const String pickerNoPersonaSentinel = '__pyre_picker_no_persona__';

// ---------------------------------------------------------------------------
// 2026-07-03 (Gui): "adding characters/personas to a chat gives a mini menu
// with all the options, when it should take you to the normal screen that
// already has folders and better organization." The pickers now share the
// LIBRARY's organization instead of being flat name lists. Pure helpers so
// the behavior is unit-tested without widgets.

/// The library's organization applied to a character picker: folder
/// visibility via [topLevelVisibleCharacters] (tombstones excluded, the home
/// view hides filed cards, a query searches everything), minus the ids
/// already in the chat, favorites floated first, each group sorted with the
/// library's sort key.
({List<Character> favs, List<Character> rest}) organizePickerCharacters({
  required List<Character> all,
  required List<Folder> folders,
  required Set<String> excludeIds,
  String? folderId,
  String query = '',
  String sortKey = 'recent',
  Map<String, int> chatCounts = const {},
  Map<String, int> lastUsedAt = const {},
}) {
  final q = query.trim().toLowerCase();
  Iterable<Character> stream = topLevelVisibleCharacters(
    all,
    folders,
    activeFolderId: folderId,
    query: q,
  ).where((c) => !excludeIds.contains(c.id));
  if (q.isNotEmpty) {
    stream = stream.where((c) {
      final hay = [c.name, c.tagline ?? '', c.tags.join(' '), c.description]
          .join(' ')
          .toLowerCase();
      return hay.contains(q);
    });
  }
  final list = stream.toList();
  switch (sortKey) {
    case 'created':
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      break;
    case 'alpha':
      list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
    case 'chatted':
      list.sort(
          (a, b) => (chatCounts[b.id] ?? 0).compareTo(chatCounts[a.id] ?? 0));
      break;
    case 'recent':
    default:
      list.sort(
          (a, b) => (lastUsedAt[b.id] ?? 0).compareTo(lastUsedAt[a.id] ?? 0));
      break;
  }
  return (
    favs: list.where((c) => c.favorite).toList(),
    rest: list.where((c) => !c.favorite).toList(),
  );
}

/// Library-parity organization for the persona pickers (personas have no
/// folders): tombstones excluded, favorites floated first, each group sorted
/// with the library's persona sort key.
({List<Persona> favs, List<Persona> rest}) organizePickerPersonas({
  required List<Persona> all,
  String query = '',
  String sortKey = 'recent',
  Map<String, int> lastUsedAt = const {},
}) {
  final q = query.trim().toLowerCase();
  final list = all.where((p) => !p.deleted).where((p) {
    if (q.isEmpty) return true;
    final hay =
        [p.name, p.tagline ?? '', p.description].join(' ').toLowerCase();
    return hay.contains(q);
  }).toList();
  switch (sortKey) {
    case 'created':
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      break;
    case 'alpha':
      list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      break;
    case 'recent':
    default:
      list.sort(
          (a, b) => (lastUsedAt[b.id] ?? 0).compareTo(lastUsedAt[a.id] ?? 0));
      break;
  }
  return (
    favs: list.where((p) => p.favorite).toList(),
    rest: list.where((p) => !p.favorite).toList(),
  );
}

/// One O(N_chats) pass: persona id → most recent chat.updatedAt. Mirrors the
/// library's "Recently used" persona sort.
Map<String, int> lastUsedAtByPersona(List<Chat> chats) {
  final m = <String, int>{};
  for (final ch in chats) {
    final pid = ch.personaId;
    if (pid == null) continue;
    final prev = m[pid];
    if (prev == null || ch.updatedAt > prev) m[pid] = ch.updatedAt;
  }
  return m;
}

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
  // Dead-context fix (2026-07-03, review HIGH): callers like the character
  // details SHEET pop themselves before calling this, so `context` (the
  // sheet's element) is disposed by the time an awaited picker returns —
  // `context.mounted` goes false and the flow silently died. Capture the
  // long-lived NavigatorState up front and gate on ITS mounted instead.
  final navigator = Navigator.of(context);
  if (!store.chatSettings.askPersonaOnNewChat) {
    final fresh = store.startChatWith(primary);
    if (!navigator.mounted) return;
    final route = MaterialPageRoute(
      builder: (_) => ChatScreen(chatId: fresh.id),
    );
    if (replace) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
    return;
  }
  final picked = await navigator.push<String>(
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
  if (!navigator.mounted || picked == null) return;
  final fresh = store.startChatWith(primary);
  if (picked == pickerNoPersonaSentinel) {
    store.setChatPersona(fresh.id, kExplicitNoPersonaId);
  } else {
    store.setChatPersona(fresh.id, picked);
  }
  final route = MaterialPageRoute(
    builder: (_) => ChatScreen(chatId: fresh.id),
  );
  if (replace) {
    navigator.pushReplacement(route);
  } else {
    navigator.push(route);
  }
}

/// Facilidade (owner 2026-07): start a NEW GROUP chat in one flow — pick the
/// members up front (multi-select, [primary] pre-selected) instead of forming
/// the group member-by-member after creation. Honours the same
/// `askPersonaOnNewChat` prompt as [startNewChatWithPersonaPrompt], creates
/// the chat with EVERY picked member, opens it, and suggests Party mode via
/// the same snackbar the add-member flow uses.
Future<void> startNewGroupChat(
  BuildContext context,
  Character primary,
) async {
  final store = context.read<AppStore>();
  // Dead-context fix (2026-07-03, review HIGH): the ONLY call site (the
  // character details sheet) pops itself before calling this, so `context`
  // is disposed ~250ms in — every `context.mounted` gate went false the
  // moment the picker returned and the flow silently created NOTHING.
  // Capture the long-lived navigator + messenger up front; gate on
  // `navigator.mounted`, never on the dead originating context.
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final memberIds = await navigator.push<List<String>>(
    MaterialPageRoute(
      builder: (_) => GroupCharacterPickerScreen(primary: primary),
    ),
  );
  if (memberIds == null || memberIds.isEmpty || !navigator.mounted) return;

  String? personaPick;
  if (store.chatSettings.askPersonaOnNewChat) {
    personaPick = await navigator.push<String>(
      MaterialPageRoute(
        builder: (_) => PersonaPickerScreen(
          title: 'Persona for the new group chat',
          subtitle:
              'Pick the persona to play as. "No persona" means no {{user}} identity for this chat.',
          showCurrentSelection: false,
        ),
      ),
    );
    if (personaPick == null || !navigator.mounted) return; // dismissed
  }

  final members = [
    for (final id in memberIds) store.characterById(id),
  ].whereType<Character>().toList();
  if (members.isEmpty) return;
  final fresh = store.startChatWith(members.first);
  for (final m in members.skip(1)) {
    store.addCharacterToChat(fresh.id, m);
  }
  if (personaPick != null) {
    store.setChatPersona(
        fresh.id,
        personaPick == pickerNoPersonaSentinel
            ? kExplicitNoPersonaId
            : personaPick);
  }
  if (!navigator.mounted) return;
  navigator.push(
    MaterialPageRoute(builder: (_) => ChatScreen(chatId: fresh.id)),
  );
  // Party suggestion — same affordance as forming a group via "Add
  // character to chat". Root-level ScaffoldMessenger, so it shows on top of
  // the freshly pushed chat.
  if (members.length > 1) {
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
            'Group created! Party mode makes everyone reply in one scene.'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Enable',
          onPressed: () => store.setChatPartyMode(fresh.id, true),
        ),
      ),
    );
  }
}

/// Shared organized body for the character pickers: subtitle + search +
/// folder browsing (LOCAL state — never touches the library tab's own folder
/// view) + favorites section, with each picker rendering its own row widget.
/// Virtualized — only on-screen rows inflate.
class _OrganizedCharacterPickerBody extends StatefulWidget {
  final String subtitle;
  final Set<String> excludeIds;
  final Widget Function(Character c) buildRow;
  const _OrganizedCharacterPickerBody({
    required this.subtitle,
    required this.excludeIds,
    required this.buildRow,
  });

  @override
  State<_OrganizedCharacterPickerBody> createState() =>
      _OrganizedCharacterPickerBodyState();
}

class _OrganizedCharacterPickerBodyState
    extends State<_OrganizedCharacterPickerBody> {
  String _query = '';
  String? _folderId;

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Text(
          text,
          style: TextStyle(
            color: EmberColors.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final q = _query.trim().toLowerCase();
    final liveFolders = store.folders.where((f) => !f.deleted).toList();
    // A folder deleted (or synced away) while browsing it falls back to the
    // home view gracefully instead of rendering an empty husk.
    Folder? activeFolder;
    for (final f in liveFolders) {
      if (f.id == _folderId) {
        activeFolder = f;
        break;
      }
    }
    final organized = organizePickerCharacters(
      all: store.characters,
      folders: store.folders,
      excludeIds: widget.excludeIds,
      folderId: activeFolder?.id,
      query: q,
      sortKey: store.charSortKey,
      chatCounts: store.chatCountByCharacter,
      lastUsedAt: store.lastUsedAtByCharacter,
    );
    final onHome = activeFolder == null && q.isEmpty;

    int selectableIn(Folder f) {
      final ids = f.characterIds.toSet();
      return store.characters
          .where((c) =>
              !c.deleted &&
              ids.contains(c.id) &&
              !widget.excludeIds.contains(c.id))
          .length;
    }

    // Lazily-built row list (thunks, not widgets) so a big library only
    // inflates on-screen rows — same virtualization as the library tab.
    final rows = <Widget Function()>[];
    if (onHome && liveFolders.isNotEmpty) {
      rows.add(() => _sectionLabel('FOLDERS'));
      for (final f in liveFolders) {
        final count = selectableIn(f);
        rows.add(() => ListTile(
              leading:
                  Icon(Icons.folder_outlined, color: EmberColors.textMid),
              title: Text(f.name),
              subtitle: Text(
                '$count character${count == 1 ? '' : 's'}',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => setState(() => _folderId = f.id),
            ));
      }
      rows.add(() => const SizedBox(height: 8));
    }
    if (organized.favs.isNotEmpty) {
      rows.add(() => _sectionLabel('FAVORITES'));
      for (final c in organized.favs) {
        rows.add(() => widget.buildRow(c));
      }
      if (organized.rest.isNotEmpty) rows.add(() => const SizedBox(height: 8));
    }
    for (final c in organized.rest) {
      rows.add(() => widget.buildRow(c));
    }
    // Home view with folders but zero unfiled rows: keep the folder tiles
    // visible and say where everyone is.
    final noCharacterRows = organized.favs.isEmpty && organized.rest.isEmpty;
    if (noCharacterRows && onHome && liveFolders.isNotEmpty) {
      rows.add(() => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Everyone else lives inside a folder — open one above, or '
              'search to look across all of them.',
              style: TextStyle(
                  color: EmberColors.textMid, fontSize: 12, height: 1.4),
            ),
          ));
    }

    final liveCount = store.characters.where((c) => !c.deleted).length;
    final Widget listBody;
    if (rows.isEmpty) {
      listBody = Padding(
        padding: const EdgeInsets.all(32),
        child: EmptyState(
          icon: liveCount == 0 ? Icons.person_outline : Icons.search_off,
          title: liveCount == 0
              ? 'No characters yet'
              : q.isNotEmpty
                  ? 'No matches'
                  : 'Every character is already in this chat',
          subtitle: liveCount == 0
              ? 'Import or create one from the Characters tab.'
              : q.isNotEmpty
                  ? 'Try a different search term.'
                  : 'They\'re all members already.',
        ),
      );
    } else {
      listBody = ListView.builder(
        itemCount: rows.length,
        itemBuilder: (_, i) => rows[i](),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            widget.subtitle,
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
              hintText: 'Search characters…',
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (activeFolder != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 16, 4),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => _folderId = null),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('All characters'),
                ),
                const SizedBox(width: 4),
                Icon(Icons.folder_outlined,
                    size: 16, color: EmberColors.textMid),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    activeFolder.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        Expanded(child: listBody),
      ],
    );
  }
}

/// Multi-select character picker for [startNewGroupChat]. Pops with the
/// ordered member id list ([primary] first, locked), or null if dismissed.
class GroupCharacterPickerScreen extends StatefulWidget {
  final Character primary;
  const GroupCharacterPickerScreen({super.key, required this.primary});

  @override
  State<GroupCharacterPickerScreen> createState() =>
      _GroupCharacterPickerScreenState();
}

class _GroupCharacterPickerScreenState
    extends State<GroupCharacterPickerScreen> {
  // Selection order is preserved → it becomes the member order (primary
  // first; primary is locked on).
  late final List<String> _selected = [widget.primary.id];

  @override
  Widget build(BuildContext context) {
    final n = _selected.length;
    return Scaffold(
      appBar: AppBar(title: const Text('New group chat')),
      body: Column(
        children: [
          Expanded(
            child: _OrganizedCharacterPickerBody(
              subtitle: 'Pick the members. ${widget.primary.name} opens the '
                  'chat (their greeting starts it); everyone joins the scene.',
              excludeIds: const {},
              buildRow: (c) {
                final isPrimary = c.id == widget.primary.id;
                return CheckboxListTile(
                  activeColor: EmberColors.primary,
                  controlAffinity: ListTileControlAffinity.trailing,
                  secondary: AvatarBubble(
                    dataUrl: c.avatar,
                    fallback: c.name,
                    radius: 18,
                  ),
                  title: Text(c.name),
                  subtitle: isPrimary
                      ? Text('Opens the chat',
                          style: TextStyle(
                              color: EmberColors.primary, fontSize: 12))
                      : (c.tagline != null && c.tagline!.isNotEmpty
                          ? Text(
                              c.tagline!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: EmberColors.textMid, fontSize: 12),
                            )
                          : null),
                  value: _selected.contains(c.id),
                  // The primary is locked on — unchecking it would
                  // orphan the greeting that opens the chat.
                  onChanged: isPrimary
                      ? null
                      : (v) => setState(() {
                            if (v == true) {
                              _selected.add(c.id);
                            } else {
                              _selected.remove(c.id);
                            }
                          }),
                );
              },
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      n <= 1
                          ? 'Just ${widget.primary.name} — a regular 1:1 chat'
                          : '$n members',
                      style: TextStyle(
                        color: n > 1
                            ? EmberColors.primary
                            : EmberColors.textMid,
                        fontSize: 12,
                        fontWeight:
                            n > 1 ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: EmberColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () =>
                        Navigator.pop(context, List<String>.from(_selected)),
                    child: const Text('Create chat'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
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
    // M-4 (tombstone exclusion) + 2026-07-03 (Gui, library-parity
    // organization): favorites float first and the library's persona sort
    // applies, all via the shared pure helper.
    final organized = organizePickerPersonas(
      all: store.personas,
      query: _query,
      sortKey: store.personaSortKey,
      lastUsedAt: lastUsedAtByPersona(store.chats),
    );
    final filtered = [...organized.favs, ...organized.rest];
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              widget.subtitle,
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
                  leading: Icon(Icons.person_off_outlined,
                      color: EmberColors.textDim),
                  title: const Text('No persona'),
                  subtitle: Text(
                    'Send messages without a {{user}} identity.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  trailing: (widget.showCurrentSelection &&
                          widget.selectedPersonaId == null)
                      ? Icon(Icons.check, color: EmberColors.primary)
                      : null,
                  onTap: () =>
                      Navigator.pop(context, pickerNoPersonaSentinel),
                );
                final divider =
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
                              style: TextStyle(
                                  color: EmberColors.textMid, fontSize: 12),
                            )
                          : null,
                      trailing: (widget.showCurrentSelection &&
                              p.id == widget.selectedPersonaId)
                          ? Icon(Icons.check,
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
/// null if dismissed. Excludes ids already in [excludeIds]. Organized like
/// the library (folders + favorites + the library's sort).
class CharacterPickerScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _OrganizedCharacterPickerBody(
        subtitle: subtitle,
        excludeIds: excludeIds,
        buildRow: (c) => ListTile(
          leading: AvatarBubble(
            dataUrl: c.avatar,
            fallback: c.name,
            radius: 18,
          ),
          title: Text(c.name),
          subtitle: c.tagline != null && c.tagline!.isNotEmpty
              ? Text(
                  c.tagline!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: EmberColors.textMid, fontSize: 12),
                )
              : null,
          onTap: () => Navigator.pop(context, c.id),
        ),
      ),
    );
  }
}

/// 2026-07-03 (Gui): full-screen MULTI-select persona picker for the per-chat
/// persona / persona party — replaces the cramped bottom sheet ("a mini menu
/// with all the options") with the same organized screen the other pickers
/// use: favorites float first, the library's persona sort, search. Selection
/// order = party order (first = primary). Pops with the ordered id list
/// (empty = No persona), or null if dismissed without applying.
class PersonaPartyPickerScreen extends StatefulWidget {
  final List<String> initialSelected;
  const PersonaPartyPickerScreen({super.key, this.initialSelected = const []});

  @override
  State<PersonaPartyPickerScreen> createState() =>
      _PersonaPartyPickerScreenState();
}

class _PersonaPartyPickerScreenState extends State<PersonaPartyPickerScreen> {
  String _query = '';
  // Insertion order = party order (first = primary).
  late final List<String> _selected = List<String>.from(widget.initialSelected);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final organized = organizePickerPersonas(
      all: store.personas,
      query: _query,
      sortKey: store.personaSortKey,
      lastUsedAt: lastUsedAtByPersona(store.chats),
    );
    final n = _selected.length;
    final status = n == 0
        ? 'No persona'
        : n == 1
            ? 'Solo — 1 persona'
            : 'Persona party — $n personas (your messages = the whole group)';

    Widget row(Persona p) => CheckboxListTile(
          value: _selected.contains(p.id),
          onChanged: (v) => setState(() {
            if (v == true) {
              if (!_selected.contains(p.id)) _selected.add(p.id);
            } else {
              _selected.remove(p.id);
            }
          }),
          activeColor: EmberColors.primary,
          controlAffinity: ListTileControlAffinity.trailing,
          secondary: AvatarBubble(
            dataUrl: p.avatar,
            fallback: p.name,
            radius: 16,
          ),
          title: Text(p.name),
          subtitle: p.tagline != null && p.tagline!.isNotEmpty
              ? Text(
                  p.tagline!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: EmberColors.textMid, fontSize: 12),
                )
              : null,
        );

    final rows = <Widget Function()>[];
    if (organized.favs.isNotEmpty) {
      rows.add(() => Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'FAVORITES',
              style: TextStyle(
                color: EmberColors.textDim,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ));
      for (final p in organized.favs) {
        rows.add(() => row(p));
      }
      if (organized.rest.isNotEmpty) rows.add(() => const SizedBox(height: 8));
    }
    for (final p in organized.rest) {
      rows.add(() => row(p));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Persona for this chat')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Pick one to play solo, or several for a persona party. '
              'Uncheck everything for no persona. Only affects this chat.',
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
                hintText: 'Search personas…',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: EmptyState(
                      icon: store.personas.where((p) => !p.deleted).isEmpty
                          ? Icons.face_outlined
                          : Icons.search_off,
                      title: store.personas.where((p) => !p.deleted).isEmpty
                          ? 'No personas yet'
                          : 'No matches',
                      subtitle: store.personas
                              .where((p) => !p.deleted)
                              .isEmpty
                          ? 'Create one from the Personas tab to play as a specific identity.'
                          : 'Nothing matches your search.',
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) => rows[i](),
                  ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      status,
                      style: TextStyle(
                        color: n > 1
                            ? EmberColors.primary
                            : EmberColors.textMid,
                        fontSize: 12,
                        fontWeight: n > 1 ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: EmberColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () =>
                        Navigator.pop(context, List<String>.from(_selected)),
                    child: const Text('Done'),
                  ),
                ],
              ),
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
          Padding(
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
                          'Create or import lorebooks from the Lorebooks '
                          'section of the Characters tab.',
                    ),
                  )
                : ListView.separated(
                    itemCount: available.length,
                    separatorBuilder: (_, _) => Divider(
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
                          style: TextStyle(
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
                          // H-2: attaching/detaching a per-chat lorebook edits
                          // chat sub-state that rides a chat sync, but a bare
                          // notifyAndPersist() never bumps chat.mtime — so the
                          // change saved locally but never propagated. Route
                          // through touchChat (mirrors the detach path in
                          // group_lorebooks_sheet.dart) so it reaches the
                          // paired device.
                          store.touchChat(chat);
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
