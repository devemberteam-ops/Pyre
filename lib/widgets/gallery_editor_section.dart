// Wave CY.18.128: reusable native gallery editor section.
//
// Used by both the character editor (`character_edit_screen.dart`) and the
// persona editor (`persona_editor.dart`). Renders the current gallery as a
// thumbnail grid + an "+ Add image" file-picker flow that stores bytes via the
// content-addressed `AttachmentStore` (a `pyre://attachment/<sha256>` ref is
// appended — NEVER inline base64). Per-thumb: remove and "Use as avatar".
//
// On web (`kIsWeb`) the section is read-only — `AttachmentStore.store` returns
// null there, and inlining gallery bytes as data URLs would bloat the synced
// JSON (the exact thing AttachmentStore exists to avoid). So on web we hide the
// Add button and show a short note; existing refs synced from a desktop still
// render via the avatar resolution path's web handling (broken-image fallback
// until the bytes arrive).

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/attachment_store.dart';
import '../theme.dart';

/// A labelled "Gallery" section with a thumbnail grid + add/remove/
/// use-as-avatar affordances. Stateless in the sense that the owning editor
/// holds the canonical `gallery` list and rebuilds it from `onChanged`.
class GalleryEditorSection extends StatefulWidget {
  /// Current ordered list of `pyre://attachment/<hash>` refs.
  final List<String> gallery;

  /// Called with a NEW list whenever the gallery changes (add / remove).
  /// The owning editor stores it and rebuilds.
  final void Function(List<String>) onChanged;

  /// Optional — when provided, each thumbnail offers a "Use as avatar"
  /// action that calls this with the tapped index. The caller repoints
  /// the avatar to `gallery[index]` (a ref copy, never new bytes).
  final void Function(int index)? onUseAsAvatar;

  const GalleryEditorSection({
    super.key,
    required this.gallery,
    required this.onChanged,
    this.onUseAsAvatar,
  });

  @override
  State<GalleryEditorSection> createState() => _GalleryEditorSectionState();
}

class _GalleryEditorSectionState extends State<GalleryEditorSection> {
  bool _adding = false;

  Future<void> _addImage() async {
    if (kIsWeb || _adding) return;
    setState(() => _adding = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) return;
      // Best-effort mime from the picked extension; AttachmentStore keeps a
      // sidecar so the bytes can be served with the right content-type later.
      final ext = (file.extension ?? '').toLowerCase();
      final mime = ext.isEmpty ? 'image/png' : 'image/$ext';
      final ref = await AttachmentStore.store(bytes, mime: mime);
      // Web (or a store failure) → ref is null. NEVER inline bytes as base64
      // into the gallery list; just bail.
      if (ref == null) return;
      if (!mounted) return;
      widget.onChanged([...widget.gallery, ref]);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _remove(int index) {
    if (index < 0 || index >= widget.gallery.length) return;
    final next = [...widget.gallery]..removeAt(index);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final gallery = widget.gallery;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
          child: Text(
            'GALLERY',
            style: const TextStyle(
              color: EmberColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Extra images beyond the avatar. Tap a thumbnail for options.',
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
        if (gallery.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'No gallery images yet.',
              style: TextStyle(color: EmberColors.textDim, fontSize: 13),
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < gallery.length; i++)
                _GalleryThumb(
                  ref: gallery[i],
                  index: i,
                  onRemove: () => _remove(i),
                  onUseAsAvatar: widget.onUseAsAvatar == null
                      ? null
                      : () => widget.onUseAsAvatar!(i),
                ),
            ],
          ),
        if (kIsWeb)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Add gallery images on desktop or mobile.',
              style: TextStyle(color: EmberColors.textDim, fontSize: 12),
            ),
          )
        else
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: _adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('Add image'),
              onPressed: _adding ? null : _addImage,
            ),
          ),
      ],
    );
  }
}

/// A single gallery thumbnail. Renders the `pyre://` ref via the same
/// `AttachmentStore.fileForSync` resolution the avatar uses, with a
/// broken-image fallback on miss. Tap opens a small action sheet
/// (remove + optional use-as-avatar).
class _GalleryThumb extends StatelessWidget {
  final String ref;
  final int index;
  final VoidCallback onRemove;
  final VoidCallback? onUseAsAvatar;

  const _GalleryThumb({
    required this.ref,
    required this.index,
    required this.onRemove,
    this.onUseAsAvatar,
  });

  ImageProvider? _resolve() {
    if (kIsWeb) return null;
    final f = AttachmentStore.fileForSync(ref);
    if (f == null) return null;
    return FileImage(f);
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onUseAsAvatar != null)
              ListTile(
                leading: const Icon(Icons.account_circle_outlined,
                    color: EmberColors.textMid),
                title: const Text('Use as avatar'),
                onTap: () {
                  Navigator.pop(sheet);
                  onUseAsAvatar!();
                },
              ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: EmberColors.danger),
              title: const Text('Remove from gallery'),
              onTap: () {
                Navigator.pop(sheet);
                onRemove();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _resolve();
    const double size = 84;
    return GestureDetector(
      onTap: () => _showActions(context),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: EmberColors.bgDeep,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: EmberColors.stroke),
          image: image == null
              ? null
              : DecorationImage(image: image, fit: BoxFit.cover),
        ),
        child: image == null
            ? const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: EmberColors.textDim,
                  size: 28,
                ),
              )
            : null,
      ),
    );
  }
}
