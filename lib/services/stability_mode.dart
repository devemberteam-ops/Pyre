import 'dart:io';

import 'package:flutter/foundation.dart';

/// Pyre 1.1 — Windows graphics "Stability mode" marker.
///
/// Some Windows machines crash with an access violation (0xc0000005) inside
/// `flutter_windows.dll` on the window-message -> ANGLE/D3D11 present /
/// accessibility path. Every captured crash had the NVIDIA GeForce overlay
/// (`nvspcap64.dll`, which hooks the shared DXGI `Present` chain) AND the
/// reactive UI-Automation accessibility bridge loaded in-process.
///
/// The D3D11 swapchain is owned inside the Flutter engine and isn't reachable
/// from the embedder, but the native runner CAN steer the engine onto
/// lower-risk pre-init paths (MSAA `IAccessible` instead of the reactive UIA
/// fragment tree; the low-power GPU when one exists). That choice has to be
/// made before the Dart VM starts, so it can't live in normal app settings.
/// Instead the app drops a tiny marker file that `windows/runner/main.cpp`
/// checks at launch (`PyreStabilityModeEnabled`).
///
/// This is intentionally a PER-MACHINE flag — it's about *this* machine's GPU
/// and overlay — so it is deliberately NOT part of the synced [UiPrefs] and
/// never travels to other devices. It also takes effect only on the next
/// launch (the running engine was already configured).
class StabilityMode {
  StabilityMode._();

  /// The marker is only meaningful on the Windows desktop build; the runner
  /// on other platforms never reads it.
  static bool get supported => !kIsWeb && Platform.isWindows;

  /// `%LOCALAPPDATA%\Pyre\stability_mode.flag` — the same fixed directory the
  /// native crash logger uses, chosen so the runner can read it before the
  /// Dart VM (and app settings) exist. Returns null if LOCALAPPDATA is
  /// unexpectedly missing.
  static String? _markerPath() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    return '$local\\Pyre\\stability_mode.flag';
  }

  /// Whether Stability mode is currently armed (i.e. the marker file exists).
  /// The UI reads this directly so the toggle reflects real on-disk state
  /// rather than a possibly-stale cached bool.
  static bool isEnabled() {
    if (!supported) return false;
    final p = _markerPath();
    if (p == null) return false;
    try {
      return File(p).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Arm or disarm Stability mode. Takes effect on the NEXT launch. Best-effort:
  /// a failure just means the toggle didn't stick — callers re-read
  /// [isEnabled] afterwards so the UI never lies about the real state.
  static Future<void> setEnabled(bool enabled) async {
    if (!supported) return;
    final p = _markerPath();
    if (p == null) return;
    final file = File(p);
    try {
      if (enabled) {
        await file.parent.create(recursive: true);
        await file.writeAsString('1', flush: true);
      } else if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      // Swallow: see method doc — the UI re-reads actual state.
    }
  }
}
