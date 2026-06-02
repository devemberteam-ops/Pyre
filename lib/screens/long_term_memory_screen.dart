// Global long-term memory preferences.
//
// Wave CY.18: memory is no longer a single overwriteable summary —
// each chat keeps a CHAIN of branch-aware [MemoryCheckpoint]s
// (see lib/services/memory.dart). The settings here drive every
// chat's auto-summariser:
//   - Auto-checkpoint frequency (autoEvery)
//       N messages between checkpoints. 0 disables the auto-trigger
//       across all chats — manual "Summarise now" still works.
//   - Target words per checkpoint (memoryLimit)
//       Interpolated into the {{words}} placeholder in the summary
//       prompt. Acts as a soft cap on each checkpoint's length so
//       the chain stays bounded as the chat grows.
//   - Summary Prompt (summaryPrompt)
//       The system prompt the summariser uses. Supports {{words}}.
//
// The per-chat Memory screen (screens/memory_screen.dart) shows the
// actual checkpoint chain and lets the user retry / delete entries
// or toggle memory off for that single chat.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/how_it_works_card.dart';

class LongTermMemoryScreen extends StatefulWidget {
  const LongTermMemoryScreen({super.key});

  @override
  State<LongTermMemoryScreen> createState() => _LongTermMemoryScreenState();
}

class _LongTermMemoryScreenState extends State<LongTermMemoryScreen> {
  late MemorySettings _draft;
  late TextEditingController _promptCtl;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    final src = store.memorySettings;
    _draft = MemorySettings(
      autoEvery: src.autoEvery,
      memoryLimit: src.memoryLimit,
      summaryPrompt: src.summaryPrompt,
    );
    _promptCtl = TextEditingController(text: src.summaryPrompt);
  }

  @override
  void dispose() {
    _promptCtl.dispose();
    super.dispose();
  }

  void _commit() {
    _draft.summaryPrompt = _promptCtl.text;
    context.read<AppStore>().updateMemorySettings(_draft);
  }

  void _restore() {
    setState(() {
      _draft = MemorySettings();
      _promptCtl.text = _draft.summaryPrompt;
    });
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Long-term Memory'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: OutlinedButton(
              onPressed: _restore,
              child: const Text('Restore'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // Wave CY.18.206: rich, structured "How it works" explainer —
          // same shared renderer / styling as the Character Creator card.
          // Collapsed by default. Copy is kept accurate to memory.dart
          // (branch-aware checkpoint chain, story-style recap, auto-
          // continue on truncation, near-top injection).
          const HowItWorksCard(
            title: 'How long-term memory works',
            subtitle: 'What it is, how recaps build, controls.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'A roleplay can run far longer than the model\'s '
                    'context window can hold. Instead of re-sending the '
                    'entire history every turn (slow and expensive), Pyre '
                    'periodically **summarises the older messages into a '
                    'running, story-style recap** and injects that recap '
                    'as memory.'),
                HowItWorksBlock.paragraph(
                    'The model keeps continuity — who did what, where '
                    'things stand — while you spend a fraction of the '
                    'tokens. Memory is **per chat** and can be toggled off '
                    'for any single conversation.'),
              ]),
              HowItWorksSection('How the recap builds', [
                HowItWorksBlock.paragraph(
                    'Every N messages a new **checkpoint** is written. '
                    'Each checkpoint is the NEXT paragraph of one ongoing '
                    'narrative — not a dry bullet list of events — so the '
                    'recap reads like the story so far.'),
                HowItWorksBlock.bullet(
                    '**Branch-aware** — each conversation branch keeps its '
                    'own valid checkpoints. Re-roll or branch off a past '
                    'message and the checkpoints that no longer fit the '
                    'new path are set aside (they stay on disk, so your '
                    'old branch keeps its memory when you navigate back '
                    'via the chat tree).'),
                HowItWorksBlock.bullet(
                    '**Injected near the top of the prompt** — the model '
                    'sees the recap as established backstory before the '
                    'recent verbatim messages.'),
                HowItWorksBlock.bullet(
                    '**Self-healing on truncation** — if a summary comes '
                    'back cut off mid-sentence, Pyre automatically asks '
                    'the model to continue it (bounded, so it never loops '
                    'forever).'),
              ]),
              HowItWorksSection('Settings', [
                HowItWorksBlock.bullet(
                    '**Auto-checkpoint frequency** — how many new messages '
                    'accumulate before the next checkpoint fires. Set it '
                    'to 0 to disable auto-summarising across all chats '
                    '(you can still summarise manually).'),
                HowItWorksBlock.bullet(
                    '**Target words per checkpoint** — a soft cap on each '
                    'checkpoint\'s length so the recap stays bounded as '
                    'the chat grows.'),
                HowItWorksBlock.bullet(
                    '**Summary Prompt** — the system prompt the summariser '
                    'runs. Supports the {{words}} placeholder.'),
              ]),
              HowItWorksSection('Controls (per chat)', [
                HowItWorksBlock.paragraph(
                    'Open a chat\'s menu → Memory to manage that '
                    'conversation\'s recap:'),
                HowItWorksBlock.bullet(
                    '**Edit a checkpoint** inline — fix anything the model '
                    'got wrong; your edit is what future turns see.'),
                HowItWorksBlock.bullet(
                    '**Retry a checkpoint** — regenerate just that one '
                    'over the same slice of conversation.'),
                HowItWorksBlock.bullet(
                    '**Summarise now** — force a checkpoint immediately '
                    'instead of waiting for the cadence.'),
                HowItWorksBlock.bullet(
                    '**Memory on/off** for this chat — when off, no recap '
                    'is built or injected (but "Summarise now" still '
                    'works).'),
              ]),
              HowItWorksSection('Honest notes', [
                HowItWorksBlock.bullet(
                    'It\'s an LLM summary, so it can miss nuance or '
                    'compress something you cared about. If it does, edit '
                    'the checkpoint — the corrected text is authoritative.'),
                HowItWorksBlock.bullet(
                    'A capable model writes far better recaps. If a '
                    'reasoning model leaks its thinking or a summary keeps '
                    'truncating, that\'s the provider, not the feature.'),
              ]),
            ],
          ),
          _SliderCard(
            label: 'Auto-checkpoint frequency',
            subtitle:
                'Drop a new checkpoint every N uncovered messages (0 to '
                'disable across all chats).',
            value: _draft.autoEvery.toDouble(),
            min: 0,
            max: 60,
            divisions: 60,
            display: _draft.autoEvery.toString(),
            onChanged: (v) => setState(() => _draft.autoEvery = v.round()),
            onChangeEnd: (_) => _commit(),
          ),
          _SliderCard(
            label: 'Target words per checkpoint',
            subtitle:
                'Soft cap on each checkpoint\'s length. Interpolated into '
                'the {{words}} placeholder of the prompt below.',
            value: _draft.memoryLimit.toDouble(),
            min: 100,
            max: 5000,
            divisions: 49,
            display: _draft.memoryLimit.toString(),
            onChanged: (v) =>
                setState(() => _draft.memoryLimit = v.round()),
            onChangeEnd: (_) => _commit(),
          ),
          // Wave CY.18.202: the Live Sheet cadence slider that lived here
          // (Wave 174) moved to its own screen — Chat Settings → Live
          // Sheet — so the global Live Sheet knob has a single home.
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Summary Prompt',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'System prompt sent to the model when it builds a '
                    'checkpoint. Supports {{words}}.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _promptCtl,
                    maxLines: 8,
                    minLines: 4,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _commit(),
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

class _SliderCard extends StatelessWidget {
  final String label;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  const _SliderCard({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            color: EmberColors.textMid, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  display,
                  style: const TextStyle(
                    color: EmberColors.textMid,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                activeColor: EmberColors.primary,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
