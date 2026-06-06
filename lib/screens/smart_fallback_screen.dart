// Smart provider fallback — dedicated settings home.
//
// The provider-fallback feature used to live as a lone toggle inside the
// "Advanced" expander on the API Connections screen, which made it hard
// to discover and gave it no explainer. It now has its own screen with a
// shared "How it works" card (matching Long-term Memory / Live Sheet /
// Script / Creator) plus the single master toggle.
//
// BEHAVIOUR IS UNCHANGED — the toggle binds to the exact same
// `uiPrefs.askToSwitchOnFailure` field via `setAskToSwitchOnFailure`,
// and the provider list on API Connections is still the fallback order.
// This screen only improves discoverability + explains the feature.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/how_it_works_card.dart';

class SmartFallbackScreen extends StatelessWidget {
  const SmartFallbackScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Smart provider fallback')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // ── How it works ──────────────────────────────────────────────
          const HowItWorksCard(
            title: 'How smart provider fallback works',
            subtitle: 'What it does, and how to opt out.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'If the provider you\'re using **fails or refuses** a '
                    'reply, Pyre offers to retry it on the **next configured '
                    'provider** — so a single flaky or strict endpoint '
                    'doesn\'t stop your story.'),
              ]),
              HowItWorksSection('How it works', [
                HowItWorksBlock.bullet(
                    '**Always user-confirmed, never silent** — Pyre asks '
                    'before switching, so it never spends a different '
                    'provider\'s budget behind your back.'),
                HowItWorksBlock.bullet(
                    '**The order is the provider list** on API Connections. '
                    'Drag to reorder; your active chat provider is always '
                    'tried first.'),
                HowItWorksBlock.bullet(
                    '**Refusal detection learns** — it spots a refusal (a '
                    'short, unformatted, English brush-off) and remembers '
                    'the patterns it has seen, so it gets better at '
                    'recognising them over time.'),
              ]),
              HowItWorksSection('Opting out', [
                HowItWorksBlock.paragraph(
                    'Turn the toggle below **off** and Pyre will never offer '
                    'to switch — a failed reply just surfaces the error.'),
              ]),
            ],
          ),
          const SizedBox(height: 8),
          // ── The single master toggle (moved verbatim from the old
          //    "Advanced" expander; same field, same setter). ────────────
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              value: store.uiPrefs.askToSwitchOnFailure,
              onChanged: store.setAskToSwitchOnFailure,
              title: const Text('Ask to switch providers when one fails',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                'When a provider errors or refuses, Pyre offers to retry '
                'the reply on another configured provider. Off: never asks.',
                style: TextStyle(
                    color: EmberColors.textMid, fontSize: 12, height: 1.4),
              ),
              activeThumbColor: EmberColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
