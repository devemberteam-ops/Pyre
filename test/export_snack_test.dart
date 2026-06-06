import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/widgets/export_snack.dart';

void main() {
  // Pump a host with a button that, when tapped, fires [onReady] with the
  // ScaffoldMessenger so the helper can be driven exactly as a screen would.
  Future<void> pumpHost(
    WidgetTester tester,
    void Function(ScaffoldMessengerState) onReady,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => onReady(ScaffoldMessenger.of(context)),
            child: const Text('go'),
          ),
        ),
      ),
    ));
  }

  testWidgets('shows the banner with a Share action when onShare is given',
      (tester) async {
    await pumpHost(
        tester, (m) => showExportSnack(m, 'Exported — x.card.png', () async {}));
    await tester.tap(find.text('go'));
    await tester.pump(); // schedule
    await tester.pump(); // entrance

    expect(find.text('Exported — x.card.png'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);

    // Drain both the built-in and guaranteed-close timers so the test ends
    // with no pending timers.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('omits the action button when onShare is null', (tester) async {
    await pumpHost(tester, (m) => showExportSnack(m, 'Exported 3 cards', null));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Exported 3 cards'), findsOneWidget);
    expect(find.text('Share'), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('always dismisses within the guaranteed window', (tester) async {
    await pumpHost(
      tester,
      (m) => showExportSnack(m, 'Exported — y.card.png', null,
          visible: const Duration(seconds: 2)),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Exported — y.card.png'), findsOneWidget);

    // visible (2s) + guaranteed (1s) = gone by 4s.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Exported — y.card.png'), findsNothing);
  });
}
