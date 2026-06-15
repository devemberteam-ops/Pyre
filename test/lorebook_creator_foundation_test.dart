// Wave CY.18.XX (Lorebook Creator, Wave 1 foundation): tests for the three
// pure back-end files:
//   - lorebook_entry_schema.dart  → entryJsonToLoreEntry
//   - lorebook_architect_prompts.dart → hasBuildEntryMarker, stripBuildEntryMarker,
//                                        isBuildEntryCommand
//   - lorebook_entry_build.dart   → draftLoreEntry (fake-call)

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/lorebook_entry_schema.dart';
import 'package:pyre/services/lorebook_architect_prompts.dart';
import 'package:pyre/services/lorebook_entry_build.dart';
import 'package:pyre/services/chat_api.dart' show ChatTurn;

void main() {
  // ── entryJsonToLoreEntry ───────────────────────────────────────────────────
  group('entryJsonToLoreEntry', () {
    test('clean JSON maps correctly', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['Thalorim', 'Thal', 'the city'],
        'content': 'Thalorim is a walled coastal city known for its salt markets.',
        'constant': false,
        'comment': 'City: Thalorim',
      });

      expect(entry.keys, ['Thalorim', 'Thal', 'the city']);
      expect(entry.content,
          'Thalorim is a walled coastal city known for its salt markets.');
      expect(entry.constant, isFalse);
      expect(entry.id, startsWith('lore-entry-'));
    });

    test('constant:true preserved', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['The Vael'],
        'content': 'The Vael is the name of the world.',
        'constant': true,
      });
      expect(entry.constant, isTrue);
    });

    test('LoreEntry defaults are intact (enabled, order, secondaryKeys…)', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['Maela'],
        'content': 'A rogue merchant.',
      });
      expect(entry.enabled, isTrue);
      expect(entry.order, 0);
      expect(entry.secondaryKeys, isEmpty);
      expect(entry.probability, 100);
      expect(entry.useProbability, isFalse);
    });

    test('each call generates a unique id', () {
      final a = entryJsonToLoreEntry({'keys': ['k'], 'content': 'c'});
      final b = entryJsonToLoreEntry({'keys': ['k'], 'content': 'c'});
      expect(a.id, isNot(equals(b.id)));
    });

    // ── Key sanitization ────────────────────────────────────────────────────
    test('keys are trimmed and empty strings dropped', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['  Thalorim  ', '', '  Thal  ', '   '],
        'content': 'c',
      });
      expect(entry.keys, ['Thalorim', 'Thal']);
    });

    test('single string for keys → one-element list', () {
      final entry = entryJsonToLoreEntry({
        'keys': 'Maela Vorne',
        'content': 'c',
      });
      expect(entry.keys, ['Maela Vorne']);
    });

    test('null keys → empty list', () {
      final entry = entryJsonToLoreEntry({'content': 'c'});
      expect(entry.keys, isEmpty);
    });

    test('non-string list items are converted via toString', () {
      final entry = entryJsonToLoreEntry({
        'keys': [42, true, 'real-key'],
        'content': 'c',
      });
      // 42 and true convert to their string forms; 'real-key' stays as-is
      expect(entry.keys, contains('real-key'));
      expect(entry.keys.length, 3);
    });

    // ── Bool tolerance ──────────────────────────────────────────────────────
    test('int 0 → constant false', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['k'],
        'content': 'c',
        'constant': 0,
      });
      expect(entry.constant, isFalse);
    });

    test('int 1 → constant true', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['k'],
        'content': 'c',
        'constant': 1,
      });
      expect(entry.constant, isTrue);
    });

    test('int 2 → constant true (non-zero)', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['k'],
        'content': 'c',
        'constant': 2,
      });
      expect(entry.constant, isTrue);
    });

    test('string "true" → constant true', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['k'],
        'content': 'c',
        'constant': 'true',
      });
      expect(entry.constant, isTrue);
    });

    test('string "1" → constant true', () {
      final entry = entryJsonToLoreEntry({
        'keys': ['k'],
        'content': 'c',
        'constant': '1',
      });
      expect(entry.constant, isTrue);
    });

    // ── Missing/wrong-typed fields → safe defaults ──────────────────────────
    test('missing content → empty string', () {
      final entry = entryJsonToLoreEntry({'keys': ['k']});
      expect(entry.content, '');
    });

    test('null content → empty string', () {
      final entry = entryJsonToLoreEntry({'keys': ['k'], 'content': null});
      expect(entry.content, '');
    });

    test('int content → empty string (non-string type rejected)', () {
      final entry = entryJsonToLoreEntry({'keys': ['k'], 'content': 42});
      expect(entry.content, '');
    });

    test('completely empty map → all safe defaults, never throws', () {
      final entry = entryJsonToLoreEntry({});
      expect(entry.keys, isEmpty);
      expect(entry.content, '');
      expect(entry.constant, isFalse);
      expect(entry.enabled, isTrue);
    });

    test('unexpected types for keys field → empty list', () {
      final entry = entryJsonToLoreEntry({'keys': 99, 'content': 'c'});
      expect(entry.keys, isEmpty);
    });

    test('comment field in JSON is silently accepted (no crash)', () {
      // LoreEntry has no comment field — entryJsonToLoreEntry ignores it.
      expect(
        () => entryJsonToLoreEntry({
          'keys': ['k'],
          'content': 'c',
          'comment': 'NPC: Foo',
        }),
        returnsNormally,
      );
    });

    test('extra unknown keys in JSON are silently ignored', () {
      expect(
        () => entryJsonToLoreEntry({
          'keys': ['k'],
          'content': 'c',
          'colour': 'blue',
          'flavour': 'sweet',
        }),
        returnsNormally,
      );
    });
  });

  // ── hasBuildEntryMarker ────────────────────────────────────────────────────
  group('hasBuildEntryMarker', () {
    test('detects the marker in a complete reply', () {
      const reply = "Sure thing!\n[[BUILD_ENTRY]]\n"
          '{"keys":["Tide-Priests"],"content":"The Tide-Priests serve the deep.","constant":false,"comment":"Faction: Tide-Priests"}';
      expect(hasBuildEntryMarker(reply), isTrue);
    });

    test('returns false for a reply without the marker', () {
      expect(hasBuildEntryMarker('How about we draft this entry?'), isFalse);
    });

    test('case-insensitive: lowercase marker detected', () {
      expect(hasBuildEntryMarker('ok\n[[build_entry]]\n{}'), isTrue);
    });

    test('whitespace inside brackets tolerated', () {
      expect(hasBuildEntryMarker('[[ BUILD_ENTRY ]]'), isTrue);
    });
  });

  // ── stripBuildEntryMarker ─────────────────────────────────────────────────
  group('stripBuildEntryMarker', () {
    test('strips the [[BUILD_ENTRY]] token, leaving confirmation and JSON line', () {
      const raw = 'Great, building it now.\n\n[[BUILD_ENTRY]]\n'
          '{"keys":["Thalorim"],"content":"A coastal city.","constant":false,"comment":"City: Thalorim"}';
      final stripped = stripBuildEntryMarker(raw);
      // The marker token is stripped; the confirmation + JSON object survive.
      expect(stripped.contains('[[BUILD_ENTRY]]'), isFalse);
      expect(stripped.contains('Great, building it now.'), isTrue);
      // The JSON object line is preserved — the drafter needs it.
      expect(stripped.contains('"Thalorim"'), isTrue);
    });

    test('no marker → trimmed input returned unchanged', () {
      const raw = '  Let me know if you want to adjust the keys.  ';
      expect(stripBuildEntryMarker(raw), 'Let me know if you want to adjust the keys.');
    });

    test('multiple markers all stripped', () {
      const raw = '[[BUILD_ENTRY]]\ntext\n[[BUILD_ENTRY]]';
      final stripped = stripBuildEntryMarker(raw);
      expect(stripped.contains('[[BUILD_ENTRY]]'), isFalse);
      expect(stripped.contains('text'), isTrue);
    });

    test('case-insensitive stripping', () {
      const raw = 'Done.\n[[build_entry]]\n{}';
      final stripped = stripBuildEntryMarker(raw);
      expect(stripped.contains('build_entry'), isFalse);
      expect(stripped.contains('Done.'), isTrue);
    });

    test('trailing whitespace/newlines after marker absorbed', () {
      const raw = 'Ok.\n\n[[BUILD_ENTRY]]\n   \n';
      final stripped = stripBuildEntryMarker(raw);
      expect(stripped.trim(), 'Ok.');
    });

    test('non-ASCII confirmation line preserved verbatim', () {
      const raw = 'Construindo agora — вот, 了解.\n[[BUILD_ENTRY]]\n{}';
      final stripped = stripBuildEntryMarker(raw);
      expect(stripped.contains('Construindo agora'), isTrue);
      expect(stripped.contains('[[BUILD_ENTRY]]'), isFalse);
    });
  });

  // ── isBuildEntryCommand ───────────────────────────────────────────────────
  group('isBuildEntryCommand', () {
    test('/entry matches', () {
      expect(isBuildEntryCommand('/entry'), isTrue);
    });

    test('/build it matches', () {
      expect(isBuildEntryCommand('/build it'), isTrue);
    });

    test('build it (no slash) matches', () {
      expect(isBuildEntryCommand('build it'), isTrue);
    });

    test('case-insensitive', () {
      expect(isBuildEntryCommand('/ENTRY'), isTrue);
      expect(isBuildEntryCommand('/BUILD IT'), isTrue);
      expect(isBuildEntryCommand('BUILD IT'), isTrue);
    });

    test('surrounding whitespace tolerated', () {
      expect(isBuildEntryCommand('  /entry  '), isTrue);
      expect(isBuildEntryCommand('  /build it  '), isTrue);
      expect(isBuildEntryCommand('\t/build it\n'), isTrue);
    });

    test('partial / extra text → not a command', () {
      expect(isBuildEntryCommand('/entry now'), isFalse);
      expect(isBuildEntryCommand('entry'), isFalse);
      expect(isBuildEntryCommand('please /entry'), isFalse);
      expect(isBuildEntryCommand('/build'), isFalse);
      expect(isBuildEntryCommand(''), isFalse);
      expect(isBuildEntryCommand('can you build it please'), isFalse);
    });
  });

  // ── draftLoreEntry ────────────────────────────────────────────────────────
  group('draftLoreEntry', () {
    /// Helper: a fake `call` that always returns [response].
    Future<String> Function(List<ChatTurn>) fakeCall(String response) {
      return (_) async => response;
    }

    /// A minimal valid JSON entry response.
    const validJson =
        '{"keys":["Thalorim","Thal"],"content":"A walled city by the sea.","constant":false,"comment":"City: Thalorim"}';

    test('clean JSON reply → returns parsed LoreEntry', () async {
      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'Tell me about Thalorim.')],
        call: fakeCall(validJson),
      );
      expect(entry, isNotNull);
      expect(entry!.keys, containsAll(['Thalorim', 'Thal']));
      expect(entry.content, 'A walled city by the sea.');
      expect(entry.constant, isFalse);
    });

    test('JSON wrapped in prose → still parses (extractJsonObject)', () async {
      const wrapped =
          'Here is the finished entry:\n$validJson\nLet me know if you want edits.';
      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok go')],
        call: fakeCall(wrapped),
      );
      expect(entry, isNotNull);
      expect(entry!.keys, containsAll(['Thalorim', 'Thal']));
    });

    test('JSON wrapped in a ```json fence → still parses', () async {
      const fenced = '```json\n$validJson\n```';
      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: fakeCall(fenced),
      );
      expect(entry, isNotNull);
      expect(entry!.content, 'A walled city by the sea.');
    });

    test('garbage reply → returns null', () async {
      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: fakeCall('Sorry, I cannot do that. (refusal/garbage)'),
      );
      expect(entry, isNull);
    });

    test('empty reply → returns null', () async {
      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: fakeCall(''),
      );
      expect(entry, isNull);
    });

    test('reasoning preamble (<think>…</think>) before JSON → still parses',
        () async {
      const withReasoning =
          '<think>The user wants an entry about Thalorim. Let me draft the JSON.'
          ' {"keys":["draft"],"content":"draft content."}'  // draft inside think
          '</think>\n'
          '$validJson'; // real answer after </think>
      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: fakeCall(withReasoning),
      );
      // Should pick up the object AFTER </think> (Thalorim), not the draft inside.
      expect(entry, isNotNull);
      expect(entry!.keys, containsAll(['Thalorim', 'Thal']));
    });

    test('reasoning with JSON ONLY inside <think> → falls back and still parses',
        () async {
      // Degenerate case: the model put its answer ONLY inside <think>.
      const onlyInThink =
          '<think>$validJson</think>';
      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: fakeCall(onlyInThink),
      );
      // extractJsonAfterReasoning falls back to scanning the whole buffer.
      expect(entry, isNotNull);
      expect(entry!.keys, containsAll(['Thalorim', 'Thal']));
    });

    test('truncated reply triggers ONE continuation then parses', () async {
      // The partial is a truncated JSON object — string cut mid-value (no closing quote).
      // looksTruncatedJson returns true because the brace scan ends inside an
      // unterminated string.
      const partial =
          '{"keys":["Thalorim","Thal"],"content":"A walled city by the'; // mid-string cut
      // The continuation resumes exactly where it left off (the rest of the
      // string value + the remaining keys), producing a valid stitched object.
      const continuation =
          ' sea.","constant":false,"comment":"City: Thalorim"}';

      var callCount = 0;
      Future<String> trackingCall(List<ChatTurn> turns) async {
        callCount++;
        if (callCount == 1) return partial;
        return continuation;
      }

      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: trackingCall,
      );
      expect(callCount, 2); // initial + exactly one continuation
      expect(entry, isNotNull);
      expect(entry!.keys, containsAll(['Thalorim', 'Thal']));
      expect(entry.content, 'A walled city by the sea.');
    });

    test('truncated then garbage continuation → returns null after 1 continuation',
        () async {
      var callCount = 0;
      Future<String> trackingCall(List<ChatTurn> turns) async {
        callCount++;
        // Partial truncated mid-string — looksTruncatedJson → true.
        if (callCount == 1) return '{"keys":["k"],"content":"partial value that never';
        // The continuation is garbage and does not complete the JSON.
        return 'still garbage no closing brace ever';
      }

      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: trackingCall,
      );
      expect(callCount, 2); // bounded: max 1 continuation
      expect(entry, isNull);
    });

    test('network error (call throws) → returns null', () async {
      Future<String> errorCall(List<ChatTurn> _) async {
        throw Exception('network error');
      }

      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: errorCall,
      );
      expect(entry, isNull);
    });

    test('continuation call throws → returns null (bounded, no rethrow)', () async {
      var callCount = 0;
      Future<String> trackingCall(List<ChatTurn> turns) async {
        callCount++;
        if (callCount == 1) return '{"keys":["k"],"content":"partial'; // truncated
        throw Exception('provider unavailable');
      }

      final entry = await draftLoreEntry(
        turns: [ChatTurn('user', 'ok')],
        call: trackingCall,
      );
      expect(entry, isNull);
    });
  });
}
