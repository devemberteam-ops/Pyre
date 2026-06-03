// Pyre 1.1 (F4) — AppStore wiring for the regexRules synced list.
// Mirrors the lorebook CRUD + tombstone pattern (no HTTP / no mocking — the
// pure store mutations only).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/regex_rules.dart';
import 'package:pyre/state/app_store.dart';

void main() {
  group('AppStore regexRules CRUD', () {
    test('addRegexRule appends + stamps mtime', () {
      final s = AppStore();
      final r = RegexRule(id: 'r1', name: 'A', pattern: 'x');
      s.addRegexRule(r);
      expect(s.regexRules.length, 1);
      expect(s.regexRules.first.id, 'r1');
      expect(s.regexRules.first.mtime > 0, isTrue);
    });

    test('updateRegexRule replaces in place + bumps mtime', () {
      final s = AppStore();
      final r = RegexRule(id: 'r1', name: 'A', pattern: 'x');
      s.addRegexRule(r);
      final firstMtime = s.regexRules.first.mtime;
      final edited = r.clone()..name = 'B';
      s.updateRegexRule(edited);
      expect(s.regexRules.first.name, 'B');
      expect(s.regexRules.first.mtime >= firstMtime, isTrue);
    });

    test('updateRegexRule is a no-op for an unknown id', () {
      final s = AppStore();
      s.addRegexRule(RegexRule(id: 'r1', pattern: 'x'));
      s.updateRegexRule(RegexRule(id: 'ghost', pattern: 'y'));
      expect(s.regexRules.length, 1);
      expect(s.regexRules.first.id, 'r1');
    });

    test('removeRegexRule hard-removes + records a tombstone', () {
      final s = AppStore();
      s.addRegexRule(RegexRule(id: 'r1', pattern: 'x'));
      s.removeRegexRule('r1');
      expect(s.regexRules, isEmpty);
      expect(s.tombstones.containsKey('regexRule:r1'), isTrue);
      expect(s.tombstones['regexRule:r1']! > 0, isTrue);
    });

    test('removeRegexRule on an unknown id records no tombstone', () {
      final s = AppStore();
      s.removeRegexRule('ghost');
      expect(s.tombstones.containsKey('regexRule:ghost'), isFalse);
    });

    test('isTombstonedNewer recognises the regexRule kind', () {
      final s = AppStore();
      s.addRegexRule(RegexRule(id: 'r1', pattern: 'x'));
      s.removeRegexRule('r1');
      // A peer offering the same id at an older mtime is suppressed.
      expect(s.isTombstonedNewer('regexRule', 'r1', 1), isTrue);
    });
  });
}
