// Tests for creator_json.dart (Wave CY.18.227, Creator Structured Build, Task 3).
// All tests are headless — pure Dart, no Flutter.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_json.dart';

void main() {
  group('extractJsonObject', () {
    test('1. clean object returns correct map', () {
      const reply = '{"name":"Ren","age":"21"}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['name'], 'Ren');
      expect(result['age'], '21');
    });

    test('2. ```json-fenced object is extracted', () {
      const reply = '```json\n{"a":"x"}\n```';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['a'], 'x');
    });

    test('3. prose-wrapped object is extracted', () {
      const reply = 'Sure, here you go: {"a":"x"} — hope that helps!';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['a'], 'x');
    });

    test('4. braces inside string values do not break the scan', () {
      const reply = '{"note":"use {curly} braces {here}","b":"y"}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['note'], 'use {curly} braces {here}');
      expect(result['b'], 'y');
    });

    test('5. escaped quote inside a string is handled correctly', () {
      // Dart string: '{"q":"she said \\"hi\\"","b":"y"}'
      // JSON:        {"q":"she said \"hi\"","b":"y"}
      const reply = '{"q":"she said \\"hi\\"","b":"y"}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['q'], 'she said "hi"');
      expect(result['b'], 'y');
    });

    test('6. trailing comma is tolerated', () {
      const reply = '{"a":"x","b":"y",}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['a'], 'x');
      expect(result['b'], 'y');
    });

    test('7. truncated mid-string returns null', () {
      const reply = '{"a":"x","b":"unter';
      expect(extractJsonObject(reply), isNull);
    });

    test('8. truncated mid-object (unbalanced braces) returns null', () {
      const reply = '{"a":"x","b":{"c":"d"';
      expect(extractJsonObject(reply), isNull);
    });

    test('9. top-level array returns null', () {
      const reply = '[1,2,3]';
      expect(extractJsonObject(reply), isNull);
    });

    test('10. no JSON at all returns null', () {
      const reply = 'I cannot help with that.';
      expect(extractJsonObject(reply), isNull);
    });

    // CRITICAL 3: a BALANCED object that is invalid only because a value string
    // contains a raw newline (a lone control char) — very common with cheap
    // models writing multi-line prose into a field — is REPAIRED, not dropped.
    test('11. raw newline inside a string value is repaired', () {
      // Dart raw string: the value spans two physical lines (a literal LF).
      const reply = '{"a":"line one\nline two","b":"y"}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull, reason: 'a lone control char must be repaired');
      expect(result!['a'], 'line one\nline two');
      expect(result['b'], 'y');
    });

    // CRITICAL 3: a raw tab inside a string value is also repaired.
    test('12. raw tab inside a string value is repaired', () {
      const reply = '{"a":"col1\tcol2","b":"y"}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['a'], 'col1\tcol2');
      expect(result['b'], 'y');
    });

    // CRITICAL 3: smart/curly quotes a model emits inside a string value (or as
    // an apostrophe) don't break decoding — they decode as literal characters.
    test('13. smart quotes inside string values are preserved + decode', () {
      // Curly double quotes and a curly apostrophe inside the VALUE.
      const reply = '{"a":"she said “hi”","b":"it’s fine"}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull);
      expect(result!['a'], 'she said “hi”');
      expect(result['b'], 'it’s fine');
    });

    // CRITICAL 3: a model that uses SMART double-quotes as the JSON string
    // DELIMITERS (instead of straight ASCII ") is normalised + parsed.
    test('14. smart double-quotes used as string delimiters are normalised', () {
      const reply = '{“a”:“x”,“b”:“y”}';
      final result = extractJsonObject(reply);
      expect(result, isNotNull, reason: 'smart-quote delimiters must normalise');
      expect(result!['a'], 'x');
      expect(result['b'], 'y');
    });

    // CRITICAL 3: the repair pass must NOT corrupt a genuinely truncated reply
    // into a false-positive — an unbalanced object still returns null.
    test('15. repair does not rescue a truncated (unbalanced) object', () {
      const reply = '{"a":"x","b":{"c":"d"';
      expect(extractJsonObject(reply), isNull);
    });
  });

  group('extractJsonAfterReasoning (HIGH 5)', () {
    test('prefers the object AFTER </think>, not a draft inside <think>', () {
      // A reasoning model drafts a half-formed object inside <think>, then emits
      // the real answer after closing the reasoning channel. The first `{` is
      // the DRAFT; we must recover the FINAL object instead.
      const raw =
          '<think>let me try {"face":"maybe round?"} hmm</think>'
          '{"face":"Round, soft.","hair":"Black"}';
      final result = extractJsonAfterReasoning(raw);
      expect(result, isNotNull);
      expect(result!['face'], 'Round, soft.');
      expect(result['hair'], 'Black');
    });

    test('falls back to the whole buffer when there is no </think>', () {
      const raw = '{"a":"x","b":"y"}';
      final result = extractJsonAfterReasoning(raw);
      expect(result, isNotNull);
      expect(result!['a'], 'x');
    });

    test('uses the LAST </think> when several are present', () {
      const raw = '<think>draft {"a":"1"}</think>'
          '<think>more {"a":"2"}</think>'
          '{"a":"final"}';
      final result = extractJsonAfterReasoning(raw);
      expect(result, isNotNull);
      expect(result!['a'], 'final');
    });

    test('recovers a JSON object that is INSIDE the reasoning when there is no '
        'post-think object', () {
      // Some models put the whole answer in the reasoning channel and never
      // close it (or close it after the object) — fall back to scanning the
      // whole buffer so we still recover it.
      const raw = '<think>here is the card: {"a":"x"}</think>';
      final result = extractJsonAfterReasoning(raw);
      expect(result, isNotNull);
      expect(result!['a'], 'x');
    });

    test('returns null when there is no object anywhere', () {
      const raw = '<think>I cannot do that.</think>';
      expect(extractJsonAfterReasoning(raw), isNull);
    });
  });

  group('looksTruncatedJson', () {
    test('1. clean object is NOT truncated', () {
      expect(looksTruncatedJson('{"name":"Ren","age":"21"}'), isFalse);
    });

    test('2. ```json-fenced object is NOT truncated', () {
      expect(looksTruncatedJson('```json\n{"a":"x"}\n```'), isFalse);
    });

    test('3. prose-wrapped object is NOT truncated', () {
      expect(looksTruncatedJson('Sure, here you go: {"a":"x"} — hope!'),
          isFalse);
    });

    test('4. braces inside string value: NOT truncated', () {
      expect(
          looksTruncatedJson('{"note":"use {curly} braces {here}","b":"y"}'),
          isFalse);
    });

    test('7. truncated mid-string IS truncated', () {
      expect(looksTruncatedJson('{"a":"x","b":"unter'), isTrue);
    });

    test('8. truncated mid-object (unbalanced) IS truncated', () {
      expect(looksTruncatedJson('{"a":"x","b":{"c":"d"'), isTrue);
    });

    test('10. no JSON at all is NOT truncated', () {
      expect(looksTruncatedJson('I cannot help with that.'), isFalse);
    });
  });
}
