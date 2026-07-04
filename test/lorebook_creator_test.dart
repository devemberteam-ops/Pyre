// Wave CY.18.122 (Lorebook Creator, Wave 2): tests for the pure extraction
// and save-append logic — now in services/lorebook_entry_drafts.dart
// (2026-07-03: the standalone LorebookCreatorScreen was removed; the main AI
// Creator's in-canvas lorebook mode is the sole consumer of these helpers).
//
// We test the pure helper `extractEntryDraftFromReply` directly — it is the
// wiring between the architect's [[BUILD_ENTRY]] reply and the EntryDraft
// panel. The save-append logic is exercised against the models directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/lorebook_entry_drafts.dart'
    show
        extractEntryDraftFromReply,
        extractEntryDraftsFromReply,
        lorebookCreatorDisplayText,
        stripLorebookStreamArtifacts;
import 'package:pyre/services/lorebook_architect_prompts.dart'
    show hasBuildEntryMarker, stripBuildEntryMarker;

void main() {
  // ── extractEntryDraftFromReply ─────────────────────────────────────────────

  group('extractEntryDraftFromReply', () {
    test('standard reply with marker + JSON → populated draft', () {
      const reply =
          'Committing the entry now.\n'
          '[[BUILD_ENTRY]]\n'
          '{"keys":["Thalorim","City of Thalorim","the city"],'
          '"content":"Thalorim is a port city of 80 000 souls, built on salt '
          'marshes at the mouth of the Vel river.",'
          '"constant":false,'
          '"comment":"City: Thalorim"}';

      final draft = extractEntryDraftFromReply(reply);
      expect(draft, isNotNull, reason: 'should parse a well-formed reply');
      expect(draft!.entry.keys, containsAll(['Thalorim', 'City of Thalorim']));
      expect(draft.entry.content, contains('port city'));
      expect(draft.entry.constant, isFalse);
      expect(draft.comment, 'City: Thalorim');
    });

    test('constant:true propagates', () {
      const reply =
          'Done.\n[[BUILD_ENTRY]]\n'
          '{"keys":["Gates","the Gates"],'
          '"content":"The Gates are rifts in reality that allow travel between worlds.",'
          '"constant":true,'
          '"comment":"World: Gates"}';

      final draft = extractEntryDraftFromReply(reply);
      expect(draft, isNotNull);
      expect(draft!.entry.constant, isTrue);
    });

    test('no comment field → comment is null', () {
      const reply =
          'OK.\n[[BUILD_ENTRY]]\n'
          '{"keys":["Vel River"],'
          '"content":"The Vel River divides the city\'s old and new quarters.",'
          '"constant":false}';

      final draft = extractEntryDraftFromReply(reply);
      expect(draft, isNotNull);
      expect(draft!.comment, isNull);
    });

    test('reply with no JSON → null', () {
      const reply = 'Sure, what should the entry be about?';
      expect(extractEntryDraftFromReply(reply), isNull);
    });

    test('reply with marker but malformed JSON → null', () {
      const reply = 'Building.\n[[BUILD_ENTRY]]\n{broken json here';
      expect(extractEntryDraftFromReply(reply), isNull);
    });

    test('entry gets a fresh non-empty id', () {
      const reply =
          '[[BUILD_ENTRY]]\n'
          '{"keys":["A"],"content":"Alpha.","constant":false}';
      final draft = extractEntryDraftFromReply(reply);
      expect(draft, isNotNull);
      expect(draft!.entry.id, isNotEmpty);
    });

    test('keys field as single string accepted', () {
      const reply =
          '[[BUILD_ENTRY]]\n'
          '{"keys":"Solo Key","content":"Solo content.","constant":false}';
      final draft = extractEntryDraftFromReply(reply);
      expect(draft, isNotNull);
      expect(draft!.entry.keys, ['Solo Key']);
    });

    test('reply with reasoning preamble before marker still extracts', () {
      // A reasoning model may emit <think>…</think> before the marker.
      const reply =
          '<think>Let me draft this entry carefully.</think>\n'
          'Entry committed.\n'
          '[[BUILD_ENTRY]]\n'
          '{"keys":["Maela","Maela Vorne"],'
          '"content":"Maela Vorne is the harbor master of Thalorim.",'
          '"constant":false,'
          '"comment":"NPC: Maela Vorne"}';
      final draft = extractEntryDraftFromReply(reply);
      expect(draft, isNotNull);
      expect(draft!.entry.keys, contains('Maela Vorne'));
    });

    test('multi-entry wrapper extracts every draft', () {
      const reply =
          'Done.\n[[BUILD_ENTRY]]\n'
          '{"entries":[{"keys":["Nemeia"],"content":"Nemeia is a sacred crossroads.",'
          '"constant":false,"comment":"Place: Nemeia"},'
          '{"keys":["minor gods"],"content":"Minor gods intervene through signs.",'
          '"constant":false,"comment":"Rule: Minor Gods"},'
          '{"keys":["satyrs"],"content":"Satyrs are disruptive but rarely malicious.",'
          '"constant":false,"comment":"Creature: Satyrs"}]}';

      final drafts = extractEntryDraftsFromReply(reply);
      expect(drafts.length, 3);
      expect(drafts.map((d) => d.entry.keys.single), [
        'Nemeia',
        'minor gods',
        'satyrs',
      ]);
      expect(drafts.map((d) => d.comment), [
        'Place: Nemeia',
        'Rule: Minor Gods',
        'Creature: Satyrs',
      ]);
      expect(extractEntryDraftFromReply(reply)!.entry.keys, ['Nemeia']);
    });
  });

  // ── stripBuildEntryMarker (used by the screen's display path) ─────────────

  group('stripBuildEntryMarker for display', () {
    test('marker stripped, prose kept', () {
      const raw =
          'Entry ready.\n[[BUILD_ENTRY]]\n{"keys":["K"],"content":"C","constant":false}';
      final display = stripBuildEntryMarker(raw);
      expect(display.contains('[[BUILD_ENTRY]]'), isFalse);
      expect(display.contains('Entry ready.'), isTrue);
    });

    test('no marker → returned unchanged (trimmed)', () {
      const raw = 'What should we cover next?';
      expect(stripBuildEntryMarker(raw), raw);
    });
  });

  // ── Save-append logic ──────────────────────────────────────────────────────
  //
  // We exercise the data-model layer directly (no UI / AppStore needed):
  //   extractEntryDraftFromReply → build edited LoreEntry → append to Lorebook.

  group('stream artifact cleanup', () {
    test('finish sentinel is stripped from live display text', () {
      const raw =
          'What should the first entry cover?<<__PYRE_FINISH__:stop__>>';
      expect(
        lorebookCreatorDisplayText(raw),
        'What should the first entry cover?',
      );
    });

    test('dropped-frame sentinel is stripped before parsing/display', () {
      const raw = 'Entry ready.<<__PYRE_DROPPED__:2:FormatException__>>';
      expect(stripLorebookStreamArtifacts(raw), 'Entry ready.');
    });

    test('extractEntryDraftFromReply tolerates finish sentinel after JSON', () {
      const raw =
          '[[BUILD_ENTRY]]\n'
          '{"keys":["Harbor"],"content":"Harbor lore.","constant":false}'
          '<<__PYRE_FINISH__:stop__>>';
      final draft = extractEntryDraftFromReply(raw);
      expect(draft, isNotNull);
      expect(draft!.entry.keys, ['Harbor']);
    });
  });

  group('save-append to lorebook', () {
    test(
      'appending a draft entry to an existing book increments entry count',
      () {
        final book = Lorebook(id: 'lore-1', name: 'Test Book');
        expect(book.entries, isEmpty);

        const reply =
            '[[BUILD_ENTRY]]\n'
            '{"keys":["Harbor","Thalorim Harbor"],'
            '"content":"The harbor of Thalorim.",'
            '"constant":false,'
            '"comment":"Location: Harbor"}';

        final draft = extractEntryDraftFromReply(reply)!;
        // Simulate user-edited keys / content via controller read-back.
        final entry = LoreEntry(
          id: draft.entry.id,
          keys: draft.entry.keys,
          content: draft.entry.content,
          constant: draft.entry.constant,
        );
        book.entries.add(entry);

        expect(book.entries.length, 1);
        expect(book.entries.first.keys, contains('Harbor'));
      },
    );

    test('two saves produce two distinct entries', () {
      final book = Lorebook(id: 'lore-2', name: 'Book 2');

      const reply1 =
          '[[BUILD_ENTRY]]\n'
          '{"keys":["Alpha"],"content":"Alpha lore.","constant":false}';
      const reply2 =
          '[[BUILD_ENTRY]]\n'
          '{"keys":["Beta"],"content":"Beta lore.","constant":true}';

      for (final reply in [reply1, reply2]) {
        final draft = extractEntryDraftFromReply(reply)!;
        book.entries.add(
          LoreEntry(
            id: draft.entry.id,
            keys: draft.entry.keys,
            content: draft.entry.content,
            constant: draft.entry.constant,
          ),
        );
      }

      expect(book.entries.length, 2);
      expect(book.entries[0].keys, contains('Alpha'));
      expect(book.entries[1].keys, contains('Beta'));
      expect(book.entries[1].constant, isTrue);
    });

    test(
      'entries get unique ids across two extractEntryDraftFromReply calls',
      () {
        const reply =
            '[[BUILD_ENTRY]]\n'
            '{"keys":["X"],"content":"Xeno lore.","constant":false}';
        final d1 = extractEntryDraftFromReply(reply)!;
        final d2 = extractEntryDraftFromReply(reply)!;
        // entryJsonToLoreEntry always assigns a fresh id via newId.
        expect(d1.entry.id, isNot(d2.entry.id));
      },
    );
  });

  // ── hasBuildEntryMarker (used by the stream onDone gate) ──────────────────

  group('hasBuildEntryMarker', () {
    test('detects the marker', () {
      expect(hasBuildEntryMarker('foo\n[[BUILD_ENTRY]]\n{}'), isTrue);
    });

    test('no marker → false', () {
      expect(hasBuildEntryMarker('Just chatting.'), isFalse);
    });

    test('case-insensitive detection', () {
      expect(hasBuildEntryMarker('[[build_entry]]'), isTrue);
    });
  });
}
