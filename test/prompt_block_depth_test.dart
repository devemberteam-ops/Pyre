// Preset Prompt Manager Core (ST parity), Task 1: PromptBlock gains a nullable
// `depth`. null = use `position` (beforeHistory/afterHistory) exactly as today.
// Non-null = inject the block as a turn at `depth` messages from the END of the
// chat history (mirrors ST `injection_depth`). toJson OMITS it when null so
// existing preset blobs / backups / sync payloads stay byte-identical.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('PromptBlock.depth', () {
    test('defaults to null and is OMITTED from toJson (byte-identical blobs)', () {
      final b = PromptBlock(id: 'b', name: 'x');
      expect(b.depth, isNull);
      expect(b.toJson().containsKey('depth'), isFalse);
    });

    test('round-trips a set depth', () {
      final b = PromptBlock(id: 'b', name: 'x', depth: 3);
      expect(b.toJson()['depth'], 3);
      expect(PromptBlock.fromJson(b.toJson()).depth, 3);
    });

    test('fromJson without depth → null', () {
      expect(PromptBlock.fromJson({'id': 'b', 'name': 'x'}).depth, isNull);
    });

    test('fromJson tolerates a num depth', () {
      expect(PromptBlock.fromJson({'id': 'b', 'name': 'x', 'depth': 4}).depth, 4);
    });
  });
}
