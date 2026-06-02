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
