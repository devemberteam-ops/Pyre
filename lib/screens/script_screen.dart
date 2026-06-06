// Wave CY.18.187 — Script editor screen (renamed from Roteiro / story_roadmap_screen.dart).
//
// Lets the user plant future plot beats, edit them inline, mark them as done,
// and re-activate or delete them. Active beats are injected into the model
// context (built by story_roadmap.dart) so the AI builds toward them gradually.
//
// Controller lifecycle mirrors live_sheet_screen.dart:
//   - Controllers are keyed by beat.id (stable ID, never by list index).
//   - Created lazily in _controllerFor / putIfAbsent.
//   - Disposed and removed OUTSIDE setState before mutation (no frame-disposal).
//   - All controllers disposed in dispose().

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/story_roadmap.dart' as roadmap;
import '../state/app_store.dart';
import '../theme.dart';
import 'script_settings_screen.dart';

class ScriptScreen extends StatefulWidget {
  final String chatId;
  const ScriptScreen({super.key, required this.chatId});

  @override
  State<ScriptScreen> createState() => _ScriptScreenState();
}

class _ScriptScreenState extends State<ScriptScreen> {
  /// Controllers for active-beat rows, keyed by beat.id.
  final Map<String, TextEditingController> _controllers = {};

  /// Controller for the multiline "Add beats" input box.
  final TextEditingController _addCtl = TextEditingController();

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _addCtl.dispose();
    super.dispose();
  }

  // ─── helpers ────────────────────────────────────────────────────────────────

  Chat? _chat(AppStore store) {
    for (final c in store.chats) {
      if (c.id == widget.chatId) return c;
    }
    return null;
  }

  /// Returns (creating lazily) a controller for an active beat row.
  TextEditingController _controllerFor(StoryBeat beat) {
    return _controllers.putIfAbsent(
      beat.id,
      () => TextEditingController(text: beat.text),
    );
  }

  /// Disposes and removes the controller for a single beat, outside setState.
  void _disposeController(String beatId) {
    _controllers.remove(beatId)?.dispose();
  }

  // ─── actions ────────────────────────────────────────────────────────────────

  /// Called on every text change in an active-beat row.
  void _onBeatChanged(StoryBeat beat, String value) {
    // Keep the model in-memory current while typing (cheap — no disk write, no
    // rebuild). Persistence happens on blur (_onBeatBlur). This mirrors the Live
    // Sheet editor, which never persists per-keystroke.
    beat.text = value;
  }

  /// Called when an active-beat row loses focus: trims or drops empty beats.
  void _onBeatBlur(AppStore store, Chat chat, StoryBeat beat, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      // Drop the empty beat. Dispose controller OUTSIDE setState first.
      _disposeController(beat.id);
      setState(() {
        chat.storyBeats.removeWhere((b) => b.id == beat.id);
      });
    } else {
      beat.text = trimmed;
      // Sync the controller text so it shows the trimmed value.
      _controllers[beat.id]?.text = trimmed;
      _controllers[beat.id]?.selection =
          TextSelection.collapsed(offset: trimmed.length);
    }
    store.touchChat(chat); // F1: beat edit/remove syncs
  }

  void _markDone(AppStore store, Chat chat, StoryBeat beat) {
    // Flush any in-flight typed-but-not-blurred edit before disposing the
    // controller, so the Completed row shows the latest text (belt-and-suspenders
    // on top of _onBeatChanged keeping beat.text current per-keystroke).
    final ctl = _controllers[beat.id];
    if (ctl != null) {
      final trimmed = ctl.text.trim();
      if (trimmed.isNotEmpty) beat.text = trimmed;
    }
    // Dispose controller OUTSIDE setState.
    _disposeController(beat.id);
    setState(() {
      beat.done = true;
    });
    store.touchChat(chat); // F1: beat done toggle syncs
  }

  void _reactivate(AppStore store, Chat chat, StoryBeat beat) {
    setState(() {
      beat.done = false;
    });
    // Controller will be created lazily on next build via _controllerFor.
    store.touchChat(chat); // F1: beat reactivate syncs
  }

  void _deleteBeat(AppStore store, Chat chat, StoryBeat beat) {
    // Dispose controller OUTSIDE setState.
    _disposeController(beat.id);
    setState(() {
      chat.storyBeats.removeWhere((b) => b.id == beat.id);
    });
    store.touchChat(chat); // F1: beat delete syncs
  }

  // ─── options ─────────────────────────────────────────────────────────────
  //
  // Wave CY.18.202: the gear now navigates to the GLOBAL
  // ScriptSettingsScreen (single source of truth) instead of an inline
  // bottom sheet, so the beats-cap knob lives in exactly one place —
  // also reachable from Chat Settings → Script.
  void _showOptions() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ScriptSettingsScreen()),
    );
  }

  void _addBeats(AppStore store, Chat chat) {
    final raw = _addCtl.text;
    if (raw.trim().isEmpty) return;
    bool added = false;
    for (final line in raw.split('\n')) {
      if (roadmap.appendStoryBeat(chat, line) != null) added = true;
    }
    if (added) {
      _addCtl.clear();
      store.touchChat(chat); // F1: beat add syncs
    }
  }

  // ─── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chat = _chat(store);

    if (chat == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Script')),
        body: const Center(child: Text('Chat not found.')),
      );
    }

    final activeBeats = chat.storyBeats.where((b) => !b.done).toList();
    final doneBeats = chat.storyBeats.where((b) => b.done).toList();
    final hasAny = chat.storyBeats.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Script'),
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
          // ── Help card ───────────────────────────────────────────────────────
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: EmberColors.bgElevated,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Icon(Icons.map_outlined, size: 18, color: EmberColors.primary),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Write future plot directions (one per line). '
                      'The AI builds toward them gradually and respects '
                      'conditions like "when arriving at X". Mark completed '
                      'beats as done (or revisit them later).',
                      style: TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Empty state ─────────────────────────────────────────────────────
          if (!hasAny)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  'No directions yet — write one below.',
                  style: const TextStyle(
                    color: EmberColors.textDim,
                    fontSize: 13,
                  ),
                ),
              ),
            ),

          // ── Active beats ─────────────────────────────────────────────────
          if (activeBeats.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
              child: const Text(
                'ACTIVE',
                style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            for (final beat in activeBeats)
              _ActiveBeatRow(
                key: ValueKey(beat.id),
                beat: beat,
                controller: _controllerFor(beat),
                onChanged: (v) => _onBeatChanged(beat, v),
                onBlur: (v) => _onBeatBlur(store, chat, beat, v),
                onMarkDone: () => _markDone(store, chat, beat),
                onDelete: () => _deleteBeat(store, chat, beat),
              ),
          ],

          // ── Add beats box ───────────────────────────────────────────────────
          Card(
            margin: const EdgeInsets.only(top: 16, bottom: 4),
            color: EmberColors.bgElevated,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _addCtl,
                    minLines: 2,
                    maxLines: 8,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'One direction per line…',
                      hintStyle: TextStyle(color: EmberColors.textDim),
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add'),
                      onPressed: () => _addBeats(store, chat),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Done beats ──────────────────────────────────────────────────────
          if (doneBeats.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 20, bottom: 4, left: 4),
              child: const Text(
                'COMPLETED',
                style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            for (final beat in doneBeats)
              _DoneBeatRow(
                key: ValueKey('done_${beat.id}'),
                beat: beat,
                onReactivate: () => _reactivate(store, chat, beat),
                onDelete: () => _deleteBeat(store, chat, beat),
              ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ActiveBeatRow — an editable row for a non-done beat
// ─────────────────────────────────────────────────────────────────────────────

class _ActiveBeatRow extends StatelessWidget {
  final StoryBeat beat;
  final TextEditingController controller;
  final void Function(String) onChanged;
  final void Function(String) onBlur;
  final VoidCallback onMarkDone;
  final VoidCallback onDelete;

  const _ActiveBeatRow({
    super.key,
    required this.beat,
    required this.controller,
    required this.onChanged,
    required this.onBlur,
    required this.onMarkDone,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Focus(
              onFocusChange: (hasFocus) {
                if (!hasFocus) onBlur(controller.text);
              },
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                ),
                onChanged: onChanged,
              ),
            ),
          ),
          // Mark done
          IconButton(
            tooltip: 'Mark as done',
            icon: const Icon(Icons.check_circle_outline,
                size: 20, color: EmberColors.primary),
            onPressed: onMarkDone,
            visualDensity: VisualDensity.compact,
          ),
          // Delete
          IconButton(
            tooltip: 'Remove beat',
            icon: const Icon(Icons.close,
                size: 18, color: EmberColors.textMid),
            onPressed: onDelete,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DoneBeatRow — read-only strikethrough row for a done beat
// ─────────────────────────────────────────────────────────────────────────────

class _DoneBeatRow extends StatelessWidget {
  final StoryBeat beat;
  final VoidCallback onReactivate;
  final VoidCallback onDelete;

  const _DoneBeatRow({
    super.key,
    required this.beat,
    required this.onReactivate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              beat.text,
              style: const TextStyle(
                fontSize: 13,
                decoration: TextDecoration.lineThrough,
                decorationColor: EmberColors.textDim,
                color: EmberColors.textDim,
              ),
            ),
          ),
          // Reactivate
          IconButton(
            tooltip: 'Reactivate beat',
            icon: const Icon(Icons.undo,
                size: 18, color: EmberColors.textMid),
            onPressed: onReactivate,
            visualDensity: VisualDensity.compact,
          ),
          // Delete
          IconButton(
            tooltip: 'Remove beat',
            icon: const Icon(Icons.close,
                size: 18, color: EmberColors.textMid),
            onPressed: onDelete,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// Wave CY.18.202: the inline _ScriptOptionsSheet was removed — the gear
// now opens the shared global ScriptSettingsScreen so there is a single
// source of truth for the beats-cap knob.
