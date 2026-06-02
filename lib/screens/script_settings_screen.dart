// Wave CY.18.202 — global Script settings screen.
//
// Single source of truth for the GLOBAL Script knobs stored on
// `store.scriptSettings` (currently the active-beats injection cap).
// Both entry points open THIS screen so there is no duplicated editor:
//   • Chat Settings hub  → "Script"
//   • The per-chat Script editor's gear icon (script_screen.dart)
//
// The per-chat beat list (plant / edit / mark done) stays on the
// per-chat ScriptScreen — this screen only owns the global settings +
// a short "How it works" explainer.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../widgets/how_it_works_card.dart';
import '../widgets/setting_slider.dart';

class ScriptSettingsScreen extends StatefulWidget {
  const ScriptSettingsScreen({super.key});

  @override
  State<ScriptSettingsScreen> createState() => _ScriptSettingsScreenState();
}

class _ScriptSettingsScreenState extends State<ScriptSettingsScreen> {
  late int _beatsCap;

  @override
  void initState() {
    super.initState();
    _beatsCap = context.read<AppStore>().scriptSettings.beatsCap;
  }

  void _commit() {
    final store = context.read<AppStore>();
    store.scriptSettings.beatsCap = _beatsCap;
    store.notifyAndPersist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Script')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // ── How it works ──────────────────────────────────────────────
          // Wave CY.18.206: rich, structured explainer (shared renderer /
          // styling, collapsed by default). Copy kept accurate to
          // story_roadmap.dart — beats are injected as SOFT direction with
          // anti-rush framing; "done" beats drop out of injection.
          const HowItWorksCard(
            title: 'How the Script works',
            subtitle: 'What it is, how it paces, controls.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'The Script lets you **plant future plot beats** — '
                    'things you want to happen later in the story. Pyre '
                    'then nudges the roleplay toward them **gradually** '
                    'instead of rushing there in the next reply.'),
                HowItWorksBlock.paragraph(
                    'Write it and forget it: you set the destination, the '
                    'AI builds toward it over time.'),
              ]),
              HowItWorksSection('How it works', [
                HowItWorksBlock.bullet(
                    '**Add beats** in the Script editor (a chat\'s menu → '
                    'Script). Keep each one a short, concrete idea.'),
                HowItWorksBlock.bullet(
                    '**Active beats are injected as SOFT direction**, not '
                    'commands. The framing tells the model to foreshadow '
                    'and set up, advance a small step at a time, and only '
                    'when the story organically reaches it — never to fire '
                    'a beat early or resolve it all in one reply.'),
                HowItWorksBlock.bullet(
                    '**Mark a beat done** once it\'s been fulfilled (the '
                    'editor also moves a beat aside when it\'s clearly '
                    'happened). Done beats stop being injected, freeing '
                    'room for new ones.'),
              ]),
              HowItWorksSection('Settings', [
                HowItWorksBlock.bullet(
                    '**Inject at most N directions** — cap how many active '
                    'beats are sent to the model at once. Useful when you '
                    'have many queued and want to keep the context '
                    'footprint low. Set it to 0 to send all active '
                    'beats.'),
              ]),
              HowItWorksSection('Controls (per chat)', [
                HowItWorksBlock.bullet(
                    '**Add** a new beat.'),
                HowItWorksBlock.bullet(
                    '**Edit** a beat\'s wording inline.'),
                HowItWorksBlock.bullet(
                    '**Mark done** when it\'s been fulfilled.'),
                HowItWorksBlock.bullet(
                    '**Reactivate** a done beat to bring it back into '
                    'play.'),
              ]),
              HowItWorksSection('When to use it', [
                HowItWorksBlock.paragraph(
                    'When you have a destination or a twist in mind but '
                    'want organic pacing — building toward it naturally '
                    'rather than the AI rushing straight there.'),
              ]),
              HowItWorksSection('Honest note', [
                HowItWorksBlock.paragraph(
                    'Beats are **soft guidance**, not a script the model '
                    'must follow line by line. The model paces them, so '
                    'exact timing varies. Keep each beat concise — a clear '
                    'one-line idea steers better than a paragraph.'),
              ]),
            ],
          ),
          // ── Beats cap ─────────────────────────────────────────────────
          SliderCard(
            label: 'Inject at most N directions',
            subtitle: _beatsCap <= 0
                ? 'All active directions are sent to the model each turn.'
                : 'Only the first $_beatsCap active direction${_beatsCap == 1 ? "" : "s"} '
                    'are sent each turn — useful when you have many queued '
                    'to keep context footprint low. '
                    '0 sends all directions.',
            value: _beatsCap.toDouble(),
            min: 0,
            max: 20,
            divisions: 20,
            display: _beatsCap <= 0 ? 'all' : '$_beatsCap',
            onChanged: (v) {
              setState(() => _beatsCap = v.round());
            },
            onChangeEnd: (_) => _commit(),
          ),
        ],
      ),
    );
  }
}
