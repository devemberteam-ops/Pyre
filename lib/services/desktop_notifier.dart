// Wave CY.18.56: native desktop completion toasts.
//
// When a chat reply or Creator block finishes and the user has Pyre
// minimized, hidden in the system tray, or pushed into the background,
// we fire a small native OS toast ("Pyre — response ready") so they
// know to come back. WinToast on Windows, NSUserNotification on macOS,
// libnotify on Linux. The plugin (`local_notifier`) ships nothing for
// Android / iOS / web — those platforms hit the early return below and
// the call is free.
//
// Why hook it into `GenerationKeepAlive` and not at every `onDone`
// callback? Chat + Creator + variant retry + regenerate + impersonate
// all have their own onDone paths (12+ sites). Hooking once at
// `start/stop` means future generation paths get the notification for
// free, and the same refcount that gates the foreground service ALSO
// determines when generation is truly idle (last stop = response
// ready).
//
// Why skip when focused? If the user is staring at the window watching
// tokens stream, popping a toast is pure noise. The toast is only
// useful for the "I tabbed away to check email" case.
//
// Why the 5-second minimum? Generation can fail instantly (auth error,
// rate limit) before we ever start streaming. We don't want a "ready!"
// toast for what was actually a 200ms error. Real responses take 5s+
// even on local models.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

class DesktopNotifier {
  DesktopNotifier._();

  static bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  static bool _initialised = false;
  static DateTime? _lastFired;

  /// Lazy one-time init. The plugin's `localNotifier.setup` registers
  /// the app name with the OS-level notification center. Calling
  /// repeatedly is harmless; we guard for cheap.
  static Future<void> _ensureInit() async {
    if (_initialised) return;
    _initialised = true; // set first so failure doesn't loop forever
    if (!_isDesktopPlatform) return;
    try {
      await localNotifier.setup(
        appName: 'Pyre',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
    } catch (e) {
      // If init fails (e.g. user has notifications disabled at OS
      // level), `show` will also fail later — we accept silent
      // degradation. Not worth blocking generation completion over.
      debugPrint('[DesktopNotifier] setup failed: $e');
    }
  }

  /// Show a "response ready" toast. No-op on every non-desktop
  /// platform, and ALSO no-op when:
  ///   - the Pyre window is currently focused (user is watching),
  ///   - another toast fired within the last 3 seconds (debounce —
  ///     prevents spam during retry storms or multi-block creator
  ///     cascades that finish in quick succession).
  ///
  /// Returns silently in all skip cases — callers don't need to know
  /// or care whether the notification actually showed.
  static Future<void> fireGenerationDone() async {
    if (!_isDesktopPlatform) return;

    final now = DateTime.now();
    if (_lastFired != null &&
        now.difference(_lastFired!).inMilliseconds < 3000) {
      return;
    }

    try {
      final focused = await windowManager.isFocused();
      if (focused) {
        // User is watching — no need to grab attention. Visible streaming
        // already tells them the response is ready.
        return;
      }
    } catch (e) {
      // If window_manager errors (race during shutdown, plugin not
      // wired), prefer to notify rather than to be silent — better
      // false-positive than missed completion.
      debugPrint('[DesktopNotifier] isFocused check failed: $e');
    }

    await _ensureInit();

    try {
      final n = LocalNotification(
        title: 'Pyre',
        body: 'Response ready',
      );
      await n.show();
      _lastFired = now;
    } catch (e) {
      debugPrint('[DesktopNotifier] show failed: $e');
    }
  }
}
