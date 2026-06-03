// Wave CY.18.214: opt-in, local-only diagnostics log of every REAL LLM
// request + response, tagged per feature (chat / ltm / livesheet /
// creator-architect / creator-vision / scene). Export-only — there is no
// in-app viewer in v1. The user flips it on in Storage → Developer,
// reproduces an issue, then exports the JSONL so a human (or an agent)
// can analyse exactly what Pyre sent and got back.
//
// This mirrors `error_log.dart`'s file discipline (one JSON object per
// line, atomic-ish append, size cap with oldest-half trim) but adds:
//   - a persisted `enabled` flag (default FALSE), so the chat_api hook is
//     a STRICT no-op when off — `record` returns before touching disk;
//   - daily files: `{appDocs}/Pyre/logs/llm/<yyyy-mm-dd>.jsonl`, so a
//     session's calls cluster by day and old days can be wiped;
//   - a typed [LlmCallRecord] value object.
//
// SECURITY (load-bearing): the API key is NEVER logged. The record is
// built from the request BODY map (`{model, messages, sampling, ...}`)
// which is key-free BY CONSTRUCTION — in chat_api the apiKey rides the
// HTTP `Authorization` header, set separately, and is never put in the
// body. We never pass the header (or the provider's `apiKey` field) into
// [LlmCallRecord]; the only provider data captured is its display `name`
// + `model`. `test/llm_debug_log_test.dart` proves a sentinel key string
// appears nowhere in a serialised record.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'package:pyre/dev_flavor.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One captured LLM call. Built at the chat_api chokepoint from the
/// request body (key-free) + the response + timing. Serialises to a
/// single JSON object (one JSONL line).
///
/// [provider] is the provider's DISPLAY NAME only — never its apiKey,
/// baseUrl, or headers. [messages] + [sampling] come straight from the
/// request body map chat_api already builds, which contains no key.
class LlmCallRecord {
  /// ms-epoch capture time.
  final int ts;

  /// Feature tag: `chat`, `ltm`, `livesheet`, `creator-architect`,
  /// `creator-vision`, `scene`, or any future tag.
  final String feature;

  /// Provider display name (e.g. "Venice"). NOT the key/url/headers.
  final String provider;

  /// Model id sent in the request (`body['model']`).
  final String model;

  /// The request `messages` array, exactly as serialised into the body
  /// (`messages.map((m) => m.toJson())`). Key-free.
  final List<dynamic> messages;

  /// The sampling + extra-params portion of the request body (temp,
  /// top_p, max_tokens, plus any `extraParams`/`stop`/`stream`). Key-free.
  final Map<String, dynamic> sampling;

  /// The model's response text (already assembled / sentinel-stripped by
  /// the caller where applicable). May be empty on a failed call.
  final String response;

  /// Captured finish_reason (`stop` / `length` / …) when known.
  final String? finishReason;

  /// Wall-clock duration of the call in milliseconds.
  final int durationMs;

  /// Optional caller-supplied parse outcome note (e.g. "recapLooksComplete",
  /// "SHEET present", a thrown-error string). Free-form.
  final String? parseOutcome;

  LlmCallRecord({
    required this.ts,
    required this.feature,
    required this.provider,
    required this.model,
    required this.messages,
    required this.sampling,
    required this.response,
    this.finishReason,
    required this.durationMs,
    this.parseOutcome,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': ts,
        'feature': feature,
        'provider': provider,
        'model': model,
        'messages': messages,
        'sampling': sampling,
        'response': response,
        if (finishReason != null && finishReason!.isNotEmpty)
          'finishReason': finishReason,
        'durationMs': durationMs,
        if (parseOutcome != null && parseOutcome!.isNotEmpty)
          'parseOutcome': parseOutcome,
      };
}

class LlmDebugLog {
  LlmDebugLog._();

  /// Singleton — the chat_api hook + the UI toggle share one instance.
  static final LlmDebugLog instance = LlmDebugLog._();

  static const String _prefEnabled = 'llmDebugLog.enabled';
  static const String _logDirName = 'Pyre/logs/llm';

  /// Cap each day's file at ~4 MB. LLM payloads are far bigger than crash
  /// lines (a full chat prompt can be 20-50 KB), so the per-file budget is
  /// roomier than error_log's 1 MB. When appending would exceed it we drop
  /// the oldest half of that day's lines (same self-trim as error_log).
  static const int _maxBytes = 4 * 1024 * 1024;

  /// Cap on records buffered in-memory while a write is inflight. A real
  /// session never approaches this; the guard just prevents pile-up if the
  /// disk stalls under a burst (e.g. a fast regen loop).
  static const int _maxQueued = 200;
  int _queued = 0;

  /// Serialises writes so concurrent appends from different features don't
  /// interleave bytes within a line.
  Future<void> _inflight = Future.value();

  /// Cached log dir; `null` until [_resolveDir] runs once.
  Directory? _dir;

  /// Test seam: when set, [_resolveDir] returns this instead of the OS
  /// application-documents dir, so unit tests can write to a temp dir
  /// WITHOUT mocking path_provider. Production never sets it.
  Directory? debugOverrideDir;

  bool _enabled = false;
  bool _initialised = false;

  /// True iff the user has turned the diagnostics log ON. Default FALSE.
  /// The chat_api hook reads this synchronously and short-circuits when
  /// false, so logging is a strict no-op with zero disk/CPU cost when off.
  bool get enabled => _enabled;

  /// Read the persisted flag at startup. Safe to call repeatedly (the
  /// first call wins). On web (no file system) the log is inert — the
  /// flag still loads so the toggle reflects state, but [record] no-ops.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefEnabled) ?? false;
    } catch (e) {
      debugPrint('[LlmDebugLog] init failed: $e');
    }
  }

  /// Flip the toggle + persist it. The UI calls this.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabled, value);
    } catch (e) {
      debugPrint('[LlmDebugLog] persist enabled failed: $e');
    }
  }

  /// Append one captured call as a JSONL line to today's file.
  ///
  /// STRICT NO-OP when [enabled] is false OR on web — returns immediately
  /// without touching disk. The chat_api hook ALSO guards on [enabled]
  /// before building a record, so when off there's zero serialisation
  /// cost; this second guard is belt-and-suspenders.
  Future<void> record(LlmCallRecord rec) async {
    if (!_enabled) return; // strict no-op when disabled
    if (kIsWeb) return; // no file system in the browser
    if (_queued >= _maxQueued) return; // drop on overflow rather than balloon
    _queued++;
    String line;
    try {
      line = jsonEncode(rec.toJson());
    } catch (e) {
      // A record we can't serialise is a record we can't log — never let
      // it throw into the generation path.
      _queued--;
      debugPrint('[LlmDebugLog] encode failed: $e');
      return;
    }
    _inflight = _inflight
        .then((_) => _appendLine(line))
        .whenComplete(() => _queued--);
    return _inflight;
  }

  /// List every JSONL file currently on disk (any day), newest first.
  /// Used by the export button to share/copy the full set.
  Future<List<File>> logFiles() async {
    try {
      await _inflight; // flush pending writes first
      final dir = await _resolveDir();
      if (!await dir.exists()) return <File>[];
      final files = <File>[];
      await for (final ent in dir.list()) {
        if (ent is File && ent.path.endsWith('.jsonl')) files.add(ent);
      }
      files.sort((a, b) => b.path.compareTo(a.path)); // yyyy-mm-dd sorts
      return files;
    } catch (e) {
      debugPrint('[LlmDebugLog] logFiles failed: $e');
      return <File>[];
    }
  }

  /// Concatenate all days' logs into one string. Empty if nothing logged.
  Future<String> readAll() async {
    try {
      final files = await logFiles();
      if (files.isEmpty) return '';
      final buf = StringBuffer();
      for (final f in files) {
        buf.write(await f.readAsString());
        if (!buf.toString().endsWith('\n')) buf.write('\n');
      }
      return buf.toString();
    } catch (e) {
      return 'failed to read llm log: $e';
    }
  }

  /// Copy the full log text to the clipboard. Returns bytes copied.
  Future<int> copyToClipboard() async {
    final text = await readAll();
    await Clipboard.setData(ClipboardData(text: text));
    return text.length;
  }

  /// Delete every day's log file. Used by the "Clear" affordance.
  Future<void> clear() async {
    try {
      await _inflight;
      final dir = await _resolveDir();
      if (!await dir.exists()) return;
      await for (final ent in dir.list()) {
        if (ent is File && ent.path.endsWith('.jsonl')) {
          await ent.delete();
        }
      }
    } catch (e) {
      debugPrint('[LlmDebugLog] clear failed: $e');
    }
  }

  // --- internals -----------------------------------------------------------

  String _todayStamp() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '${now.year}-$mm-$dd';
  }

  Future<Directory> _resolveDir() async {
    if (debugOverrideDir != null) {
      final d = debugOverrideDir!;
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final logDir = kDevFlavor ? '$_logDirName-dev' : _logDirName;
    final dir = Directory('${docs.path}/$logDir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  Future<void> _appendLine(String line) async {
    try {
      final dir = await _resolveDir();
      final f = File('${dir.path}/${_todayStamp()}.jsonl');
      // Rotation: drop the oldest half of TODAY's file if appending would
      // push it past the cap. Mirrors error_log's strategy.
      if (await f.exists()) {
        final size = await f.length();
        if (size + line.length + 1 > _maxBytes) {
          final all = await f.readAsString();
          final lines = const LineSplitter().convert(all);
          final keep = lines.sublist(lines.length ~/ 2);
          await f.writeAsString('${keep.join('\n')}\n', flush: true);
        }
      }
      await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (e) {
      // Never recurse a logging failure into the error log — just print.
      debugPrint('[LlmDebugLog] write failed: $e');
    }
  }
}
