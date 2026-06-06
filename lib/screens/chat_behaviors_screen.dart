// Wave CY.18.202 — "Behaviors" sub-screen.
//
// Holds the generation / interaction BEHAVIOUR options lifted out of
// the old flat Chat Settings screen:
//   • Delete behavior        (what deleting a message does)
//   • Ask persona on new chat
//   • Streaming               (generation behaviour — bind to ModelSettings)
//
// Behaviour is unchanged from the pre-split Chat Settings — the section
// widgets were moved verbatim. Delete behavior + Ask persona bind to
// `ChatSettings` (persist via updateChatSettings); Streaming binds to
// the global `ModelSettings.stream` (persist via updateModelSettings),
// exactly as before.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/how_it_works_card.dart';

class ChatBehaviorsScreen extends StatefulWidget {
  const ChatBehaviorsScreen({super.key});

  @override
  State<ChatBehaviorsScreen> createState() => _ChatBehaviorsScreenState();
}

class _ChatBehaviorsScreenState extends State<ChatBehaviorsScreen> {
  late ChatSettings _draft;

  @override
  void initState() {
    super.initState();
    // Audit presets-regex-appearance-01: carry ALL 15 ChatSettings fields into
    // the draft via copyWith(). This screen only edits deleteBehavior +
    // askPersonaOnNewChat, but `updateChatSettings` does a FULL replace — so a
    // partial draft (the old code copied only 7 fields) silently reset every
    // bubble/background customization to its constructor default on commit.
    // Cloning the live settings preserves the 8 appearance fields this screen
    // doesn't manage.
    _draft = context.read<AppStore>().chatSettings.copyWith();
  }

  void _commit() => context.read<AppStore>().updateChatSettings(_draft);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Behaviors')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // ── How it works ──────────────────────────────────────────────
          const HowItWorksCard(
            title: 'How behaviors work',
            subtitle: 'What each toggle controls.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'These settings control how a chat **behaves** during '
                    'use — what deleting a message does, whether new chats '
                    'ask for a persona, and how replies are displayed as '
                    'they generate.'),
                HowItWorksBlock.paragraph(
                    'They\'re **global** — they apply to every chat, not '
                    'just the one you came from.'),
              ]),
              HowItWorksSection('The toggles', [
                HowItWorksBlock.bullet(
                    '**Delete behavior** — choose whether deleting a '
                    'message removes only that one, or that message and '
                    'everything after it.'),
                HowItWorksBlock.bullet(
                    '**Ask persona on new chat** — when on, starting a new '
                    'chat opens the persona picker first; when off, it uses '
                    'your default persona automatically.'),
                HowItWorksBlock.bullet(
                    '**Streaming** — show each reply token by token as it '
                    'generates, instead of all at once when it\'s done.'),
              ]),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Delete behavior',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    'When you delete a message in a chat.',
                    style:
                        TextStyle(color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<DeleteBehavior>(
                    segments: const [
                      ButtonSegment(
                        value: DeleteBehavior.onlyThis,
                        label: Text('Only this message'),
                      ),
                      ButtonSegment(
                        value: DeleteBehavior.thisAndAfter,
                        label: Text('This message and after'),
                      ),
                    ],
                    selected: {_draft.deleteBehavior},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) {
                      setState(() => _draft.deleteBehavior = s.first);
                      _commit();
                    },
                    style: ButtonStyle(
                      backgroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        return states.contains(WidgetState.selected)
                            ? EmberColors.primary
                            : EmberColors.bgElevated;
                      }),
                      foregroundColor:
                          WidgetStateProperty.resolveWith((states) {
                        return states.contains(WidgetState.selected)
                            ? Colors.white
                            : EmberColors.textMid;
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Wave CY.15: persona-on-new-chat behaviour
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              title: const Text('Ask persona on new chat',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                'When ON, starting a new chat with a character opens the persona picker first. When OFF, it uses your default persona automatically.',
                style:
                    TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              value: _draft.askPersonaOnNewChat,
              activeThumbColor: EmberColors.primary,
              onChanged: (v) {
                setState(() => _draft.askPersonaOnNewChat = v);
                _commit();
              },
            ),
          ),
          // Wave CY.18.192: the "Streaming" toggle binds to the global
          // `ModelSettings.stream`, not ChatSettings — so it commits via
          // a separate update method. Wave CY.18.202 places it under
          // Behaviors (it's a generation behaviour, not a display knob).
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              title: const Text(
                'Streaming',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Display the response bit by bit as it is generated.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              value: context.watch<AppStore>().modelSettings.stream,
              activeThumbColor: EmberColors.primary,
              onChanged: (v) {
                final store = context.read<AppStore>();
                final ms = store.modelSettings;
                ms.stream = v;
                store.updateModelSettings(ms);
              },
            ),
          ),
        ],
      ),
    );
  }
}
