// 2026-07-03 review (H2): factoryReset replaced uiPrefs but never re-applied
// the palette — the OLD theme/accent stayed live until an app restart while
// the prefs claimed 'ember'. (H1 is the same bug on backup restore; the
// restore site is screen-private, so this store-level reset is the
// unit-testable guard for the shared rule: "whenever uiPrefs is replaced
// wholesale, re-apply the palette".)

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';
import 'package:pyre/theme.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('factoryReset re-applies the default palette immediately', () async {
    final store = AppStore(storage: _NoopBackend());
    store.setAccentColor(0xFF123456);
    expect(EmberColors.primary, const Color(0xFF123456),
        reason: 'sanity: the accent override is live before the reset');

    await store.factoryReset();

    expect(store.uiPrefs.accentArgb, isNull);
    expect(store.uiPrefs.activeThemeId, 'ember');
    expect(EmberColors.primary, paletteById('ember').primary,
        reason: 'the palette must reset with the prefs, not on next restart');
  });
}
