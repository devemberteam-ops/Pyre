// Tier-1 ENVIRONMENT-MATRIX harness.
//
// Two shipped bugs (issue #2: kebab-menu items landing under the Android
// gesture-nav strip; Create/Import sheets unscrollable in landscape) were
// ENVIRONMENT bugs — invisible in a default-size `flutter test` pump. Screen
// size/orientation, gesture-nav insets, and font scale are all SIMULABLE in
// plain widget tests, and Flutter already fails a test on RenderFlex
// overflow, so a small matrix of fake "devices" catches this class of bug
// for free.
//
// [pumpInEnv] mechanics (the one non-obvious part): on this Flutter version
// (the post-multi-window "View" architecture), `WidgetsApp`/`MaterialApp`
// never introduces a `MediaQuery` of their own — the outermost `View`
// (inserted once, above whatever widget `tester.pumpWidget` is given) is the
// ONLY place `MediaQueryData.fromView` runs. So an explicit `MediaQuery`
// wrapped around the pumped widget — OUTSIDE its `MaterialApp` — is NOT
// silently discarded; it's simply the nearest ancestor `MediaQuery.of`
// resolves to, all the way down through `SafeArea` and into
// `showModalBottomSheet`/`showDialog` content (verified: those still read
// the same ambient `MediaQuery`, since their routes mount into the same
// `Overlay` under the same `MaterialApp`/`Navigator`).
//
// This matters for a second, less obvious reason: `Provider`/
// `ChangeNotifierProvider` MUST wrap the whole `MaterialApp` (never just
// `MaterialApp(home: ...)`'s content) for the fixture to survive
// `Navigator.push` and modal sheets/dialogs — those routes mount as
// SIBLING overlay entries, not descendants, of whatever `home` originally
// wrapped, so a Provider scoped inside `home` alone is invisible to any
// later-pushed route. `pumpInEnv` therefore takes the SAME fully-formed
// tree existing tests already build (Provider (if any) wrapping a
// `MaterialApp(home: Screen())`, mirroring `test/chat_import_entry_test.dart`
// and `test/characters_search_debounce_test.dart`) and just layers the
// env's fake size/insets/text-scale around the outside of it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One simulated device/orientation/accessibility combination.
class TestEnv {
  final String name;
  final Size logicalSize; // e.g. Size(360, 780) portrait phone
  final double textScale; // 1.0 / 1.3
  final EdgeInsets viewPadding; // gesture nav: bottom 48; status bar: top 24
  const TestEnv(
    this.name,
    this.logicalSize, {
    this.textScale = 1.0,
    this.viewPadding = EdgeInsets.zero,
  });
}

const kEnvMatrix = [
  TestEnv('portrait-phone', Size(360, 780),
      viewPadding: EdgeInsets.only(top: 24, bottom: 48)),
  TestEnv('landscape-phone', Size(780, 360),
      viewPadding: EdgeInsets.only(top: 24, bottom: 48)),
  TestEnv('short-landscape', Size(640, 320),
      viewPadding: EdgeInsets.only(top: 24, bottom: 48)),
  TestEnv('portrait-bigfont', Size(360, 780),
      textScale: 1.3, viewPadding: EdgeInsets.only(top: 24, bottom: 48)),
];

/// Pumps [app] — a complete widget tree the caller would otherwise have
/// handed straight to `tester.pumpWidget` (typically a `Provider`/
/// `ChangeNotifierProvider` wrapping a `MaterialApp(home: ...)`, matching
/// the rest of `test/`) — sized/inset/scaled to simulate [env], then
/// settles.
Future<void> pumpInEnv(WidgetTester tester, TestEnv env, Widget app) async {
  const dpr = 3.0;
  tester.view.physicalSize = env.logicalSize * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          viewPadding: env.viewPadding,
          padding: env.viewPadding,
          textScaler: TextScaler.linear(env.textScale),
        ),
        child: app,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
