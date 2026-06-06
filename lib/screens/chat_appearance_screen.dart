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

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/attachment_store.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/how_it_works_card.dart';
import '../widgets/lightbox.dart';

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
      // F2 bubble customization — carry the existing values into the draft.
      userBubbleColor: src.userBubbleColor,
      aiBubbleColor: src.aiBubbleColor,
      bubbleCornerRadius: src.bubbleCornerRadius,
      bubbleBorderWidth: src.bubbleBorderWidth,
      bubbleBorderColor: src.bubbleBorderColor,
      bubbleBlurSigma: src.bubbleBlurSigma,
      bubbleTextScale: src.bubbleTextScale,
    );
  }

  /// F2: a small curated palette for the bubble-color swatches. A few
  /// Ember-warm tones plus dark neutrals — enough to differentiate the
  /// user vs AI bubble without a full color-picker dependency. A leading
  /// `null` entry is the "Default" chip (clears the override → bgPanel).
  static const List<int?> _bubblePalette = <int?>[
    null, // Default (EmberColors.bgPanel)
    0xFF14141B, // bgPanel (the legacy base, explicit)
    0xFF1B1B24, // bgElevated (slightly lighter neutral)
    0xFF2A1D17, // warm umber
    0xFF3A2018, // ember brown
    0xFF1A2230, // cool slate blue
    0xFF152619, // deep green
    0xFF241526, // muted plum
    0xFF2C2233, // dusk violet
    0xFF332016, // burnt sienna
  ];

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
    // B-2 / H-6: externalise into the AttachmentStore (pyre:// ref) instead of
    // inline base64 (web falls back to a data URL).
    final ref = await externalizeImageBytes(bytes);
    if (!mounted) return;
    setState(() {
      _draft.customBackgroundDataUrl = ref;
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
          // ── How it works ──────────────────────────────────────────────
          const HowItWorksCard(
            title: 'How customizing the chat works',
            subtitle: 'Bubbles, background, and the scene-aware mode.',
            sections: [
              HowItWorksSection('What it is', [
                HowItWorksBlock.paragraph(
                    'These are the **looks** of every chat — how the message '
                    'bubbles are styled, what sits behind them, and whether a '
                    'reasoning model\'s thinking is shown. They\'re global '
                    'defaults; a single chat can override its background from '
                    'its own menu.'),
              ]),
              HowItWorksSection('Bubbles', [
                HowItWorksBlock.bullet(
                    '**Bubble opacity** — how visible the message background '
                    'is over the chat backdrop.'),
                HowItWorksBlock.bullet(
                    '**Message bubbles** — separate colors for your and the '
                    'character\'s bubbles, plus corner radius, border, text '
                    'size, and a frosted-glass **background blur**. Leave it '
                    'all as-is for the default style.'),
              ]),
              HowItWorksSection('Background', [
                HowItWorksBlock.bullet(
                    'Pick what sits behind the bubbles: the **character '
                    'avatar** (default), your **persona avatar**, a **custom '
                    'image** you upload, or **none**. Background opacity and '
                    'fit tune how it\'s drawn.'),
                HowItWorksBlock.bullet(
                    '**Scene-aware (dynamic)** — the background follows the '
                    'story automatically. As the scene moves, Pyre runs a '
                    'small model pass to classify the new location and swap '
                    'the backdrop to match. It uses your configured model, '
                    'so it adds a little latency on a scene change.'),
                HowItWorksBlock.paragraph(
                    'To trigger a scene-aware update by hand — or to correct '
                    'the location — open a chat\'s menu → **Customize chat** '
                    'and use **Detect location from chat**.'),
              ]),
              HowItWorksSection('Reasoning', [
                HowItWorksBlock.bullet(
                    '**Hide model reasoning** — hides a reasoning model\'s '
                    '<think>…</think> blocks (DeepSeek-R1 and similar) from '
                    'the chat. It\'s display-only and never changes what the '
                    'model generates.'),
              ]),
            ],
          ),
          const SizedBox(height: 8),
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
          // Pyre 1.1 — F2: chat bubble customization (separate user vs AI
          // color, corner radius, border, text size, backdrop blur). Every
          // control defaults to the current look, so leaving this card alone
          // keeps bubbles exactly as they are today.
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Message bubbles',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    'Tune the look of your bubbles. Leave everything as-is for the default style.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  // User bubble color
                  const Text('Your bubble color',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  _BubbleColorRow(
                    selected: _draft.userBubbleColor,
                    palette: _bubblePalette,
                    onPick: (argb) {
                      setState(() => _draft.userBubbleColor = argb);
                      _commit();
                    },
                  ),
                  const SizedBox(height: 16),
                  // AI bubble color
                  const Text('Character bubble color',
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  _BubbleColorRow(
                    selected: _draft.aiBubbleColor,
                    palette: _bubblePalette,
                    onPick: (argb) {
                      setState(() => _draft.aiBubbleColor = argb);
                      _commit();
                    },
                  ),
                  const SizedBox(height: 16),
                  // Corner radius
                  _SliderRow(
                    label: 'Corner radius',
                    value: _draft.bubbleCornerRadius,
                    min: 0,
                    max: 24,
                    divisions: 24,
                    valueLabel:
                        '${_draft.bubbleCornerRadius.round()}',
                    onChanged: (v) =>
                        setState(() => _draft.bubbleCornerRadius = v),
                    onChangeEnd: () => _commit(),
                  ),
                  // Border width
                  _SliderRow(
                    label: 'Border width',
                    value: _draft.bubbleBorderWidth,
                    min: 0,
                    max: 3,
                    divisions: 6,
                    valueLabel:
                        _draft.bubbleBorderWidth.toStringAsFixed(1),
                    onChanged: (v) =>
                        setState(() => _draft.bubbleBorderWidth = v),
                    onChangeEnd: () => _commit(),
                  ),
                  // Border color — only meaningful when a border is drawn.
                  if (_draft.bubbleBorderWidth > 0) ...[
                    const SizedBox(height: 4),
                    const Text('Border color',
                        style: TextStyle(fontSize: 13)),
                    const SizedBox(height: 6),
                    _BubbleColorRow(
                      selected: _draft.bubbleBorderColor,
                      palette: _bubblePalette,
                      onPick: (argb) {
                        setState(() => _draft.bubbleBorderColor = argb);
                        _commit();
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Bubble text size
                  _SliderRow(
                    label: 'Bubble text size',
                    value: _draft.bubbleTextScale,
                    min: 0.8,
                    max: 1.4,
                    divisions: 12,
                    valueLabel:
                        '${(_draft.bubbleTextScale * 100).round()}%',
                    onChanged: (v) =>
                        setState(() => _draft.bubbleTextScale = v),
                    onChangeEnd: () => _commit(),
                  ),
                  // Background blur (frosted glass behind the bubble)
                  _SliderRow(
                    label: 'Background blur',
                    value: _draft.bubbleBlurSigma,
                    min: 0,
                    max: 12,
                    divisions: 12,
                    valueLabel: '${_draft.bubbleBlurSigma.round()}',
                    onChanged: (v) =>
                        setState(() => _draft.bubbleBlurSigma = v),
                    onChangeEnd: () => _commit(),
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
                    // B-2 / H-6: the custom background is now usually a
                    // `pyre://` ref (externalised on pick), so resolve it via
                    // the shared image resolver rather than a raw base64Decode
                    // (which would throw on a non-data: URL).
                    if (_draft.customBackgroundDataUrl != null &&
                        Lightbox.resolveImage(
                                _draft.customBackgroundDataUrl) !=
                            null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image(
                            image: Lightbox.resolveImage(
                                _draft.customBackgroundDataUrl)!,
                            height: 120,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const SizedBox.shrink(),
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

/// Pyre 1.1 — F2: a row of tappable color swatches plus a leading "Default"
/// chip. The palette's first entry is `null` (= Default → clears the
/// override). Tapping a swatch reports its ARGB int; tapping Default reports
/// `null`. The currently-selected entry gets a ring. No heavyweight
/// color-picker dependency — a small curated palette is enough.
class _BubbleColorRow extends StatelessWidget {
  final int? selected;
  final List<int?> palette;
  final ValueChanged<int?> onPick;
  const _BubbleColorRow({
    required this.selected,
    required this.palette,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final argb in palette)
          if (argb == null)
            // "Default" chip — clears the override.
            ChoiceChip(
              label: const Text('Default'),
              selected: selected == null,
              selectedColor: EmberColors.primary.withValues(alpha: 0.25),
              onSelected: (_) => onPick(null),
            )
          else
            _Swatch(
              color: Color(argb),
              selected: selected == argb,
              onTap: () => onPick(argb),
            ),
      ],
    );
  }
}

/// A single circular color swatch with a selection ring.
class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? EmberColors.primary : EmberColors.stroke,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 16, color: EmberColors.textHigh)
            : null,
      ),
    );
  }
}

/// Pyre 1.1 — F2: a labelled slider row matching the existing "Bubble
/// opacity" layout (label on the left, live value on the right, thin track).
class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
            Text(
              valueLabel,
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
            onChangeEnd: (_) => onChangeEnd(),
          ),
        ),
      ],
    );
  }
}
