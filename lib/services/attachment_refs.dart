// Wave CY.18.127: the single source of truth for "which attachment blobs
// are still referenced by some record". Both GC triggers — the desktop LAN
// server's `start()` (PyreServer._runAttachmentGc) and the once-per-launch
// local sweep in AppStore.load() — call `collectReferencedAttachmentHashes`
// so they can never drift apart. The union covers EVERY surface that holds a
// `pyre://attachment/<hash>` ref: each character's avatar + gallery, each
// persona's avatar + gallery, and the custom chat background. Anything whose
// hash is NOT in this set is an orphan that `AttachmentStore.gcOrphans` frees.

import '../state/app_store.dart';
import 'attachment_store.dart';

/// Extract the `<sha256>` hash from a `pyre://attachment/<hash>` URL, or
/// `null` if [url] is null or isn't a pyre attachment ref (e.g. a legacy
/// inline `data:` URL, an http URL, or empty).
String? hashFromPyreUrl(String? url) =>
    (url != null && url.startsWith(AttachmentStore.urlPrefix))
        ? url.substring(AttachmentStore.urlPrefix.length)
        : null;

/// Union of every attachment hash referenced anywhere in the store. The GC
/// keeps a `.bin` alive as long as its hash is in this set, so a blob shared
/// by (say) a character's gallery AND a persona's avatar survives until the
/// LAST referrer drops it — hence dedup via a `Set` is the whole point.
Set<String> collectReferencedAttachmentHashes(AppStore s) {
  final out = <String>{};
  void add(String? url) {
    final h = hashFromPyreUrl(url);
    if (h != null) out.add(h);
  }

  for (final c in s.characters) {
    add(c.avatar);
    c.gallery.forEach(add);
  }
  for (final p in s.personas) {
    add(p.avatar);
    p.gallery.forEach(add);
  }
  // Wave CY.18.255 (FIX 2): include the resumable character DRAFTS. A draft
  // is a persisted Character whose avatar/gallery may already be a
  // `pyre://` ref (the manual editor externalises on attach). Skipping it
  // would let the GC free a blob an open draft still points at.
  for (final d in s.characterDrafts) {
    add(d.avatar);
    d.gallery.forEach(add);
  }
  add(s.chatSettings.customBackgroundDataUrl);
  // Wave CY.18.255 (FIX 2): include each chat's PER-CHAT custom background
  // override (models.dart Chat.customBackgroundDataUrl) in addition to the
  // GLOBAL chatSettings background above. Today both are still inline
  // `data:` URLs, but if a per-chat background ever becomes a `pyre://`
  // ref this guards it from premature collection. `hashFromPyreUrl`
  // ignores non-pyre URLs, so adding these is a no-op while still inline.
  for (final c in s.chats) {
    add(c.customBackgroundDataUrl);
  }
  return out;
}
