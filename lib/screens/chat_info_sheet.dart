// Chat info sheet — shows the token-budget breakdown by source.
//
// Wave CM. Lets the user see at a glance which part of the context is
// eating their budget (preset prompts vs character descriptions vs
// lorebooks vs message history). Pure read-only, no actions.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/live_sheet.dart' as lsheet;
import '../services/lorebook_inject.dart';
import '../services/memory.dart' as ltm;
import '../services/model_metadata.dart';
import '../services/story_roadmap.dart' as roadmap;
import '../services/token_estimate.dart';
import '../state/app_store.dart';
import '../theme.dart';

class ChatInfoSheet extends StatefulWidget {
  final String chatId;
  const ChatInfoSheet({super.key, required this.chatId});

  @override
  State<ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends State<ChatInfoSheet> {
  // Wave CY.13: Characters row drills down into per-character costs.
  // Off by default — most chats have one char and the breakdown is
  // identical to the total, so opening it by default adds noise.
  bool _charsExpanded = false;

  // Wave CY.18.100: memoize the context-window lookup so FutureBuilder
  // doesn't refire a network request on every rebuild. Keyed by
  // provider id + model + manual override, so it refreshes only when
  // one of those actually changes.
  String? _ctxKey;
  Future<int?>? _ctxFuture;

  Future<int?> _contextWindowFuture(ApiProvider? p) {
    if (p == null) return Future<int?>.value(null);
    final key = '${p.id}|${p.model}|${p.contextWindow}';
    if (key != _ctxKey) {
      _ctxKey = key;
      _ctxFuture = fetchContextWindow(p);
    }
    return _ctxFuture!;
  }

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
    if (chat == null) return const SizedBox.shrink();
    final breakdown = _buildBreakdown(store, chat);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(
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
              'Chat info',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Approximate token weight of every component sent to the '
              'model on the next turn. Counts use the chars/4 heuristic '
              '(close enough for the "is this big or small" question).',
              style: const TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 12,
                  height: 1.4),
            ),
            const SizedBox(height: 16),
            // Total at the top — biggest number, most visible.
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: EmberColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: EmberColors.primary.withValues(alpha: 0.40),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.toll,
                      color: EmberColors.primary, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Total context',
                      style: TextStyle(
                          color: EmberColors.textHigh,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    formatTokenCount(breakdown.total) ?? '~0 tokens',
                    style: const TextStyle(
                      color: EmberColors.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            // Wave CY.18.100: context-window usage. Auto-detected from
            // the active provider's /models (manual override wins), with
            // a fill bar that warms toward red as you approach the cap.
            const SizedBox(height: 10),
            FutureBuilder<int?>(
              future: _contextWindowFuture(store.activeProvider),
              builder: (ctx, snap) => _ContextWindowRow(
                loading: snap.connectionState == ConnectionState.waiting,
                window: snap.data,
                used: breakdown.total,
              ),
            ),
            const SizedBox(height: 12),
            ..._row(
                'Preset',
                'mainPrompt + post-history',
                breakdown.preset,
                breakdown.total,
                Icons.tune),
            // Wave CY.13: per-character drilldown — tap to expand and
            // see each char's individual token weight. Useful in
            // group chats where one heavy bot can dominate the cost.
            ..._charactersRow(breakdown),
            ..._row(
                'Persona',
                breakdown.personaName ?? '(no persona)',
                breakdown.persona,
                breakdown.total,
                Icons.face),
            ..._row(
                breakdown.lorebookNames.length > 1
                    ? 'Lorebooks (${breakdown.lorebookNames.length})'
                    : 'Lorebooks',
                breakdown.lorebookNames.isEmpty
                    ? '(none active)'
                    : breakdown.lorebookNames.join(', '),
                breakdown.lorebooks,
                breakdown.total,
                Icons.menu_book_outlined),
            // Wave CY.18.190: Live Sheet — only when enabled + non-empty.
            if (breakdown.liveSheet > 0)
              ..._row(
                  'Live Sheet',
                  'active state snapshot',
                  breakdown.liveSheet,
                  breakdown.total,
                  Icons.track_changes_outlined),
            // Wave CY.18.190: Script — only when there are active beats.
            if (breakdown.script > 0)
              ..._row(
                  'Script',
                  'story beats roadmap',
                  breakdown.script,
                  breakdown.total,
                  Icons.auto_stories_outlined),
            ..._row(
                'Memory summary',
                breakdown.memoryNote,
                breakdown.memory,
                breakdown.total,
                Icons.psychology),
            ..._row(
                'Messages',
                '${breakdown.messageCount} kept in window',
                breakdown.messages,
                breakdown.total,
                Icons.chat_bubble_outline),
          ],
        ),
      ),
    );
  }

  /// Wave CM: build a single breakdown row — icon + label + subtitle +
  /// token count + tiny proportion bar. Returns a `List<Widget>` so
  /// the spread-operator call site can drop in a row + spacer in one
  /// shot.
  List<Widget> _row(String title, String subtitle, int tokens, int total,
      IconData icon) {
    final pct = total == 0 ? 0.0 : (tokens / total).clamp(0.0, 1.0);
    final tokenLabel = formatTokenCount(tokens) ?? '~0 tokens';
    return [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: EmberColors.textMid),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style:
                          const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: EmberColors.textMid, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  tokenLabel,
                  style: const TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  width: 64,
                  height: 4,
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: EmberColors.stroke,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: pct,
                        child: Container(
                          decoration: BoxDecoration(
                            color: EmberColors.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// Wave CY.13: expandable Characters row. The header looks like the
  /// regular [_row] (icon + total + tiny chevron) but when tapped it
  /// expands to show every char in the chat with their individual
  /// token cost. Drilldown only — switching members happens in
  /// Customize chat. Header tap is no-op when there's only one char
  /// (the drilldown adds nothing).
  List<Widget> _charactersRow(_ChatBreakdown breakdown) {
    final names = breakdown.characterNames;
    final hasMany = names.length > 1;
    final headerTitle = hasMany ? 'Characters (${names.length})' : 'Character';
    final headerSubtitle = names.join(', ');
    final pct = breakdown.total == 0
        ? 0.0
        : (breakdown.characters / breakdown.total).clamp(0.0, 1.0);
    final tokenLabel =
        formatTokenCount(breakdown.characters) ?? '~0 tokens';
    final canExpand = breakdown.characterBreakdown.length > 1;
    final header = InkWell(
      onTap: canExpand
          ? () => setState(() => _charsExpanded = !_charsExpanded)
          : null,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.person,
                size: 16, color: EmberColors.textMid),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(headerTitle,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                    if (canExpand) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _charsExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 16,
                        color: EmberColors.textMid,
                      ),
                    ],
                  ]),
                  Text(
                    headerSubtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: EmberColors.textMid, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  tokenLabel,
                  style: const TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  width: 64,
                  height: 4,
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: EmberColors.stroke,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: pct,
                        child: Container(
                          decoration: BoxDecoration(
                            color: EmberColors.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final children = <Widget>[header];
    if (canExpand && _charsExpanded) {
      for (final entry in breakdown.characterBreakdown) {
        final entryPct = breakdown.characters == 0
            ? 0.0
            : (entry.value / breakdown.characters).clamp(0.0, 1.0);
        final entryLabel = formatTokenCount(entry.value) ?? '~0 tokens';
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(34, 2, 0, 6),
          child: Row(
            children: [
              const Icon(Icons.arrow_right,
                  size: 14, color: EmberColors.textMid),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  entry.key,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: EmberColors.textMid, fontSize: 12),
                ),
              ),
              Text(
                entryLabel,
                style: const TextStyle(
                  color: EmberColors.textHigh,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 48,
                height: 3,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: EmberColors.stroke,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: entryPct,
                      child: Container(
                        decoration: BoxDecoration(
                          color: EmberColors.primary
                              .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ));
      }
    }
    return children;
  }
}

/// Wave CM: pure data class — token totals + display labels for the
/// breakdown UI. Builders compute it via [_buildBreakdown].
class _ChatBreakdown {
  final int preset;
  final int characters;
  final int persona;
  final int lorebooks;
  final int memory;
  /// Wave CY.18.190: Live Sheet active-snapshot injection.
  final int liveSheet;
  /// Wave CY.18.190: Script (story beats) injection block.
  final int script;
  final int messages;
  final List<String> characterNames;
  /// Wave CY.13: per-character (name, tokens) for the drilldown.
  /// Same order as [characterNames]; sums to [characters].
  final List<MapEntry<String, int>> characterBreakdown;
  final String? personaName;
  final List<String> lorebookNames;
  final String memoryNote;
  final int messageCount;

  int get total =>
      preset + characters + persona + lorebooks + memory + liveSheet + script + messages;

  _ChatBreakdown({
    required this.preset,
    required this.characters,
    required this.persona,
    required this.lorebooks,
    required this.memory,
    required this.liveSheet,
    required this.script,
    required this.messages,
    required this.characterNames,
    required this.characterBreakdown,
    required this.personaName,
    required this.lorebookNames,
    required this.memoryNote,
    required this.messageCount,
  });
}

_ChatBreakdown _buildBreakdown(AppStore store, Chat chat) {
  // Preset — mainPrompt + postHistoryInstructions + jailbreak.
  final preset = store.activePreset;
  var presetTokens = 0;
  if (preset != null) {
    presetTokens += approxTokens(preset.mainPrompt);
    presetTokens += approxTokens(preset.postHistoryInstructions);
  }

  // Characters — every member of the chat contributes.
  var charTokens = 0;
  final charNames = <String>[];
  final charBreakdown = <MapEntry<String, int>>[];
  for (final cid in chat.characterIds) {
    final c = chat.characterSnapshots[cid] ?? store.characterById(cid);
    if (c == null) continue;
    final t = approxTokensForCharacter(c);
    charNames.add(c.name);
    charBreakdown.add(MapEntry(c.name, t));
    charTokens += t;
  }

  // Persona — per-chat first (Wave CX), fall back to global default
  // for legacy chats with null personaId. Without this, the token
  // breakdown shows the wrong persona's numbers when the chat-bound
  // persona differs from store.activePersonaId.
  // Wave CY: was `store.activePersona` — caught by audit.
  Persona? persona;
  final pid = chat.personaId;
  if (pid != null) {
    for (final p in store.personas) {
      if (p.id == pid) {
        persona = p;
        break;
      }
    }
  }
  persona ??= store.activePersona;
  final personaTokens = persona != null ? approxTokensForPersona(persona) : 0;

  // Lorebooks — the 3-source combined set (per-chat + char + persona),
  // deduped. Same path the runtime uses for injection.
  final attachedBooks = collectBoundLorebooks(
    chat: chat,
    persona: persona,
    lookupBook: store.lorebookById,
    lookupCharacter: store.characterById,
  );
  var loreTokens = 0;
  for (final b in attachedBooks) {
    loreTokens += approxTokensForLorebook(b);
  }

  // Memory checkpoints — the LTM chain the auto-summariser appends to.
  // Wave CY.18: we now count tokens across every VALID checkpoint for
  // the current branch (orphaned ones from other branches don't go to
  // the model). Mirrors what buildRecapBlock injects at send time.
  final validCheckpoints = ltm.findValidCheckpoints(chat);
  var memTokens = 0;
  for (final c in validCheckpoints) {
    memTokens += approxTokens(c.summary);
  }
  final memNote = validCheckpoints.isEmpty
      ? '(no checkpoints yet)'
      : '${validCheckpoints.length} checkpoint${validCheckpoints.length == 1 ? "" : "s"}';

  // Wave CY.18.190: Live Sheet — count the injected active-snapshot block,
  // the exact same text that buildLiveSheetBlock sends to the model.
  final liveSheetBlock = lsheet.buildLiveSheetBlock(chat);
  final liveSheetTokens = approxTokens(liveSheetBlock);

  // Wave CY.18.190: Script (story beats) — count the injected roadmap block,
  // the exact same text that buildStoryRoadmapBlock sends to the model.
  final scriptBlock = roadmap.buildStoryRoadmapBlock(
      chat, beatsCap: store.scriptSettings.beatsCap);
  final scriptTokens = approxTokens(scriptBlock);

  // Messages — the chat history that effectively hits the LLM is
  // the post-LTM tail (everything after the last checkpoint's anchor,
  // since LTM-covered messages are summarised in the system prompt
  // instead of sent verbatim).
  //
  // Wave CY.18.37: dropped the redundant `modelSettings.memory` trim
  // here. The chat_screen turn builder no longer windows by last-N
  // either — context is purely LTM-cutoff driven.
  final ltmStart = ltm.firstUncoveredIndex(chat);
  final recent =
      chat.messages.sublist(ltmStart.clamp(0, chat.messages.length));
  var msgTokens = 0;
  for (final m in recent) {
    msgTokens += approxTokens(m.text);
  }

  return _ChatBreakdown(
    preset: presetTokens,
    characters: charTokens,
    persona: personaTokens,
    lorebooks: loreTokens,
    memory: memTokens,
    liveSheet: liveSheetTokens,
    script: scriptTokens,
    messages: msgTokens,
    characterNames: charNames,
    characterBreakdown: charBreakdown,
    personaName: persona?.name,
    lorebookNames: attachedBooks.map((b) => b.name).toList(),
    memoryNote: memNote,
    messageCount: recent.length,
  );
}

Future<void> showChatInfoSheet(BuildContext context, String chatId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: EmberColors.bgPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => ChatInfoSheet(chatId: chatId),
  );
}

/// Wave CY.18.100: the context-window usage strip under "Total context".
/// Three states: loading (probing /models), unknown (provider didn't
/// expose a context length and no manual override), and known (shows
/// used / window + a percent fill bar).
class _ContextWindowRow extends StatelessWidget {
  final bool loading;
  final int? window;
  final int used;
  const _ContextWindowRow({
    required this.loading,
    required this.window,
    required this.used,
  });

  /// Compact size label: 8192 → "8k", 200000 → "200k", 1048576 → "1M".
  static String _compact(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000;
      return k >= 100 ? '${k.round()}k' : '${k.toStringAsFixed(k.truncateToDouble() == k ? 0 : 1)}k';
    }
    final m = n / 1000000;
    return '${m.toStringAsFixed(m.truncateToDouble() == m ? 0 : 1)}M';
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 2),
        child: Text(
          'Checking model context window…',
          style: TextStyle(color: EmberColors.textDim, fontSize: 11),
        ),
      );
    }
    if (window == null || window! <= 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 2),
        child: Text(
          'Context window: unknown — set it manually in More → API '
          'Connections if you want the usage bar.',
          style: TextStyle(color: EmberColors.textDim, fontSize: 11),
        ),
      );
    }
    final pct = (used / window!).clamp(0.0, 1.0);
    final pctLabel = (pct * 100).clamp(0, 100).toStringAsFixed(0);
    final Color barColor = pct >= 0.9
        ? Colors.redAccent
        : (pct >= 0.7 ? Colors.amber : EmberColors.primary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.data_usage,
                size: 14, color: EmberColors.textMid),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${_compact(used)} of ~${_compact(window!)} window',
                style: const TextStyle(
                    color: EmberColors.textMid, fontSize: 12),
              ),
            ),
            Text(
              '$pctLabel%',
              style: TextStyle(
                color: barColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 5,
            backgroundColor: EmberColors.bgDeep,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
      ],
    );
  }
}
