// System note — global settings screen (Pyre 1.1.3).
//
// "Add system note" inserts a one-off `/sys` system-role instruction into the
// transcript. It's a power-user feature most people never need, so it's HIDDEN
// from the chat input's ⋮ menu by default; this screen is the single toggle
// that surfaces it. Opened from the Chat Settings hub → "System note". The flag
// lives on `ChatSettings.systemNoteEnabled`, so it persists and rides the
// existing synced-settings unit with the rest of the chat settings.
//
// Styled like the Guide / Live Sheet / Script settings screens (a "How it
// works" explainer + a single toggle Card).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/how_it_works_card.dart';

class SystemNoteSettingsScreen extends StatelessWidget {
  const SystemNoteSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final enabled = context.watch<AppStore>().chatSettings.systemNoteEnabled;
    return Scaffold(
      appBar: AppBar(title: const Text('System note')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // ── How it works ──────────────────────────────────────────────
          const HowItWorksCard(
            title: 'How the system note works',
            subtitle: 'A one-off instruction to the model, mid-chat.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'A **system note** drops a one-off, system-role instruction '
                    'into the conversation — exactly what the `/sys` command '
                    'does. Use it to steer the model directly ("describe the '
                    'room in more detail", "raise the stakes", "keep it in past '
                    'tense") without speaking as your character.'),
                HowItWorksBlock.paragraph(
                    'Unlike a **Guide** (ephemeral, never saved), a system note '
                    'is a REAL message in the transcript — it stays in history '
                    'and is re-sent every turn until you delete it. It\'s close '
                    'to an **OOC** message, but it carries the system role '
                    'instead of an out-of-character aside.'),
              ]),
              HowItWorksSection('Why it\'s off by default', [
                HowItWorksBlock.paragraph(
                    'Most people never need it, so to keep the chat input menu '
                    'tidy it stays hidden until you turn it on here. The `/sys` '
                    'slash command keeps working either way.'),
              ]),
            ],
          ),
          const SizedBox(height: 8),
          // ── Enable toggle ─────────────────────────────────────────────
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              title: const Text('Show "Add system note"',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                'Adds a "system note" action to the chat input\'s ⋮ menu, next '
                'to Impersonate and Add OOC. The /sys command works regardless.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              value: enabled,
              activeThumbColor: EmberColors.primary,
              onChanged: (v) {
                final store = context.read<AppStore>();
                store.updateChatSettings(
                    store.chatSettings.copyWith(systemNoteEnabled: v));
              },
            ),
          ),
        ],
      ),
    );
  }
}
