// BATCH P2-ui (I) + (A): the Characters search box is debounced, and the list
// is virtualized (ListView.builder). This test types into the search field and
// asserts the filter only applies AFTER the debounce window — and that the
// list renders rows via a builder.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/characters_screen.dart';
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

void main() {
  testWidgets('search filter is debounced (~250ms), then virtualized list updates',
      (tester) async {
    final store = AppStore(storage: _NoopBackend());
    store.addCharacter(Character(id: 'a', name: 'Alpha'));
    store.addCharacter(Character(id: 'b', name: 'Beta'));
    await store.flushPersist();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: const MaterialApp(home: CharactersScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // The virtualized list renders both rows.
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    // Type a query that should filter out Beta.
    await tester.enterText(find.byType(TextField), 'alpha');
    // Immediately after typing, before the debounce fires, the filter has NOT
    // applied yet — both rows still present.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Beta'), findsOneWidget,
        reason: 'filter should not apply before the debounce window');

    // After the debounce window elapses, the filter applies → only Alpha.
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    await store.flushPersist();
  });

  testWidgets('the Characters list uses a ListView.builder (virtualized)',
      (tester) async {
    final store = AppStore(storage: _NoopBackend());
    for (var i = 0; i < 5; i++) {
      store.addCharacter(Character(id: 'c$i', name: 'Char$i'));
    }
    await store.flushPersist();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: const MaterialApp(home: CharactersScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // A virtualized ListView has a non-null itemCount-driven childrenDelegate
    // (SliverChildBuilderDelegate). The old ListView(children:[...]) used a
    // SliverChildListDelegate. Assert we're on the builder path.
    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.childrenDelegate, isA<SliverChildBuilderDelegate>());

    await store.flushPersist();
  });
}
