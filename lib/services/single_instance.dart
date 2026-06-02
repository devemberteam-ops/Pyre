// Wave CY.18.77: single-instance enforcement on desktop.
//
// Problem: Pyre hides to tray on window-close (Wave 55). If the user
// launches `pyre.exe` again from the desktop shortcut while a hidden
// instance is alive, Windows happily spawns a SECOND process — same
// codebase, same data dir, but unaware of the first. The user ends
// up with 3-4 hidden Pyres eating 100+MB each, all racing to write
// the same JSON state file. Bad.
//
// Solution: try to bind a Pyre-specific localhost-only port at boot.
//   - If bind SUCCEEDS → we're the primary instance. Keep listening
//     forever; treat any incoming connection as "another launch
//     attempted — wake me up". On wake, call `windowManager.show() +
//     focus()` so the user sees the existing window pop forward.
//   - If bind FAILS with EADDRINUSE → an existing primary is alive.
//     Open a TCP connection to that port (the connect itself is the
//     wake signal — primary's onAccept handler fires), then exit
//     this process cleanly so no duplicate state writes happen.
//
// Why a TCP port and not a named mutex / lock file?
//   - TCP is cross-platform (works on Linux + macOS + Windows with
//     identical Dart code).
//   - The same socket is both the "I'm here" advertisement and the
//     IPC channel for the wake signal.
//   - Lock files have stale-file problems after crashes; sockets
//     are reclaimed by the OS automatically.
//
// Port choice: 51234 — high enough to be in the registered/dynamic
// range, doesn't collide with anything common, Pyre-specific via the
// 127.0.0.1 binding (no other host can talk to it).
//
// Web / Android / iOS skip this entirely — the OS already enforces
// single-instance there (mobile apps don't spawn duplicate processes;
// web tabs are independent by design).

import 'dart:async';
import 'dart:io' show InternetAddress, ServerSocket, Socket, SocketException;

import 'package:flutter/foundation.dart';

class SingleInstance {
  SingleInstance._();

  /// The magic localhost port that proves "Pyre is already running
  /// here". Choosing a specific number (not 0) means the SECONDARY
  /// can know exactly where to send its wake ping without any prior
  /// discovery handshake.
  static const int _lockPort = 51234;

  static ServerSocket? _socket;

  /// True when this process is the primary instance (acquired the
  /// lock socket). False BEFORE [acquire] runs.
  static bool _isPrimary = false;
  static bool get isPrimary => _isPrimary;

  /// Attempt to become the primary instance. Returns:
  ///   - true: this process owns the lock, caller should continue
  ///     normal startup. The primary listens on the lock port for
  ///     wake pings from future launches and calls [onWake] when
  ///     one arrives.
  ///   - false: another Pyre is already running. The wake ping has
  ///     been sent to the existing primary (best-effort). Caller
  ///     should `exit(0)` immediately — DO NOT touch the state file,
  ///     DO NOT open windows, DO NOT init anything else.
  static Future<bool> acquire({required Future<void> Function() onWake}) async {
    try {
      _socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        _lockPort,
        shared: false,
      );
      _isPrimary = true;
      // Each connection IS the wake signal — we don't even read its
      // bytes. Connect = "please come to the front".
      _socket!.listen((Socket conn) async {
        debugPrint('[SingleInstance] wake ping received');
        try {
          await onWake();
        } catch (e) {
          debugPrint('[SingleInstance] onWake handler failed: $e');
        }
        try {
          await conn.close();
        } catch (_) {}
      }, onError: (Object e) {
        debugPrint('[SingleInstance] lock listen error: $e');
      });
      debugPrint('[SingleInstance] primary on 127.0.0.1:$_lockPort');
      return true;
    } on SocketException catch (e) {
      // Bind failed → another instance owns the port. Send a wake
      // ping and bail out. Open + immediately close = the ping.
      debugPrint('[SingleInstance] lock taken (${e.osError?.errorCode}) — '
          'sending wake ping');
      try {
        final c = await Socket.connect(
          InternetAddress.loopbackIPv4,
          _lockPort,
          timeout: const Duration(seconds: 2),
        );
        await c.flush();
        await c.close();
      } catch (e) {
        debugPrint('[SingleInstance] wake ping failed: $e — '
            'primary may be unresponsive');
      }
      return false;
    } catch (e) {
      // Any other error — be conservative and assume we ARE the
      // primary so the user isn't blocked from launching. Log loud.
      debugPrint('[SingleInstance] unexpected acquire error: $e — '
          'falling through as primary');
      _isPrimary = true;
      return true;
    }
  }

  /// Release the lock on shutdown. Idempotent.
  static Future<void> release() async {
    final s = _socket;
    _socket = null;
    if (s != null) {
      try {
        await s.close();
      } catch (_) {}
    }
  }
}
