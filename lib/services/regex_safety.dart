// 2026-07-13 — audit round 19 (MED/HIGH availability): ReDoS guard for
// user-authored / imported regex rules.
//
// Dart's RegExp is SYNCHRONOUS with no execution timeout, so a pathological
// pattern — `(a+)+$` and friends — hangs the isolate via catastrophic
// backtracking. The apply path's 200k-char input cap (regex_rules.dart) does
// NOT help: these patterns explode on inputs of a few hundred chars. And
// rules ride in imported ST cards/presets, so the pattern isn't necessarily
// the user's own.
//
// Strategy: probe the pattern ONCE, at save/import time (never in the hot
// apply path), inside a KILLABLE isolate. The probe runs the compiled regex
// against a small adversarial corpus (long homogeneous runs with a non-match
// tail — the classic backtracking triggers). A benign pattern finishes in
// well under a millisecond; a catastrophic one blows the timeout, the isolate
// is killed (freeing the CPU — an abandoned `Isolate.run` would spin forever,
// which is why we spawn manually), and the pattern is reported unsafe.
//
// This is a heuristic, not a proof: a pattern can pass the probe and still be
// slow on some exotic input. But it catches the entire classic catastrophic
// family, costs nothing at chat time, and fails OPEN on infrastructure
// problems (isolate spawn failure, web) so a save is never blocked by a
// platform limitation.

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;

/// How long the probe may run before the pattern is declared unsafe. A benign
/// pattern completes the whole corpus in <10ms even on weak hardware; 500ms is
/// two orders of magnitude of headroom.
const Duration kRegexProbeTimeout = Duration(milliseconds: 500);

/// True when [pattern]+[flags] executed against the adversarial corpus without
/// blowing [timeout]. Invalid patterns return true — the apply path already
/// no-ops them (and the editor reports them via `regexPatternIsValid`), so
/// "unsafe" is reserved for patterns that RUN and hang. On web (no isolates)
/// this always returns true — behavior there is unchanged from today.
Future<bool> regexPatternIsSafe(
  String pattern,
  String flags, {
  Duration timeout = kRegexProbeTimeout,
}) async {
  if (kIsWeb) return true;
  if (pattern.isEmpty) return true;
  final receive = ReceivePort();
  Isolate? iso;
  try {
    iso = await Isolate.spawn<List<Object>>(
      _probeEntry,
      [receive.sendPort, pattern, flags],
      errorsAreFatal: true,
    );
    final verdict = await receive.first
        .timeout(timeout, onTimeout: () => false);
    return verdict == true;
  } catch (_) {
    // Spawn/platform failure — fail OPEN (this guard is best-effort; blocking
    // every save on an infra hiccup would be worse than the risk it manages).
    return true;
  } finally {
    iso?.kill(priority: Isolate.immediate);
    receive.close();
  }
}

/// Isolate entry: compile EXACTLY like the apply path (`_compileCached`
/// semantics — i/m/s flags) and run the adversarial corpus.
void _probeEntry(List<Object> args) {
  final send = args[0] as SendPort;
  final pattern = args[1] as String;
  final flags = (args[2] as String).toLowerCase();
  RegExp re;
  try {
    re = RegExp(
      pattern,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
    );
  } catch (_) {
    // Invalid pattern — not this guard's verdict (see regexPatternIsValid).
    send.send(true);
    return;
  }
  // Adversarial corpus: homogeneous runs + almost-match tails. Small on
  // purpose — catastrophic patterns explode exponentially, so a few hundred
  // chars is already far past any timeout; benign patterns scan these in
  // microseconds.
  final probes = <String>[
    '${'a' * 512}!',
    '${'ab' * 256}!',
    '${' ' * 384}x',
    'a' * 1024,
    '${'foo bar baz ' * 64}\n${'a' * 256}!',
  ];
  for (final p in probes) {
    re.hasMatch(p);
    re.allMatches(p).length;
  }
  send.send(true);
}
