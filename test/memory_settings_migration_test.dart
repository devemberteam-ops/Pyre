import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

// The Checkpoints "Summary Prompt" default changed between Pyre 1.0 and 1.1.
// Gui's call: FORCE everyone onto the new default on upgrade (don't try to
// preserve customisations), so nobody is stranded on the old prompt needing a
// manual "Restore". Mechanism: a version stamp — when the shipped
// [kSummaryPromptVersion] is newer than what the install last saw, fromJson
// resets the prompt to the current default for EVERY install, then stamps the
// current version so it happens exactly once and the prompt stays editable.
void main() {
  group('MemorySettings summary-prompt version force-reset', () {
    test('a pre-1.1 install (no version) is force-reset to the new default', () {
      final m = MemorySettings.fromJson(const {
        'summaryPrompt': 'whatever the 1.0 default or anything else was',
      });
      expect(m.summaryPrompt, MemorySettings.defaultSummaryPrompt);
      expect(m.summaryPromptVersion, MemorySettings.kSummaryPromptVersion);
    });

    test('an OLDER version is force-reset even if the prompt was CUSTOMISED',
        () {
      final m = MemorySettings.fromJson({
        'summaryPrompt': 'My hand-written custom summariser instructions.',
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion - 1,
      });
      // "modify everyone" — customisations on an old version are intentionally
      // overwritten.
      expect(m.summaryPrompt, MemorySettings.defaultSummaryPrompt);
    });

    test('a CURRENT-version custom prompt is preserved (edits stick after reset)',
        () {
      final m = MemorySettings.fromJson({
        'summaryPrompt': 'custom on the current version',
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion,
      });
      expect(m.summaryPrompt, 'custom on the current version');
    });

    test('missing prompt resolves to the current default', () {
      final m = MemorySettings.fromJson(const {});
      expect(m.summaryPrompt, MemorySettings.defaultSummaryPrompt);
    });

    test('blank prompt resolves to the current default even at current version',
        () {
      final m = MemorySettings.fromJson({
        'summaryPrompt': '   ',
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion,
      });
      expect(m.summaryPrompt, MemorySettings.defaultSummaryPrompt);
    });

    test('fromJson always stamps the current version', () {
      expect(MemorySettings.fromJson(const {}).summaryPromptVersion,
          MemorySettings.kSummaryPromptVersion);
      expect(
          MemorySettings.fromJson(const {'summaryPromptVersion': 0})
              .summaryPromptVersion,
          MemorySettings.kSummaryPromptVersion);
    });

    test('a fresh MemorySettings() is on the current version + default', () {
      final m = MemorySettings();
      expect(m.summaryPrompt, MemorySettings.defaultSummaryPrompt);
      expect(m.summaryPromptVersion, MemorySettings.kSummaryPromptVersion);
    });

    test('toJson persists both the prompt and its version', () {
      final j = MemorySettings(summaryPrompt: 'x').toJson();
      expect(j['summaryPrompt'], 'x');
      expect(j['summaryPromptVersion'], MemorySettings.kSummaryPromptVersion);
    });

    test('round-trip after the reset: a later edit survives', () {
      // 1. pre-1.1 install loads → force-reset + stamped current.
      final reset = MemorySettings.fromJson(const {'summaryPrompt': 'old'});
      expect(reset.summaryPrompt, MemorySettings.defaultSummaryPrompt);
      // 2. user edits the prompt, it persists.
      reset.summaryPrompt = 'edited after reset';
      final back = MemorySettings.fromJson(reset.toJson());
      // 3. same (current) version → edit is kept, not re-reset.
      expect(back.summaryPrompt, 'edited after reset');
    });
  });
}
