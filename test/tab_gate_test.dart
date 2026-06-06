// BATCH P2-ui (F): ActiveTabGate keeps an off-screen tab mounted but stops it
// rebuilding on unrelated AppStore notifies (the per-token streaming notifies
// that previously rebuilt every IndexedStack tab).
//
// The gated child must NOT do its own root context.watch (the real Chats /
// Characters screens were switched to context.read for this). Here a stand-in
// child uses context.read, mirroring that contract.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pyre/main.dart' show ActiveTabGate;
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

int gatedBuilds = 0;

/// No-disk backend so a store mutation's debounced persist doesn't touch the
/// filesystem in a widget test.
class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

/// A real store mutation that fires `notifyListeners()` — stands in for the
/// per-token streaming notifies that used to rebuild every mounted tab.
void _notify(AppStore s) =>
    s.addCharacter(Character(id: 'x${s.characters.length}', name: 'X'));

/// A child that reads (does NOT watch) the store, like the gated tab screens.
class _GatedChild extends StatelessWidget {
  const _GatedChild();
  @override
  Widget build(BuildContext context) {
    context.read<AppStore>(); // read, not watch
    gatedBuilds++;
    return const SizedBox();
  }
}

Widget _host({required int activeIndex}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: IndexedStack(
      index: activeIndex,
      children: [
        // Non-const child: the gate forces an active rebuild by re-invoking
        // childBuilder; a const (identical) child would short-circuit it.
        // ignore: prefer_const_constructors
        ActiveTabGate(
            active: activeIndex == 0, childBuilder: (_) => _GatedChild()),
        // ignore: prefer_const_constructors
        ActiveTabGate(
            active: activeIndex == 1, childBuilder: (_) => _GatedChild()),
      ],
    ),
  );
}

void main() {
  testWidgets(
      'inactive gated tab does NOT rebuild on notify; active one does',
      (tester) async {
    gatedBuilds = 0;
    final store = AppStore(storage: _NoopBackend());
    // Tab 0 active, tab 1 inactive.
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: _host(activeIndex: 0),
      ),
    );
    // Both children built once during the initial pump.
    expect(gatedBuilds, 2);

    gatedBuilds = 0;
    // An unrelated notify (e.g. a streaming token bumping a message).
    _notify(store);
    await tester.pump();
    // Only the ACTIVE tab (index 0) rebuilds; the inactive one (index 1)
    // stays frozen. So exactly 1 build, not 2.
    expect(gatedBuilds, 1);

    // A second notify behaves the same — the inactive tab stays frozen
    // (no transient leak).
    gatedBuilds = 0;
    _notify(store);
    await tester.pump();
    expect(gatedBuilds, 1);

    // Flush the debounced persist timer inside the body so no Timer is left
    // pending when the widget tree is disposed.
    await store.flushPersist();
  });

  testWidgets('switching tabs rebuilds the newly-active tab and frees the old',
      (tester) async {
    gatedBuilds = 0;
    final store = AppStore(storage: _NoopBackend());
    Widget build(int idx) => ChangeNotifierProvider<AppStore>.value(
          value: store,
          child: _host(activeIndex: idx),
        );
    await tester.pumpWidget(build(0));
    // Switch active tab 0 -> 1.
    await tester.pumpWidget(build(1));
    // Let the rebuilds settle.
    gatedBuilds = 0;
    // Now notify twice: only the new active tab (1) should rebuild — once per
    // notify — and the now-inactive tab (0) stays frozen.
    _notify(store);
    await tester.pump();
    _notify(store);
    await tester.pump();
    expect(gatedBuilds, 2); // 1 per notify, only the active tab

    await store.flushPersist();
  });
}
