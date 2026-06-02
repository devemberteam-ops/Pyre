import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/model_metadata.dart';

void main() {
  group('parseContextWindow', () {
    test('OpenRouter top-level context_length', () {
      expect(
          parseContextWindow({'id': 'x', 'context_length': 200000}), 200000);
    });

    test('OpenRouter nested top_provider.context_length when top-level absent',
        () {
      expect(
          parseContextWindow({
            'id': 'x',
            'top_provider': {'context_length': 131072},
          }),
          131072);
    });

    test('top-level wins over nested', () {
      expect(
          parseContextWindow({
            'context_length': 200000,
            'top_provider': {'context_length': 64000},
          }),
          200000);
    });

    test('vLLM max_model_len', () {
      expect(parseContextWindow({'id': 'x', 'max_model_len': 32768}), 32768);
    });

    test('context_window key', () {
      expect(parseContextWindow({'context_window': 8192}), 8192);
    });

    test('string number is parsed', () {
      expect(parseContextWindow({'context_length': '128000'}), 128000);
    });

    test('num (double) is floored to int', () {
      expect(parseContextWindow({'context_length': 128000.0}), 128000);
    });

    test('absent / zero / negative / junk → null', () {
      expect(parseContextWindow({'id': 'x'}), isNull);
      expect(parseContextWindow({'context_length': 0}), isNull);
      expect(parseContextWindow({'context_length': -5}), isNull);
      expect(parseContextWindow({'context_length': 'lots'}), isNull);
      expect(parseContextWindow({'top_provider': 'nope'}), isNull);
    });
  });
}
