// Wave BM: foreground-service wrapper for in-flight LLM streams.
//
// Without this, Android can kill Pyre while a generation is mid-flight
// when the user minimizes the app. That's especially bad for the
// Character Creator (Block emissions take 1-2 minutes on most
// providers).
//
// Strategy:
//   - Refcounted start/stop so concurrent long-running generations
//     (creator block + vision) share one service.
//   - The service is invisible to the user except for a persistent
//     notification on Android. iOS doesn't need this (Background Modes
//     handles it via plist capability; not configured yet — iOS support
//     is best-effort for now).
//   - All API surface is `Future<void>` and tolerant of plugin failure
//     (e.g. on web where the plugin is a no-op). Callers don't need to
//     check platform.
//
// Wave CY.18.35: `heavy` parameter added so only LONG-running streams
// (Character Creator block emissions, vision analysis) actually start
// the foreground service + persistent notification. Regular chat
// streams and the fast canvas updater pass `heavy: false` (the
// default), which decrements/increments nothing — the calls become
// no-ops. The user pays the notification cost only for the
// minutes-long cascades where it actually matters; quick chat replies
// no longer trigger the notification on every send. Tradeoff: long
// (1500+ token) chat replies CAN be killed mid-stream if the user
// minimises the app during them, but that's a deliberate UX choice —
// surveys / observed traffic say most chat replies finish in 30-60s
// which is well within Android's "grace period" for non-foreground
// processes.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'desktop_notifier.dart';

/// Wave CY.18.46: the foreground-service plugin is Android (and partially
/// iOS) only. On Windows + Linux desktop the process is never silently
/// killed mid-generation — the OS treats the running window the same as
/// any other long-lived app, no special permissions needed. On Flutter
/// web there's no concept of a foreground service at all. So this whole
/// layer becomes a no-op on every non-mobile platform: every method
/// returns immediately and never touches the plugin (which would throw
/// `MissingPluginException` on platforms where no native side exists).
bool get _platformSupportsForegroundService {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

class GenerationKeepAlive {
  GenerationKeepAlive._();

  /// Active HEAVY stream count. Only `start(heavy: true)` increments
  /// this and only its symmetric `stop(heavy: true)` decrements. Service
  /// runs while this is > 0. Light calls (`heavy: false`, the default)
  /// are no-ops — they exist on the API surface so callers can
  /// uniformly call `start/stop` regardless of duration and the
  /// keepalive layer decides whether to actually invoke the
  /// foreground service.
  static int _heavyRefs = 0;

  /// Wave CY.18.56: ANY-stream refcount (light OR heavy). Used purely
  /// to drive the desktop completion toast — when this drops back to
  /// zero AND the last generation took long enough to be worth
  /// notifying about, we fire `DesktopNotifier.fireGenerationDone()`.
  /// Distinct from `_heavyRefs` so chat replies (light) also trigger
  /// the toast — the user wants "your response is ready" regardless
  /// of whether the foreground service ran.
  static int _anyRefs = 0;
  static DateTime? _anyStartedAt;

  /// Wave CY.18.70: public read of the any-counter so the SyncEngine
  /// can implement the spec's generation interlock — "skip push while
  /// `_anyRefs > 0`" — without us having to leak the underlying int.
  /// Pull still happens during generation; only push waits, so a
  /// half-streamed assistant message isn't shipped to the server
  /// mid-flight.
  static bool get isGenerating => _anyRefs > 0;
  static const _toastMinDuration = Duration(seconds: 5);

  /// Set true the first time `start` is called so we lazily init the
  /// plugin's notification channel.
  static bool _initialised = false;

  /// One-time plugin init — channel name, channel ID, defaults.
  /// Calling more than once is a no-op (the plugin handles idempotence).
  static Future<void> _ensureInit() async {
    if (_initialised) return;
    // Wave CY.18.46: plugin is Android/iOS only — Windows / Linux /
    // macOS / web all skip init entirely (calling FlutterForegroundTask
    // methods on those would throw MissingPluginException).
    if (!_platformSupportsForegroundService) {
      _initialised = true;
      return;
    }
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'pyre_generation',
          channelName: 'Generation',
          channelDescription:
              'Shown while Pyre is generating an LLM response. '
              'Pyre uses this to stay alive when the app is minimized.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          showWhen: false,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      // Wave BN: Android 13+ requires runtime POST_NOTIFICATIONS for
      // the foreground-service notification to display. If we DON'T
      // ask, the service is silently downgraded by the OS and can be
      // killed in background — defeating the whole point. The plugin
      // throws / returns false safely if the user denies, but the
      // service still starts (just without visible notification on
      // Android 13+, which IS less reliable but better than nothing).
      try {
        final status = await FlutterForegroundTask.checkNotificationPermission();
        if (status != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
      } catch (e) {
        debugPrint('GenerationKeepAlive notification permission ask failed: $e');
      }
      _initialised = true;
    } catch (e) {
      // If the plugin fails to init we still want streams to proceed —
      // worst case, the user loses generation on background, which is
      // the SAME behaviour as before this wave.
      debugPrint('GenerationKeepAlive init failed: $e');
      _initialised = true; // don't retry forever
    }
  }

  /// Start the service (or refcount-bump if already running). Callers
  /// MUST pair every `start()` with a matching `stop()` in a finally
  /// block so a failure mid-stream doesn't leave the notification
  /// stuck on-screen.
  ///
  /// Wave CY.18.35: pass `heavy: true` ONLY for calls that genuinely
  /// take long enough to risk being killed in background — Character
  /// Creator block emissions (1-2 minutes each, 3-5 minutes for a
  /// Freeform cascade) and vision analysis (~1 minute per image).
  /// Default `heavy: false` means "don't bother with the foreground
  /// service for this one" — typical for chat replies (30-60s, well
  /// inside Android's grace period) and the canvas updater (fast
  /// JSON merge, ~10s). Light calls don't show the persistent
  /// notification and can\'t outlive a background transition, but
  /// they also don\'t pay the notification UX cost on every send.
  static Future<void> start({bool heavy = false}) async {
    // Wave CY.18.56: ALWAYS bump the any-counter, regardless of heavy.
    // This is what drives the desktop completion toast in `stop()` —
    // we want to notify on chat replies too, not just creator blocks.
    _anyRefs++;
    if (_anyRefs == 1) {
      _anyStartedAt = DateTime.now();
    }

    if (!heavy) {
      // Wave CY.18.35: light calls are no-ops for the foreground
      // service. We keep the method signature uniform so callers can
      // `start/stop` without branching, and so future changes (e.g.
      // a user setting to promote all calls to heavy) can flip a
      // single line here.
      return;
    }
    _heavyRefs++;
    debugPrint('[GenerationKeepAlive] start(heavy) refs=$_heavyRefs');
    if (_heavyRefs > 1) return; // already running
    await _ensureInit();
    // Wave CY.18.46: bail on platforms without the plugin's native side.
    if (!_platformSupportsForegroundService) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        debugPrint('[GenerationKeepAlive] service already running, skip start');
        return;
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: 4242, // unique per-app
        notificationTitle: 'Pyre — building your card',
        notificationText:
            'Heavy generation in progress. Pyre will stay alive in '
            'the background until it finishes.',
      );
      debugPrint('[GenerationKeepAlive] startService → $result');
    } catch (e) {
      debugPrint('[GenerationKeepAlive] start failed: $e');
    }
  }

  /// Decrement refcount; stop the service when the last heavy stream
  /// ends. Pass `heavy: true` symmetric to the matching `start` — light
  /// stops are no-ops just like light starts.
  static Future<void> stop({bool heavy = false}) async {
    // Wave CY.18.56: decrement the any-counter and, when it hits zero,
    // decide whether to fire a desktop completion toast. Guarded
    // against double-stop with the `>0` check so a buggy caller
    // can't make `_anyRefs` go negative and trap us in "permanent
    // generation" state.
    if (_anyRefs > 0) _anyRefs--;
    if (_anyRefs == 0) {
      final startedAt = _anyStartedAt;
      _anyStartedAt = null;
      if (startedAt != null) {
        final dur = DateTime.now().difference(startedAt);
        if (dur >= _toastMinDuration) {
          // Fire-and-forget — the notifier handles its own platform +
          // focus + debounce gating. We don't await so a slow OS
          // notification API can't delay the user-visible "generation
          // done" state.
          unawaited(DesktopNotifier.fireGenerationDone());
        }
      }
    }

    if (!heavy) return;
    if (_heavyRefs > 0) _heavyRefs--;
    debugPrint('[GenerationKeepAlive] stop(heavy) refs=$_heavyRefs');
    if (_heavyRefs > 0) return;
    // Wave CY.18.46: same plugin-availability gate as `start`.
    if (!_platformSupportsForegroundService) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        final result = await FlutterForegroundTask.stopService();
        debugPrint('[GenerationKeepAlive] stopService → $result');
      } else {
        debugPrint('[GenerationKeepAlive] service was already stopped');
      }
    } catch (e) {
      debugPrint('[GenerationKeepAlive] stop failed: $e');
    }
  }

  /// Convenience: wrap an async action with start/stop. Use this when
  /// the call site is a single async function; for streams, prefer
  /// manual start/stop in the listener's `onDone` + `onError`.
  static Future<T> guard<T>(Future<T> Function() body,
      {bool heavy = false}) async {
    await start(heavy: heavy);
    try {
      return await body();
    } finally {
      await stop(heavy: heavy);
    }
  }
}
