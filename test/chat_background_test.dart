// Wave CY.18.156: per-chat background override (source + custom image +
// opacity) on the Chat model. null fields = "inherit the global ChatSettings"
// and are OMITTED from JSON so existing chats are byte-identical + unaffected.
//
// Wave CY.18.203: extended for backgroundFit + boxFitFor.

import 'package:flutter/material.dart' show BoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('Chat background override', () {
    test('no override → null fields, keys omitted from JSON (inherit)', () {
      final c = Chat(id: 'c1', characterIds: const ['x']);
      final json = c.toJson();
      expect(json.containsKey('backgroundSource'), isFalse);
      expect(json.containsKey('customBackgroundDataUrl'), isFalse);
      expect(json.containsKey('backgroundOpacity'), isFalse);

      final back = Chat.fromJson(json);
      expect(back.backgroundSource, isNull);
      expect(back.customBackgroundDataUrl, isNull);
      expect(back.backgroundOpacity, isNull);
    });

    test('a full override survives a round-trip', () {
      final c = Chat(
        id: 'c2',
        characterIds: const ['x'],
        backgroundSource: ChatBackgroundSource.custom,
        customBackgroundDataUrl: 'data:image/png;base64,AAAA',
        backgroundOpacity: 0.3,
      );
      final back = Chat.fromJson(c.toJson());
      expect(back.backgroundSource, ChatBackgroundSource.custom);
      expect(back.customBackgroundDataUrl, 'data:image/png;base64,AAAA');
      expect(back.backgroundOpacity, 0.3);
    });

    test('an explicit "none" override is distinct from inherit-null', () {
      final c = Chat(
        id: 'c3',
        characterIds: const ['x'],
        backgroundSource: ChatBackgroundSource.none,
      );
      final back = Chat.fromJson(c.toJson());
      expect(back.backgroundSource, ChatBackgroundSource.none);
    });

    test('enum ↔ name mapping is stable + null/garbage → null', () {
      for (final s in ChatBackgroundSource.values) {
        expect(chatBgSourceFromNameOrNull(chatBgSourceToName(s)), s);
      }
      expect(chatBgSourceFromNameOrNull(null), isNull);
      expect(chatBgSourceFromNameOrNull('bogus'), isNull);
      expect(chatBgSourceFromNameOrNull(42), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Wave CY.18.203: ChatBackgroundFit + boxFitFor
  // -------------------------------------------------------------------------
  group('ChatBackgroundFit', () {
    test('chatBgFitToName / chatBgFitFromNameOrNull round-trip for all values',
        () {
      for (final f in ChatBackgroundFit.values) {
        final name = chatBgFitToName(f);
        expect(chatBgFitFromNameOrNull(name), f,
            reason: 'round-trip failed for $f (name=$name)');
      }
    });

    test('chatBgFitFromNameOrNull returns null for null/unknown', () {
      expect(chatBgFitFromNameOrNull(null), isNull);
      expect(chatBgFitFromNameOrNull('bogus'), isNull);
      expect(chatBgFitFromNameOrNull(42), isNull);
    });

    test('boxFitFor maps each enum value to the correct BoxFit', () {
      expect(boxFitFor(ChatBackgroundFit.cover), BoxFit.cover);
      expect(boxFitFor(ChatBackgroundFit.contain), BoxFit.contain);
      expect(boxFitFor(ChatBackgroundFit.fitWidth), BoxFit.fitWidth);
      expect(boxFitFor(ChatBackgroundFit.fill), BoxFit.fill);
    });

    test('ChatSettings.backgroundFit defaults to cover + survives round-trip',
        () {
      final s = ChatSettings();
      expect(s.backgroundFit, ChatBackgroundFit.cover);

      final j = s.toJson();
      expect(j['backgroundFit'], 'cover');

      final back = ChatSettings.fromJson(j);
      expect(back.backgroundFit, ChatBackgroundFit.cover);
    });

    test('ChatSettings.backgroundFit can be set to contain + persists', () {
      final s = ChatSettings(backgroundFit: ChatBackgroundFit.contain);
      final back = ChatSettings.fromJson(s.toJson());
      expect(back.backgroundFit, ChatBackgroundFit.contain);
    });

    test('ChatSettings.fromJson missing backgroundFit key → cover (default)',
        () {
      // Simulate loading from an old JSON blob that has no backgroundFit key.
      final j = <String, dynamic>{
        'backgroundSource': 'characterAvatar',
        'backgroundOpacity': 0.55,
      };
      final s = ChatSettings.fromJson(j);
      expect(s.backgroundFit, ChatBackgroundFit.cover);
    });

    test('Chat.backgroundFit: null (inherit) is omitted from JSON', () {
      final c = Chat(id: 'c4', characterIds: const ['x']);
      final json = c.toJson();
      expect(json.containsKey('backgroundFit'), isFalse);

      final back = Chat.fromJson(json);
      expect(back.backgroundFit, isNull);
    });

    test('Chat.backgroundFit: set value survives round-trip', () {
      final c = Chat(
        id: 'c5',
        characterIds: const ['x'],
        backgroundFit: ChatBackgroundFit.fitWidth,
      );
      final back = Chat.fromJson(c.toJson());
      expect(back.backgroundFit, ChatBackgroundFit.fitWidth);
    });

    test('Chat.backgroundFit: all non-cover values persist correctly', () {
      for (final f in ChatBackgroundFit.values) {
        final c = Chat(id: 'cx', characterIds: const ['x'], backgroundFit: f);
        expect(Chat.fromJson(c.toJson()).backgroundFit, f);
      }
    });
  });
}
