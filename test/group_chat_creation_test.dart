// Facilidade (owner 2026-07): create a GROUP chat in one flow. Covers the
// multi-select GroupCharacterPickerScreen — the primary is locked on and the
// popped id list preserves selection order (primary first), which becomes the
// member order of the created chat.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_picker_screens.dart';
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

Character _char(String id, String name) => Character(
    id: id, name: name, description: 'x', createdAt: 0, updatedAt: 0);

void main() {
  testWidgets(
      'group picker: primary locked on, popped list preserves order '
      '(primary first)', (tester) async {
    final store = AppStore(storage: _NoopBackend());
    final a = _char('ca', 'Sera');
    final b = _char('cb', 'Talia');
    final c = _char('cc', 'Orin');
    store.characters.addAll([a, b, c]);

    List<String>? popped;
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<List<String>>(
                MaterialPageRoute(
                  builder: (_) => GroupCharacterPickerScreen(primary: a),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Primary row is locked (its checkbox has onChanged == null → disabled).
    final primaryTile = tester.widget<CheckboxListTile>(
      find.ancestor(
        of: find.text('Sera'),
        matching: find.byType(CheckboxListTile),
      ),
    );
    expect(primaryTile.onChanged, isNull);
    expect(primaryTile.value, isTrue);

    // Select Orin THEN Talia — the popped order must reflect that.
    await tester.tap(find.text('Orin'));
    await tester.pump();
    await tester.tap(find.text('Talia'));
    await tester.pump();
    expect(find.text('3 members'), findsOneWidget);

    await tester.tap(find.text('Create chat'));
    await tester.pumpAndSettle();

    expect(popped, ['ca', 'cc', 'cb']); // primary first, then tap order
  });

  testWidgets('group picker with just the primary reads as a 1:1 chat',
      (tester) async {
    final store = AppStore(storage: _NoopBackend());
    final a = _char('ca', 'Sera');
    store.characters.add(a);

    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: GroupCharacterPickerScreen(primary: a)),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('a regular 1:1 chat'), findsOneWidget);
  });
}
