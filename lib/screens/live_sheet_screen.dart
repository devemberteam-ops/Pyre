// Wave CY.18.174 — Live Sheet editor screen.
//
// Per-chat screen that lets the user:
//   • Toggle the Live Sheet on/off for this chat.
//   • View and edit entity facts inline.
//   • Add / remove NPC entities.
//   • Run a manual LLM update or seed an individual entity from chat.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/live_sheet.dart' as lsheet;
import '../state/app_store.dart';
import '../theme.dart';
import 'live_sheet_settings_screen.dart';

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class LiveSheetScreen extends StatefulWidget {
  final String chatId;
  const LiveSheetScreen({super.key, required this.chatId});

  @override
  State<LiveSheetScreen> createState() => _LiveSheetScreenState();
}

class _LiveSheetScreenState extends State<LiveSheetScreen> {
  // Tracks which entity + section + fact index is currently being seeded or
  // updated so we can show per-entity spinners without a separate map.
  String? _seedingEntityId;
  bool _updating = false;

  // TextEditingControllers are managed per-fact: keyed by
  // "${entityId}/${section.name}/${factIndex}" and stored in a flat map.
  // They are created lazily in _controllerFor and disposed in dispose().
  final Map<String, TextEditingController> _controllers = {};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ─── helpers ──────────────────────────────────────────────────────────────

  Chat? _chat(AppStore store) {
    for (final c in store.chats) {
      if (c.id == widget.chatId) return c;
    }
    return null;
  }

  /// Inline copy of chat_screen.dart's private `_chatPersona`. Resolves the
  /// chat-specific persona, falling back to the global active persona.
  /// Returns null when the user has explicitly chosen "No persona".
  Persona? _chatPersona(AppStore store, Chat chat) {
    final pid = chat.personaId;
    if (pid == kExplicitNoPersonaId) return null;
    if (pid != null) {
      for (final p in store.personas) {
        if (p.id == pid) return p;
      }
    }
    return store.activePersona;
  }

  TextEditingController _controllerFor(
      String entityId, LiveSheetSection section, int index, String text) {
    final key = '$entityId/${section.name}/$index';
    return _controllers.putIfAbsent(key, () => TextEditingController(text: text));
  }

  /// Invalidates all controllers for an entity (used when its sections are
  /// fully replaced after a seed call).
  void _invalidateEntityControllers(String entityId) {
    final toRemove = _controllers.keys
        .where((k) => k.startsWith('$entityId/'))
        .toList();
    for (final k in toRemove) {
      _controllers.remove(k)?.dispose();
    }
  }

  /// Invalidates all controllers for a single entity+section (used after a
  /// fact is inserted or removed so index-keyed controllers are rebuilt fresh
  /// from the updated [_facts] list on the next build).
  void _invalidateSectionControllers(
      String entityId, LiveSheetSection section) {
    final prefix = '$entityId/${section.name}/';
    final toRemove =
        _controllers.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in toRemove) {
      _controllers.remove(k)?.dispose();
    }
  }

  // ─── options ──────────────────────────────────────────────────────────────
  //
  // Wave CY.18.202: the gear now navigates to the GLOBAL
  // LiveSheetSettingsScreen (single source of truth) instead of an
  // inline bottom sheet, so the same cadence knob lives in exactly one
  // place — also reachable from Chat Settings → Live Sheet.
  void _showOptions() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LiveSheetSettingsScreen()),
    );
  }

  // ─── snapshot bootstrap ───────────────────────────────────────────────────

  void _ensureSnapshot(AppStore store, Chat chat) {
    // C-3: delegate to the shared (idempotent) seeder so the screen and the
    // chat-creation path produce identical entities. Resolves the chat persona
    // + non-narrator characters; only touches the chat when a snapshot was
    // actually appended (so it still syncs).
    final persona = _chatPersona(store, chat);
    final characters = chat.characterIds
        .map((id) => chat.characterSnapshots[id] ?? store.characterById(id))
        .whereType<Character>();
    final seeded = lsheet.ensureLiveSheetSeed(
      chat: chat,
      personaName: persona?.name,
      characters: characters,
    );
    if (seeded) store.touchChat(chat); // F1: snapshot seed syncs
  }

  // ─── LLM actions ──────────────────────────────────────────────────────────

  Future<void> _runUpdate(AppStore store, Chat chat) async {
    final provider = store.activeProvider;
    if (provider == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set up a provider first.')),
      );
      return;
    }

    // Wave CY.18.245: branch on whether there are new messages since the
    // active snapshot's anchor. The common confusing case — enabling Live
    // Sheet mid-chat — anchors the snapshot at the latest message, so there
    // are no new messages to diff and generateLiveSheetUpdate would return
    // null ("No significant changes detected.") on a completely empty sheet.
    // When there's nothing new AND the sheet is empty, populate it from the
    // existing conversation instead.
    if (lsheet.liveSheetHasNewMessages(chat)) {
      setState(() => _updating = true);
      try {
        final snap = await lsheet.generateLiveSheetUpdate(
          chat: chat,
          provider: provider,
          settings: store.modelSettings,
          liveSheetSettings: store.liveSheetSettings,
        );
        if (!mounted) return;
        if (snap != null) {
          lsheet.appendLiveSheetSnapshot(chat, snap);
          store.touchChat(chat); // F1: snapshot update syncs
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No significant changes detected.')),
          );
        }
      } finally {
        if (mounted) setState(() => _updating = false);
      }
      return;
    }

    // No new messages since the anchor.
    final active = lsheet.activeLiveSheetSnapshot(chat);
    final empty =
        active == null || active.entities.every((e) => !e.hasAnyFact);
    if (!empty) {
      // Sheet already has facts — do NOT re-seed (would clobber existing or
      // locked facts). Just tell the user there's nothing to refresh.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Already up to date — no new messages since the last refresh.')),
      );
      return;
    }
    if (active == null) {
      // Edge guard: enabling always creates a snapshot, so this is unreachable
      // in practice. Fall back to the "no changes" toast rather than crash.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No significant changes detected.')),
      );
      return;
    }

    // Empty sheet, nothing new to diff → populate every entity from history.
    setState(() => _updating = true);
    try {
      await _seedAllEntities(store, chat, active);
      // The seed folds the WHOLE conversation into the snapshot's facts but
      // mutates the EXISTING snapshot in place — its anchor still points at
      // enable-time. Re-anchor to the latest message (matching the auto-update
      // path) so the next auto-update diffs forward instead of re-feeding the
      // history already folded into the seed (double-counting). Once, after
      // every entity is seeded.
      lsheet.reanchorSnapshotToLatest(chat, active);
      store.touchChat(chat); // F1: re-anchor + seeded facts sync
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Filled the sheet from the conversation.')),
      );
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  /// Wave CY.18.245: seed every entity of [active] from the conversation by
  /// reusing the per-entity seed path (which respects each entity's card
  /// description and REPLACES that entity's sections). Used by the empty-sheet
  /// branch of "Update state now". Iterates a copy of the list so concurrent
  /// mutation can't trip the loop. Each call manages its own per-entity
  /// spinner; the surrounding [_updating] flag drives the button spinner.
  Future<void> _seedAllEntities(
      AppStore store, Chat chat, LiveSheetSnapshot active) async {
    for (final entity in active.entities.toList()) {
      if (!mounted) return;
      await _seedEntity(store, chat, entity);
    }
  }

  Future<void> _seedEntity(
      AppStore store, Chat chat, LiveSheetEntity entity) async {
    final provider = store.activeProvider;
    if (provider == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set up a provider first.')),
      );
      return;
    }

    // Resolve card description for user/char kinds.
    String? cardDescription;
    if (entity.kind == LiveSheetEntityKind.user) {
      final persona = _chatPersona(store, chat);
      cardDescription = persona?.description;
    } else if (entity.kind == LiveSheetEntityKind.char) {
      // Find the character by name from the chat members.
      final match = chat.characterIds
          .map((id) => chat.characterSnapshots[id] ?? store.characterById(id))
          .whereType<Character>()
          .where((c) => c.name == entity.name)
          .firstOrNull;
      cardDescription = match?.description;
    }
    // NPC: null

    setState(() => _seedingEntityId = entity.id);
    try {
      final sections = await lsheet.seedLiveSheetEntity(
        chat: chat,
        entityName: entity.name,
        kind: entity.kind,
        cardDescription:
            (cardDescription?.trim().isNotEmpty == true) ? cardDescription : null,
        provider: provider,
        settings: store.modelSettings,
        liveSheetSettings: store.liveSheetSettings,
      );
      if (!mounted) return;
      if (sections != null) {
        _invalidateEntityControllers(entity.id);
        for (final s in LiveSheetSection.values) {
          entity.sections[s] = sections[s] ?? [];
        }
        store.touchChat(chat); // F1: seeded entity sections sync
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not generate sheet data.')),
        );
      }
    } finally {
      if (mounted) setState(() => _seedingEntityId = null);
    }
  }

  // ─── NPC dialog ───────────────────────────────────────────────────────────

  Future<void> _showAddNpcDialog(
      AppStore store, Chat chat, LiveSheetSnapshot active) async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgElevated,
        title: const Text('Add NPC'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'NPC name',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (name == null || name.isEmpty) return;
    if (!mounted) return;

    final entity = LiveSheetEntity(
      id: newId('lse'),
      name: name,
      kind: LiveSheetEntityKind.npc,
    );
    active.entities.add(entity);
    store.touchChat(chat); // F1: NPC entity add syncs

    // Offer to generate from chat.
    if (!mounted) return;
    final generate = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgElevated,
        title: Text('Generate "$name" from chat?'),
        content: const Text(
          'Ask the AI to fill in this NPC\'s current state '
          'based on the conversation so far?',
          style: TextStyle(color: EmberColors.textMid),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Generate'),
          ),
        ],
      ),
    );
    if (generate == true && mounted) {
      final storeNow = context.read<AppStore>();
      final chatNow = _chat(storeNow);
      if (chatNow != null) await _seedEntity(storeNow, chatNow, entity);
    }
  }

  // ─── remove entity ────────────────────────────────────────────────────────

  Future<void> _confirmRemoveEntity(AppStore store, Chat chat,
      LiveSheetSnapshot active, LiveSheetEntity entity) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgElevated,
        title: Text('Remove "${entity.name}"?'),
        content: const Text(
          'This entity and all its tracked facts will be removed '
          'from the Live Sheet.',
          style: TextStyle(color: EmberColors.textMid),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: EmberColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _invalidateEntityControllers(entity.id);
    active.entities.removeWhere((e) => e.id == entity.id);
    store.touchChat(chat); // F1: entity removal syncs
  }

  // ─── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chat = _chat(store);

    if (chat == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Live Sheet')),
        body: const Center(child: Text('Chat not found.')),
      );
    }

    final active = lsheet.activeLiveSheetSnapshot(chat);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Sheet'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Options',
            onPressed: _showOptions,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          // ── Enable toggle ────────────────────────────────────────────────
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: EmberColors.bgElevated,
            child: SwitchListTile(
              value: chat.liveSheetEnabled,
              onChanged: (v) {
                chat.liveSheetEnabled = v;
                if (v) _ensureSnapshot(store, chat);
                store.touchChat(chat); // F1: liveSheetEnabled toggle syncs
              },
              title: const Text('Live Sheet'),
              subtitle: const Text(
                'Track each character\'s current state as the story unfolds.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              activeThumbColor: EmberColors.primary,
            ),
          ),

          if (!chat.liveSheetEnabled) ...[
            // ── Disabled explainer ───────────────────────────────────────
            Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              color: EmberColors.bgElevated,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Icon(Icons.checklist_rtl,
                        size: 18, color: EmberColors.primary),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'When enabled, Pyre keeps a small live sheet that '
                        'tracks each character\'s appearance, clothing, '
                        'conditions, possessions, and notable facts as they '
                        'change throughout the conversation. The sheet is '
                        'injected into the model\'s context so it always '
                        'knows the current state of the world.',
                        style: TextStyle(
                            color: EmberColors.textMid,
                            fontSize: 12,
                            height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (active == null) ...[
            // ── Snapshot missing guard (shouldn't happen post-enable) ─────
            Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              color: EmberColors.bgElevated,
              child: ListTile(
                leading: const Icon(Icons.info_outline,
                    color: EmberColors.textMid),
                title: const Text('No active snapshot'),
                subtitle: const Text(
                  'Toggle the Live Sheet off and on again to create one.',
                  style: TextStyle(color: EmberColors.textMid, fontSize: 12),
                ),
              ),
            ),
          ] else ...[
            // ── Entity cards ─────────────────────────────────────────────
            for (final entity in active.entities)
              _EntityCard(
                entity: entity,
                isSeeding: _seedingEntityId == entity.id,
                controllerFor: _controllerFor,
                onInvalidateSection: _invalidateSectionControllers,
                onPersist: () => store.touchChat(chat), // F1: fact edits sync
                onRemoveEntity: () =>
                    _confirmRemoveEntity(store, chat, active, entity),
                onSeedFromChat: () => _seedEntity(store, chat, entity),
              ),

            // ── + NPC button ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.person_add_outlined),
                label: const Text('+ NPC'),
                onPressed: () => _showAddNpcDialog(store, chat, active),
              ),
            ),

            // ── Update state now ─────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                icon: _updating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.sync),
                label: const Text('Update state now'),
                onPressed: _updating ? null : () => _runUpdate(store, chat),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _EntityCard — one card per tracked entity
// ---------------------------------------------------------------------------

class _EntityCard extends StatelessWidget {
  final LiveSheetEntity entity;
  final bool isSeeding;
  final TextEditingController Function(
      String entityId, LiveSheetSection section, int index, String text)
      controllerFor;
  final void Function(String entityId, LiveSheetSection section) onInvalidateSection;
  final VoidCallback onPersist;
  final VoidCallback onRemoveEntity;
  final VoidCallback onSeedFromChat;

  const _EntityCard({
    required this.entity,
    required this.isSeeding,
    required this.controllerFor,
    required this.onInvalidateSection,
    required this.onPersist,
    required this.onRemoveEntity,
    required this.onSeedFromChat,
  });

  String get _entityLabel {
    final you = entity.kind == LiveSheetEntityKind.user ? ' (you)' : '';
    return '${entity.name}$you';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: EmberColors.bgElevated,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Entity header ──────────────────────────────────────────
            Row(
              children: [
                Icon(
                  entity.kind == LiveSheetEntityKind.user
                      ? Icons.person
                      : entity.kind == LiveSheetEntityKind.char
                          ? Icons.auto_stories_outlined
                          : Icons.people_outline,
                  size: 16,
                  color: EmberColors.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _entityLabel,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                ),
                // Generate from chat
                if (isSeeding)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Generate from chat',
                    icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                    onPressed: onSeedFromChat,
                    visualDensity: VisualDensity.compact,
                  ),
                // Remove entity
                IconButton(
                  tooltip: 'Remove entity',
                  icon: const Icon(Icons.remove_circle_outline,
                      size: 18, color: EmberColors.danger),
                  onPressed: onRemoveEntity,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const Divider(height: 12),

            // ── Sections ──────────────────────────────────────────────
            for (final section in LiveSheetSection.values)
              _SectionRows(
                entity: entity,
                section: section,
                controllerFor: controllerFor,
                onInvalidateSection: onInvalidateSection,
                onPersist: onPersist,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SectionRows — one section inside an entity card
// ---------------------------------------------------------------------------

class _SectionRows extends StatefulWidget {
  final LiveSheetEntity entity;
  final LiveSheetSection section;
  final TextEditingController Function(
      String entityId, LiveSheetSection section, int index, String text)
      controllerFor;
  final void Function(String entityId, LiveSheetSection section) onInvalidateSection;
  final VoidCallback onPersist;

  const _SectionRows({
    required this.entity,
    required this.section,
    required this.controllerFor,
    required this.onInvalidateSection,
    required this.onPersist,
  });

  @override
  State<_SectionRows> createState() => _SectionRowsState();
}

class _SectionRowsState extends State<_SectionRows> {
  // Focus node for the most-recently-added row so we can auto-focus it.
  FocusNode? _pendingFocus;

  @override
  void dispose() {
    _pendingFocus?.dispose();
    super.dispose();
  }

  List<LiveSheetFact> get _facts =>
      widget.entity.sections[widget.section]!;

  void _addFact() {
    // I1: dispose any previous pending focus before creating a new one.
    // I2: _pendingFocus is cleared in the post-frame callback after requestFocus.
    setState(() {
      _facts.add(LiveSheetFact(text: ''));
      _pendingFocus?.dispose();
      _pendingFocus = FocusNode();
    });
    // Focus happens on next frame after the row is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingFocus?.requestFocus();
      // I2: clear the reference so the node is no longer pinned to the last
      // row across subsequent rebuilds.
      setState(() => _pendingFocus = null);
    });
    widget.onPersist();
  }

  void _removeFact(int index) {
    // C1: mutate the model inside setState, then invalidate ALL controllers
    // for this section OUTSIDE setState so disposal never happens mid-frame.
    // This avoids index→fact desync when a middle row is removed: the next
    // build recreates every controller via controllerFor/putIfAbsent using
    // the now-shorter _facts list.
    setState(() => _facts.removeAt(index));
    widget.onInvalidateSection(widget.entity.id, widget.section);
    widget.onPersist();
  }

  void _onBlur(int index, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      // Drop empty facts on blur.
      _removeFact(index);
    } else {
      _facts[index].text = trimmed;
      widget.onPersist();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: Text(
            widget.section.label,
            style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5),
          ),
        ),
        for (var i = 0; i < _facts.length; i++)
          _FactRow(
            key: ValueKey('${widget.entity.id}/${widget.section.name}/$i'),
            fact: _facts[i],
            controller: widget.controllerFor(
                widget.entity.id, widget.section, i, _facts[i].text),
            focusNode: (i == _facts.length - 1 && _pendingFocus != null)
                ? _pendingFocus
                : null,
            onBlur: (text) => _onBlur(i, text),
            onToggleLock: () {
              setState(() => _facts[i].locked = !_facts[i].locked);
              widget.onPersist();
            },
            onDelete: () => _removeFact(i),
          ),
        TextButton.icon(
          icon: const Icon(Icons.add, size: 14),
          label: const Text('add fact'),
          style: TextButton.styleFrom(
            foregroundColor: EmberColors.textMid,
            textStyle: const TextStyle(fontSize: 12),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: _addFact,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _FactRow — a single editable fact with lock + delete
// ---------------------------------------------------------------------------

class _FactRow extends StatelessWidget {
  final LiveSheetFact fact;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final void Function(String text) onBlur;
  final VoidCallback onToggleLock;
  final VoidCallback onDelete;

  const _FactRow({
    super.key,
    required this.fact,
    required this.controller,
    this.focusNode,
    required this.onBlur,
    required this.onToggleLock,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Focus(
            onFocusChange: (hasFocus) {
              if (!hasFocus) onBlur(controller.text);
            },
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
            ),
          ),
        ),
        // Lock toggle
        IconButton(
          tooltip: fact.locked ? 'Unlock fact' : 'Lock fact',
          icon: Icon(
            fact.locked ? Icons.lock : Icons.lock_open_outlined,
            size: 16,
            color: fact.locked ? EmberColors.primary : EmberColors.textMid,
          ),
          onPressed: onToggleLock,
          visualDensity: VisualDensity.compact,
        ),
        // Delete
        IconButton(
          tooltip: 'Delete fact',
          icon: const Icon(Icons.close, size: 16, color: EmberColors.textMid),
          onPressed: onDelete,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

// Wave CY.18.202: the inline _LiveSheetOptionsSheet was removed — the
// gear now opens the shared global LiveSheetSettingsScreen so there is a
// single source of truth for the cadence knob.
