import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/attachment_store.dart';
import '../services/scene_background.dart' as scenebg;
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/lightbox.dart';

/// Wave CY.18.195: this sheet now hosts ONLY the per-chat background controls
/// (source + opacity + the scene-aware "Set background now" action). The
/// Members management + Lorebook sections it used to carry moved to the
/// dedicated Group chat & Lorebooks sheet (group_lorebooks_sheet.dart).
class CustomizeChatSheet extends StatelessWidget {
  final String chatId;
  const CustomizeChatSheet({super.key, required this.chatId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    // Chat may have been deleted while this sheet was open. Auto-close
    // rather than throwing on the firstWhere lookup.
    Chat? chat;
    for (final c in store.chats) {
      if (c.id == chatId) {
        chat = c;
        break;
      }
    }
    if (chat == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.maybePop(context);
      });
      return const SizedBox.shrink();
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        // Wave CY.18.156: scrollable — the sheet now also carries a Background
        // section, which can push it past the screen on shorter devices.
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: SizedBox(
                  width: 40,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: EmberColors.stroke,
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
            const Text(
              'Chat background',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            // Wave CY.18.156: per-chat background OVERRIDE (source + opacity),
            // folded into this existing sheet so there's no competing
            // "set background" entry point. Defaults to "Use app default".
            //
            // Wave CY.18.195: the Members + Lorebooks sections that used to
            // live here moved to the dedicated Group chat & Lorebooks sheet
            // (group_lorebooks_sheet.dart) so this sheet stays focused on the
            // background (and, in Wave 197, the scene-aware location field).
            _ChatBackgroundSection(chatId: chatId),
          ],
          ),
        ),
      ),
    );
  }
}

/// Wave CY.18.156: per-chat background OVERRIDE — source + opacity. Lives
/// inside the Customize-chat sheet so there's no second "set background"
/// entry point competing with it. Everything defaults to "Use app default"
/// (the global ChatSettings), so an untouched chat behaves exactly as before;
/// picking anything else writes the override onto the [Chat].
class _ChatBackgroundSection extends StatefulWidget {
  final String chatId;
  const _ChatBackgroundSection({required this.chatId});

  @override
  State<_ChatBackgroundSection> createState() => _ChatBackgroundSectionState();
}

class _ChatBackgroundSectionState extends State<_ChatBackgroundSection> {
  // Transient opacity while dragging — committed (and persisted) onChangeEnd
  // so the slider stays smooth without thrashing the store every tick.
  double? _dragOpacity;
  // Wave CY.18.185: true while the manual "Set background now" classify is running.
  bool _classifying = false;
  // Wave CY.18.197: inline editor for the AI-tracked current location. The
  // controller is seeded from chat.sceneLocation on first build and only
  // re-synced when the underlying value changes from OUTSIDE this field (e.g.
  // the auto-pipeline moved the scene) — never mid-edit, so we don't clobber
  // the user's keystrokes. A focus node lets us commit on focus loss.
  TextEditingController? _locationCtrl;
  final FocusNode _locationFocus = FocusNode();
  String _locationSynced = '';

  @override
  void initState() {
    super.initState();
    _locationFocus.addListener(_onLocationFocusChange);
  }

  @override
  void dispose() {
    _locationFocus.removeListener(_onLocationFocusChange);
    _locationFocus.dispose();
    _locationCtrl?.dispose();
    super.dispose();
  }

  void _onLocationFocusChange() {
    if (!_locationFocus.hasFocus) _commitLocation();
  }

  Chat? _findChat(AppStore store) {
    for (final c in store.chats) {
      if (c.id == widget.chatId) return c;
    }
    return null;
  }

  // null = the "Use app default" option (inherit the global ChatSettings).
  static String _label(ChatBackgroundSource? s) {
    switch (s) {
      case null:
        return 'Use app default';
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

  static String _subtitle(ChatBackgroundSource? s) {
    switch (s) {
      case null:
        return 'Follow the global Chat Settings.';
      case ChatBackgroundSource.characterAvatar:
        return 'This character\'s portrait sits behind the chat.';
      case ChatBackgroundSource.personaAvatar:
        return 'Your persona\'s avatar (falls back to the character).';
      case ChatBackgroundSource.custom:
        return 'Upload an image just for this chat.';
      case ChatBackgroundSource.none:
        return 'No backdrop for this chat.';
      case ChatBackgroundSource.dynamic:
        return 'Background follows the scene as the story moves (uses your model).';
    }
  }

  Future<void> _pickCustom(AppStore store, Chat chat) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;
    chat.backgroundSource = ChatBackgroundSource.custom;
    // B-2 / H-6: externalise into the AttachmentStore (pyre:// ref) instead of
    // inline base64 (web falls back to a data URL).
    chat.customBackgroundDataUrl = await externalizeImageBytes(bytes);
    store.touchChat(chat); // F1: custom background syncs
  }

  /// Wave CY.18.185: manually trigger a scene classify from the current chat
  /// history. Decoupled from the chat_screen auto-pipeline — bypasses cooldown,
  /// does its own inline classify, then advances the watermarks so the auto-
  /// pipeline skips a re-classify of the same window.
  ///
  /// Wave CY.18.199: this is the "Detect location from chat" action — the AI
  /// reads the recent chat, resolves the location + setting, and updates BOTH
  /// the tracked `sceneLocation` (the field) AND the background image.
  Future<void> _setSceneNow(AppStore store, Chat chat) async {
    // Build recent text from the last few RP messages (raw text is fine here).
    final recentText = _autoRecentWindow(chat);
    if (recentText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Nothing to read yet — send a message or two first.'),
      ));
      return;
    }
    await _classifyAndPick(store, chat, recentText);
  }

  /// Wave CY.18.197: shared classify-and-pick path used by BOTH the manual
  /// "Detect location from chat" button (narration = recent messages) and the
  /// "Current location" edit (narration = recent messages + the user's typed
  /// hint, which seeds + corrects the classifier). It runs the free keyword
  /// pre-pass, then the classifier (anchored on the chat's tracked location +
  /// setting), updates the sticky setting + tracked location note + sceneBgFile,
  /// advances the watermarks, and surfaces a SnackBar. Bypasses cooldown (this
  /// is an explicit action).
  ///
  /// Wave CY.18.199: the watermark is always advanced against the chat's REAL
  /// recent window (not the seeded narration), so a manual location hint never
  /// poisons the auto-pipeline dedup key.
  Future<void> _classifyAndPick(
      AppStore store, Chat chat, String narrationText) async {
    final provider = store.activeProvider;
    if (provider == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No active provider — set one in API Connections first.'),
      ));
      return;
    }

    final manifest = await scenebg.loadSceneManifest();
    if (manifest == null || !mounted) return;

    setState(() => _classifying = true);
    try {
      // Keyword pre-pass first (free) — CONFIDENT hits only. A weak lone
      // generic word falls through to the classifier on a miss.
      String? targetSlug =
          scenebg.confidentKeywordPrePass(manifest, narrationText);
      String timeOfDay = 'unknown';
      String? locationNote;
      if (targetSlug != null) {
        // Pre-pass yields only a slug; track the category's display name.
        locationNote = manifest.categoryBySlug(targetSlug)?.name;
      } else {
        final verdict = await scenebg.classifyScene(
          manifest: manifest,
          recentText: narrationText,
          provider: provider,
          settings: store.modelSettings,
          currentLocation: chat.sceneLocation,
          currentSetting: chat.sceneSetting,
        );
        if (verdict != null) {
          // Sticky setting: only overwrite when the classifier is sure.
          if (verdict.setting != 'unknown') chat.sceneSetting = verdict.setting;
          timeOfDay = verdict.timeOfDay;
          final decision = scenebg.decideSwitch(verdict,
              hasCurrent: chat.sceneBgFile != null);
          if (decision.kind == scenebg.SceneDecisionKind.setLocation) {
            targetSlug = decision.slug;
            locationNote = verdict.locationNote.isNotEmpty
                ? verdict.locationNote
                : manifest.categoryBySlug(targetSlug ?? '')?.name;
          } else if (decision.kind == scenebg.SceneDecisionKind.neutral) {
            targetSlug = manifest.fallbackSlug;
          }
        }
      }
      // Advance watermarks against the chat's actual recent window so the auto-
      // pipeline doesn't immediately re-classify it (use the real recent text,
      // not the seed, so a location edit doesn't poison the dedup key).
      final autoWindow = _autoRecentWindow(chat);
      chat.sceneLastClassifyKey = scenebg.sceneWindowKey(autoWindow);
      chat.sceneLastClassifyMsgCount = chat.messages.length;

      var changed = false;
      if (targetSlug != null) {
        final cat = manifest.categoryBySlug(targetSlug);
        if (cat != null) {
          final file = scenebg.pickSceneImage(
              cat,
              chat.sceneSetting,
              timeOfDay,
              scenebg.weatherCueFromText(narrationText),
              chat.id);
          if (file != null) {
            chat.sceneBgFile = file;
            changed = true;
          }
          // Keep the tracked location note current.
          if (locationNote != null &&
              locationNote.isNotEmpty &&
              chat.sceneLocation != locationNote) {
            chat.sceneLocation = locationNote;
            changed = true;
          }
        }
      }
      store.touchChat(chat); // F1: scene fields + watermarks sync
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(changed
              ? 'Background updated to match the scene.'
              : 'Couldn\'t place this scene — keeping the current background.'),
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      if (mounted) setState(() => _classifying = false);
    }
  }

  /// The chat's real recent-message window (matches chat_screen's
  /// _sceneRecentText shape) — used only to compute the dedup watermark key so
  /// a manual action / location edit doesn't clobber the auto-pipeline's dedup.
  String _autoRecentWindow(Chat chat) {
    final msgs = chat.messages
        .where((m) =>
            m.kind == MessageKind.user ||
            m.kind == MessageKind.char ||
            m.kind == MessageKind.scene)
        .toList();
    final tail = msgs.length <= 4 ? msgs : msgs.sublist(msgs.length - 4);
    return tail.map((m) => m.text).join('\n').trim();
  }

  /// Wave CY.18.197: commit an edit to the "Current location" field. Persists
  /// the typed note onto chat.sceneLocation, then re-picks the background by
  /// feeding the typed text to the classifier as narration (so a user
  /// correction like "the guild hall" immediately resolves a slug + setting).
  ///
  /// Wave CY.18.199 — FIX for "typed 'Guild' but the background didn't change":
  /// feeding ONLY the typed word ("Guild") to the classifier gave it no world
  /// cues, so with a stuck wrong `sceneSetting:'modern'` it returned a low-
  /// confidence / modern pick. We now build the narration as the chat's REAL
  /// recent window PLUS a strong authoritative hint line naming the typed
  /// location. The classifier then sees both the medieval-world cues from the
  /// chat AND the user's location intent — so "Guild" in a medieval RP resolves
  /// to fantasy_tavern and the stuck `modern` setting self-corrects to
  /// `medieval_fantasy`.
  void _commitLocation() {
    final ctrl = _locationCtrl;
    if (ctrl == null) return;
    final store = context.read<AppStore>();
    final chat = _findChat(store);
    if (chat == null) return;
    final text = ctrl.text.trim();
    if (text == chat.sceneLocation.trim()) return; // no change → no work
    chat.sceneLocation = text;
    _locationSynced = text;
    store.touchChat(chat); // F1: location edit syncs
    if (text.isEmpty) return; // cleared → just persist, nothing to classify
    // Combine the chat's real recent window with an authoritative hint so the
    // classifier has both the world cues AND the user's intent. The recent
    // window goes first (context), the hint last (the instruction the model
    // reads most recently). Falls back to hint-only if the chat is empty.
    final recent = _autoRecentWindow(chat);
    final hint =
        'The user has indicated the current scene location is: $text. '
        'Use this as the authoritative current location.';
    final narration = recent.isEmpty ? hint : '$recent\n\n$hint';
    // Re-pick from the combined narration (fire-and-forget, guarded).
    unawaited(_classifyAndPick(store, chat, narration));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chat = _findChat(store);
    if (chat == null) return const SizedBox.shrink();
    final settings = store.chatSettings;

    // The EFFECTIVE source decides whether an opacity slider is even relevant.
    final effectiveSource = chat.backgroundSource ?? settings.backgroundSource;
    final effectiveOpacity =
        _dragOpacity ?? chat.backgroundOpacity ?? settings.backgroundOpacity;

    // Wave CY.18.197: lazily create the location controller and keep it in
    // sync with chat.sceneLocation when the value changes from OUTSIDE this
    // field (auto-pipeline). We only re-seed when NOT focused, so we never
    // clobber the user mid-edit.
    _locationCtrl ??= TextEditingController(text: chat.sceneLocation);
    if (!_locationFocus.hasFocus &&
        chat.sceneLocation != _locationSynced &&
        chat.sceneLocation != _locationCtrl!.text) {
      _locationCtrl!.text = chat.sceneLocation;
      _locationSynced = chat.sceneLocation;
    }

    const options = <ChatBackgroundSource?>[
      null,
      ChatBackgroundSource.characterAvatar,
      ChatBackgroundSource.personaAvatar,
      ChatBackgroundSource.custom,
      ChatBackgroundSource.dynamic,
      ChatBackgroundSource.none,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Background',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: EmberColors.textMid,
                fontSize: 12),
          ),
        ),
        RadioGroup<ChatBackgroundSource?>(
          groupValue: chat.backgroundSource,
          onChanged: (v) {
            chat.backgroundSource = v;
            store.touchChat(chat); // F1: background source syncs
          },
          child: Column(
            children: [
              for (final s in options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Radio<ChatBackgroundSource?>(
                    value: s,
                    activeColor: EmberColors.primary,
                  ),
                  title: Text(_label(s)),
                  subtitle: Text(
                    _subtitle(s),
                    style: const TextStyle(
                        color: EmberColors.textMid, fontSize: 11),
                  ),
                  onTap: () {
                    chat.backgroundSource = s;
                    store.touchChat(chat); // F1: background source syncs
                  },
                ),
            ],
          ),
        ),
        if (chat.backgroundSource == ChatBackgroundSource.custom) ...[
          const SizedBox(height: 4),
          // B-2 / H-6: the custom background is now usually a `pyre://` ref
          // (externalised on pick), so resolve it via the shared image
          // resolver rather than a raw base64Decode (which would throw on a
          // non-data: URL).
          if (chat.customBackgroundDataUrl != null &&
              Lightbox.resolveImage(chat.customBackgroundDataUrl) != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image(
                  image:
                      Lightbox.resolveImage(chat.customBackgroundDataUrl)!,
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          Row(
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.upload, size: 16),
                label: Text(chat.customBackgroundDataUrl == null
                    ? 'Choose image'
                    : 'Replace image'),
                onPressed: () => _pickCustom(store, chat),
              ),
              const SizedBox(width: 8),
              if (chat.customBackgroundDataUrl != null)
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: EmberColors.danger),
                  label: const Text('Clear',
                      style: TextStyle(color: EmberColors.danger)),
                  onPressed: () {
                    chat.customBackgroundDataUrl = null;
                    store.touchChat(chat); // F1: clear custom bg syncs
                  },
                ),
            ],
          ),
        ],
        // Wave CY.18.185: manual classify button for dynamic mode.
        // Wave CY.18.197: + an editable AI-tracked "Current location" field.
        if (effectiveSource == ChatBackgroundSource.dynamic) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'Current location',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: EmberColors.stroke.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'experimental',
                  style:
                      TextStyle(fontSize: 9, color: EmberColors.textMid),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _locationCtrl,
            focusNode: _locationFocus,
            enabled: !_classifying,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _commitLocation(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'e.g. the Serpent’s Fang guild hall',
              helperMaxLines: 3,
              helperText:
                  'Pyre keeps this updated as the scene moves. Type a place '
                  '(e.g. "the guild") to correct the background — it reads the '
                  'recent chat to place it in the right world.',
              helperStyle:
                  TextStyle(color: EmberColors.textMid, fontSize: 11),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'The background follows the scene automatically as you chat. '
            'You can also let Pyre read the recent chat and figure out the '
            'location + background right now:',
            style: TextStyle(color: EmberColors.textMid, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton.icon(
                icon: _classifying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.travel_explore, size: 16),
                label: Text(_classifying
                    ? 'Reading the scene…'
                    : 'Detect location from chat'),
                onPressed:
                    _classifying ? null : () => _setSceneNow(store, chat),
              ),
            ],
          ),
          if (chat.sceneBgFile != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Current: ${chat.sceneBgFile}',
                style:
                    const TextStyle(color: EmberColors.textMid, fontSize: 10),
              ),
            ),
        ],
        if (effectiveSource != ChatBackgroundSource.none) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text('Opacity', style: TextStyle(fontSize: 13)),
              ),
              Text(
                '${(effectiveOpacity * 100).round()}%'
                '${chat.backgroundOpacity == null ? "  · app default" : ""}',
                style: const TextStyle(
                    color: EmberColors.textMid, fontSize: 12),
              ),
              if (chat.backgroundOpacity != null)
                TextButton(
                  onPressed: () {
                    setState(() => _dragOpacity = null);
                    chat.backgroundOpacity = null;
                    store.touchChat(chat); // F1: opacity reset syncs
                  },
                  child: const Text('Reset'),
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
              value: effectiveOpacity.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              divisions: 20,
              activeColor: EmberColors.primary,
              onChanged: (v) => setState(() => _dragOpacity = v),
              onChangeEnd: (v) {
                _dragOpacity = null;
                chat.backgroundOpacity = v;
                store.touchChat(chat); // F1: opacity change syncs
              },
            ),
          ),
          // Wave CY.18.203: per-chat background fit override.
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text('Background fit', style: TextStyle(fontSize: 13)),
              ),
              if (chat.backgroundFit != null)
                TextButton(
                  onPressed: () {
                    chat.backgroundFit = null;
                    store.touchChat(chat); // F1: fit reset syncs
                  },
                  child: const Text('Reset'),
                ),
            ],
          ),
          const Text(
            'Contain shows the whole image — most useful on wide windows. "App default" follows Chat Settings.',
            style: TextStyle(color: EmberColors.textMid, fontSize: 11),
          ),
          const SizedBox(height: 8),
          _PerChatFitPicker(
            value: chat.backgroundFit,
            globalFit: settings.backgroundFit,
            onChanged: (f) {
              chat.backgroundFit = f;
              store.touchChat(chat); // F1: fit change syncs
            },
          ),
        ],
      ],
    );
  }
}

Future<void> showCustomizeChatSheet(BuildContext context, String chatId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: EmberColors.bgPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => CustomizeChatSheet(chatId: chatId),
  );
}

/// Wave CY.18.203: per-chat fit picker. Includes a null option ("App default")
/// that clears the per-chat override so it inherits the global ChatSettings.
/// Shows the effective global value in parentheses for clarity.
class _PerChatFitPicker extends StatelessWidget {
  /// null = inherit global (app default).
  final ChatBackgroundFit? value;
  final ChatBackgroundFit globalFit;
  final ValueChanged<ChatBackgroundFit?> onChanged;
  const _PerChatFitPicker({
    required this.value,
    required this.globalFit,
    required this.onChanged,
  });

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
    // "null" option label shows the app default value in parens.
    final defaultLabel = 'App default (${_label(globalFit).toLowerCase()})';
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        // The "app default / inherit" chip comes first.
        ChoiceChip(
          label: Text(defaultLabel),
          selected: value == null,
          selectedColor: EmberColors.primary.withValues(alpha: 0.25),
          onSelected: (_) => onChanged(null),
        ),
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
