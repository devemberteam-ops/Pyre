import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/token_estimate.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/gallery_editor_section.dart';
import '../widgets/lorebook_binding_section.dart';
import 'avatar_crop_screen.dart';

/// Editable form for a chara_card_v2 character.
///
/// Three modes:
/// 1. Edit existing character — `characterId` is set, looks up from
///    `store.characters`. Save updates in place.
/// 2. Per-chat snapshot override — `characterId` + `overrideChatId` both
///    set. Save mutates the chat's snapshot instead of the global char.
/// 3. **NEW (Wave BG) — Draft mode** — `draftId` is set, looks up from
///    `store.characterDrafts`. Text changes auto-save to the draft;
///    Save PROMOTES the draft to a real character and removes it from
///    drafts. Back-out keeps the draft if it has content, discards if
///    empty. This is how "Create from scratch" works now — no more
///    leaking empty Untitled rows into the characters list.
class CharacterEditScreen extends StatefulWidget {
  final String? characterId;
  final String? overrideChatId;
  final String? draftId;
  const CharacterEditScreen({
    super.key,
    this.characterId,
    this.overrideChatId,
    this.draftId,
  }) : assert(characterId != null || draftId != null,
            'Must pass either characterId or draftId');

  @override
  State<CharacterEditScreen> createState() => _CharacterEditScreenState();
}

class _CharacterEditScreenState extends State<CharacterEditScreen> {
  late TextEditingController name;
  late TextEditingController tagline;
  late TextEditingController description;
  late TextEditingController personality;
  late TextEditingController scenario;
  late TextEditingController firstMes;
  late TextEditingController mesExample;
  late TextEditingController systemPrompt;
  late TextEditingController postHistory;
  late TextEditingController creator;
  late TextEditingController characterVersion;
  late TextEditingController tagsCsv;
  // Wave BE: alternate greetings are paragraph-style strings — one
  // controller per greeting instead of a single textarea with `---`
  // separators (which was both ugly and easy to typo). The list grows
  // via "+ Add greeting" and shrinks via a per-row delete button.
  late List<TextEditingController> _greetingCtls;
  late TextEditingController creatorNotes;
  // Wave BJ: dropped depthPrompt / depthPromptDepth / extensionsJson
  // controllers and the _talkativeness field — those UIs were removed
  // from the Advanced section. Existing values on imported cards are
  // preserved through Save because `Character.fromJson(_source().toJson())`
  // copies them automatically; we just never overwrite from form state.
  String? _avatar;
  /// Wave CC: bound lorebook ids (a mutable copy of the source
  /// character's list). Edited inline via the LorebookBindingSection
  /// chip UI; flushed back into the Character on _save.
  late List<String> _lorebookIds;

  /// Wave CY.18.128: gallery refs (a mutable copy of the source
  /// character's list). Edited inline via the GalleryEditorSection;
  /// flushed back into the Character on _save.
  late List<String> _gallery;

  @override
  void initState() {
    super.initState();
    final c = _source();
    name = TextEditingController(text: c.name);
    tagline = TextEditingController(text: c.tagline ?? '');
    description = TextEditingController(text: c.description);
    personality = TextEditingController(text: c.personality);
    scenario = TextEditingController(text: c.scenario);
    firstMes = TextEditingController(text: c.firstMes);
    mesExample = TextEditingController(text: c.mesExample);
    systemPrompt = TextEditingController(text: c.systemPrompt);
    postHistory = TextEditingController(text: c.postHistoryInstructions);
    creator = TextEditingController(text: c.creator);
    characterVersion = TextEditingController(text: c.characterVersion);
    tagsCsv = TextEditingController(text: c.tags.join(', '));
    // Wave BE: seed one controller per existing greeting; if there are
    // none, start with one empty so the editor isn't a confusing void.
    _greetingCtls = c.alternateGreetings.isEmpty
        ? <TextEditingController>[TextEditingController()]
        : [
            for (final g in c.alternateGreetings)
              TextEditingController(text: g),
          ];
    creatorNotes = TextEditingController(text: c.creatorNotes);
    _avatar = c.avatar;
    // Wave CC: local copy of bound lorebook ids, mutated by the
    // LorebookBindingSection's onChanged and flushed back into the
    // character on _save → _composeFromForm.
    _lorebookIds = List<String>.from(c.lorebookIds);
    // Wave CY.18.128: local copy of gallery refs, mutated by the
    // GalleryEditorSection's onChanged + flushed back on _save.
    _gallery = List<String>.from(c.gallery);
    // Wave BG: in draft mode, every text change debounce-saves the
    // draft so backing out + relaunching the app preserves the work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _wireDraftAutosave();
    });
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    super.dispose();
  }

  Character _source() {
    final store = context.read<AppStore>();
    // Wave BG: draft mode takes precedence.
    if (widget.draftId != null) {
      return store.draftById(widget.draftId!) ??
          Character(id: widget.draftId!, name: '');
    }
    if (widget.overrideChatId != null) {
      // Manual lookup so a chat deletion mid-edit doesn't throw inside
      // the build chain — fall through to the global character then.
      for (final chat in store.chats) {
        if (chat.id == widget.overrideChatId) {
          final snap = chat.characterSnapshots[widget.characterId];
          if (snap != null) return snap;
          break;
        }
      }
    }
    return store.characterById(widget.characterId!) ??
        Character(id: widget.characterId!, name: '(deleted)');
  }

  /// Wave BG: assemble the current form state into a Character, used
  /// both by Save (commit) and by the debounced auto-save in draft mode.
  ///
  /// Wave BJ: `talkativeness`, `depthPrompt`, `depthPromptDepth`, and
  /// `extensions` are no longer overridden here — the seed comes from
  /// `Character.fromJson(_source().toJson())` so imported cards carry
  /// their original values forward intact even though we don't surface
  /// a UI for editing them.
  Character _composeFromForm() {
    return Character.fromJson(_source().toJson())
      ..name = name.text.trim()
      ..tagline = tagline.text.trim().isEmpty ? null : tagline.text.trim()
      ..description = description.text
      ..personality = personality.text
      ..scenario = scenario.text
      ..firstMes = firstMes.text
      ..mesExample = mesExample.text
      ..systemPrompt = systemPrompt.text
      ..postHistoryInstructions = postHistory.text
      ..creator = creator.text.trim()
      ..characterVersion = characterVersion.text.trim().isEmpty
          ? '1.0'
          : characterVersion.text.trim()
      ..creatorNotes = creatorNotes.text
      ..tags = tagsCsv.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList()
      ..alternateGreetings = _greetingCtls
          .map((c) => c.text.trim())
          .where((s) => s.isNotEmpty)
          .toList()
      // Wave CC: flush the locally-edited binding list.
      ..lorebookIds = List<String>.from(_lorebookIds)
      // Wave CY.18.128: flush the locally-edited gallery refs.
      ..gallery = List<String>.from(_gallery)
      ..avatar = _avatar;
  }

  /// Wave BG: debounced auto-save to the draft. Only fires in draft
  /// mode (existing-character edits commit only on explicit Save).
  /// 600ms debounce matches the AppStore's persistence cadence.
  Timer? _draftDebounce;
  void _scheduleDraftSave() {
    if (widget.draftId == null) return;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      context.read<AppStore>().saveDraft(_composeFromForm());
    });
  }

  /// Wave BG: hook every text controller so any keystroke schedules a
  /// draft save. Called once after initState.
  void _wireDraftAutosave() {
    if (widget.draftId == null) return;
    // Wave BJ: dropped depthPrompt/depthPromptDepth/extensionsJson —
    // those controllers no longer exist (their UI was removed).
    final controllers = <TextEditingController>[
      name, tagline, description, personality, scenario, firstMes,
      mesExample, systemPrompt, postHistory, creator, characterVersion,
      tagsCsv, creatorNotes,
      ..._greetingCtls,
    ];
    for (final c in controllers) {
      c.addListener(_scheduleDraftSave);
    }
  }

  Future<void> _pickAndCropAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;
    if (!mounted) return;
    // Wave CQ: store the full image as-is. The previous flow forced
    // a crop modal on every pick, which destroyed the original — bad
    // when the user picked a botbooru bot that's meant to be shown
    // whole. Recrop stays available as an explicit opt-in.
    setState(() {
      _avatar = 'data:image/png;base64,${base64Encode(bytes)}';
    });
  }

  /// Re-runs the crop dialog over the existing avatar — useful when the
  /// original card avatar came in misaligned and the user just wants to
  /// reposition without picking a new file.
  Future<void> _recropAvatar() async {
    final url = _avatar;
    if (url == null || !url.startsWith('data:')) return;
    final comma = url.indexOf(',');
    if (comma < 0) return;
    try {
      final bytes = base64Decode(url.substring(comma + 1));
      if (!mounted) return;
      final cropped = await cropAvatar(context, bytes);
      if (cropped == null) return;
      setState(() {
        _avatar = 'data:image/png;base64,${base64Encode(cropped)}';
      });
    } catch (_) {/* ignore — bad base64 */}
  }

  void _save() {
    final store = context.read<AppStore>();
    // Wave BG: draft mode → cancel any pending debounce, promote to
    // a real character via `promoteDraftToCharacter`. The draft's
    // current form contents need to be flushed FIRST so the promotion
    // picks up the latest text.
    if (widget.draftId != null) {
      _draftDebounce?.cancel();
      final composed = _composeFromForm()
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      store.saveDraft(composed); // ensure latest text is in the draft
      store.promoteDraftToCharacter(widget.draftId!);
      Navigator.pop(context);
      return;
    }

    final updated = _composeFromForm()
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;

    if (widget.overrideChatId != null) {
      // Manual lookup — chat could have been deleted between opening this
      // editor and tapping Save. Silent fall-through to global save in
      // that case (better than a StateError that crashes the save).
      Chat? chat;
      for (final c in store.chats) {
        if (c.id == widget.overrideChatId) {
          chat = c;
          break;
        }
      }
      if (chat != null) {
        chat.characterSnapshots[widget.characterId!] = updated;
        chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
        store.notifyAndPersist();
      } else {
        store.updateCharacter(updated);
      }
    } else {
      store.updateCharacter(updated);
    }
    Navigator.pop(context);
  }

  /// Wave BG: invoked when the user backs out of the editor in draft
  /// mode. If the draft has any meaningful content (typed name, body,
  /// tags, avatar, etc), keep it so they can resume. If everything is
  /// blank, discard silently. Empty drafts cluttering the Drafts list
  /// would defeat the whole point.
  Future<bool> _onWillPop() async {
    if (widget.draftId == null) return true;
    final store = context.read<AppStore>();
    _draftDebounce?.cancel();
    final composed = _composeFromForm();
    if (store.isDraftMeaningful(composed)) {
      store.saveDraft(composed);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Draft saved. Resume from Create → Resume draft.'),
        duration: Duration(seconds: 2),
      ));
    } else {
      // Pristine "Create from scratch" → no content → no clutter.
      store.removeDraft(widget.draftId!);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isOverride = widget.overrideChatId != null;
    final isDraft = widget.draftId != null;
    // Wave BG: watch drafts list so the Drafts button badge stays in
    // sync as the user auto-saves the current draft.
    final draftCount =
        context.watch<AppStore>().characterDrafts.length;
    // Wrap in PopScope so back-out in draft mode can save / discard.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) await _onWillPop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(
          isOverride
              ? 'Edit (this chat only)'
              : isDraft
                  ? 'New character'
                  : 'Edit character',
        ),
        actions: [
          // Wave BG: Drafts shortcut so the user can jump between
          // in-progress cards without going back to the Characters tab.
          // Badge shows the count INCLUDING the current draft so the
          // user has a sense of how many things they have open.
          if (isDraft && draftCount > 0)
            IconButton(
              icon: Badge.count(
                count: draftCount,
                isLabelVisible: draftCount > 1,
                child: const Icon(Icons.drafts_outlined),
              ),
              tooltip: 'Drafts',
              onPressed: _showDraftsSheet,
            ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save',
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                AvatarBubble(
                  dataUrl: _avatar,
                  fallback: name.text.isEmpty ? '?' : name.text,
                  radius: 44,
                  tappableLightbox: true,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.image_outlined, size: 14),
                      label: const Text('Change avatar'),
                      onPressed: _pickAndCropAvatar,
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _avatar != null && _avatar!.startsWith('data:')
                          ? _recropAvatar
                          : null,
                      child: const Text('Recrop'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Wave CM: live total of how heavy this card will be
                // in chat. Tracks the live form values via _composeFromForm
                // so the count updates as the user types (next rebuild).
                Builder(builder: (_) {
                  final tokens = approxTokensForCharacter(_composeFromForm());
                  final label = formatTokenCount(tokens);
                  if (label == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Card weight: $label',
                      style: const TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // ---- Identity ----
          // Wave BI: section sequence mirrors the AI Creator's Sheet
          // (_CanvasFieldsView.mainOrder) exactly — name first, then
          // description/scenario, then greeting fields, then the
          // listing-metadata cluster (tags, tagline, creator_notes),
          // and finally the Advanced collapsible. This way a user who
          // builds with the AI and then opens the manual editor sees
          // the same field flow they just lived through.
          _sectionHeader('Identity'),
          _LabeledField(label: 'Name', controller: name),

          // ---- Description & World ----
          _sectionHeader('Description & World'),
          _LabeledField(
              label: 'Description', controller: description, maxLines: 6),
          _LabeledField(label: 'Scenario', controller: scenario, maxLines: 4),

          // ---- Greeting ----
          // Wave BI: alternate greetings MOVED to Advanced to match
          // the Creator Sheet's grouping. Most cards have 0-1 greetings
          // and the field clutters the main flow.
          _sectionHeader('Greeting'),
          _LabeledField(
            label: 'First message',
            controller: firstMes,
            maxLines: 6,
          ),
          _LabeledField(
              label: 'Example dialogue', controller: mesExample, maxLines: 6),

          // ---- Card metadata ----
          // Wave BI: tags, tagline, creator_notes grouped together.
          // These three are what surface in card lists / discovery,
          // not in-character content. Order matches Creator Sheet.
          _sectionHeader('Card metadata'),
          _LabeledField(label: 'Tags (comma-separated)', controller: tagsCsv),
          _LabeledField(label: 'Tagline', controller: tagline),
          _LabeledField(
              label: 'Creator notes',
              controller: creatorNotes,
              maxLines: 4),

          // Wave CC: bind one or more lorebooks to this character so
          // they auto-activate in every chat she appears in (in
          // addition to anything the chat itself attaches). Imported
          // chara_card_v2 cards with an embedded character_book land
          // here after the user picks Extract & Link or Embedded only
          // at import time.
          const SizedBox(height: 16),
          LorebookBindingSection(
            selectedIds: _lorebookIds,
            onChanged: (next) => setState(() => _lorebookIds = next),
            sublabel:
                'These books inject in every chat with this character — '
                'on top of any books attached per-chat. Use this for '
                'world / setting context that travels with the character.',
          ),
          const SizedBox(height: 4),

          // Wave CY.18.128: native gallery — extra images beyond the avatar,
          // added via file picker → AttachmentStore (pyre:// refs, never
          // base64). "Use as avatar" repoints _avatar to the picked ref.
          GalleryEditorSection(
            gallery: _gallery,
            onChanged: (next) => setState(() => _gallery = next),
            onUseAsAvatar: (i) {
              if (i < 0 || i >= _gallery.length) return;
              setState(() => _avatar = _gallery[i]);
            },
          ),
          const SizedBox(height: 4),

          // ---- Advanced (collapsed by default) ----
          const SizedBox(height: 12),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text(
                'ADVANCED',
                style: TextStyle(
                  color: EmberColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              subtitle: const Text(
                'Personality (kept empty by spec), system prompts, '
                'alternate greetings, talkativeness, depth prompt, '
                'raw extensions.',
                style: TextStyle(
                    color: EmberColors.textMid, fontSize: 11, height: 1.4),
              ),
              children: [
                // Wave BE: personality kept in Advanced — chara_card_v2
                // spec concatenates description+personality at runtime,
                // and Pyre keeps everything in description, so this is
                // intentionally empty for AI-built cards. Manual users
                // who import an existing card may have legacy content
                // here — preserve it but don't surface in the main flow.
                _LabeledField(
                    label: 'Personality (legacy field — usually empty)',
                    controller: personality,
                    maxLines: 4),
                _LabeledField(
                    label: 'System prompt override',
                    controller: systemPrompt,
                    maxLines: 4),
                _LabeledField(
                    label: 'Post-history instructions',
                    controller: postHistory,
                    maxLines: 4),
                // Wave BI: alternate greetings moved here from main
                // Greeting section to mirror the Creator Sheet, where
                // it lives behind the same Advanced collapsible.
                _GreetingsEditor(
                  controllers: _greetingCtls,
                  onChanged: () => setState(() {}),
                ),
                _LabeledField(label: 'Creator', controller: creator),
                _LabeledField(
                    label: 'Character version', controller: characterVersion),
                // Wave BJ: Talkativeness slider, Depth prompt fields,
                // and Extensions raw-JSON were removed. Niche fields
                // that almost nobody used and that added a wall of
                // UI to the Advanced section. Values on imported
                // cards are still preserved through Save via
                // `Character.fromJson(_source().toJson())`.
              ],
            ),
          ),

          if (isOverride)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Edits here only affect this chat. They do not touch the global character.',
                style:
                    TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
            ),
        ],
      ),
      ),
    );
  }

  /// Wave BG: bottom sheet listing all saved drafts. Tap to switch into
  /// that draft (saves current first, then re-pushes the editor on the
  /// new draftId). Long-press to delete. Only available in draft mode.
  void _showDraftsSheet() {
    final store = context.read<AppStore>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) {
        final drafts = store.characterDrafts;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Drafts',
                    style: TextStyle(
                      color: EmberColors.textHigh,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'In-progress cards saved automatically as you type. '
                    'Tap to switch; long-press to delete.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: drafts.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: EmberColors.stroke),
                  itemBuilder: (_, i) {
                    final d = drafts[i];
                    final isCurrent = d.id == widget.draftId;
                    final title = d.name.trim().isEmpty
                        ? '(unnamed draft)'
                        : d.name;
                    return ListTile(
                      leading: Icon(
                        isCurrent
                            ? Icons.edit
                            : Icons.drafts_outlined,
                        color: isCurrent
                            ? EmberColors.primary
                            : EmberColors.textMid,
                      ),
                      title: Text(
                        title,
                        style: const TextStyle(
                            color: EmberColors.textHigh),
                      ),
                      subtitle: d.tagline != null && d.tagline!.isNotEmpty
                          ? Text(
                              d.tagline!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: EmberColors.textMid,
                                  fontSize: 11),
                            )
                          : null,
                      trailing: isCurrent
                          ? const Text(
                              'editing',
                              style: TextStyle(
                                color: EmberColors.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : null,
                      onTap: isCurrent
                          ? () => Navigator.pop(sheet)
                          : () {
                              Navigator.pop(sheet);
                              // Flush current draft, switch to the
                              // tapped one via pushReplacement.
                              final composed = _composeFromForm();
                              store.saveDraft(composed);
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => CharacterEditScreen(
                                    draftId: d.id,
                                  ),
                                ),
                              );
                            },
                      onLongPress: () {
                        Navigator.pop(sheet);
                        showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: EmberColors.bgPanel,
                            title: const Text('Delete draft?'),
                            content: Text(
                                'Permanently discard "$title"? '
                                'This cannot be undone.'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: EmberColors.danger,
                                ),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  store.removeDraft(d.id);
                                  // If user deleted the CURRENT draft,
                                  // pop the editor too — there's
                                  // nothing left to edit.
                                  if (isCurrent && mounted) {
                                    Navigator.of(context).pop();
                                  }
                                },
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              if (drafts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'No drafts yet.',
                    style: TextStyle(
                        color: EmberColors.textDim, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: EmberColors.primary,
            fontWeight: FontWeight.w700,
            fontSize: 11,
            letterSpacing: 1.2,
          ),
        ),
      );
}

class _LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;

  const _LabeledField({
    required this.label,
    required this.controller,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        minLines: 1,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}

/// Wave BE: alternate-greetings list editor for the manual editor. One
/// multi-line text field per greeting, with delete buttons per row and
/// an "Add greeting" button. Mirrors the dialog editor in the AI
/// Creator so users get the same UX whether they're building manually
/// or by AI handoff.
///
/// Lives inline (not in a dialog) because the manual editor is already
/// a scrollable form — wrapping greetings in a modal would break the
/// "edit everything in one page" feel that distinguishes manual mode.
class _GreetingsEditor extends StatelessWidget {
  final List<TextEditingController> controllers;
  /// Bubbled up to the parent so add/delete trigger setState there —
  /// rebuilds the form list. The parent owns the controllers; this
  /// widget only renders them.
  final VoidCallback onChanged;
  const _GreetingsEditor({
    required this.controllers,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              'Alternate greetings',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
              ),
            ),
          ),
          for (var i = 0; i < controllers.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 12),
                decoration: BoxDecoration(
                  color: EmberColors.bgDeep,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: EmberColors.stroke),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'GREETING ${i + 1}',
                            style: TextStyle(
                              color:
                                  EmberColors.primary.withValues(alpha: 0.8),
                              fontWeight: FontWeight.w700,
                              fontSize: 10,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          color: EmberColors.textMid,
                          tooltip: 'Remove this greeting',
                          onPressed: controllers.length > 1
                              ? () {
                                  controllers[i].dispose();
                                  controllers.removeAt(i);
                                  onChanged();
                                }
                              : null,
                        ),
                      ],
                    ),
                    TextField(
                      controller: controllers[i],
                      minLines: 3,
                      maxLines: 10,
                      style: const TextStyle(
                        color: EmberColors.textHigh,
                        fontSize: 13,
                        height: 1.4,
                      ),
                      decoration: const InputDecoration(
                        hintText: '*She glances up.* **"Back again?"**',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add greeting'),
              onPressed: () {
                controllers.add(TextEditingController());
                onChanged();
              },
            ),
          ),
        ],
      ),
    );
  }
}
