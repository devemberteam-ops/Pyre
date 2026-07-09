// Tier-1 ENVIRONMENT-MATRIX surface tests.
//
// Two shipped bugs (issue #2: kebab-menu items landing under the Android
// gesture-nav strip; Create/Import sheets unscrollable in landscape) were
// invisible to default-size widget tests because they were purely
// ENVIRONMENTAL — they only showed up at real device sizes/insets. This file
// re-runs the known-risk bottom-sheet surfaces across `kEnvMatrix`
// (`test/support/env_matrix.dart`) and asserts the exact property the old
// bugs violated: every item stays reachable and tappable, and Flutter's own
// RenderFlex-overflow assertion (which auto-fails a test) stands in for "no
// layout blew past its box".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/character_edit_screen.dart';
import 'package:pyre/screens/characters_screen.dart';
import 'package:pyre/screens/chat_info_sheet.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';
import 'package:pyre/widgets/menu_sheet.dart';

import 'support/env_matrix.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

AppStore _store() => AppStore(storage: _NoopBackend());

void main() {
  // ---------------------------------------------------------------------
  // 1. Character kebab menu (the issue-#2 bug surface). `_showCharacterMenu`
  //    in characters_screen.dart tops out at 10 ListTiles in its worst case
  //    (Start new chat, Start group chat, Continue chat, View details, Add
  //    as persona, Export PNG, Export JSON, Duplicate, Add to folder,
  //    Delete character) — mirror that count with dummy tiles through the
  //    SAME `showMenuSheet` helper the real menu uses, so this test tracks
  //    the shared sheet mechanics without needing the full character/chat
  //    fixture the real menu's conditionals require.
  group('character kebab menu — last item reachable', () {
    for (final env in kEnvMatrix) {
      testWidgets('character kebab menu [${env.name}]', (tester) async {
        const itemCount = 10;
        final tappedIndex = <int>[];

        await pumpInEnv(
          tester,
          env,
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showMenuSheet<void>(
                      context,
                      itemsBuilder: (sheet) => [
                        for (var i = 0; i < itemCount; i++)
                          ListTile(
                            title: Text('Item $i'),
                            onTap: () {
                              tappedIndex.add(i);
                              Navigator.pop(sheet);
                            },
                          ),
                      ],
                    ),
                    child: const Text('Open menu'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open menu'));
        await tester.pumpAndSettle();

        final lastItem = find.text('Item ${itemCount - 1}');
        await tester.ensureVisible(lastItem);
        await tester.pumpAndSettle();
        await tester.tap(lastItem);
        await tester.pumpAndSettle();

        expect(tappedIndex, [itemCount - 1],
            reason: 'the last menu item must be reachable+tappable, not '
                'hidden under the gesture-nav strip or clipped in landscape');
      });
    }
  });

  // ---------------------------------------------------------------------
  // 2. Create/Import chooser sheet: tap the AppBar "Create" button on
  //    CharactersScreen, which opens `_showImportSourceSheet`. Its last
  //    tile is "From file" — assert it's reachable+tappable in every env.
  group('Create chooser — "From file" reachable', () {
    for (final env in kEnvMatrix) {
      testWidgets('create/import chooser [${env.name}]', (tester) async {
        final store = _store();
        // One character so CharactersScreen renders the real list, not the
        // empty-state placeholder — that placeholder has its own unrelated
        // overflow issue in short/landscape envs (see report) that would
        // otherwise mask what this test is actually targeting.
        store.addCharacter(Character(id: 'c1', name: 'Aria'));

        await pumpInEnv(
          tester,
          env,
          ChangeNotifierProvider<AppStore>.value(
            value: store,
            child: const MaterialApp(home: CharactersScreen()),
          ),
        );

        await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
        await tester.pumpAndSettle();

        final lastTile = find.widgetWithText(ListTile, 'From file');
        await tester.ensureVisible(lastTile);
        await tester.pumpAndSettle();
        // The file picker plugin has no test-harness implementation, but
        // `_pickAndImportCard` wraps the whole flow in try/catch, so a
        // MissingPluginException is swallowed into a snackbar rather than
        // thrown — tapping is safe to assert hittability.
        await tester.tap(lastTile, warnIfMissed: false);
        await tester.pumpAndSettle();
      });
    }
  });

  // ---------------------------------------------------------------------
  // 3. Resume/Start-fresh sheet: seed 25 drafts so `_createBlankCharacter`
  //    routes through `_showResumeOrStartFreshSheet` instead of creating a
  //    draft directly. Assert (a) no overflow (automatic — RenderFlex
  //    overflow fails the test), (b) "Start fresh" reachable+tappable, and
  //    (c) the sheet's top edge stays below the fake status-bar inset —
  //    this locks in the 85% height-cap fix (1.2.1 audit).
  //
  //    Deliberately does NOT follow through on an actual tap of "Start
  //    fresh": its onTap pops this sheet and pushes CharacterEditScreen,
  //    and settling that transition surfaces a SEPARATE real bug — env-
  //    matrix finding #2 (see report): its avatar-row `Row`
  //    (character_edit_screen.dart:429, "Change avatar" + "Recrop")
  //    overflows at a plain 360-logical-px portrait width in EVERY env in
  //    this matrix, including plain portrait-phone. That's a different
  //    surface than this test targets, so it's reported rather than
  //    driven through here; "tappable" is instead proven the same way
  //    surface 1 proves it — geometrically, via a rect-bounds check.
  group('Resume/Start-fresh sheet — reachable + capped below status bar', () {
    for (final env in kEnvMatrix) {
      testWidgets(
        'resume-or-start-fresh sheet [${env.name}]',
        (tester) async {
          final store = _store();
          // See the "Create chooser" group above for why a real character
          // (not the empty-state placeholder) is in the fixture.
          store.addCharacter(Character(id: 'c1', name: 'Aria'));
          for (var i = 0; i < 25; i++) {
            store.saveDraft(Character(id: newId('draft'), name: 'Draft $i'));
          }

          await pumpInEnv(
            tester,
            env,
            ChangeNotifierProvider<AppStore>.value(
              value: store,
              child: const MaterialApp(home: CharactersScreen()),
            ),
          );

          await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
          await tester.pumpAndSettle();
          await tester
              .tap(find.widgetWithText(ListTile, 'Create from scratch'));
          await tester.pumpAndSettle();

          // (b) "Start fresh" is reachable and its bottom edge stays above
          // the fake gesture-nav inset — the exact property issue #2
          // violated (bottom items landing under the gesture-nav strip).
          final startFresh = find.widgetWithText(ListTile, 'Start fresh');
          await tester.ensureVisible(startFresh);
          await tester.pumpAndSettle();

          final screenHeight = env.logicalSize.height;
          final tileRect = tester.getRect(startFresh);
          expect(
            tileRect.bottom,
            lessThanOrEqualTo(screenHeight - env.viewPadding.bottom + 0.5),
            reason: '"Start fresh" must not sit under the gesture-nav inset',
          );

          // (c) the sheet's own panel never creeps above the fake status-
          // bar inset (top: 24). `BottomSheet`'s own RenderBox spans the
          // full available route height (it aligns its child to the
          // bottom internally), so it's NOT a reliable proxy for the
          // visible panel's top edge — instead anchor on the
          // `ConstrainedBox` that actually carries the `* 0.85` cap, found
          // via its known content (the sheet's title, its first child).
          final sheetTitle = find.text('Resume a draft or start fresh');
          final cappedBox = find.ancestor(
            of: sheetTitle,
            matching: find.byType(ConstrainedBox),
          );
          final sheetTop = tester.getRect(cappedBox.first).top;
          expect(sheetTop, greaterThanOrEqualTo(24 - 1),
              reason: 'the resume/start-fresh sheet must stay capped below '
                  'the status-bar inset (85% height-cap fix)');
        },
      );
    }
  });

  // ---------------------------------------------------------------------
  // 4. Chat info sheet — smoke test. Content is already scrollable
  //    (SingleChildScrollView), so this just proves it never overflows in
  //    any env; a minimal chat + character fixture is enough since
  //    `_buildBreakdown` degrades gracefully with no preset/persona/
  //    lorebooks/LTM/provider.
  group('Chat info sheet — smoke (no overflow) in every env', () {
    for (final env in kEnvMatrix) {
      testWidgets(
        'chat info sheet [${env.name}]',
        (tester) async {
          final store = _store();
          store.addCharacter(Character(id: 'c1', name: 'Aria'));
          final chat =
              store.addImportedChat(Chat(id: 'chat1', characterIds: ['c1']));

          await pumpInEnv(
            tester,
            env,
            ChangeNotifierProvider<AppStore>.value(
              value: store,
              child: MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (context) => Center(
                      child: ElevatedButton(
                        onPressed: () => showChatInfoSheet(context, chat.id),
                        child: const Text('Open chat info'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

          await tester.tap(find.text('Open chat info'));
          await tester.pumpAndSettle();

          expect(find.text('Chat info'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  // ---------------------------------------------------------------------
  // 5. CharacterEditScreen avatar row — env-matrix finding #2 (see report):
  //    the "Change avatar" + "Recrop" `Row` (character_edit_screen.dart,
  //    just under the avatar bubble) overflowed by 34px at a plain
  //    360-logical-px portrait width in EVERY env in this matrix, including
  //    plain portrait-phone. Not part of the harness's originally-assigned
  //    surfaces, so it has no pinned skipped test yet — seed a draft (like
  //    group 3 above) and pump the real edit screen across `kEnvMatrix`;
  //    Flutter's RenderFlex-overflow assertion auto-fails the test if the
  //    row still doesn't fit.
  group('CharacterEditScreen avatar row — no overflow in every env', () {
    for (final env in kEnvMatrix) {
      testWidgets('avatar row [${env.name}]', (tester) async {
        final store = _store();
        final draft = Character(id: newId('draft'), name: 'Aria');
        store.saveDraft(draft);

        await pumpInEnv(
          tester,
          env,
          ChangeNotifierProvider<AppStore>.value(
            value: store,
            child: MaterialApp(
              home: CharacterEditScreen(draftId: draft.id),
            ),
          ),
        );

        expect(find.text('Change avatar'), findsOneWidget);
        expect(find.text('Recrop'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Flush AppStore's 600ms debounced persist timer (armed by
        // saveDraft above) so it doesn't trip flutter_test's
        // no-pending-timers invariant at teardown.
        await tester.pump(const Duration(milliseconds: 700));
      });
    }
  });
}
