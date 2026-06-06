// Guide (guided generations) — global settings screen.
//
// Single source of truth for the GLOBAL Guide knobs stored on
// `store.guideSettings`. Opened from the Chat Settings hub → "Guide".
//
// A "guide" is a TRANSIENT, one-shot instruction injected for a single
// generation and then discarded — it is never saved to chat history and
// never syncs. The in-chat affordances (Guide the reply / Regenerate with a
// guide / Guide my message) arrive in a follow-up update; this screen owns
// the global settings + a "How it works" explainer styled like the LTM /
// Live Sheet / Script screens.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/how_it_works_card.dart';

class GuideSettingsScreen extends StatefulWidget {
  const GuideSettingsScreen({super.key});

  @override
  State<GuideSettingsScreen> createState() => _GuideSettingsScreenState();
}

class _GuideSettingsScreenState extends State<GuideSettingsScreen> {
  late GuideSettings _draft;

  @override
  void initState() {
    super.initState();
    final src = context.read<AppStore>().guideSettings;
    _draft = GuideSettings(
      enabled: src.enabled,
      injectionPosition: src.injectionPosition,
      defaultPerspective: src.defaultPerspective,
      mtime: src.mtime,
    );
  }

  void _commit() => context.read<AppStore>().updateGuideSettings(_draft);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guide')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // ── How it works ──────────────────────────────────────────────
          const HowItWorksCard(
            title: 'How Guide works',
            subtitle: 'Steer one reply, or draft your own message.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'Guide lets you **steer a single reply on the fly** — a '
                    'one-shot instruction for the very next generation. It is '
                    '**ephemeral**: it is never saved to the chat, never shows '
                    'up in history, and never syncs. It nudges one reply, then '
                    'it\'s gone.'),
                HowItWorksBlock.paragraph(
                    'This is different from an OOC message (which is a real, '
                    'saved message) and from the Script (which plants '
                    'persistent beats). A guide leaves no trace.'),
              ]),
              HowItWorksSection('The three actions', [
                HowItWorksBlock.bullet(
                    '**Guide the reply** — type a quick instruction for how '
                    'the next reply should go (a tone, a beat, a detail). It '
                    'steers ONLY that reply and is then discarded — it never '
                    'becomes part of the conversation.'),
                HowItWorksBlock.bullet(
                    '**Regenerate with a guide** — re-roll the current reply '
                    'into a new variant with a guide applied, when a swipe '
                    'just needs a little direction.'),
                HowItWorksBlock.bullet(
                    '**Guide my message** — give a short outline or rough '
                    'draft and Pyre expands it into a full message in your '
                    'persona\'s voice. The result lands in the input box for '
                    'you to review and edit before sending.'),
              ]),
              HowItWorksSection('Settings', [
                HowItWorksBlock.bullet(
                    '**Enable Guide** — turns the in-chat Guide actions on or '
                    'off. When on, they live in the input menu and the message '
                    'menu; when off, they\'re hidden.'),
                HowItWorksBlock.bullet(
                    '**Where the guide goes** — whether the one-shot note is '
                    'placed as a system note at the end of the prompt, or just '
                    'before your last message. End-of-prompt keeps it closest '
                    'to what the model writes next; before-your-message lets '
                    'the model read the guidance then the message it answers.'),
                HowItWorksBlock.bullet(
                    '**Default perspective** — the point of view "Guide my '
                    'message" writes in (first, second, or third person). Most '
                    'roleplay is second person ("you"). You can still override '
                    'it per message.'),
              ]),
              HowItWorksSection('Honest note', [
                HowItWorksBlock.paragraph(
                    'A guide is **soft, one-shot direction** — it steers the '
                    'next generation but the model still writes the reply. '
                    'Because it\'s never saved, its effect doesn\'t carry over '
                    'to later turns on its own.'),
              ]),
              HowItWorksSection('Coming soon', [
                HowItWorksBlock.paragraph(
                    'The in-chat Guide buttons arrive in the next update. '
                    'These settings configure them ahead of time.'),
              ]),
            ],
          ),
          const SizedBox(height: 8),
          // ── Enable toggle ─────────────────────────────────────────────
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              title: const Text('Enable Guide',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                'Show the in-chat Guide actions (steer the next reply, '
                'regenerate with a guide, guide my message). Guides are '
                'never saved to history.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              value: _draft.enabled,
              activeThumbColor: EmberColors.primary,
              onChanged: (v) {
                setState(() => _draft.enabled = v);
                _commit();
              },
            ),
          ),
          // ── Injection position ────────────────────────────────────────
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Where the guide goes',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    'Where the one-shot guidance note is placed in the prompt.',
                    style:
                        TextStyle(color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<GuideInjectionPosition>(
                    segments: const [
                      ButtonSegment(
                        value: GuideInjectionPosition.systemNoteAtEnd,
                        label: Text('System note at end'),
                      ),
                      ButtonSegment(
                        value: GuideInjectionPosition.beforeLastUserTurn,
                        label: Text('Before my last message'),
                      ),
                    ],
                    selected: {_draft.injectionPosition},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) {
                      setState(() => _draft.injectionPosition = s.first);
                      _commit();
                    },
                    style: _segStyle(),
                  ),
                ],
              ),
            ),
          ),
          // ── Default perspective ───────────────────────────────────────
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Default perspective',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    'The point of view "Guide my message" writes in. '
                    'Overridable per message.',
                    style:
                        TextStyle(color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<GuidePerspective>(
                    segments: const [
                      ButtonSegment(
                        value: GuidePerspective.first,
                        label: Text('First'),
                      ),
                      ButtonSegment(
                        value: GuidePerspective.second,
                        label: Text('Second'),
                      ),
                      ButtonSegment(
                        value: GuidePerspective.third,
                        label: Text('Third'),
                      ),
                    ],
                    selected: {_draft.defaultPerspective},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) {
                      setState(() => _draft.defaultPerspective = s.first);
                      _commit();
                    },
                    style: _segStyle(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shared segmented-button styling (mirrors ChatBehaviorsScreen).
  ButtonStyle _segStyle() => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? EmberColors.primary
              : EmberColors.bgElevated;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? Colors.white
              : EmberColors.textMid;
        }),
      );
}
