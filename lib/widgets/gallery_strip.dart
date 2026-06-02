// Wave CY.18.129: read-only gallery thumbnail strip + swipeable lightbox.
//
// Used by the character + persona DETAILS sheets (the read-only counterpart
// to `gallery_editor_section.dart`'s editing grid). Renders the gallery's
// `pyre://attachment/<hash>` refs as a horizontal thumbnail row using the
// SAME resolution path the avatar uses (`AttachmentStore.fileForSync` →
// `FileImage`, with a broken-image fallback). Tapping a thumbnail opens a
// fullscreen, swipeable viewer across `[avatarRef, ...refs]` (avatar first
// when provided) — each page reuses `Lightbox.resolveImage` /
// `Lightbox.imageWidget` so there's a single source of truth for `pyre://`
// rendering.
//
// When `onUseAsAvatar` is provided, each thumbnail offers a "Use as avatar"
// affordance (long-press / tap-and-hold menu) that calls back with the
// gallery index; the caller repoints the avatar ref (never copies bytes).

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/attachment_store.dart';
import '../services/image_export.dart';
import '../theme.dart';
import 'lightbox.dart';

class GalleryStrip extends StatelessWidget {
  /// Ordered list of `pyre://attachment/<hash>` refs (the gallery).
  final List<String> refs;

  /// Optional avatar ref. When non-null it leads the fullscreen swipe
  /// order (`[avatarRef, ...refs]`) so the viewer feels like "the whole
  /// album, avatar first". Not shown as its own thumbnail in the strip
  /// (the details sheet already shows the avatar above).
  final String? avatarRef;

  /// When provided, each thumbnail offers a "Use as avatar" action that
  /// calls this with the tapped gallery index. The caller repoints the
  /// owning record's avatar to `refs[index]` (a ref copy, never bytes).
  final void Function(int index)? onUseAsAvatar;

  /// Wave CY.18.250: owner name (character / persona) used to label saved
  /// gallery images in the fullscreen viewer's Save action — e.g.
  /// `<ownerName>_gallery_<n>.png`. Falls back to "gallery" when empty.
  final String ownerName;

  const GalleryStrip({
    super.key,
    required this.refs,
    this.avatarRef,
    this.onUseAsAvatar,
    this.ownerName = '',
  });

  @override
  Widget build(BuildContext context) {
    if (refs.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 14, bottom: 8),
          child: Text(
            'GALLERY',
            style: TextStyle(
              color: EmberColors.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: refs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _Thumb(
              ref: refs[i],
              onTap: () => _openViewer(context, galleryIndex: i),
              onUseAsAvatar:
                  onUseAsAvatar == null ? null : () => onUseAsAvatar!(i),
            ),
          ),
        ),
      ],
    );
  }

  /// Build the full swipe order (avatar first if present) and open the
  /// viewer at the page that corresponds to the tapped gallery index.
  void _openViewer(BuildContext context, {required int galleryIndex}) {
    final hasAvatar = (avatarRef != null && avatarRef!.isNotEmpty);
    final order = <String>[
      if (hasAvatar) avatarRef!,
      ...refs,
    ];
    final avatarOffset = hasAvatar ? 1 : 0;
    final initial = avatarOffset + galleryIndex;
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _GallerySwipeViewer(
        refs: order,
        initialIndex: initial,
        // The first `avatarOffset` pages are the avatar; gallery image N
        // (1-based) is at page `avatarOffset + (N - 1)`. The viewer uses
        // this to name a saved gallery image `<owner>_gallery_<N>.png`.
        galleryStartIndex: avatarOffset,
        ownerName: ownerName,
      ),
    ));
  }
}

/// A single read-only gallery thumbnail. Resolves the `pyre://` ref via the
/// same `AttachmentStore.fileForSync` path the avatar uses; missing/web →
/// broken-image glyph. Tap opens the viewer; long-press (when wired) offers
/// "Use as avatar".
class _Thumb extends StatelessWidget {
  final String ref;
  final VoidCallback onTap;
  final VoidCallback? onUseAsAvatar;

  const _Thumb({
    required this.ref,
    required this.onTap,
    this.onUseAsAvatar,
  });

  ImageProvider? _resolve() {
    if (kIsWeb) return null;
    final f = AttachmentStore.fileForSync(ref);
    if (f == null) return null;
    return FileImage(f);
  }

  void _showActions(BuildContext context) {
    final useAsAvatar = onUseAsAvatar;
    if (useAsAvatar == null) return;
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
            ListTile(
              leading: const Icon(Icons.fullscreen,
                  color: EmberColors.textMid),
              title: const Text('View fullscreen'),
              onTap: () {
                Navigator.pop(sheet);
                onTap();
              },
            ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined,
                  color: EmberColors.textMid),
              title: const Text('Use as avatar'),
              onTap: () {
                Navigator.pop(sheet);
                useAsAvatar();
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
      onTap: onTap,
      onLongPress:
          onUseAsAvatar == null ? null : () => _showActions(context),
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

/// Fullscreen swipeable viewer over a list of refs. Each page reuses
/// `Lightbox.resolveImage` + `Lightbox.imageWidget` so the `pyre://` /
/// `data:` / `http` / base64 handling (and the broken-image fallback) is
/// the single source of truth shared with the single-image `Lightbox`.
class _GallerySwipeViewer extends StatefulWidget {
  final List<String> refs;
  final int initialIndex;

  /// Page index at which the gallery images start (0 when there's no
  /// leading avatar, 1 when the avatar leads the swipe order). Used to
  /// compute the 1-based gallery number for the Save filename.
  final int galleryStartIndex;

  /// Owner (character / persona) name used in the saved-image filename.
  final String ownerName;

  const _GallerySwipeViewer({
    required this.refs,
    required this.initialIndex,
    this.galleryStartIndex = 0,
    this.ownerName = '',
  });

  @override
  State<_GallerySwipeViewer> createState() => _GallerySwipeViewerState();
}

class _GallerySwipeViewerState extends State<_GallerySwipeViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.refs.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Resolve the current page's ref to bytes and save it to PyreExports
  /// via the shared helper. The avatar pages (before [galleryStartIndex])
  /// save as `<owner>_avatar.png`; gallery pages as `<owner>_gallery_<N>.png`.
  Future<void> _saveCurrent() async {
    final messenger = ScaffoldMessenger.of(context);
    final ref = widget.refs[_index];
    final bytes = await resolveAvatarBytes(ref);
    if (!mounted) return;
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't load this image to save.")),
      );
      return;
    }
    final safeOwner = widget.ownerName
        .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
        .trim()
        .replaceAll(' ', '_');
    final owner = safeOwner.isEmpty ? 'image' : safeOwner;
    final isAvatarPage = _index < widget.galleryStartIndex;
    final filename = isAvatarPage
        ? '${owner}_avatar.png'
        : '${owner}_gallery_${_index - widget.galleryStartIndex + 1}.png';
    await saveImageBytesToExports(
      context,
      bytes,
      filename,
      shareSubject: widget.ownerName.isEmpty
          ? 'Image from Pyre'
          : '${widget.ownerName} — image from Pyre',
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.refs.length;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.96),
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: count,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) {
                final img = Lightbox.resolveImage(widget.refs[i]);
                final content = img == null
                    ? const Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: Colors.white54, size: 72),
                      )
                    : InteractiveViewer(
                        minScale: 1,
                        maxScale: 5,
                        child: Center(child: Lightbox.imageWidget(img)),
                      );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  child: content,
                );
              },
            ),
            if (count > 1)
              Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    '${_index + 1} / $count',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Save image',
                    icon: const Icon(Icons.download, color: Colors.white),
                    onPressed: _saveCurrent,
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
