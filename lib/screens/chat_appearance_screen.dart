// Wave CY.18.202 — "Customize Chat" sub-screen.
//
// Holds the AESTHETIC / display options lifted out of the old flat
// Chat Settings screen:
//   • Bubble opacity
//   • Chat background (source + opacity, custom upload)
//   • Hide model reasoning  (display-side, not generation)
//
// Behaviour is unchanged from the pre-split Chat Settings — the section
// widgets were moved verbatim, still binding to the same
// `ChatSettings` fields and persisting via `updateChatSettings`.
//
// Wave CY.18.203 will add a background-fit picker here — there is room
// inside the "Chat background" card for it.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';

class ChatAppearanceScreen extends StatefulWidget {
  const ChatAppearanceScreen({super.key});

  @override
  State<ChatAppearanceScreen> createState() => _ChatAppearanceScreenState();
}

class _ChatAppearanceScreenState extends State<ChatAppearanceScreen> {
  late ChatSettings _draft;

  @override
  void initState() {
    super.initState();
    final src = context.read<AppStore>().chatSettings;
    _draft = ChatSettings(
      deleteBehavior: src.deleteBehavior,
      hideReasoning: src.hideReasoning,
      bubbleAlpha: src.bubbleAlpha,
      backgroundSource: src.backgroundSource,
      customBackgroundDataUrl: src.customBackgroundDataUrl,
      backgroundOpacity: src.backgroundOpacity,
      backgroundFit: src.backgroundFit,
      askPersonaOnNewChat: src.askPersonaOnNewChat,
    );
  }

  /// Wave CK: pick an image from device storage and stash as base64
  /// data URL on the draft. Same pattern as character avatar uploads.
  Future<void> _pickCustomBackground() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;
    if (!mounted) return;
    setState(() {
      _draft.customBackgroundDataUrl =
          'data:image/png;base64,${base64Encode(bytes)}';
      _draft.backgroundSource = ChatBackgroundSource.custom;
    });
    _commit();
  }

  void _commit() => context.read<AppStore>().updateChatSettings(_draft);

  /// Wave CK: display label for each background source option.
  String _bgLabel(ChatBackgroundSource s) {
    switch (s) {
      case ChatBackgroundSource.characterAvatar:
        return 'Character avatar';
      case ChatBackgroundSource.personaAvatar:
        return 'Persona avatar';
      case ChatBackgroundSource.custom:
        return 'Custom image';
      case ChatBackgroundSource.none:
        return 'None — plain dark theme';
      case ChatBackgroundSource.dynamic:
        return 'Scene-aware (dynamic)';
    }
  }

  /// Wave CK: one-line explanation under each radio option.
  String _bgSubtitle(ChatBackgroundSource s) {
    switch (s) {
      case ChatBackgroundSource.characterAvatar:
        return 'Default — the primary character\'s portrait sits behind the chat.';
      case ChatBackgroundSource.personaAvatar:
        return 'Your active persona\'s avatar instead. Falls back to character if no persona is set.';
      case ChatBackgroundSource.custom:
        return 'Upload your own image (saved with the app data).';
      case ChatBackgroundSource.none:
        return 'No backdrop — bubbles float over the app background.';
      case ChatBackgroundSource.dynamic:
        return 'Background follows the scene automatically as the story moves (uses your model).';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customize Chat')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Bubble opacity',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600)),
                            SizedBox(height: 2),
                            Text(
                              'How visible the message background is over the character art.',
                              style: TextStyle(
                                  color: EmberColors.textMid, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${(_draft.bubbleAlpha * 100).round()}%',
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
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 8),
                    ),
                    child: Slider(
                      value: _draft.bubbleAlpha,
                      min: 0,
                      max: 1,
                      divisions: 20,
                      activeColor: EmberColors.primary,
                      onChanged: (v) =>
                          setState(() => _draft.bubbleAlpha = v),
                      onChangeEnd: (_) => _commit(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Wave CK: chat background picker. Default is the primary
          // character's avatar (the legacy behaviour); the user can
          // switch to the active persona's avatar, upload a custom
          // image, or disable the backdrop entirely. Custom image
          // upload also bumps the source to `custom` so the picker
          // stays consistent.
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Chat background',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    'What image (if any) sits behind the message bubbles.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  // Wave CK: RadioGroup wraps the radio tiles —
                  // the modern Flutter API (3.32+). Each tile is a
                  // bare Radio inside a ListTile so we control the
                  // layout (icon + subtitle + dense) without the
                  // deprecated RadioListTile.groupValue.
                  RadioGroup<ChatBackgroundSource>(
                    groupValue: _draft.backgroundSource,
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _draft.backgroundSource = v);
                      _commit();
                    },
                    child: Column(
                      children: [
                        for (final source in ChatBackgroundSource.values)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: Radio<ChatBackgroundSource>(
                              value: source,
                              activeColor: EmberColors.primary,
                            ),
                            title: Text(_bgLabel(source)),
                            subtitle: Text(
                              _bgSubtitle(source),
                              style: const TextStyle(
                                  color: EmberColors.textMid, fontSize: 11),
                            ),
                            onTap: () {
                              setState(
                                  () => _draft.backgroundSource = source);
                              _commit();
                            },
                          ),
                      ],
                    ),
                  ),
                  if (_draft.backgroundSource ==
                      ChatBackgroundSource.custom) ...[
                    const SizedBox(height: 4),
                    if (_draft.customBackgroundDataUrl != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            base64Decode(_draft
                                .customBackgroundDataUrl!
                                .split(',')
                                .last),
                            height: 120,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          icon: const Icon(Icons.upload, size: 16),
                          label: Text(_draft.customBackgroundDataUrl ==
                                  null
                              ? 'Choose image'
                              : 'Replace image'),
                          onPressed: _pickCustomBackground,
                        ),
                        const SizedBox(width: 8),
                        if (_draft.customBackgroundDataUrl != null)
                          TextButton.icon(
                            icon: const Icon(Icons.delete_outline,
                                size: 16, color: EmberColors.danger),
                            label: const Text('Clear',
                                style: TextStyle(
                                    color: EmberColors.danger)),
                            onPressed: () {
                              setState(() {
                                _draft.customBackgroundDataUrl = null;
                              });
                              _commit();
                            },
                          ),
                      ],
                    ),
                  ],
                  if (_draft.backgroundSource !=
                      ChatBackgroundSource.none) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(
                          child: Text('Background opacity',
                              style: TextStyle(fontSize: 13)),
                        ),
                        Text(
                          '${(_draft.backgroundOpacity * 100).round()}%',
                          style: const TextStyle(
                            color: EmberColors.textMid,
                            fontFeatures: [
                              FontFeature.tabularFigures()
                            ],
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 8),
                      ),
                      child: Slider(
                        value: _draft.backgroundOpacity,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        activeColor: EmberColors.primary,
                        onChanged: (v) => setState(
                            () => _draft.backgroundOpacity = v),
                        onChangeEnd: (_) => _commit(),
                      ),
                    ),
                    // Wave CY.18.203: background fit picker.
                    const SizedBox(height: 16),
                    const Text('Background fit',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 2),
                    const Text(
                      'Contain shows the whole image — most useful on wide windows with a portrait image.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    _BgFitPicker(
                      value: _draft.backgroundFit,
                      onChanged: (f) {
                        setState(() => _draft.backgroundFit = f);
                        _commit();
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Wave CY.18.202: "Hide model reasoning" lands here under
          // Customize Chat — it's a display-side filter (what you see),
          // not a generation behaviour.
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              title: const Text(
                'Hide model reasoning',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Hide <think>…</think> blocks from reasoning models (DeepSeek-R1 etc.) without affecting generation.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              value: _draft.hideReasoning,
              activeThumbColor: EmberColors.primary,
              onChanged: (v) {
                setState(() => _draft.hideReasoning = v);
                _commit();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Wave CY.18.203: compact row-of-chips picker for [ChatBackgroundFit].
/// Shows a [ChoiceChip] per option — no dialog needed since there are only 4.
class _BgFitPicker extends StatelessWidget {
  final ChatBackgroundFit value;
  final ValueChanged<ChatBackgroundFit> onChanged;
  const _BgFitPicker({required this.value, required this.onChanged});

  static String _label(ChatBackgroundFit f) {
    switch (f) {
      case ChatBackgroundFit.cover:
        return 'Cover';
      case ChatBackgroundFit.contain:
        return 'Contain';
      case ChatBackgroundFit.fitWidth:
        return 'Fit width';
      case ChatBackgroundFit.fill:
        return 'Stretch';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final f in ChatBackgroundFit.values)
          ChoiceChip(
            label: Text(_label(f)),
            selected: value == f,
            selectedColor: EmberColors.primary.withValues(alpha: 0.25),
            onSelected: (_) => onChanged(f),
          ),
      ],
    );
  }
}
