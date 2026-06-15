# Pyre — Theme / Color Customization (plan)

> Founder ask: community wants "Moonlit" (the SillyTavern *Moonlit Echoes* theme —
> message styles + configurable colors + shareable presets). Kuru's scope call:
> "vamos só dar opções de customização por agora, tanto faz" → V1 = **app-wide
> color customization**. Message-styles + shareable presets = deferred (V2+).
> Branch release/1.1.3.

## Why this shape
- All app color flows from 11 `static const Color` in `EmberColors` (theme.dart),
  read at 1288 sites across 62 files. Change the 11 values → whole app recolors.
- `static const` is compile-time → to switch at runtime we make them runtime
  getters. That breaks ~100–250 `const`-context usages (compiler flags each;
  mostly a mechanical `const` drop, a few need `final`/restructure).
- Pyre already has per-chat bubble customization (color/blur/radius/border/bg) —
  this V1 is the WHOLE-APP color, distinct + on top. Must not break per-chat.

## V1 scope
1. Runtime-switchable palette: `EmberColors.*` become getters reading the active
   `EmberPalette`; default = current Ember values (NO visual change by default).
2. `EmberPalette` model (11 colors + id + display name).
3. Curated palettes (code-defined): **Ember** (default, exact current hex),
   **Moonlit** (cool periwinkle/midnight), **Hearth** (warm sepia/amber dark).
4. User **accent override** (nullable ARGB) — replaces primary + primaryDim on
   top of whichever theme is active ("várias configurações").
5. `ThemeController` (ChangeNotifier) holds activeThemeId + accent; app rebuilds
   on change (MaterialApp.theme = emberTheme() recomputed; EmberColors.* live).
6. Persist `activeThemeId` + `accentArgb` + sync (mirror uiScale's persist/sync).
7. (Wave 2) Theme settings screen: pick theme (live preview) + accent picker;
   a "Theme" row in More/Display.

## Curated palettes (V1 — taste is Kuru's; he reacts after)
- **Ember** (default): primary #FF6A3D, primaryDim #E6552B, bgDeep #0B0B0F,
  bgPanel #14141B, bgElevated #1B1B24, stroke #26262F, textHigh #F2EDE6,
  textMid #AAA499, textDim #6E6A60, danger #E5484D, success #22C55E.
- **Moonlit**: primary #8FA8FF, primaryDim #6E86E0, bgDeep #0A0C14,
  bgPanel #121624, bgElevated #1A1F30, stroke #2A3042, textHigh #ECF0F8,
  textMid #9AA3B5, textDim #636B7D, danger #E5484D, success #34D399.
- **Hearth**: primary #E8A24C, primaryDim #C9863A, bgDeep #100C0A,
  bgPanel #1A1410, bgElevated #221A14, stroke #33271F, textHigh #F3EADF,
  textMid #B3A595, textDim #75695C, danger #E5484D, success #22C55E.

## Execution
- Wave A (foundation, ONE implementer, may run flutter analyze/test solo to drive
  the compiler-guided const-fix loop): unlock colors + model + curated palettes +
  controller + main wiring + persist/sync. NO settings UI. → CEO green gate.
- Wave B (UI, after A green): Theme settings screen + accent picker + nav row +
  sync of the new fields verified. → CEO gate + independent verifier.
- Default unchanged for existing users (Ember stays exact). Per-chat bubble
  customization untouched.
