// 1.2.1 #3: the "Import a chat" entry point on Backup & Restore. We can't drive
// the OS file picker headlessly, so (like ia_moves_test for the ST importer) we
// assert the affordance is present + tappable — proof the entry is wired.
//
// Harness mirrors ia_moves_test: a no-op StoreBackend so the debounced persist
// never touches disk, a roomy logical surface so content lays out.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/screens/backup_restore_screen.dart';
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

Widget _host(AppStore store) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: const MaterialApp(home: BackupRestoreScreen()),
    );

void main() {
  testWidgets('Backup & Restore shows a tappable "Import a chat" entry',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = AppStore(storage: _NoopBackend());
    await tester.pumpWidget(_host(store));
    await tester.pumpAndSettle();

    // Section header + the button that runs the import flow.
    expect(find.text('Import a chat'), findsOneWidget);
    final button = find.widgetWithText(OutlinedButton, 'Choose chat file…');
    expect(button, findsOneWidget);
    // Tappable without throwing (the picker itself is a no-op in tests).
    await tester.ensureVisible(button);
    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
  });
}
