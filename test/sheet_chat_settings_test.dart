// Audit B4(a) (owner-decided): `ModelSettings.sheetTemperature` was a dead
// setting — every creator call (including the structured/surgical-JSON
// canvas-fill and Description-edit calls) ran on `creatorTemperature`
// instead. Wire it: the STRUCTURED calls in `_runStructuredBuildFlow`
// (creator-structured batch fill, creator-surgical-desc edit) now build
// their settings via `sheetChatSettingsFor`, a sibling of
// `_creatorChatSettings` that swaps in `sheetTemperature`. The freeform
// design CONVERSATION (architect turn) is untouched and keeps
// `creatorTemperature`.
//
// `sheetChatSettingsFor` is a top-level `@visibleForTesting` pure function
// (the enclosing `_CharacterAssistantScreenState` is library-private, so
// this is the pure seam) — the State class's private `_sheetChatSettings`
// just delegates to it.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/character_assistant_screen.dart';

void main() {
  group('sheetChatSettingsFor', () {
    test('temperature comes from sheetTemperature, not creatorTemperature',
        () {
      final base = ModelSettings()
        ..creatorTemperature = 0.95
        ..sheetTemperature = 0.2;

      final out = sheetChatSettingsFor(base);

      expect(out.temperature, base.sheetTemperature);
      expect(out.temperature, isNot(base.creatorTemperature));
    });

    test('maxTokens still comes from creatorMaxTokens (unchanged cap)', () {
      final base = ModelSettings()..creatorMaxTokens = 7777;
      final out = sheetChatSettingsFor(base);
      expect(out.maxTokens, 7777);
    });

    test('a custom sheetTemperature value round-trips exactly', () {
      final base = ModelSettings()..sheetTemperature = 0.05;
      expect(sheetChatSettingsFor(base).temperature, 0.05);
    });

    test('does not mutate the input ModelSettings', () {
      final base = ModelSettings()
        ..temperature = 0.7
        ..creatorTemperature = 0.95
        ..sheetTemperature = 0.2;
      sheetChatSettingsFor(base);
      // The base object's own (chat-side) temperature is untouched.
      expect(base.temperature, 0.7);
    });
  });
}
