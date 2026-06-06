// Mega-audit 2026-06-04 — STATE batch.
//
//   presets-regex-appearance-01 (CRITICAL) — widget regression.
//
// Reproduces the exact reported path end-to-end: the user customizes bubble +
// background fields (stored in the global ChatSettings), then opens the
// Behaviors screen and toggles ONE behavior. Before the fix, the Behaviors
// screen rebuilt a partial ChatSettings (7 of 15 fields) and `updateChatSettings`
// full-replaced it, wiping every customization back to the constructor default.
// After the fix the screen clones via copyWith() so the 8 unmanaged fields
// survive the commit.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_behaviors_screen.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

Widget _host(AppStore store, Widget screen) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: screen),
    );

void main() {
  testWidgets(
      'toggling a Behaviors setting does NOT reset bubble/background customization',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = AppStore(storage: _NoopBackend());
    // The user has customized appearance (the 8 fields the Behaviors screen
    // does not manage). Start with a known-default delete behavior so the
    // toggle below is a real change.
    store.updateChatSettings(ChatSettings(
      deleteBehavior: DeleteBehavior.onlyThis,
      userBubbleColor: 0xFF112233,
      aiBubbleColor: 0xFF445566,
      bubbleCornerRadius: 24.0,
      bubbleBorderWidth: 3.0,
      bubbleBorderColor: 0xFF778899,
      bubbleBlurSigma: 5.5,
      bubbleTextScale: 1.4,
      backgroundFit: ChatBackgroundFit.contain,
    ));

    await tester.pumpWidget(_host(store, const ChatBehaviorsScreen()));
    await tester.pumpAndSettle();

    // Toggle the delete behavior via the segmented button.
    await tester.tap(find.text('This message and after'));
    await tester.pumpAndSettle();

    final cs = store.chatSettings;
    // The behavior we changed took effect.
    expect(cs.deleteBehavior, DeleteBehavior.thisAndAfter);
    // EVERY customization field must be intact (regression assertion).
    expect(cs.userBubbleColor, 0xFF112233);
    expect(cs.aiBubbleColor, 0xFF445566);
    expect(cs.bubbleCornerRadius, 24.0);
    expect(cs.bubbleBorderWidth, 3.0);
    expect(cs.bubbleBorderColor, 0xFF778899);
    expect(cs.bubbleBlurSigma, 5.5);
    expect(cs.bubbleTextScale, 1.4);
    expect(cs.backgroundFit, ChatBackgroundFit.contain);

    await store.flushPersist();
  });
}
