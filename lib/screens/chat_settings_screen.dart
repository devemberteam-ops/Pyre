// Wave CY.18.202 — Chat Settings is now a clean HUB (9 entries).
//
// The old flat screen crammed display knobs, behaviour toggles, and
// config-shortcuts together. It's now a nav list where each row opens a
// dedicated screen:
//   1. Customize Chat     → ChatAppearanceScreen  (bubble opacity,
//                            background, hide reasoning — display)
//   2. Behaviors          → ChatBehaviorsScreen    (delete behavior,
//                            ask persona, streaming — interaction)
//   3. Presets            → PresetsScreen          (existing)
//   4. Regex (find/replace) → RegexRulesScreen     (existing)
//   5. Long-term Memory   → LongTermMemoryScreen   (existing)
//   6. Live Sheet         → LiveSheetSettingsScreen (global cadence)
//   7. Script             → ScriptSettingsScreen    (global beats cap)
//   8. Guide              → GuideSettingsScreen     (guided generations)
//   9. System note        → SystemNoteSettingsScreen (opt-in /sys action)
//
// Lorebooks moved BACK to the More main menu in this wave (it was here
// since Wave 193) — it's a content library, not a chat setting.

import 'package:flutter/material.dart';

import '../theme.dart';
import 'chat_appearance_screen.dart';
import 'chat_behaviors_screen.dart';
import 'guide_settings_screen.dart';
import 'live_sheet_settings_screen.dart';
import 'long_term_memory_screen.dart';
import 'presets_screen.dart';
import 'regex_rules_screen.dart';
import 'script_settings_screen.dart';
import 'system_note_settings_screen.dart';

class ChatSettingsScreen extends StatelessWidget {
  const ChatSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chat Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          // Wave: task-based grouping (design study round 1). The 9 entries
          // are the same, now grouped so "memory" / "how the model responds" /
          // "how the chat looks" read as distinct intents instead of one flat
          // list. Section labels only — no new screens, no hidden accordions.
          _sectionLabel('Chat experience'),
          _HubCard(rows: [
            _HubRow(
              icon: Icons.palette_outlined,
              title: 'Customize Chat',
              subtitle: 'Bubbles, background, and reasoning display.',
              builder: (_) => const ChatAppearanceScreen(),
            ),
            _HubRow(
              icon: Icons.tune,
              title: 'Behaviors',
              subtitle: 'Delete, new-chat persona, and streaming.',
              builder: (_) => const ChatBehaviorsScreen(),
            ),
          ]),
          const SizedBox(height: 18),
          _sectionLabel('Replies & prompting'),
          _HubCard(rows: [
            _HubRow(
              icon: Icons.settings_suggest_outlined,
              title: 'Presets',
              subtitle: 'Sampling defaults and prompt presets.',
              builder: (_) => const PresetsScreen(),
            ),
            _HubRow(
              icon: Icons.find_replace,
              title: 'Regex (find/replace)',
              subtitle: 'Rewrite chat text on the fly (non-destructive).',
              builder: (_) => const RegexRulesScreen(),
            ),
          ]),
          const SizedBox(height: 18),
          _sectionLabel('Story continuity'),
          _HubCard(rows: [
            _HubRow(
              icon: Icons.psychology,
              title: 'Checkpoints',
              subtitle: 'Auto-summarise older messages into a recap.',
              builder: (_) => const LongTermMemoryScreen(),
            ),
            _HubRow(
              icon: Icons.checklist_rtl,
              title: 'Live Sheet',
              subtitle: 'Track each character\'s current state.',
              builder: (_) => const LiveSheetSettingsScreen(),
            ),
            _HubRow(
              icon: Icons.map_outlined,
              title: 'Script',
              subtitle: 'Plant plot beats the story builds toward.',
              builder: (_) => const ScriptSettingsScreen(),
            ),
          ]),
          const SizedBox(height: 18),
          _sectionLabel('One-shot tools'),
          _HubCard(rows: [
            _HubRow(
              icon: Icons.explore_outlined,
              title: 'Guide',
              subtitle:
                  'Steer the next reply, or draft your own message from an outline.',
              builder: (_) => const GuideSettingsScreen(),
            ),
            _HubRow(
              icon: Icons.smart_toy_outlined,
              title: 'System note',
              subtitle:
                  'Show the one-off /sys system-note action in the chat menu (off by default).',
              builder: (_) => const SystemNoteSettingsScreen(),
            ),
          ]),
        ],
      ),
    );
  }
}

/// A small uppercase section label above each hub group (design study round 1
/// — task-based grouping). Kept minimal per the "density with hierarchy, not
/// miniaturization" principle: one modest label per group, not a legend.
Widget _sectionLabel(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: EmberColors.textDim,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );

/// A single Card holding the hub rows, divided like the More screen's
/// `_MoreCard`.
class _HubCard extends StatelessWidget {
  final List<_HubRow> rows;
  const _HubCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i < rows.length - 1) {
        children.add(Divider(
          color: EmberColors.stroke,
          height: 1,
          indent: 16,
          endIndent: 16,
        ));
      }
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Column(children: children),
    );
  }
}

/// A nav row that pushes [builder] when tapped. Mirrors the house
/// ListTile nav pattern used across the More-area screens.
class _HubRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  const _HubRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: EmberColors.textMid),
      title: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: EmberColors.textMid, fontSize: 12),
      ),
      trailing: Icon(Icons.chevron_right,
          color: EmberColors.textDim, size: 22),
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: builder)),
    );
  }
}
