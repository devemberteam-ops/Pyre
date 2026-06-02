// Wave CY.18.64: content-addressed attachment storage.
//
// Pre-Wave-64 every avatar / chat-background image lived inside the
// main JSON blob as a `data:image/...;base64,...` URL. This worked but:
//   1. Bloated the blob — a 200 KB avatar burns 270 KB as base64. With
//      a few dozen characters the JSON itself is mostly base64 noise.
//   2. Made delta sync (Phase 3 LAN) expensive — any tiny edit to a
//      Character had to round-trip the entire avatar payload.
//   3. Wrote-and-rewrote the same bytes for backups + atomic saves
//      every time anything in that record changed.
//
// Strategy: extract bytes to standalone files under
// `<app-docs>/EmberChat/attachments/<sha256>.bin` (mime sidecar at
// `.mime`), reference them in records as `pyre://attachment/<hash>`
// URLs. Hash-keyed = the same image used by 10 characters takes one
// disk slot. Wave 67 will add a server-side endpoint
// (`GET /attachments/<hash>`) that mirrors this for remote clients.
//
// On web/PWA this whole service is a no-op (kIsWeb returns null from
// every method). Web reads attachments via the LAN server's HTTP
// endpoint, never via local fs — see RemoteBackend in Wave 71.

import 'dart:convert' show base64Decode;
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'lan_client.dart';

class AttachmentStore {
  AttachmentStore._();

  /// URL scheme + path prefix Pyre uses to reference content-addressed
  /// attachments. Records that hold an attachment store the FULL URL
  /// (e.g. `pyre://attachment/abc123…`) as a String so legacy code
  /// paths that look for `startsWith('data:')` or `startsWith('http')`
  /// can also detect `startsWith('pyre://attachment/')` and route
  /// accordingly.
  static const String urlPrefix = 'pyre://attachment/';

  static Directory? _cachedDir;

  /// Resolves to `<app-docs>/EmberChat/attachments/`, creating it if
  /// missing. Cached on first call. Returns null on web (no fs).
  static Future<Directory?> _attachDir() async {
    if (kIsWeb) return null;
    if (_cachedDir != null) return _cachedDir;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/EmberChat/attachments');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cachedDir = dir;
    return dir;
  }

  /// Pre-warm the directory cache so synchronous code paths (image
  /// widgets that need to build a `FileImage` without awaiting) can
  /// resolve attachment files without an extra round-trip. Call once
  /// at app startup. Idempotent — safe to call repeatedly.
  static Future<void> warmUp() async {
    await _attachDir();
  }

  /// SYNCHRONOUS path resolution after `warmUp()` has run. Returns
  /// null if the cache isn't populated yet, the URL doesn't match
  /// the scheme, or the hash is empty. Does NOT verify the file
  /// exists on disk — image widgets handle missing files via
  /// `FileImage`'s onError builder.
  static File? fileForSync(String url) {
    if (kIsWeb) return null;
    if (!isPyreUrl(url)) return null;
    final dir = _cachedDir;
    if (dir == null) return null; // warmUp() hasn't completed yet
    final hash = url.substring(urlPrefix.length);
    if (hash.isEmpty) return null;
    return File('${dir.path}/$hash.bin');
  }

  /// Hash + write bytes (idempotent — re-storing the same content is a
  /// no-op). Returns the `pyre://attachment/<hash>` URL the caller
  /// should persist on the owning record. On web returns null —
  /// callers should keep using the original data URL until the
  /// RemoteBackend round-trips through `POST /attachments` in Wave 71.
  static Future<String?> store(Uint8List bytes, {String? mime}) async {
    if (kIsWeb) return null;
    if (bytes.isEmpty) return null;
    try {
      final hash = sha256.convert(bytes).toString();
      final dir = await _attachDir();
      if (dir == null) return null;
      final file = File('${dir.path}/$hash.bin');
      if (!await file.exists()) {
        await file.writeAsBytes(bytes, flush: true);
        if (mime != null && mime.isNotEmpty) {
          try {
            await File('${dir.path}/$hash.mime').writeAsString(mime);
          } catch (e) {
            debugPrint('[AttachmentStore] mime sidecar write failed: $e');
          }
        }
      }
      return '$urlPrefix$hash';
    } catch (e) {
      debugPrint('[AttachmentStore] store failed: $e');
      return null;
    }
  }

  /// Resolve a `pyre://attachment/<hash>` URL to the underlying File
  /// for use with Flutter's `FileImage`. Returns null on web, when
  /// the URL doesn't match the scheme, or when the backing file is
  /// missing (e.g. record was synced from another device that hasn't
  /// pushed the attachment yet).
  static Future<File?> fileFor(String url) async {
    if (kIsWeb) return null;
    if (!isPyreUrl(url)) return null;
    final hash = url.substring(urlPrefix.length);
    if (hash.isEmpty) return null;
    final dir = await _attachDir();
    if (dir == null) return null;
    final file = File('${dir.path}/$hash.bin');
    if (!await file.exists()) return null;
    return file;
  }

  /// Read raw bytes for a `pyre://attachment/<hash>` URL. Used by the
  /// PyreServer's `GET /attachments/<hash>` handler in Wave 67 and by
  /// migration code that needs to re-serialise an attachment.
  static Future<Uint8List?> readBytes(String url) async {
    final f = await fileFor(url);
    if (f == null) return null;
    try {
      return await f.readAsBytes();
    } catch (e) {
      debugPrint('[AttachmentStore] readBytes failed: $e');
      return null;
    }
  }

  /// Lookup recorded mime (best effort). Returns null if the sidecar
  /// was never written or the file is gone. Callers should fall back
  /// to inferring from the URL extension or magic bytes.
  static Future<String?> mimeFor(String url) async {
    if (!isPyreUrl(url)) return null;
    final hash = url.substring(urlPrefix.length);
    final dir = await _attachDir();
    if (dir == null) return null;
    try {
      final f = File('${dir.path}/$hash.mime');
      if (!await f.exists()) return null;
      return (await f.readAsString()).trim();
    } catch (e) {
      return null;
    }
  }

  /// Cheap structural check — doesn't touch disk.
  static bool isPyreUrl(String s) => s.startsWith(urlPrefix);

  /// Wave CY.18.255 (FIX 3): in-memory cache for attachment bytes fetched
  /// over HTTP on web. Keyed by sha256 hash. Web has no local fs, so the
  /// only way to materialise a `pyre://attachment/<hash>` blob is to pull
  /// it from the paired desktop server's `GET /attachments/<hash>`
  /// endpoint. Because attachments are content-addressed (the hash IS the
  /// bytes), this cache never goes stale — once fetched, a hash maps to the
  /// same bytes forever, so we keep it for the session to avoid refetching
  /// the same avatar on every rebuild. Never populated on native.
  static final Map<String, Uint8List> _webBytesCache = {};

  /// Wave CY.18.255 (FIX 3): WEB-ONLY fetch of a `pyre://attachment/<hash>`
  /// blob over HTTP from the paired server. Returns null on native (callers
  /// should read the local file instead), when not a pyre:// URL, when not
  /// paired, or on any network / non-200 failure. The desktop/phone server
  /// serves the bytes at `GET /attachments/<hash>` behind bearer auth — the
  /// same auth header RemoteBackend uses for /pull + /push. Results are
  /// cached in [_webBytesCache] by hash (content-addressed → never stale).
  static Future<Uint8List?> fetchWebBytes(String url) async {
    if (!kIsWeb) return null;
    if (!isPyreUrl(url)) return null;
    final hash = url.substring(urlPrefix.length);
    if (hash.isEmpty) return null;
    final cached = _webBytesCache[hash];
    if (cached != null) return cached;
    final client = LanClient.instance;
    final base = client.baseUrl;
    final bearer = client.bearerToken;
    if (base == null || bearer == null || bearer.isEmpty) return null;
    try {
      final resp = await http.get(
        Uri.parse('$base/attachments/$hash'),
        headers: {'authorization': 'Bearer $bearer'},
      );
      if (resp.statusCode != 200) {
        debugPrint(
            '[AttachmentStore] web fetch $hash → HTTP ${resp.statusCode}');
        return null;
      }
      final bytes = resp.bodyBytes;
      _webBytesCache[hash] = bytes;
      return bytes;
    } catch (e) {
      debugPrint('[AttachmentStore] web fetch failed for $hash: $e');
      return null;
    }
  }

  /// Wave CY.18.255 (FIX 3): WEB-ONLY — resolve a `pyre://attachment/<hash>`
  /// ref to the `(httpUrl, authHeaders)` pair for the paired server's
  /// `GET /attachments/<hash>` endpoint. The synchronous lightbox decoder
  /// can't await an HTTP fetch, so it wraps these in a `NetworkImage`
  /// (which loads asynchronously inside the ImageProvider). Returns null
  /// on native, when not a pyre:// URL, when the hash is empty, or when
  /// not paired. Kept here (not in the lightbox) so the LanClient + scheme
  /// knowledge stays in this low-level layer.
  static ({String url, Map<String, String> headers})? webAttachmentRequest(
      String url) {
    if (!kIsWeb) return null;
    if (!isPyreUrl(url)) return null;
    final hash = url.substring(urlPrefix.length);
    if (hash.isEmpty) return null;
    final client = LanClient.instance;
    final base = client.baseUrl;
    final bearer = client.bearerToken;
    if (base == null || bearer == null || bearer.isEmpty) return null;
    return (
      url: '$base/attachments/$hash',
      headers: {'authorization': 'Bearer $bearer'},
    );
  }

  /// Wave CY.18.72: orphan GC. Walks every file in the attachment
  /// dir; any whose sha256 (the filename minus extension) is NOT in
  /// the supplied `referenced` set gets deleted. Caller is
  /// responsible for collecting the reference set by scanning all
  /// synced records' avatar / image fields for `pyre://attachment/`
  /// URLs. Returns the number of files freed.
  ///
  /// Best-effort: individual delete failures are swallowed (logged).
  /// Skip the `.mime` sidecar — it gets removed alongside its `.bin`.
  /// Skip files that don't match the `<64-hex>.bin` naming pattern
  /// (defensive — never delete something we didn't write).
  static Future<int> gcOrphans(Set<String> referenced) async {
    if (kIsWeb) return 0;
    final dir = await _attachDir();
    if (dir == null) return 0;
    final hashRe = RegExp(r'^([0-9a-f]{64})\.bin$');
    var removed = 0;
    try {
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final match = hashRe.firstMatch(name);
        if (match == null) continue;
        final hash = match.group(1)!;
        if (referenced.contains(hash)) continue;
        try {
          await entry.delete();
          // Best-effort delete of the mime sidecar too.
          final mime = File('${dir.path}/$hash.mime');
          if (await mime.exists()) {
            try {
              await mime.delete();
            } catch (_) {}
          }
          removed++;
        } catch (e) {
          debugPrint('[AttachmentStore] gc could not remove $name: $e');
        }
      }
    } catch (e) {
      debugPrint('[AttachmentStore] gc scan failed: $e');
    }
    return removed;
  }

  /// Approximate on-disk size of every attachment file. Used by the
  /// Storage screen and by Wave 72's GC.
  static Future<int> approximateSize() async {
    if (kIsWeb) return 0;
    final dir = await _attachDir();
    if (dir == null) return 0;
    var total = 0;
    try {
      await for (final entry in dir.list()) {
        if (entry is File) {
          try {
            total += await entry.length();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[AttachmentStore] approximateSize scan failed: $e');
    }
    return total;
  }
}

/// Wave CY.18.145: resolve a Character/Persona `avatar` field to raw image
/// bytes — the SINGLE source of truth for "I have an avatar string, give me
/// the bytes". Handles BOTH the migrated `pyre://attachment/<hash>` ref (the
/// normal case after the Wave CY.18.64 migration) AND a legacy / web
/// `data:...;base64,<payload>` URL (or a bare `<base64>` / `,<base64>`).
///
/// Before this helper, the card-export paths (`_exportCharacterAsPng`,
/// `_encodeCharacterToTempPng`) decoded the avatar with a naive
/// `substring(indexOf(',') + 1)` + `base64Decode`, which THREW
/// "invalid avatar data" on a `pyre://` ref — i.e. exporting / uploading a
/// saved card was silently broken for every character whose avatar had been
/// externalised to an attachment. Async because the attachment store reads
/// from disk. Returns null when empty / unreadable.
Future<Uint8List?> resolveAvatarBytes(String? avatar) async {
  if (avatar == null || avatar.isEmpty) return null;
  if (AttachmentStore.isPyreUrl(avatar)) {
    // Wave CY.18.255 (FIX 3): web has no local AttachmentStore, so a
    // `pyre://attachment/<hash>` ref can't be read off disk. Pull the
    // bytes from the paired desktop server's `GET /attachments/<hash>`
    // endpoint instead (bearer-auth, in-memory cached by hash). Native
    // is unchanged — `readBytes` reads the local file as before.
    if (kIsWeb) {
      return AttachmentStore.fetchWebBytes(avatar);
    }
    return AttachmentStore.readBytes(avatar);
  }
  // data: URL → strip the `...,` prefix; a bare base64 string has no comma.
  final commaIdx = avatar.indexOf(',');
  final b64 = commaIdx >= 0 ? avatar.substring(commaIdx + 1) : avatar;
  try {
    return base64Decode(b64);
  } catch (_) {
    return null;
  }
}
