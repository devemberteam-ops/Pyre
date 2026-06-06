// Guide (guided generations) — pure-function tests.
//
// Covers:
//   • injectGuide() placement at both positions, the no-user-turn fallback,
//     content-present-once, and the null/blank = no-op-without-mutation
//     guarantee (the caller's list must never be touched).
//   • GuideSettings toJson/fromJson round-trip + tolerant defaults.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  // A small representative turn list: system prompt, one user, one assistant,
  // one final user turn (the message the model answers).
  List<ChatTurn> sample() => [
        ChatTurn('system', 'You are a helpful roleplay partner.'),
        ChatTurn('user', 'Hi there.'),
        ChatTurn('assistant', 'Hello!'),
        ChatTurn('user', 'What do you do next?'),
      ];

  group('injectGuide', () {
    test('systemNoteAtEnd appends one system turn at the end', () {
      final turns = sample();
      final out = injectGuide(
          turns, 'be tense and brief', GuideInjectionPosition.systemNoteAtEnd);

      expect(out.length, turns.length + 1);
      expect(out.last.role, 'system');
      expect(out.last.content, contains('be tense and brief'));
      // Everything before the note is unchanged, in order.
      for (var i = 0; i < turns.length; i++) {
        expect(out[i].role, turns[i].role);
        expect(out[i].content, turns[i].content);
      }
    });

    test('beforeLastUserTurn inserts just before the LAST user turn', () {
      final turns = sample();
      final out = injectGuide(turns, 'have her hesitate first',
          GuideInjectionPosition.beforeLastUserTurn);

      expect(out.length, turns.length + 1);
      // The note sits at index 3 (right before the final user turn).
      final noteIdx = out.indexWhere((t) =>
          t.role == 'system' && t.content.contains('have her hesitate first'));
      expect(noteIdx, 3);
      expect(out[noteIdx].role, 'system');
      expect(out[noteIdx + 1].role, 'user');
      expect(out[noteIdx + 1].content, 'What do you do next?');
    });

    test('beforeLastUserTurn with no user turn falls back to appending', () {
      final turns = [
        ChatTurn('system', 'sys'),
        ChatTurn('assistant', 'a'),
      ];
      final out = injectGuide(
          turns, 'steer it', GuideInjectionPosition.beforeLastUserTurn);

      expect(out.length, turns.length + 1);
      expect(out.last.role, 'system');
      expect(out.last.content, contains('steer it'));
    });

    test('guide content appears exactly once', () {
      final out = injectGuide(
          sample(), 'mention the rain', GuideInjectionPosition.systemNoteAtEnd);
      final hits =
          out.where((t) => t.content.contains('mention the rain')).length;
      expect(hits, 1);
    });

    test('null guide is a no-op and returns the SAME list instance', () {
      final turns = sample();
      final out = injectGuide(turns, null, GuideInjectionPosition.systemNoteAtEnd);
      expect(identical(out, turns), isTrue);
      expect(out.length, turns.length);
    });

    test('blank/whitespace guide is a no-op and returns the SAME list', () {
      final turns = sample();
      final out = injectGuide(
          turns, '   \n  ', GuideInjectionPosition.beforeLastUserTurn);
      expect(identical(out, turns), isTrue);
      expect(out.length, turns.length);
    });

    test('does NOT mutate the caller\'s list (returns a new list)', () {
      final turns = sample();
      final before = turns.length;
      final out = injectGuide(
          turns, 'do a thing', GuideInjectionPosition.systemNoteAtEnd);
      // Caller's list unchanged…
      expect(turns.length, before);
      // …and the returned list is a distinct instance.
      expect(identical(out, turns), isFalse);
      expect(out.length, before + 1);
    });

    test('formatGuideNote wraps + trims the raw guide', () {
      final note = formatGuideNote('  speak softly  ');
      expect(note, contains('speak softly'));
      expect(note.contains('  speak softly  '), isFalse); // trimmed
      expect(note.startsWith('['), isTrue);
      expect(note.endsWith(']'), isTrue);
    });
  });

  group('GuideSettings', () {
    test('defaults: enabled true, end position, second person, mtime 0', () {
      final g = GuideSettings();
      expect(g.enabled, true);
      expect(g.injectionPosition, GuideInjectionPosition.systemNoteAtEnd);
      expect(g.defaultPerspective, GuidePerspective.second);
      expect(g.mtime, 0);
    });

    test('toJson/fromJson round-trips every field', () {
      final g = GuideSettings(
        enabled: false,
        injectionPosition: GuideInjectionPosition.beforeLastUserTurn,
        defaultPerspective: GuidePerspective.third,
        mtime: 12345,
      );
      final back = GuideSettings.fromJson(g.toJson());
      expect(back.enabled, false);
      expect(back.injectionPosition, GuideInjectionPosition.beforeLastUserTurn);
      expect(back.defaultPerspective, GuidePerspective.third);
      expect(back.mtime, 12345);
    });

    test('fromJson tolerates an empty / missing map (falls back to defaults)',
        () {
      final g = GuideSettings.fromJson(const <String, dynamic>{});
      expect(g.enabled, true);
      expect(g.injectionPosition, GuideInjectionPosition.systemNoteAtEnd);
      expect(g.defaultPerspective, GuidePerspective.second);
      expect(g.mtime, 0);
    });

    test('fromJson tolerates unknown enum strings (falls back to defaults)', () {
      final g = GuideSettings.fromJson(const {
        'enabled': true,
        'injectionPosition': 'garbage',
        'defaultPerspective': 'nonsense',
      });
      expect(g.injectionPosition, GuideInjectionPosition.systemNoteAtEnd);
      expect(g.defaultPerspective, GuidePerspective.second);
    });

    test('enum name helpers are stable strings', () {
      expect(
          guideInjectionPositionToName(GuideInjectionPosition.systemNoteAtEnd),
          'systemNoteAtEnd');
      expect(
          guideInjectionPositionToName(
              GuideInjectionPosition.beforeLastUserTurn),
          'beforeLastUserTurn');
      expect(guidePerspectiveToName(GuidePerspective.first), 'first');
      expect(guidePerspectiveToName(GuidePerspective.second), 'second');
      expect(guidePerspectiveToName(GuidePerspective.third), 'third');
    });
  });

  // ── Guided impersonation prompt assembly (Action 3 "Guide my message") ──
  group('buildImpersonationPrompt', () {
    test('no outline + no perspective = classic Impersonate Me (unchanged)',
        () {
      final p = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
      );
      // Still the default OOC impersonation prompt: persona-only voice, the
      // forbidden-NPC rules, formatting guidance, no thinking-out-loud.
      expect(p, startsWith('[OOC:'));
      expect(p, contains("Write the next message from Ren's perspective"));
      expect(p, contains('FORBIDDEN in this reply'));
      // No outline rider and no perspective directive when neither is given.
      expect(p.contains('EXPAND this rough outline'), isFalse);
      expect(p.contains('Write it in '), isFalse);
    });

    test('outline present → expand rider with the verbatim outline', () {
      final p = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        outline: 'refuse the offer but leave the door open',
      );
      expect(p, contains('EXPAND this rough outline from Ren'));
      expect(p, contains('refuse the offer but leave the door open'));
      // Keeps intent / does not act for others.
      expect(p, contains("keep Ren's intent"));
      expect(p, contains('do NOT speak or act for anyone else'));
    });

    test('blank/whitespace outline behaves like no outline', () {
      final p = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        outline: '   \n  ',
      );
      expect(p.contains('EXPAND this rough outline'), isFalse);
    });

    test('each perspective injects the right directive', () {
      final first = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        perspective: GuidePerspective.first,
      );
      expect(first, contains('Write it in FIRST person'));

      final second = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        perspective: GuidePerspective.second,
      );
      expect(second, contains('Write it in SECOND person'));

      final third = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        perspective: GuidePerspective.third,
      );
      expect(third, contains('Write it in THIRD person'));
    });

    test('outline × perspective combine in one prompt', () {
      final p = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        outline: 'storm off in a huff',
        perspective: GuidePerspective.third,
      );
      expect(p, contains('storm off in a huff'));
      expect(p, contains('Write it in THIRD person'));
    });

    test('preset override is honoured verbatim with names substituted', () {
      final p = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        presetImpersonationPrompt:
            'Speak as {{user}} replying to {{char}} now.',
      );
      expect(p, contains('Speak as Ren replying to Vesna now.'));
      // The built-in default body is NOT used when a preset override is set.
      expect(p.contains('FORBIDDEN in this reply'), isFalse);
    });

    test('preset override still picks up the outline + perspective riders', () {
      final p = buildImpersonationPrompt(
        personaName: 'Ren',
        speakerName: 'Vesna',
        presetImpersonationPrompt: 'Be {{user}}.',
        outline: 'apologise sincerely',
        perspective: GuidePerspective.first,
      );
      expect(p, startsWith('Be Ren.'));
      expect(p, contains('apologise sincerely'));
      expect(p, contains('Write it in FIRST person'));
    });

    test('guidePerspectivePhrase names the persona', () {
      expect(guidePerspectivePhrase(GuidePerspective.first, 'Ren'),
          contains('Ren'));
      expect(guidePerspectivePhrase(GuidePerspective.third, 'Ren'),
          contains('Ren'));
    });
  });
}
