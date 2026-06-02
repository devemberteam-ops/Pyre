import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/gallery_strip.dart';
import '../widgets/lorebook_binding_section.dart';
import 'character_assistant_screen.dart';
import 'character_edit_screen.dart';
import 'chat_picker_screens.dart';
import 'persona_editor.dart';

/// A single read-only labelled field shown in a details sheet.
class _DetailField {
  final String label;
  final String content;
  const _DetailField(this.label, this.content);
}

/// Shared body for the character + persona details sheets. Both render an
/// avatar + name (+ tagline) header, a primary action row, the read-only
/// field sections, a [GalleryStrip] (below the fields), and any bound
/// lorebooks. The persona variant calls this with [showStartChat] = false
/// (personas aren't chat targets) and its own [onEdit] (the persona editor).
///
/// Wave CY.18.129: factored out of the character sheet so the persona
/// details view is true parity, not a near-copy.
class _DetailsSheetBody extends StatelessWidget {
  final String? avatar;
  final String name;
  final String? tagline;
  final List<_DetailField> fields;

  /// Gallery refs (`pyre://attachment/<hash>`). Empty → the strip hides.
  final List<String> gallery;

  /// Bound lorebook ids (read-only here). Empty → the section hides.
  final List<String> lorebookIds;

  /// Primary button. Character: "Start chat". Persona: hidden.
  final bool showStartChat;
  final VoidCallback? onStartChat;
  final String startChatLabel;

  final String editLabel;
  final VoidCallback onEdit;

  /// When non-null, gallery thumbnails offer "Use as avatar" → repoint the
  /// owning record's avatar to `gallery[index]` (ref copy, no new bytes).
  final void Function(int index)? onUseAsAvatar;

  const _DetailsSheetBody({
    required this.avatar,
    required this.name,
    required this.tagline,
    required this.fields,
    required this.gallery,
    required this.lorebookIds,
    required this.showStartChat,
    required this.onStartChat,
    required this.startChatLabel,
    required this.editLabel,
    required this.onEdit,
    required this.onUseAsAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scroll) => Container(
        color: EmberColors.bgPanel,
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const Center(
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
            const SizedBox(height: 16),
            Center(
              child: AvatarBubble(
                dataUrl: avatar,
                fallback: name,
                radius: 56,
                tappableLightbox: true,
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                name,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700),
              ),
            ),
            if (tagline != null && tagline!.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    tagline!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: EmberColors.textMid, fontSize: 14),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (showStartChat) ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline, size: 16),
                      label: Text(startChatLabel),
                      onPressed: onStartChat,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(editLabel),
                    onPressed: onEdit,
                  ),
                ] else
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: Text(editLabel),
                      onPressed: onEdit,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // Wave CY.18.155: gallery strip near the TOP — right under the
            // avatar/name/buttons header and BEFORE the text fields — so the
            // extra art sits next to the profile image instead of buried at
            // the bottom (Gui's request). Shared body → applies to BOTH
            // characters and personas. Read-only; tap a thumb for the
            // swipeable fullscreen viewer (avatar first). "Use as avatar"
            // repoints the ref via the caller. Self-hides when the gallery
            // is empty (SizedBox.shrink → no extra gap above the fields).
            GalleryStrip(
              refs: gallery,
              avatarRef: avatar,
              onUseAsAvatar: onUseAsAvatar,
              ownerName: name,
            ),
            for (final f in fields) _section(f.label, f.content),
            // Surface bound lorebooks so the user can SEE that an imported
            // card brought a lorebook along — editable via the Edit button.
            if (lorebookIds.isNotEmpty) ...[
              const SizedBox(height: 18),
              LorebookBindingSection(
                selectedIds: lorebookIds,
                onChanged: null,
                sublabel: 'Auto-activate in every chat. '
                    'Tap Edit at the top to add or remove bindings.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _section(String label, String content) {
    if (content.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: EmberColors.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            content,
            style: const TextStyle(
              color: EmberColors.textHigh,
              height: 1.4,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

/// Sheet that shows the full chara_card_v2 fields read-only, with an
/// always-visible pencil that jumps into the editor. Mirrors the View
/// Details modal from the HTML prototype.
class CharacterDetailsSheet extends StatelessWidget {
  final String characterId;
  final String? chatId; // when set → edits target the per-chat snapshot
  const CharacterDetailsSheet({
    super.key,
    required this.characterId,
    this.chatId,
  });

  Character? _resolve(AppStore store) {
    if (chatId != null) {
      final chat = store.chats.firstWhere(
        (c) => c.id == chatId,
        orElse: () => Chat(id: 'noop', characterIds: const []),
      );
      final snap = chat.characterSnapshots[characterId];
      if (snap != null) return snap;
    }
    return store.characterById(characterId);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final c = _resolve(store);
    if (c == null) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Character not found.'),
        ),
      );
    }
    return _DetailsSheetBody(
      avatar: c.avatar,
      name: c.name,
      tagline: c.tagline,
      gallery: c.gallery,
      lorebookIds: c.lorebookIds,
      showStartChat: true,
      startChatLabel: chatId == null ? 'Start chat' : 'Back to chat',
      onStartChat: () {
        Navigator.of(context).pop();
        if (chatId == null) {
          startNewChatWithPersonaPrompt(context, c);
        }
      },
      editLabel: chatId == null ? 'Edit' : 'Edit (this chat)',
      onEdit: () => _onEditPressed(context, c),
      // Per-chat snapshots aren't a great target for repointing the avatar
      // (the edit would be ephemeral) — only offer use-as-avatar on the
      // global character.
      onUseAsAvatar: chatId != null
          ? null
          : (i) {
              if (i < 0 || i >= c.gallery.length) return;
              c.avatar = c.gallery[i];
              store.updateCharacter(c);
            },
      fields: [
        _DetailField('Description', c.description),
        _DetailField('Personality', c.personality),
        _DetailField('Scenario', c.scenario),
        _DetailField('First message', c.firstMes),
        if (c.alternateGreetings.isNotEmpty)
          _DetailField(
            'Alternate greetings',
            c.alternateGreetings.join('\n\n— — —\n\n'),
          ),
        _DetailField('Example dialogue', c.mesExample),
        _DetailField('System prompt', c.systemPrompt),
        _DetailField('Post-history instructions', c.postHistoryInstructions),
        if (c.tags.isNotEmpty) _DetailField('Tags', c.tags.join(', ')),
        _DetailField('Creator', c.creator),
        _DetailField('Version', c.characterVersion),
      ],
    );
  }

  /// Wave CS: when the user taps "Edit" on a global character, offer
  /// the two flows — AI-assisted (opens Creator with the sheet pre-loaded)
  /// or manual (the classic edit form). Per-chat edits skip the chooser
  /// since the AI assistant doesn't track per-chat snapshots — those go
  /// straight to the manual form like before.
  void _onEditPressed(BuildContext context, Character c) {
    if (chatId != null) {
      Navigator.of(context).pop();
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CharacterEditScreen(
          characterId: c.id,
          overrideChatId: chatId,
        ),
      ));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const Center(
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
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Edit this character',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.auto_awesome,
                  color: EmberColors.primary),
              title: const Text('Edit with AI'),
              subtitle: const Text(
                'Open the Character Creator with this sheet pre-loaded — '
                'chat with the assistant to make big or small changes.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CharacterAssistantScreen(
                    editingCharacterId: c.id,
                  ),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit manually'),
              subtitle: const Text(
                'Open the classic form to tweak fields directly.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CharacterEditScreen(
                    characterId: c.id,
                    overrideChatId: chatId,
                  ),
                ));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

Future<void> showCharacterDetailsSheet(
  BuildContext context, {
  required String characterId,
  String? chatId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) =>
        CharacterDetailsSheet(characterId: characterId, chatId: chatId),
  );
}

/// Wave CY.18.129: persona details view — parity with the character sheet
/// (avatar + name + description fields + gallery strip) minus "Start chat"
/// (personas aren't chat targets). Edit opens the persona editor.
class PersonaDetailsSheet extends StatelessWidget {
  final String personaId;
  const PersonaDetailsSheet({super.key, required this.personaId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    Persona? p;
    for (final x in store.personas) {
      if (x.id == personaId) {
        p = x;
        break;
      }
    }
    if (p == null) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Persona not found.'),
        ),
      );
    }
    final persona = p;
    return _DetailsSheetBody(
      avatar: persona.avatar,
      name: persona.name,
      tagline: persona.tagline,
      gallery: persona.gallery,
      lorebookIds: persona.lorebookIds,
      showStartChat: false,
      startChatLabel: '',
      onStartChat: null,
      editLabel: 'Edit',
      onEdit: () => _onPersonaEditPressed(context, persona),
      onUseAsAvatar: (i) {
        if (i < 0 || i >= persona.gallery.length) return;
        persona.avatar = persona.gallery[i];
        store.updatePersona(persona);
      },
      fields: [
        _DetailField('Description', persona.description),
        _DetailField('Dialogue examples', persona.dialogueExamples),
      ],
    );
  }

  /// Persona Creator: "Edit" on a persona offers two flows — AI-assisted
  /// (opens the Creator in persona mode with this persona pre-loaded) or
  /// manual (the classic persona form). Mirrors the character edit
  /// chooser in `CharacterDetailsSheet._onEditPressed`.
  void _onPersonaEditPressed(BuildContext context, Persona p) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const Center(
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
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Edit this persona',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.auto_awesome,
                  color: EmberColors.primary),
              title: const Text('Edit with AI'),
              subtitle: const Text(
                'Open the Creator with this persona pre-loaded — chat with '
                'the assistant to make changes.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      CharacterAssistantScreen(editingPersonaId: p.id),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit manually'),
              subtitle: const Text(
                'Open the classic form to tweak fields directly.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context).pop();
                showPersonaEditor(context, existing: p);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

Future<void> showPersonaDetailsSheet(
  BuildContext context, {
  required String personaId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => PersonaDetailsSheet(personaId: personaId),
  );
}
