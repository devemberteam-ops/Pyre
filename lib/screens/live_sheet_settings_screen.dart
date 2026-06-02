// Wave CY.18.202 — global Live Sheet settings screen.
//
// Single source of truth for the GLOBAL Live Sheet knobs stored on
// `store.liveSheetSettings` (currently the auto-update cadence). Both
// entry points open THIS screen so there is no duplicated editor:
//   • Chat Settings hub  → "Live Sheet"
//   • The per-chat Live Sheet editor's gear icon (live_sheet_screen.dart)
//
// The per-chat enable toggle + entity editing stays on the per-chat
// LiveSheetScreen — this screen only owns the global settings + a short
// "How it works" explainer.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../widgets/how_it_works_card.dart';
import '../widgets/setting_slider.dart';

class LiveSheetSettingsScreen extends StatefulWidget {
  const LiveSheetSettingsScreen({super.key});

  @override
  State<LiveSheetSettingsScreen> createState() =>
      _LiveSheetSettingsScreenState();
}

class _LiveSheetSettingsScreenState extends State<LiveSheetSettingsScreen> {
  late int _autoEvery;

  @override
  void initState() {
    super.initState();
    _autoEvery = context.read<AppStore>().liveSheetSettings.autoEvery;
  }

  void _commit() {
    final store = context.read<AppStore>();
    store.liveSheetSettings.autoEvery = _autoEvery;
    store.notifyAndPersist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Sheet')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // ── How it works ──────────────────────────────────────────────
          // Wave CY.18.206: rich, structured explainer (shared renderer /
          // styling, collapsed by default). Copy kept accurate to
          // live_sheet.dart + the LiveSheet model (5 sections: appearance,
          // clothing, conditions, possessions, facts; locked facts; per-
          // entity seed; authoritative re-injection every turn).
          const HowItWorksCard(
            title: 'How the Live Sheet works',
            subtitle: 'What it is, how it tracks, controls.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'The Live Sheet is a **per-chat tracker of each '
                    'character\'s current state** — their appearance, '
                    'clothing, conditions, possessions, and notable '
                    'facts.'),
                HowItWorksBlock.paragraph(
                    'It\'s re-injected into context every turn, so the '
                    'model doesn\'t forget details that **drift over a '
                    'long RP** — an outfit change three scenes ago, a '
                    'fresh injury, a new possession, a haircut. The sheet '
                    'is treated as authoritative: where it and the '
                    'character card disagree, the sheet wins.'),
              ]),
              HowItWorksSection('How it works', [
                HowItWorksBlock.bullet(
                    '**Enable it per chat** (from a chat\'s menu → Live '
                    'Sheet) and pick who gets tracked.'),
                HowItWorksBlock.bullet(
                    '**The AI updates the sheet** every N character turns, '
                    'reading the conversation since the last update and '
                    'writing only what actually changed.'),
                HowItWorksBlock.bullet(
                    '**You can edit facts by hand** at any time — add, '
                    'reword, or remove anything.'),
                HowItWorksBlock.bullet(
                    '**Locked facts are never overwritten** by the AI. '
                    'Lock the things that must stay fixed (a permanent '
                    'scar, a fixed eye colour) and the auto-updater leaves '
                    'them alone.'),
                HowItWorksBlock.bullet(
                    '**The current sheet is injected into context**, so '
                    'the model always sees the latest state before it '
                    'writes.'),
              ]),
              HowItWorksSection('Settings', [
                HowItWorksBlock.bullet(
                    '**Auto-update every N turns** — how often the AI '
                    'refreshes the sheet from the conversation. Set it to '
                    '0 to disable auto-update and refresh only manually. '
                    'This cadence applies to every chat.'),
              ]),
              HowItWorksSection('Controls (per chat)', [
                HowItWorksBlock.bullet(
                    '**Add / edit / remove** entities and their facts.'),
                HowItWorksBlock.bullet(
                    '**Lock a fact** so the AI can\'t change it.'),
                HowItWorksBlock.bullet(
                    '**Seed from chat** — let the AI fill in an entity\'s '
                    'current state from the conversation so far.'),
                HowItWorksBlock.bullet(
                    '**Update state now** — force a refresh immediately '
                    'instead of waiting for the cadence.'),
              ]),
              HowItWorksSection('When to use it', [
                HowItWorksBlock.paragraph(
                    'Long roleplays where appearance, clothing, or '
                    'conditions change and you want the model to stay '
                    'consistent across scenes.'),
              ]),
              HowItWorksSection('Honest note', [
                HowItWorksBlock.paragraph(
                    'It tracks **significant, durable changes** — not '
                    'every micro-detail of every reply. If a specific '
                    'detail must never slip, write it as a fact and lock '
                    'it.'),
              ]),
            ],
          ),
          // ── Auto-update cadence ───────────────────────────────────────
          SliderCard(
            label: 'Auto-update every',
            subtitle: _autoEvery <= 0
                ? 'Auto-update disabled — use "Update state now" manually.'
                : 'Pyre updates the sheet every $_autoEvery character turns. '
                    '0 disables auto-update.',
            value: _autoEvery.toDouble(),
            min: 0,
            max: 30,
            divisions: 30,
            display: _autoEvery <= 0 ? 'off' : '$_autoEvery turns',
            onChanged: (v) {
              setState(() => _autoEvery = v.round());
            },
            onChangeEnd: (_) => _commit(),
          ),
        ],
      ),
    );
  }
}
