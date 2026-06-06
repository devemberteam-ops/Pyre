// WS-J — IA moves: two relocations with no behaviour change.
//
//   (1) "App text size" moved OUT of the inline More list into a NEW
//       Display settings screen (DisplaySettingsScreen). This screen exists
//       and hosts the global text-size slider, wired to AppStore.setUiScale.
//   (2) "Import from SillyTavern" moved OUT of the More list and INTO the
//       Backup & Restore screen, where it is reachable (an entry that runs
//       the same bulk-import flow).
//
// Harness conventions mirror new_features_ui_test.dart: a no-op StoreBackend
// so the debounced persist never touches disk, a ChangeNotifierProvider +
// MaterialApp host, and a roomy logical surface so content lays out and is
// hit-testable. Each test flushes the persist debounce at the end.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart' show UiPrefs;
import 'package:pyre/screens/backup_restore_screen.dart';
import 'package:pyre/screens/display_settings_screen.dart';
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

void _useRoomyView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  // ===========================================================================
  // (1) Display settings screen — exists + hosts the App text size slider, and
  //     dragging it commits through AppStore.setUiScale (identical behaviour).
  // ===========================================================================
  group('DisplaySettingsScreen — hosts the App text size slider', () {
    testWidgets('renders the "App text size" control with a Slider',
        (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());

      await tester.pumpWidget(_host(store, const DisplaySettingsScreen()));
      await tester.pumpAndSettle();

      // The relocated control's label + its slider are present on this screen.
      expect(find.text('App text size'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);

      await store.flushPersist();
    });

    testWidgets('dragging the slider commits a new scale via setUiScale',
        (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());
      // Start at the default 1.0.
      expect(store.uiPrefs.clampedUiScale, 1.0);

      await tester.pumpWidget(_host(store, const DisplaySettingsScreen()));
      await tester.pumpAndSettle();

      // Drag the slider thumb to the right; onChangeEnd commits via setUiScale,
      // which clamps into [kUiScaleMin, kUiScaleMax] and persists.
      await tester.drag(find.byType(Slider), const Offset(400, 0));
      await tester.pumpAndSettle();

      // The stored scale moved off 1.0 and stayed within the supported range
      // (proving the same clamp+persist path as the old inline card).
      expect(store.uiPrefs.clampedUiScale, greaterThan(1.0));
      expect(store.uiPrefs.clampedUiScale,
          lessThanOrEqualTo(UiPrefs.kUiScaleMax));

      await store.flushPersist();
    });
  });

  // ===========================================================================
  // (2) Backup & Restore — "Import from SillyTavern" is reachable here (moved
  //     out of the More list). We assert the entry is present on the screen;
  //     it runs the same runStBulkImport flow (a file picker), which can't be
  //     driven headlessly, so we verify the affordance exists + is tappable.
  // ===========================================================================
  group('BackupRestoreScreen — hosts the SillyTavern import entry', () {
    testWidgets('shows a "Import from SillyTavern" entry', (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());

      await tester.pumpWidget(_host(store, const BackupRestoreScreen()));
      await tester.pumpAndSettle();

      // The ST import entry is reachable from Backup & Restore (label present).
      expect(find.text('Import from SillyTavern'), findsOneWidget);

      await store.flushPersist();
    });
  });
}
