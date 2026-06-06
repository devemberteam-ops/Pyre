// Wave CY.18: full-screen long-term memory inspector & control.
//
// Replaces the cramped bottom-sheet from earlier waves. Each chat's
// memory is now a CHAIN of branch-aware [MemoryCheckpoint]s instead of
// a single overwriteable string, so the screen renders one card per
// checkpoint with per-checkpoint Retry / Delete actions plus a global
// "Summarise now" button at the bottom.
//
// The screen filters checkpoints to only those VALID for the current
// branch — orphaned checkpoints from other branches (the user navigated
// back via the chat-tree to a divergence point) are hidden but stay on
// disk, so re-visiting the original branch restores its full memory.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/memory.dart' as ltm;
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';

class MemoryScreen extends StatefulWidget {
  final String chatId;
  const MemoryScreen({super.key, required this.chatId});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  bool _summarising = false;
  final Set<String> _retrying = <String>{};

  /// Wave CY.18.24: single in-flight lock shared by Summarise-now AND
  /// per-checkpoint Retry. Spam-clicking both used to fire two parallel
  /// LLM calls that raced applyCheckpoint/replaceCheckpoint and
  /// produced duplicate anchors. `_summarising` and `_retrying` are
  /// kept separately for the per-button spinner UI, but no mutation
  /// proceeds while ANY of them is in flight.
  bool get _anyMemoryWorkInFlight =>
      _summarising || _retrying.isNotEmpty;

  Chat? _liveChat(AppStore store) {
    for (final c in store.chats) {
      if (c.id == widget.chatId) return c;
    }
    return null;
  }

  Future<void> _runManualSummarise() async {
    if (_anyMemoryWorkInFlight) {
      _toast('Another memory operation is already running — wait for it '
          'to finish before starting another.');
      return;
    }
    final store = context.read<AppStore>();
    final chat = _liveChat(store);
    if (chat == null) return;
    final provider = store.activeProvider;
    if (provider == null) {
      _toast('No active API provider — set one up in More → API.');
      return;
    }
    setState(() => _summarising = true);
    final ckpt = await ltm.generateCheckpoint(
      chat: chat,
      provider: provider,
      settings: store.modelSettings,
      memorySettings: store.memorySettings,
    );
    if (!mounted) return;
    setState(() => _summarising = false);
    if (ckpt == null) {
      _toast('Couldn\'t summarise — provider error or chat too short.');
      return;
    }
    // Wave CY.18.24: respect memoryEnabled flipped to false
    // mid-flight. The toggle could happen while the LLM call was
    // running; persisting an unwanted checkpoint anyway is wasted
    // work that the user explicitly opted out of.
    if (!chat.memoryEnabled) {
      _toast('Memory was disabled while summarising — checkpoint '
          'discarded.');
      return;
    }
    ltm.applyCheckpoint(chat, ckpt);
    store.touchChat(chat); // F1: checkpoint add syncs
    setState(() {});
  }

  Future<bool> _retryCheckpoint(MemoryCheckpoint target) async {
    if (_anyMemoryWorkInFlight) {
      _toast('Another memory operation is already running — wait for it '
          'to finish before starting another.');
      return false;
    }
    final store = context.read<AppStore>();
    final chat = _liveChat(store);
    if (chat == null) return false;
    final provider = store.activeProvider;
    if (provider == null) {
      _toast('No active API provider — set one up in More → API.');
      return false;
    }
    // Wave CY.18.24: clarify the failure mode when the checkpoint is
    // not on the current branch anymore (regenerate refuses to act
    // on stale data). Pre-Wave the user saw "provider error" which
    // pointed them at the API.
    final stillValid = ltm
        .findValidCheckpoints(chat)
        .any((c) => c.id == target.id);
    if (!stillValid) {
      _toast('This checkpoint isn\'t on the current branch — go back '
          'to the branch it belongs to via the chat tree, or delete '
          'it from here.');
      return false;
    }
    setState(() => _retrying.add(target.id));
    final replacement = await ltm.regenerateCheckpoint(
      chat: chat,
      target: target,
      provider: provider,
      settings: store.modelSettings,
      memorySettings: store.memorySettings,
    );
    if (!mounted) return false;
    setState(() => _retrying.remove(target.id));
    if (replacement == null) {
      _toast('Couldn\'t regenerate — provider error.');
      return false;
    }
    ltm.replaceCheckpoint(chat, replacement);
    store.touchChat(chat); // F1: checkpoint retry syncs
    setState(() {});
    return true;
  }

  /// Wave CY.18.3: open a roomy editor dialog for [target]'s summary
  /// text so the user can fix small mistakes (typos, a misplaced
  /// comma, a missing detail) without burning a full regeneration.
  /// Preserves id / anchor / pathHash so chain validity is unchanged.
  Future<bool> _editCheckpoint(MemoryCheckpoint target) async {
    final store = context.read<AppStore>();
    final chat = _liveChat(store);
    if (chat == null) return false;
    final ctl = TextEditingController(text: target.summary);
    final result = await showDialog<String?>(
      context: context,
      builder: (d) {
        return Dialog(
          backgroundColor: EmberColors.bgPanel,
          insetPadding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 32),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(d).size.height * 0.85,
              maxWidth: 720,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.edit_outlined,
                          size: 18, color: EmberColors.primary),
                      SizedBox(width: 8),
                      Text(
                        'Edit checkpoint',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Fix typos or small mistakes without regenerating. '
                    'Anchor and branch validity stay the same.',
                    style: TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 12,
                        height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: TextField(
                      controller: ctl,
                      autofocus: true,
                      maxLines: null,
                      expands: true,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontSize: 13, height: 1.45),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(d, ctl.text),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: EmberColors.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    ctl.dispose();
    if (!mounted || result == null) return false;
    final trimmed = result.trim();
    if (trimmed.isEmpty) {
      _toast('Checkpoint can\'t be empty — use Delete if you want to drop it.');
      return false;
    }
    if (trimmed == target.summary.trim()) return false; // no-op
    ltm.replaceCheckpoint(
      chat,
      MemoryCheckpoint(
        id: target.id,
        summary: trimmed,
        anchorMessageIdx: target.anchorMessageIdx,
        pathHash: target.pathHash,
        createdAt: target.createdAt,
      ),
    );
    store.touchChat(chat); // F1: checkpoint edit syncs
    setState(() {});
    return true;
  }

  Future<bool> _deleteCheckpoint(MemoryCheckpoint target) async {
    final store = context.read<AppStore>();
    final chat = _liveChat(store);
    if (chat == null) return false;
    final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            backgroundColor: EmberColors.bgPanel,
            title: const Text('Delete checkpoint?'),
            content: const Text(
              'This summary will be removed from the chain. The next '
              'auto-summarisation will re-summarise the same range from '
              'scratch.',
              style: TextStyle(color: EmberColors.textMid),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(d, true),
                style:
                    TextButton.styleFrom(foregroundColor: EmberColors.danger),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return false;
    ltm.deleteCheckpoint(chat, target.id);
    store.touchChat(chat); // F1: checkpoint delete syncs
    setState(() {});
    return true;
  }

  Future<void> _wipeAll() async {
    final store = context.read<AppStore>();
    final chat = _liveChat(store);
    if (chat == null) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            backgroundColor: EmberColors.bgPanel,
            title: const Text('Wipe all checkpoints?'),
            content: const Text(
              'Every checkpoint on every branch of this chat will be '
              'erased. The model will lose its recap until you '
              're-summarise.',
              style: TextStyle(color: EmberColors.textMid),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(d, true),
                style:
                    TextButton.styleFrom(foregroundColor: EmberColors.danger),
                child: const Text('Wipe'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    ltm.wipeAllCheckpoints(chat);
    store.touchChat(chat); // F1: wipe-all syncs
    setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _anchorLabel(Chat chat, MemoryCheckpoint c) {
    // Wave CY.18.24: guard against an empty message list — `length - 1`
    // is -1 and `clamp(0, -1)` returns -1 → label says "through
    // message 0" which is nonsense. Bail to a neutral phrase.
    if (chat.messages.isEmpty) return 'before any message';
    if (c.anchorMessageIdx < 0) return 'before message 1';
    final idx = c.anchorMessageIdx.clamp(0, chat.messages.length - 1);
    return 'through message ${idx + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chat = _liveChat(store);
    if (chat == null) {
      return const Scaffold(
        body: Center(child: Text('Chat not found.')),
      );
    }
    final valid = ltm.findValidCheckpoints(chat);
    final orphanedCount = chat.memoryCheckpoints.length - valid.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Checkpoints'),
        actions: [
          if (chat.memoryCheckpoints.isNotEmpty)
            IconButton(
              tooltip: 'Wipe all',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _wipeAll,
            ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Branch-aware checkpoints — each one summarises a chunk '
              'of the conversation and gets fed back into the model so '
              'it remembers past the rolling window. Re-rolling old '
              'messages branches the chat, and checkpoints stay tied to '
              'the branch where they were taken.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Auto-summariser'),
            subtitle: const Text(
              'Off = no auto-checkpoints fire and existing ones are not '
              'fed to the model. "Summarise now" still works.',
              style: TextStyle(
                  color: EmberColors.textMid, fontSize: 11, height: 1.4),
            ),
            value: chat.memoryEnabled,
            activeThumbColor: EmberColors.primary,
            onChanged: (v) {
              chat.memoryEnabled = v;
              store.touchChat(chat); // F1: memoryEnabled toggle syncs
              setState(() {});
            },
          ),
          const Divider(color: EmberColors.stroke, height: 1),
          // Wave CY.18.24: surface the cap-N notice when the chain
          // is longer than `kMaxCheckpointsInPrompt`. The runtime
          // injects only the most recent N at chat-time, so older
          // checkpoints stop influencing the model — without UI
          // feedback the user can't tell why narrative continuity
          // appears to start in the middle of the story.
          if (valid.length > ltm.kMaxCheckpointsInPrompt)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.fromLTRB(16, 8, 16, 8),
              color: EmberColors.primary.withValues(alpha: 0.10),
              child: Text(
                'Only the ${ltm.kMaxCheckpointsInPrompt} most recent '
                'checkpoints are fed to the model on each turn — the '
                '${valid.length - ltm.kMaxCheckpointsInPrompt} older '
                'one${valid.length - ltm.kMaxCheckpointsInPrompt == 1 ? "" : "s"} '
                'still appear here but no longer shape the recap. '
                'Consider editing or deleting old ones if the story has '
                'moved past them.',
                style: const TextStyle(
                    color: EmberColors.primary,
                    fontSize: 11,
                    height: 1.4),
              ),
            ),
          Expanded(
            child: valid.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: EmptyState(
                      icon: Icons.psychology_outlined,
                      title: 'No checkpoints yet',
                      subtitle: orphanedCount > 0
                          ? 'No checkpoints exist on this branch. '
                              '$orphanedCount checkpoint${orphanedCount == 1 ? "" : "s"} '
                              'from other branches stay on disk and will '
                              'reappear if you navigate back to them via '
                              'the chat tree.'
                          : 'The auto-summariser writes a new checkpoint '
                              'every 20 or so messages. You can also tap '
                              '"Summarise now" below to force one.',
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: valid.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final c = valid[i];
                      final retrying = _retrying.contains(c.id);
                      return _CheckpointCard(
                        index: i + 1,
                        total: valid.length,
                        checkpoint: c,
                        anchorLabel: _anchorLabel(chat, c),
                        retrying: retrying,
                        onOpen: () {
                          Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _CheckpointDetailScreen(
                              chatId: widget.chatId,
                              checkpointId: c.id,
                              index: i + 1,
                              total: valid.length,
                              anchorLabel: _anchorLabel(chat, c),
                              onRetry: _retryCheckpoint,
                              onEdit: _editCheckpoint,
                              onDelete: _deleteCheckpoint,
                            ),
                          ));
                        },
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: _summarising
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add, size: 18),
                  label: Text(
                    _summarising ? 'Summarising…' : 'Summarise now',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: EmberColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _summarising ? null : _runManualSummarise,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wave CY.18.9: compact 4-line preview. Tap opens
/// [_CheckpointDetailScreen] for the full text + retry / edit /
/// delete controls — keeping the list scannable for chats with many
/// checkpoints instead of letting one entry dominate the screen.
class _CheckpointCard extends StatelessWidget {
  final int index;
  final int total;
  final MemoryCheckpoint checkpoint;
  final String anchorLabel;
  final bool retrying;
  final VoidCallback onOpen;

  const _CheckpointCard({
    required this.index,
    required this.total,
    required this.checkpoint,
    required this.anchorLabel,
    required this.retrying,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EmberColors.bgElevated,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: EmberColors.stroke, width: 1),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.psychology_outlined,
                      size: 16, color: EmberColors.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Checkpoint $index of $total',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  if (retrying)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      anchorLabel,
                      style: const TextStyle(
                          color: EmberColors.textMid, fontSize: 11),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                checkpoint.summary,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: EmberColors.textHigh,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 4),
              const Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'Tap to read · edit · retry',
                  style: TextStyle(
                      color: EmberColors.textDim, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wave CY.18.9: full-screen view of a single checkpoint. Scrollable
/// for long recaps, with the per-checkpoint action bar (Retry / Edit
/// / Delete) at the bottom. Pop returns to the list; mutations
/// happen in-place on the underlying chat (the parent [MemoryScreen]
/// will re-fetch from the store on its next build).
class _CheckpointDetailScreen extends StatefulWidget {
  final String chatId;
  final String checkpointId;
  final int index;
  final int total;
  final String anchorLabel;
  final Future<bool> Function(MemoryCheckpoint) onRetry;
  final Future<bool> Function(MemoryCheckpoint) onEdit;
  final Future<bool> Function(MemoryCheckpoint) onDelete;

  const _CheckpointDetailScreen({
    required this.chatId,
    required this.checkpointId,
    required this.index,
    required this.total,
    required this.anchorLabel,
    required this.onRetry,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_CheckpointDetailScreen> createState() =>
      _CheckpointDetailScreenState();
}

class _CheckpointDetailScreenState extends State<_CheckpointDetailScreen> {
  bool _retrying = false;

  MemoryCheckpoint? _resolve(AppStore store) {
    Chat? chat;
    for (final c in store.chats) {
      if (c.id == widget.chatId) {
        chat = c;
        break;
      }
    }
    if (chat == null) return null;
    for (final c in chat.memoryCheckpoints) {
      if (c.id == widget.checkpointId) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final ckpt = _resolve(store);
    if (ckpt == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Checkpoint')),
        body: const Center(child: Text('Checkpoint no longer exists.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('Checkpoint ${widget.index} of ${widget.total}'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.psychology_outlined,
                    size: 14, color: EmberColors.primary),
                const SizedBox(width: 6),
                Text(
                  widget.anchorLabel,
                  style: const TextStyle(
                      color: EmberColors.textMid, fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SelectableText(
                ckpt.summary,
                style: const TextStyle(
                  color: EmberColors.textHigh,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _retrying
                          ? null
                          : () async {
                              setState(() => _retrying = true);
                              await widget.onRetry(ckpt);
                              if (mounted) {
                                setState(() => _retrying = false);
                              }
                            },
                      icon: _retrying
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.refresh, size: 16),
                      label: Text(_retrying ? 'Retrying…' : 'Retry'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: EmberColors.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => widget.onEdit(ckpt),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: EmberColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Builder(
                      builder: (btnCtx) => OutlinedButton.icon(
                        onPressed: () async {
                          final removed = await widget.onDelete(ckpt);
                          if (!removed) return;
                          if (!btnCtx.mounted) return;
                          Navigator.of(btnCtx).pop();
                        },
                        icon: const Icon(Icons.delete_outline, size: 16),
                        label: const Text('Delete'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: EmberColors.danger,
                        ),
                      ),
                    ),
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
