// Persona editor — mirrors the HTML prototype's "Edit persona" modal:
// avatar (Change + Recrop) + name + tagline + description + "Set as default".

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/gallery_editor_section.dart';
import '../widgets/lorebook_binding_section.dart';
import 'avatar_crop_screen.dart';

class PersonaEditorSheet extends StatefulWidget {
  final Persona? existing;
  const PersonaEditorSheet({super.key, this.existing});

  @override
  State<PersonaEditorSheet> createState() => _PersonaEditorSheetState();
}

class _PersonaEditorSheetState extends State<PersonaEditorSheet> {
  late TextEditingController _name;
  late TextEditingController _tagline;
  late TextEditingController _desc;
  /// Wave CX.1: dialogue-examples editor — first-person dialogue / action
  /// samples in the user's voice. Persisted in Persona.dialogueExamples.
  late TextEditingController _dialogue;
  String? _avatar;
  bool _isDefault = false;
  /// Wave CC: bound lorebook ids, mutated by LorebookBindingSection.
  late List<String> _lorebookIds;
  /// Wave CY.18.128: gallery refs, mutated by GalleryEditorSection.
  late List<String> _gallery;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _name = TextEditingController(text: p?.name ?? 'You');
    _tagline = TextEditingController(text: p?.tagline ?? '');
    _desc = TextEditingController(text: p?.description ?? '');
    _dialogue =
        TextEditingController(text: p?.dialogueExamples ?? '');
    _avatar = p?.avatar;
    _lorebookIds = List<String>.from(p?.lorebookIds ?? const []);
    _gallery = List<String>.from(p?.gallery ?? const []);
    _isDefault = (p != null) &&
        p.id == context.read<AppStore>().activePersonaId;
  }

  @override
  void dispose() {
    _name.dispose();
    _tagline.dispose();
    _desc.dispose();
    _dialogue.dispose();
    super.dispose();
  }

  Future<void> _changeAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;
    if (!mounted) return;
    // Wave CQ: store full image; recrop is a separate explicit step.
    setState(() {
      _avatar = 'data:image/png;base64,${base64Encode(bytes)}';
    });
  }

  Future<void> _recrop() async {
    final url = _avatar;
    if (url == null || !url.startsWith('data:')) return;
    final comma = url.indexOf(',');
    if (comma < 0) return;
    try {
      final bytes = base64Decode(url.substring(comma + 1));
      final cropped = await cropAvatar(context, bytes);
      if (cropped == null) return;
      setState(() {
        _avatar = 'data:image/png;base64,${base64Encode(cropped)}';
      });
    } catch (_) {}
  }

  void _save() {
    final store = context.read<AppStore>();
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Persona persona;
    if (widget.existing == null) {
      persona = Persona(
        id: newId('persona'),
        name: name,
        tagline: _tagline.text.trim().isEmpty ? null : _tagline.text.trim(),
        description: _desc.text.trim(),
        dialogueExamples: _dialogue.text.trim(),
        avatar: _avatar,
        // Wave CC: persist the locally-edited binding list.
        lorebookIds: List<String>.from(_lorebookIds),
        // Wave CY.18.128: persist the locally-edited gallery refs.
        gallery: List<String>.from(_gallery),
      );
      store.addPersona(persona);
    } else {
      persona = widget.existing!
        ..name = name
        ..tagline = _tagline.text.trim().isEmpty ? null : _tagline.text.trim()
        ..description = _desc.text.trim()
        ..dialogueExamples = _dialogue.text.trim()
        ..avatar = _avatar
        // Wave CC: in-place update keeps the rest of the persona intact.
        ..lorebookIds = List<String>.from(_lorebookIds)
        // Wave CY.18.128: in-place update of the gallery refs.
        ..gallery = List<String>.from(_gallery);
      store.updatePersona(persona);
    }
    if (_isDefault) store.setActivePersona(persona.id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hasAvatar = _avatar != null && _avatar!.startsWith('data:');
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
            const SizedBox(height: 8),
            Text(
              widget.existing == null ? 'New persona' : 'Edit persona',
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                AvatarBubble(
                  dataUrl: _avatar,
                  fallback: _name.text.isEmpty ? '?' : _name.text,
                  radius: 32,
                  tappableLightbox: true,
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _changeAvatar,
                  child: const Text('Change avatar'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: hasAvatar ? _recrop : null,
                  child: const Text('Recrop'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tagline,
              decoration: const InputDecoration(
                labelText: 'Tagline',
                hintText: 'A short tagline shown in lists (one line)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              maxLines: 10,
              minLines: 4,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText:
                    'How the user appears in chats. Personality, looks, anything the model should know.',
              ),
            ),
            const SizedBox(height: 12),
            // Wave CX.1: dialogue examples land here as a standalone
            // field. When a character is "Added as persona" with a
            // mes_example, the bytes show up here pre-filled and
            // {{char}}↔{{user}} swapped, ready to be edited.
            TextField(
              controller: _dialogue,
              maxLines: 12,
              minLines: 4,
              decoration: const InputDecoration(
                labelText: 'Dialogue examples',
                hintText:
                    'Optional. First-person dialogue / action samples in the user\'s voice. `<START>` separator between exchanges, same shape as a chara_card_v2 mes_example.',
              ),
            ),
            const SizedBox(height: 16),
            // Wave CC: persona-side lorebook binding (mirrors the same
            // section on character editor). Same widget, same picker —
            // books bound here auto-activate when this persona is the
            // active user-side.
            LorebookBindingSection(
              selectedIds: _lorebookIds,
              onChanged: (next) => setState(() => _lorebookIds = next),
              sublabel:
                  'These books inject in every chat where this persona is '
                  'active — on top of the chat\'s own attachments and the '
                  'character\'s books.',
            ),
            const SizedBox(height: 4),
            // Wave CY.18.128: native gallery for personas (parity with
            // characters). "Use as avatar" repoints _avatar to the picked ref.
            GalleryEditorSection(
              gallery: _gallery,
              onChanged: (next) => setState(() => _gallery = next),
              onUseAsAvatar: (i) {
                if (i < 0 || i >= _gallery.length) return;
                setState(() => _avatar = _gallery[i]);
              },
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('Set as default persona'),
              value: _isDefault,
              activeColor: EmberColors.primary,
              contentPadding: EdgeInsets.zero,
              dense: true,
              onChanged: (v) => setState(() => _isDefault = v ?? false),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showPersonaEditor(BuildContext context, {Persona? existing}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: EmberColors.bgPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => PersonaEditorSheet(existing: existing),
  );
}
