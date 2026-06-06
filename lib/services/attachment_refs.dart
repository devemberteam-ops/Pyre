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

/// SYNC W7 (attachment volume): given the attachment hashes a client
/// REFERENCES and the set the server already HAS, return only the ones the
/// server is MISSING. The push uploads exactly this set, so each blob transfers
/// at most once — never re-sending gigabytes of images the peer already holds.
/// Blank, whitespace, and path-unsafe hashes (containing `/` or `..`) are
/// dropped so a hostile/garbled hash can never reference a file outside the
/// content-addressed store.
Set<String> attachmentHashesMissing(
    Iterable<String> requested, Set<String> present) {
  final out = <String>{};
  for (final h in requested) {
    final clean = h.trim();
    if (clean.isEmpty || clean.contains('/') || clean.contains('..')) continue;
    if (!present.contains(clean)) out.add(clean);
  }
  return out;
}

/// SYNC (pull-side reconcile): the `pyre://attachment/<hash>` refs a freshly
/// applied character/persona record contributes to the blob fetch the puller
/// runs after a merge. Covers the displayed [avatar], the preserved UNCROPPED
/// [avatarOriginal] (non-destructive recrop — WITHOUT this a synced recrop's
/// full image renders broken when tapped, because the bytes never get pulled),
/// and every [gallery] image. Nulls and non-pyre URLs (inline `data:`, `http`)
/// are ignored; a ref shared between fields de-dupes via the returned `Set`.
///
/// Pure (no AppStore, no I/O) so the engine's pull reconcile delegates here and
/// the avatarOriginal coverage can't silently regress.
Set<String> incomingRecordAttachmentRefs({
  String? avatar,
  String? avatarOriginal,
  List<String> gallery = const [],
}) {
  final out = <String>{};
  void add(String? url) {
    if (url != null && AttachmentStore.isPyreUrl(url)) out.add(url);
  }

  add(avatar);
  add(avatarOriginal);
  for (final g in gallery) {
    add(g);
  }
  return out;
}

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
    // Non-destructive Recrop: keep the UNCROPPED original blob alive too —
    // both so the GC never frees it AND so the LAN sync attachment-push (which
    // uses this same set) ships it to paired devices. No-op when null.
    add(c.avatarOriginal);
    c.gallery.forEach(add);
  }
  for (final p in s.personas) {
    add(p.avatar);
    add(p.avatarOriginal);
    p.gallery.forEach(add);
  }
  // Wave CY.18.255 (FIX 2): include the resumable character DRAFTS. A draft
  // is a persisted Character whose avatar/gallery may already be a
  // `pyre://` ref (the manual editor externalises on attach). Skipping it
  // would let the GC free a blob an open draft still points at.
  for (final d in s.characterDrafts) {
    add(d.avatar);
    // Non-destructive Recrop: a draft can be recropped in the manual editor
    // too, so guard its preserved original from premature collection.
    add(d.avatarOriginal);
    d.gallery.forEach(add);
  }
  add(s.chatSettings.customBackgroundDataUrl);
  // Non-destructive Recrop: the BotBooru profile avatar is now externalised
  // to a `pyre://` ref on recrop, and keeps an uncropped original. Both are
  // added so neither blob is GC'd (and so the LAN sync push ships them). The
  // `add` helper ignores legacy inline `data:` profile avatars (no hash).
  add(s.botbooruAvatar);
  add(s.botbooruAvatarOriginal);
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
