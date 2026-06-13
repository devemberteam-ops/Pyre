// Pyre 1.1.3 (liveoaktripper / Gui): the "Add system note" chat action is a
// power-user feature most people never touch, so it is HIDDEN by default and
// opt-in via Chat Settings → System note. The toggle lives on ChatSettings so
// it persists + rides the existing synced-settings unit for free. These tests
// pin the default (off) and the JSON round-trip.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('ChatSettings.systemNoteEnabled', () {
    test('defaults to false — the Add system note action is hidden by default',
        () {
      expect(ChatSettings().systemNoteEnabled, isFalse);
    });

    test('round-trips true through toJson/fromJson', () {
      final restored =
          ChatSettings.fromJson(ChatSettings(systemNoteEnabled: true).toJson());
      expect(restored.systemNoteEnabled, isTrue);
    });

    test('an old saved blob without the key defaults to false', () {
      expect(
        ChatSettings.fromJson(const <String, dynamic>{}).systemNoteEnabled,
        isFalse,
      );
    });

    test('copyWith carries the flag and can override it', () {
      final base = ChatSettings(systemNoteEnabled: true);
      expect(base.copyWith().systemNoteEnabled, isTrue);
      expect(
          base.copyWith(systemNoteEnabled: false).systemNoteEnabled, isFalse);
    });
  });
}
