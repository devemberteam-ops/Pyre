// Audit B4(b) (owner-decided): the Behaviors screen's "Streaming" toggle
// bound to `ModelSettings.stream`, but no send path ever consulted that
// field — flipping it did nothing observable. Remove the inert control.
// `ModelSettings.stream` itself stays (backup/sync compat — old blobs carry
// it; it's just parsed-and-unused from now on).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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
  testWidgets('the Behaviors screen no longer shows a Streaming toggle',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = AppStore(storage: _NoopBackend());
    await tester.pumpWidget(_host(store, const ChatBehaviorsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Streaming'), findsNothing);
    expect(
      find.text('Display the response bit by bit as it is generated.'),
      findsNothing,
    );
  });
}
