// Mega-audit 2026-06-04 — STATE batch.
//
//   presets-regex-appearance-01 — toggling any Behaviors setting must NOT
//   wipe the bubble/background customization fields. The Behaviors screen's
//   per-screen draft used to copy only 7 of the 15 ChatSettings fields, and
//   `updateChatSettings` full-replaces, so the 8 omitted fields fell back to
//   constructor defaults on every Behaviors commit. The fix is a
//   `ChatSettings.copyWith` that carries EVERY field forward; the Behaviors
//   screen edits a copyWith of the live settings so nothing can be dropped.
//
// This test locks the copyWith contract: a fully-customized settings object
// round-trips through copyWith with a single behavior field changed and EVERY
// other field is preserved bit-for-bit.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  group('presets-regex-appearance-01 — ChatSettings.copyWith preserves all 15 fields', () {
    // A non-default value for every single field, so any dropped field
    // reverts to a constructor default and the test catches it.
    ChatSettings fullyCustom() => ChatSettings(
          deleteBehavior: DeleteBehavior.thisAndAfter,
          hideReasoning: false,
          bubbleAlpha: 0.31,
          backgroundSource: ChatBackgroundSource.custom,
          customBackgroundDataUrl: 'data:image/png;base64,AAAA',
          backgroundOpacity: 0.42,
          backgroundFit: ChatBackgroundFit.contain,
          askPersonaOnNewChat: false,
          userBubbleColor: 0xFF112233,
          aiBubbleColor: 0xFF445566,
          bubbleCornerRadius: 24.0,
          bubbleBorderWidth: 3.0,
          bubbleBorderColor: 0xFF778899,
          bubbleBlurSigma: 5.5,
          bubbleTextScale: 1.4,
        );

    void expectAllFieldsEqual(ChatSettings a, ChatSettings b) {
      expect(a.deleteBehavior, b.deleteBehavior);
      expect(a.hideReasoning, b.hideReasoning);
      expect(a.bubbleAlpha, b.bubbleAlpha);
      expect(a.backgroundSource, b.backgroundSource);
      expect(a.customBackgroundDataUrl, b.customBackgroundDataUrl);
      expect(a.backgroundOpacity, b.backgroundOpacity);
      expect(a.backgroundFit, b.backgroundFit);
      expect(a.askPersonaOnNewChat, b.askPersonaOnNewChat);
      expect(a.userBubbleColor, b.userBubbleColor);
      expect(a.aiBubbleColor, b.aiBubbleColor);
      expect(a.bubbleCornerRadius, b.bubbleCornerRadius);
      expect(a.bubbleBorderWidth, b.bubbleBorderWidth);
      expect(a.bubbleBorderColor, b.bubbleBorderColor);
      expect(a.bubbleBlurSigma, b.bubbleBlurSigma);
      expect(a.bubbleTextScale, b.bubbleTextScale);
    }

    test('copyWith() with no args is a faithful clone of all fields', () {
      final src = fullyCustom();
      final clone = src.copyWith();
      expectAllFieldsEqual(clone, src);
    });

    test('changing ONE behavior field keeps every customization field', () {
      final src = fullyCustom();
      // Simulate the Behaviors screen toggling delete behavior.
      final next = src.copyWith(deleteBehavior: DeleteBehavior.onlyThis);
      expect(next.deleteBehavior, DeleteBehavior.onlyThis);
      // Every appearance/bubble field must survive untouched.
      expect(next.userBubbleColor, 0xFF112233);
      expect(next.aiBubbleColor, 0xFF445566);
      expect(next.bubbleCornerRadius, 24.0);
      expect(next.bubbleBorderWidth, 3.0);
      expect(next.bubbleBorderColor, 0xFF778899);
      expect(next.bubbleBlurSigma, 5.5);
      expect(next.bubbleTextScale, 1.4);
      expect(next.backgroundFit, ChatBackgroundFit.contain);
      expect(next.backgroundSource, ChatBackgroundSource.custom);
      expect(next.customBackgroundDataUrl, 'data:image/png;base64,AAAA');
      expect(next.backgroundOpacity, 0.42);
      expect(next.bubbleAlpha, 0.31);
      expect(next.hideReasoning, false);
    });

    test('toggling askPersonaOnNewChat keeps every customization field', () {
      final src = fullyCustom();
      final next = src.copyWith(askPersonaOnNewChat: true);
      expect(next.askPersonaOnNewChat, true);
      // The previously-CUSTOM fields must not revert to constructor defaults.
      expect(next.bubbleCornerRadius, isNot(12.0));
      expect(next.bubbleTextScale, isNot(1.0));
      expect(next.userBubbleColor, isNotNull);
      expect(next.backgroundFit, ChatBackgroundFit.contain);
    });

    test('copyWith preserves a non-null nullable field when omitted', () {
      final src = fullyCustom();
      // Omitting a nullable arg must keep the current (non-null) value — this
      // is the only copyWith semantic the Behaviors screen relies on (it never
      // clears a color; it only flips deleteBehavior / askPersonaOnNewChat).
      final next = src.copyWith(hideReasoning: true);
      expect(next.hideReasoning, true);
      expect(next.userBubbleColor, 0xFF112233);
      expect(next.customBackgroundDataUrl, 'data:image/png;base64,AAAA');
      expect(next.bubbleBorderColor, 0xFF778899);
    });
  });
}
