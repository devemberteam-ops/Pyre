// Wave CY.18.1.3 (Theme Foundation): tests for the runtime theme palette
// system — EmberPalette model, curated palettes, applyTheme accent-override,
// and the UiPrefs fromJson/toJson round-trip for activeThemeId + accentArgb.
//
// All of these are PURE (no Flutter widgets, no disk, no providers) and can
// run in a bare Dart test runner.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/theme.dart';
import 'package:pyre/models/models.dart' show UiPrefs;

void main() {
  // ─── paletteById ─────────────────────────────────────────────────────────

  group('paletteById', () {
    test('returns Ember palette for id "ember"', () {
      final p = paletteById('ember');
      expect(p.id, 'ember');
      expect(p.name, isNotEmpty);
    });

    test('returns Moonlit palette for id "moonlit"', () {
      final p = paletteById('moonlit');
      expect(p.id, 'moonlit');
    });

    test('returns Hearth palette for id "hearth"', () {
      final p = paletteById('hearth');
      expect(p.id, 'hearth');
    });

    test('unknown id falls back to Ember', () {
      final p = paletteById('does-not-exist');
      expect(p.id, 'ember');
    });

    test('empty string falls back to Ember', () {
      final p = paletteById('');
      expect(p.id, 'ember');
    });
  });

  // ─── kCuratedPalettes ────────────────────────────────────────────────────

  group('kCuratedPalettes', () {
    test('contains exactly 3 entries in order: ember, moonlit, hearth', () {
      expect(kCuratedPalettes.length, 3);
      expect(kCuratedPalettes[0].id, 'ember');
      expect(kCuratedPalettes[1].id, 'moonlit');
      expect(kCuratedPalettes[2].id, 'hearth');
    });

    test('Ember primary is byte-identical to the old const #FF6A3D', () {
      final ember = kCuratedPalettes[0];
      expect(ember.primary.toARGB32(), 0xFFFF6A3D);
    });

    test('Ember bgDeep is #0B0B0F', () {
      expect(kCuratedPalettes[0].bgDeep.toARGB32(), 0xFF0B0B0F);
    });

    test('Moonlit primary is #8FA8FF', () {
      expect(kCuratedPalettes[1].primary.toARGB32(), 0xFF8FA8FF);
    });

    test('Hearth primary is #E8A24C', () {
      expect(kCuratedPalettes[2].primary.toARGB32(), 0xFFE8A24C);
    });
  });

  // ─── EmberColors.applyTheme ──────────────────────────────────────────────

  group('EmberColors.applyTheme', () {
    setUp(() {
      // Always reset to Ember before each test.
      EmberColors.applyTheme(themeId: 'ember');
    });

    test('default active palette is Ember', () {
      expect(EmberColors.primary.toARGB32(), 0xFFFF6A3D);
      expect(EmberColors.bgDeep.toARGB32(), 0xFF0B0B0F);
    });

    test('applyTheme("moonlit") switches primary to Moonlit primary', () {
      EmberColors.applyTheme(themeId: 'moonlit');
      expect(EmberColors.primary.toARGB32(), 0xFF8FA8FF);
    });

    test('applyTheme("hearth") switches bgDeep to Hearth bgDeep', () {
      EmberColors.applyTheme(themeId: 'hearth');
      expect(EmberColors.bgDeep.toARGB32(), 0xFF100C0A);
    });

    test('unknown themeId falls back to Ember', () {
      EmberColors.applyTheme(themeId: 'nope');
      expect(EmberColors.primary.toARGB32(), 0xFFFF6A3D);
    });

    test('accent override replaces primary when accentArgb != null', () {
      const kRedArgb = 0xFFFF0000;
      EmberColors.applyTheme(themeId: 'ember', accentArgb: kRedArgb);
      expect(EmberColors.primary.toARGB32(), kRedArgb);
    });

    test('accent override also derives a darker primaryDim', () {
      const kRedArgb = 0xFFFF0000;
      EmberColors.applyTheme(themeId: 'ember', accentArgb: kRedArgb);
      // primaryDim must differ from primary (darkened) and have full alpha.
      final dim = EmberColors.primaryDim;
      expect(dim.a, 1.0);
      // It should be darker — a simple check: the accent is fully saturated
      // red (r=255, g=0, b=0); the dim version should have r < 255.
      expect(dim.r, lessThan(1.0)); // r component is 0..1 in flutter Color
    });

    test('null accent uses theme primaryDim unchanged', () {
      EmberColors.applyTheme(themeId: 'moonlit');
      expect(EmberColors.primaryDim.toARGB32(), 0xFF6E86E0);
    });

    test('non-primary colors are not affected by accent override', () {
      EmberColors.applyTheme(themeId: 'ember', accentArgb: 0xFFFF0000);
      // bgDeep stays Ember
      expect(EmberColors.bgDeep.toARGB32(), 0xFF0B0B0F);
      expect(EmberColors.danger.toARGB32(), 0xFFE5484D);
    });

    test('applyTheme is deterministic — calling twice gives same result', () {
      EmberColors.applyTheme(themeId: 'moonlit', accentArgb: 0xFF00FF00);
      final p1 = EmberColors.primary.toARGB32();
      EmberColors.applyTheme(themeId: 'moonlit', accentArgb: 0xFF00FF00);
      expect(EmberColors.primary.toARGB32(), p1);
    });
  });

  // ─── UiPrefs fromJson / toJson round-trip ────────────────────────────────

  group('UiPrefs theme fields — fromJson/toJson', () {
    test('defaults: activeThemeId="ember", accentArgb=null', () {
      final prefs = UiPrefs.fromJson(const <String, dynamic>{});
      expect(prefs.activeThemeId, 'ember');
      expect(prefs.accentArgb, isNull);
    });

    test('round-trips a non-default themeId', () {
      final prefs = UiPrefs(activeThemeId: 'moonlit');
      final json = prefs.toJson();
      final restored = UiPrefs.fromJson(json);
      expect(restored.activeThemeId, 'moonlit');
    });

    test('toJson omits activeThemeId when it is the default "ember"', () {
      final prefs = UiPrefs(activeThemeId: 'ember');
      final json = prefs.toJson();
      // Keep backups clean: no key for the default.
      expect(json.containsKey('activeThemeId'), isFalse);
    });

    test('toJson includes activeThemeId when non-default', () {
      final prefs = UiPrefs(activeThemeId: 'hearth');
      expect(prefs.toJson()['activeThemeId'], 'hearth');
    });

    test('round-trips a non-null accentArgb', () {
      final prefs = UiPrefs(accentArgb: 0xFFABCDEF);
      final json = prefs.toJson();
      final restored = UiPrefs.fromJson(json);
      expect(restored.accentArgb, 0xFFABCDEF);
    });

    test('toJson omits accentArgb when null', () {
      final prefs = UiPrefs();
      expect(prefs.toJson().containsKey('accentArgb'), isFalse);
    });

    test('fromJson tolerates bad activeThemeId type (non-string → default)', () {
      final prefs = UiPrefs.fromJson({'activeThemeId': 42});
      expect(prefs.activeThemeId, 'ember');
    });

    test('fromJson tolerates bad accentArgb type (non-int → null)', () {
      final prefs = UiPrefs.fromJson({'accentArgb': 'red'});
      expect(prefs.accentArgb, isNull);
    });
  });
}
