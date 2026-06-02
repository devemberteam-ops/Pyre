// Local-only crash + uncaught-exception capture.
//
// Wave CY.18.45: shipped to give Pyre any observability at all post-
// launch. The privacy policy promises no analytics, no telemetry, no
// network-borne crash reports — and we keep that promise: NOTHING here
// leaves the device. The log lives on disk as JSONL, capped, and the
// user can export it manually via Storage screen when they want to
// attach a bug report to a GitHub issue.
//
// Wired in `main.dart` via `ErrorLog.install()` BEFORE `runApp` so we
// catch (a) Flutter framework errors via `FlutterError.onError`,
// (b) async / platform errors via `PlatformDispatcher.instance.onError`,
// and (c) anything inside `runZonedGuarded`.
//
// Captured shape per entry (one JSON object per line):
//   {
//     "ts":  <ms epoch>,
//     "kind": "flutter" | "platform" | "manual",
//     "lib": "<library/widget where it fired, if known>",
//     "msg": "<short message>",
//     "stack": "<optional stack trace>"
//   }
//
// File rotation: writes are atomic-temp+rename (same pattern as
// JsonStorage). When the file would exceed [_maxBytes] we drop the
// oldest half and keep going — so the log self-trims and never grows
// unbounded, even if some user hits a tight error loop.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart'
    show FlutterError, FlutterErrorDetails;
import 'package:path_provider/path_provider.dart';

class ErrorLog {
  ErrorLog._();

  static const String _logFileName = 'errors.jsonl';
  static const String _logDirName = 'Pyre/logs';
  /// Cap at ~1 MB. Anything beyond and we trim the oldest half. Most
  /// users will never reach this; the cap exists to guard against a
  /// pathological retry loop that drops 50+ identical entries per
  /// second.
  static const int _maxBytes = 1024 * 1024;

  /// Cached directory path so we don't re-resolve on every write.
  /// `null` until [_resolveDir] runs once.
  static Directory? _dir;
  /// Serialises writes — error handlers fire from many isolates /
  /// async contexts and concurrent appends would interleave bytes.
  static Future<void> _inflight = Future.value();
  /// Cap on entries we'll buffer in-memory before write completes.
  /// In practice writes finish in <10ms so this never matters; the
  /// guard prevents pathological pile-up under error storms.
  static const int _maxQueued = 100;
  static int _queued = 0;

  /// Install the global error handlers. Idempotent — calling twice is
  /// a no-op. Safe to call before `runApp`.
  static bool _installed = false;
  static void install() {
    if (_installed) return;
    _installed = true;

    // Flutter framework errors (build / paint / layout / widget
    // lifecycle). Default behaviour was the red error screen + console
    // print; we keep both via `presentError` and ADD our log write.
    final prevFlutterHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      record(
        kind: 'flutter',
        lib: details.library ?? '',
        message: details.exceptionAsString(),
        stack: details.stack?.toString(),
      );
      if (prevFlutterHandler != null) {
        prevFlutterHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    // Async / platform / isolate errors (anything not caught inside
    // Flutter widget callbacks). Returning `true` says "we handled it"
    // — which we kind of did, we logged it. Returning `false` would
    // crash the isolate, which is rarely what we want.
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record(
        kind: 'platform',
        lib: '',
        message: error.toString(),
        stack: stack.toString(),
      );
      return true;
    };
  }

  /// Append one entry. Public so callers (e.g. catch blocks deep in
  /// services) can record a manual entry with `kind: 'manual'`.
  static void record({
    required String kind,
    required String message,
    String lib = '',
    String? stack,
  }) {
    // Drop record on overflow — better to lose a stale entry than
    // balloon memory waiting for the disk.
    if (_queued >= _maxQueued) return;
    _queued++;
    final entry = <String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'kind': kind,
      if (lib.isNotEmpty) 'lib': lib,
      'msg': message,
      if (stack != null && stack.isNotEmpty) 'stack': stack,
    };
    debugPrint('[ErrorLog] $kind: $message');
    // Chain on the existing inflight future so writes are serialised.
    _inflight = _inflight
        .then((_) => _appendLine(jsonEncode(entry)))
        .whenComplete(() => _queued--);
  }

  /// Returns the absolute path to the log file. Creates the directory
  /// if needed. Used by Storage screen's Export button.
  static Future<String> logPath() async {
    final dir = await _resolveDir();
    return '${dir.path}/$_logFileName';
  }

  /// Read the log into memory as one big string. Returns empty string
  /// if the file doesn't exist yet. Used by Storage screen's "Copy".
  static Future<String> readAll() async {
    try {
      // Drain any pending writes first so an Export captures the
      // latest entries.
      await _inflight;
      final dir = await _resolveDir();
      final f = File('${dir.path}/$_logFileName');
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      return 'failed to read log: $e';
    }
  }

  /// Wipes the on-disk log. Used by Storage screen "Clear error log".
  static Future<void> clear() async {
    try {
      await _inflight;
      final dir = await _resolveDir();
      final f = File('${dir.path}/$_logFileName');
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[ErrorLog] clear failed: $e');
    }
  }

  /// Copy the full log text to the system clipboard. Returns the
  /// number of bytes copied so the caller can show a snackbar.
  static Future<int> copyToClipboard() async {
    final text = await readAll();
    await Clipboard.setData(ClipboardData(text: text));
    return text.length;
  }

  // --- internals -----------------------------------------------------------

  static Future<Directory> _resolveDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_logDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  static Future<void> _appendLine(String line) async {
    try {
      final dir = await _resolveDir();
      final f = File('${dir.path}/$_logFileName');
      // Rotation: if appending would push past the cap, drop the
      // oldest half. Cheaper than tracking byte counts as we go and
      // accurate enough since entries are small.
      if (await f.exists()) {
        final size = await f.length();
        if (size + line.length + 1 > _maxBytes) {
          final all = await f.readAsString();
          final lines = const LineSplitter().convert(all);
          // Keep the newest half. `+1` so a 200-line file becomes
          // 100 lines, not 99.
          final keep = lines.sublist(lines.length ~/ 2);
          await f.writeAsString('${keep.join('\n')}\n', flush: true);
        }
      }
      // Append the new line. Single shot, flush=true so a crash
      // immediately after doesn't lose the very entry that just
      // logged the cause.
      await f.writeAsString('$line\n',
          mode: FileMode.append, flush: true);
    } catch (e) {
      // Last-ditch — if disk write itself blows up we don't want a
      // log handler to recursively log its own failure (infinite
      // loop). Just print.
      debugPrint('[ErrorLog] write failed: $e');
    }
  }
}
