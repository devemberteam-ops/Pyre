// Wave CY.18.64: one-shot migration that extracts inline `data:image/`
// URLs from synced records into the AttachmentStore.
//
// Strategy:
//   1. Walk every record that can hold an avatar/image (Character +
//      Persona + ChatSettings background).
//   2. For each inline data URL: decode bytes → hash + write to the
//      attachment store → replace the record's URL with `pyre://`.
//   3. Set `prefs['attachments.migrated'] = true` ONLY if EVERY scanned
//      data URL was successfully externalised. Otherwise the flag stays
//      unset and the migration re-runs on next launch — letting a
//      crash mid-pass resume cleanly.
//   4. Records that get migrated have their `mtime` bumped, so the next
//      LAN sync pushes the new URL form to the other devices.
//
// Web/PWA: skipped entirely (AttachmentStore.store returns null on
// web; the data URLs stay inline and the RemoteBackend in Wave 71
// uploads them through `POST /attachments` on demand).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_store.dart';
import 'attachment_store.dart';

class AttachmentMigration {
  AttachmentMigration._();

  static const String _prefKey = 'attachments.migrated.v1';

  /// Run the migration if not already complete. Idempotent: safe to
  /// call on every load. Returns true if any record was modified
  /// (caller decides whether to persist + notifyListeners).
  static Future<bool> runIfNeeded(AppStore store) async {
    if (kIsWeb) return false;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefKey) ?? false) return false;

    var anyMigrated = false;
    var anyRemainingInline = false;
    final now = DateTime.now().millisecondsSinceEpoch;

    Future<String?> migrate(String? maybeUrl) async {
      if (maybeUrl == null) return null;
      if (!maybeUrl.startsWith('data:')) return null; // already external
      final bytes = _decodeDataUrl(maybeUrl);
      if (bytes == null) {
        anyRemainingInline = true;
        return null;
      }
      final mime = _mimeFromDataUrl(maybeUrl);
      final newUrl = await AttachmentStore.store(bytes, mime: mime);
      if (newUrl == null) {
        anyRemainingInline = true;
        return null;
      }
      return newUrl;
    }

    for (final c in store.characters) {
      final next = await migrate(c.avatar);
      if (next != null) {
        c.avatar = next;
        c.mtime = now;
        anyMigrated = true;
      }
    }
    for (final p in store.personas) {
      final next = await migrate(p.avatar);
      if (next != null) {
        p.avatar = next;
        p.mtime = now;
        anyMigrated = true;
      }
    }
    // Chat settings background — single setting, not synced today but
    // migrated for parity (the bytes still bloat the JSON otherwise).
    final cs = store.chatSettings;
    final csNext = await migrate(cs.customBackgroundDataUrl);
    if (csNext != null) {
      cs.customBackgroundDataUrl = csNext;
      anyMigrated = true;
    }

    if (!anyRemainingInline) {
      await prefs.setBool(_prefKey, true);
      debugPrint('[AttachmentMigration] complete — flag set');
    } else {
      debugPrint('[AttachmentMigration] partial — will resume next launch');
    }
    return anyMigrated;
  }

  /// `data:image/png;base64,xxx` → decoded bytes. Returns null on any
  /// malformed input — caller treats that as "leave URL inline and
  /// retry next launch".
  static Uint8List? _decodeDataUrl(String url) {
    final comma = url.indexOf(',');
    if (comma <= 0) return null;
    final payload = url.substring(comma + 1);
    try {
      return Uint8List.fromList(base64Decode(payload));
    } catch (_) {
      return null;
    }
  }

  /// `data:image/png;base64,...` → `image/png`. Best-effort.
  static String? _mimeFromDataUrl(String url) {
    if (!url.startsWith('data:')) return null;
    final semi = url.indexOf(';');
    if (semi < 5) return null;
    return url.substring(5, semi);
  }
}
