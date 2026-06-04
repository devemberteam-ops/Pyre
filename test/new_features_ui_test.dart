// Pyre 1.1 — WIDGET / interaction tests for the new 1.1 screens & controls.
//
// These pump the REAL screen widget, drive a control the way a user would
// (type / tap / select), and then assert the UNDERLYING store/model field
// actually changed (and persists). They complement the existing pure-engine
// tests (regex_rules_test, lorebook_entry_test, prompt_post_processing_test)
// and the render-level tests (bubble_uiscale_render_test) by proving the UI
// is wired to the store on a real interaction.
//
// Harness conventions (mirrored from widget_test.dart):
//   • AppStore is built with a no-op StoreBackend so the debounced `_persist`
//     never touches disk / platform channels. Each test ends with
//     `await store.flushPersist()` to cancel the pending debounce timer and
//     run the (no-op) save, leaving NO live timers behind.
//   • The screen is wrapped in ChangeNotifierProvider<AppStore> + MaterialApp
//     (the screens read the store via `context.watch/read<AppStore>()`).
//   • A generous logical surface size is set (via `tester.view`, the modern
//     per-test API) so off-screen list/dialog content lays out and is
//     tappable without scrolling surprises; each test resets the view via
//     addTearDown so nothing leaks into the next.
//
// SKIPPED (with reasons) are documented in the test report, NOT left as
// `skip:`-marked or failing tests here.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/lorebooks_screen.dart';
import 'package:pyre/screens/presets_screen.dart';
import 'package:pyre/screens/regex_rules_screen.dart';
import 'package:pyre/services/regex_rules.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

/// No-op persistence backend (same shape as widget_test.dart's): keeps the
/// debounced `_persist` harmless so a UI interaction that schedules a save can
/// be asserted without a live filesystem / platform channel.
class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

/// Wrap a screen with the providers + MaterialApp the real app gives it.
Widget _host(AppStore store, Widget screen) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: screen),
    );

/// Set a roomy logical surface so dialogs / list rows lay out and are
/// hit-testable, and register the reset so it never leaks into the next test.
void _useRoomyView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  // ===========================================================================
  // 1) Regex editor — RegexRuleEditorScreen (the most logic-heavy new screen)
  // ===========================================================================
  group('Regex editor (RegexRuleEditorScreen) — wires to store.regexRules', () {
    testWidgets(
        'filling name + find + replace and tapping Save adds a rule with those '
        'values', (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());
      // Pump the editor directly — it's a public StatefulWidget pushable from
      // the list; `existing: null` is the "New rule" path.
      await tester.pumpWidget(_host(store, const RegexRuleEditorScreen()));
      await tester.pumpAndSettle();

      // No rules to start.
      expect(store.regexRules, isEmpty);

      // Fill the three labelled fields by their label text.
      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Strip asterisks');
      await tester.enterText(find.widgetWithText(TextField, 'Find'), 'fox');
      await tester.enterText(
          find.widgetWithText(TextField, 'Replace'), 'cat');
      await tester.pumpAndSettle();

      // Save (the AppBar action).
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      // The store gained exactly one rule with the typed values.
      expect(store.regexRules.length, 1);
      final r = store.regexRules.single;
      expect(r.name, 'Strip asterisks');
      expect(r.pattern, 'fox');
      expect(r.replacement, 'cat');
      // mtime was stamped by addRegexRule (sync eligibility).
      expect(r.mtime, greaterThan(0));

      await store.flushPersist();
    });

    testWidgets(
        'a /pat/flags literal in Find is split into pattern + flags on save',
        (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());
      await tester.pumpWidget(_host(store, const RegexRuleEditorScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Find'), '/dog/gi');
      await tester.enterText(
          find.widgetWithText(TextField, 'Replace'), 'wolf');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      final r = store.regexRules.single;
      // parseRegexLiteral split the literal: body → pattern, trailing → flags.
      expect(r.pattern, 'dog');
      expect(r.flags, 'gi');

      await store.flushPersist();
    });

    testWidgets(
        'the live Result box reflects the rule applied to the sample text',
        (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());
      await tester.pumpWidget(_host(store, const RegexRuleEditorScreen()));
      await tester.pumpAndSettle();

      // The default sample contains "fox"; a global fox→CAT rule should show
      // CAT in the live preview WITHOUT saving anything.
      await tester.enterText(
          find.widgetWithText(TextField, 'Find'), '/fox/g');
      await tester.enterText(
          find.widgetWithText(TextField, 'Replace'), 'CAT');
      await tester.pumpAndSettle();

      // The preview targets the AI stream by default and applies regardless of
      // the toggles, so the SelectableText result should contain the replaced
      // word. (The pure engine is tested elsewhere; here we prove the screen
      // wires the form fields → applyRegexRules → the on-screen Result.)
      final resultText = applyRegexRules(
        'The quick brown fox jumps over the lazy dog.',
        [
          RegexRule(
            pattern: 'fox',
            flags: 'g',
            replacement: 'CAT',
          ),
        ],
        stream: RegexStream.aiOutput,
        stage: RegexStage.display,
      );
      expect(resultText, contains('CAT'));
      expect(find.text(resultText), findsOneWidget,
          reason: 'the live Result box should render the transformed sample');

      // Nothing was saved by merely previewing.
      expect(store.regexRules, isEmpty);
      await store.flushPersist();
    });
  });

  // ===========================================================================
  // 2) Lorebook entry editor — pump LorebookEditScreen, add an entry via the
  //    dialog, assert the new SillyTavern-style fields persisted on LoreEntry.
  // ===========================================================================
  group('Lorebook entry editor — wires the F3 keyword options to LoreEntry',
      () {
    testWidgets(
        'New entry → fill keys + secondary + logic + trigger-chance → Save '
        'persists the entry with those fields', (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());
      final book = Lorebook(id: 'lb-1', name: 'World', entries: []);
      store.lorebooks.add(book);

      await tester.pumpWidget(
          _host(store, const LorebookEditScreen(lorebookId: 'lb-1')));
      await tester.pumpAndSettle();

      // Open the "New entry" dialog (the AppBar + action).
      await tester.tap(find.byTooltip('New entry'));
      await tester.pumpAndSettle();

      // Primary + secondary keywords. Typing the secondary reveals the Logic
      // dropdown (it's hidden until secondary keywords exist).
      await tester.enterText(
          find.widgetWithText(TextField, 'Trigger keywords'), 'castle');
      await tester.enterText(
          find.widgetWithText(TextField, 'Secondary keywords (optional)'),
          'siege, banner');
      await tester.enterText(
          find.widgetWithText(TextField, 'Content to inject'),
          'The old castle.');
      await tester.pumpAndSettle();

      // Pick the "All of these" logic (LoreSelectiveLogic.andAll).
      await tester.tap(find.byType(DropdownButtonFormField<LoreSelectiveLogic>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All of these').last);
      await tester.pumpAndSettle();

      // Enable the trigger-chance switch (reveals the Slider).
      await tester.tap(find.widgetWithText(SwitchListTile, 'Use trigger chance'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget,
          reason: 'enabling "Use trigger chance" must reveal the slider');

      // Save ("Add" for a new entry).
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();

      // The book now has one entry with the typed/selected options.
      final saved = store.lorebookById('lb-1')!;
      expect(saved.entries.length, 1);
      final e = saved.entries.single;
      expect(e.keys, ['castle']);
      expect(e.secondaryKeys, ['siege', 'banner']);
      expect(e.selectiveLogic, LoreSelectiveLogic.andAll);
      expect(e.content, 'The old castle.');
      expect(e.useProbability, isTrue);
      // probability defaults to 100 and we didn't move the slider, so it stays
      // 100 — but the toggle (useProbability) is the wired bit we assert.
      expect(e.probability, 100);

      await store.flushPersist();
    });
  });

  // ===========================================================================
  // 3) Preset editor — modular "Prompt blocks" list (Pyre 1.1 Prompt Manager).
  //    Open the editor for a MODULAR preset via the kebab → Edit, flip a
  //    block's Switch, tap Save, and assert the underlying PromptBlock.enabled
  //    flipped on the store's preset (i.e. the toggle persisted through the
  //    same save path mainPrompt uses).
  // ===========================================================================
  group('Preset editor — modular block list wires to Preset.promptBlocks', () {
    testWidgets(
        'toggling a block\'s switch + Save flips PromptBlock.enabled on the '
        'stored preset', (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());
      // Seed a MODULAR preset: two blocks, both enabled. Added directly so it's
      // the only row in the list (the locked default is built in load(), which
      // we don't run here — addPreset just appends).
      final preset = Preset(
        id: 'preset-modular',
        name: 'Frankenstein',
        promptBlocks: [
          PromptBlock(id: 'b1', name: 'README', content: 'readme text'),
          PromptBlock(id: 'b2', name: 'OMNI PROTOCOL', content: 'omni text'),
        ],
      );
      store.addPreset(preset);

      await tester.pumpWidget(_host(store, const PresetsScreen()));
      await tester.pumpAndSettle();

      // Open the preset's kebab, then Edit.
      await tester.tap(find.byTooltip('Preset actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Edit'));
      await tester.pumpAndSettle();

      // The modular editor shows the "Prompt blocks" section with both names
      // and a Switch per block (no flat Main prompt field — the blocks are it).
      expect(find.text('PROMPT BLOCKS'), findsOneWidget);
      expect(find.text('README'), findsOneWidget);
      expect(find.text('OMNI PROTOCOL'), findsOneWidget);
      final switches = find.byType(Switch);
      expect(switches, findsNWidgets(2),
          reason: 'one on/off switch per block');

      // Both start enabled.
      expect(tester.widget<Switch>(switches.first).value, isTrue);

      // Flip the first block (README) OFF.
      await tester.tap(switches.first);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse,
          reason: 'the switch reflects the local draft immediately');

      // Save commits the draft via store.updatePreset (the same path used for
      // mainPrompt). The dialog passes through "Save".
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      // The stored preset's first block is now disabled; the second untouched.
      final saved =
          store.presets.firstWhere((p) => p.id == 'preset-modular');
      expect(saved.promptBlocks.length, 2);
      expect(saved.promptBlocks[0].name, 'README');
      expect(saved.promptBlocks[0].enabled, isFalse);
      expect(saved.promptBlocks[1].enabled, isTrue);

      await store.flushPersist();
    });

    testWidgets(
        'a FLAT preset shows the Main prompt field and NO block list',
        (tester) async {
      _useRoomyView(tester);
      final store = AppStore(storage: _NoopBackend());
      // Flat preset: no promptBlocks.
      store.addPreset(Preset(
        id: 'preset-flat',
        name: 'Simple',
        mainPrompt: 'You are a helpful assistant.',
      ));

      await tester.pumpWidget(_host(store, const PresetsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Preset actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Edit'));
      await tester.pumpAndSettle();

      // Flat editor: the existing Main prompt TextField is present, the block
      // section is NOT (the flat UX is unchanged). The prompt text also shows
      // in the list row's subtitle behind the dialog, so scope the assertion
      // to the editable TextField holding the value.
      expect(find.text('PROMPT BLOCKS'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(
        find.widgetWithText(TextField, 'You are a helpful assistant.'),
        findsOneWidget,
        reason: 'the flat Main prompt TextField still renders its text',
      );

      await store.flushPersist();
    });
  });

  // ===========================================================================
  // SKIPPED (deliberately not written as a flaky/skip: test) — see the report:
  //   • Provider editor "Prompt post-processing" dropdown
  //     (api_connections_screen.dart): the dropdown is buried inside a
  //     COLLAPSED "Advanced" ExpansionTile that sits at the very bottom of an
  //     AlertDialog whose content (a SizedBox + SingleChildScrollView with no
  //     height bound) overflows the dialog and is clipped against the fixed
  //     action-button row. The "Advanced" header can't be brought into a
  //     reliably-tappable region (ensureVisible / drag / scrollUntilVisible all
  //     leave it pinned at the bottom edge under the actions), so a tap to
  //     expand it is non-deterministic. The model wiring (`PromptPostProcessing`
  //     ↔ provider) is already covered by prompt_post_processing_test.dart.
  //   • In-chat preset switcher (`_showPresetSwitcher`, chat_screen.dart) and
  //     the More→Display text-size slider (`_DisplayCard`, more_screen.dart) are
  //     PRIVATE widgets reachable only through the full ChatScreen / MoreScreen
  //     (heavy nav + platform channels). The store methods they call
  //     (setActivePreset / setUiScale) are covered by unit tests, and the
  //     uiScale math is covered by bubble_uiscale_render_test.dart.
}
