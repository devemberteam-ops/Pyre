@TestOn('vm')
library;

// ReDoS guard (2026-07-13, audit round 19 MED/HIGH): regexPatternIsSafe probes
// a pattern in a killable isolate against a catastrophic-backtracking corpus.
// These pin: benign patterns pass, the classic catastrophic family is caught
// and killed, and invalid patterns are NOT this guard's verdict (the apply
// path no-ops them; the editor's validity check reports them separately).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/regex_safety.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('benign patterns are safe (and fast)', () async {
    expect(await regexPatternIsSafe(r'\bfoo\b', 'gi'), isTrue);
    expect(await regexPatternIsSafe(r'^(\w+): (.*)$', 'gm'), isTrue);
    expect(await regexPatternIsSafe(r'a+b*c?', 'g'), isTrue);
    expect(await regexPatternIsSafe('', 'g'), isTrue, reason: 'empty = no-op');
  });

  test('the classic catastrophic-backtracking family is UNSAFE', () async {
    // (a+)+$ — exponential on a long "aaaa…!" input; the probe corpus
    // contains exactly that shape, so the isolate blows the timeout and is
    // killed. This is THE pattern class that froze the UI (audit finding).
    expect(await regexPatternIsSafe(r'(a+)+$', 'g'), isFalse);
    expect(await regexPatternIsSafe(r'(a|a)+$', 'g'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('an INVALID pattern is not this guard\'s verdict → safe', () async {
    // The apply path no-ops invalid rules and the editor's
    // regexPatternIsValid already reports them — the safety probe must not
    // double-report.
    expect(await regexPatternIsSafe(r'([unclosed', 'g'), isTrue);
  });
}
