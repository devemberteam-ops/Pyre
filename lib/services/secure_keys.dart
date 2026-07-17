// OS-level secret store for API keys.
//
// Why this exists: the rest of app state lives in a plaintext JSON blob
// (lib/services/storage.dart). On Android that file is in the app sandbox
// but still readable via `adb backup`, root, or shared-uid attacks; on web
// it's in localStorage and any same-origin XSS lifts it. Bearer tokens for
// the LLM provider — which an attacker can rack up unbounded usage with —
// don't belong there.
//
// Keys are keyed by `provider.id`. The provider's `apiKey` field in the
// main blob is wiped on save and re-hydrated on load via this layer.
//
// Wave CY.18.42: pre-Wave this class swallowed every storage failure
// with `catch (_)` — and a user lost their entire API key set after a
// crash, with no diagnostic in the app to explain why. Now every
// failure is recorded into [SecureKeys.lastErrors] so the Storage
// screen can show a warning banner ("API key for X failed to load —
// re-paste in API Connections"). The methods still return safe
// defaults on failure (empty string for read, no-op for write/delete)
// so callers don't crash, but the user is no longer blindsided.

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureKeys {
  // Android: EncryptedSharedPreferences (Android Keystore backed).
  // iOS / macOS: Keychain.
  // Linux: libsecret. Windows: Credential Manager.
  // Web: AES-encrypted localStorage (best the browser can do — still better
  // than a raw JSON blob since the encryption key lives in a separate slot
  // and isn't part of any backup export).
  static const _store = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Wave CY.18.42: per-operation error log. Each entry is a
  /// human-readable line like:
  ///   "read provider:abc123 failed: PlatformException(BadPaddingException)"
  /// Capped at 20 entries (newest first) so a runaway loop doesn't
  /// balloon. Cleared by the Storage screen after the user has seen
  /// the banner (or via [clearErrorLog]).
  static final List<String> lastErrors = [];
  static const int _maxErrorEntries = 20;

  static void _logError(String op, Object e) {
    final msg = '$op failed: $e';
    debugPrint('[SecureKeys] $msg');
    lastErrors.insert(0, msg);
    if (lastErrors.length > _maxErrorEntries) {
      lastErrors.removeRange(_maxErrorEntries, lastErrors.length);
    }
  }

  /// Clears the in-memory error log. Called by the Storage screen
  /// after the user has acknowledged the banner.
  static void clearErrorLog() {
    lastErrors.clear();
  }

  /// Stores [key] under `provider:<providerId>`. Empty string deletes (we
  /// never want to keep an empty-string sentinel around).
  ///
  /// Wave CY.18.42: failures are now logged into [lastErrors] instead
  /// of bubbling silently. The caller still gets back a Future that
  /// completes (so async chains don't break), but the user-visible
  /// state will surface the failure on next Storage-screen open.
  static Future<void> write(String providerId, String key) async {
    // Fire-and-forget contract (no-throw) preserved for the many callers that
    // don't need to know; the checked variant does the work.
    await tryWrite(providerId, key);
  }

  /// Sync-B blocker 4 (2026-07-17, Codex review): a CHECKED write that reports
  /// success. [write] deliberately swallows storage failures (returns normally),
  /// which is wrong for the sync-apply path: it would put a key in RAM, answer
  /// "accepted", and — because the JSON blob deliberately omits `apiKey` — LOSE
  /// the key on the next restart while the client already advanced its cursor.
  /// The sync path uses this and returns `retryable_error` (holding the cursor)
  /// WITHOUT mutating RAM when it returns false. Failures are still logged.
  static Future<bool> tryWrite(String providerId, String key) async {
    // 1.1.3: a web build proxies LLM calls through the paired desktop and NEVER
    // uses a locally-stored key, but flutter_secure_storage_web can throw a
    // null-check writing one. Skip secure storage on web — treat as no-op success.
    if (kIsWeb) return true;
    final slot = 'provider:$providerId';
    try {
      if (key.isEmpty) {
        await _store.delete(key: slot);
      } else {
        await _store.write(key: slot, value: key);
      }
      return true;
    } catch (e) {
      _logError('write $slot', e);
      return false;
    }
  }

  static Future<String> read(String providerId) async {
    if (kIsWeb) return ''; // web never stores keys (see write)
    final slot = 'provider:$providerId';
    try {
      final v = await _store.read(key: slot);
      return v ?? '';
    } catch (e) {
      // Wave CY.18.42: on web the plugin throws on some browsers
      // when there's no entry yet — that's expected first-launch
      // noise, not a real failure. We still record it so a pattern
      // (every read failing on every launch) is visible, but flag
      // the type of error.
      _logError('read $slot', e);
      return '';
    }
  }

  static Future<void> delete(String providerId) async {
    if (kIsWeb) return; // web never stores keys (see write)
    final slot = 'provider:$providerId';
    try {
      await _store.delete(key: slot);
    } catch (e) {
      _logError('delete $slot', e);
    }
  }

  /// Wipe every secret. Used by the Storage screen's "Wipe local data".
  static Future<void> clearAll() async {
    if (kIsWeb) return; // web never stores keys (see write)
    try {
      await _store.deleteAll();
    } catch (e) {
      _logError('clearAll', e);
    }
  }

  /// On web the plugin's encryption is weak (it's still ultimately backed
  /// by localStorage). Callers can use this to decide whether to surface
  /// "your API key is only as safe as your browser" warnings.
  static bool get isStrongPlatform => !kIsWeb;
}
