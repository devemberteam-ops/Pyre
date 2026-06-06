// Mega-audit 2026-06-05 — backup completeness drift (F3/F1/F2).
//
// The Pyre-native backup export/import had drifted behind several
// persisted, user-editable top-level categories: regexRules, folders,
// liveSheetSettings, scriptSettings, guideSettings, and the botbooru
// creator profile. They were never written by `_exportBlob` nor read by
// `_applyImport`, so a back-up → restore on a new device SILENTLY lost
// all of them.
//
// The fix folds them into the "App settings" category via two pure
// helpers shared by export + import. These tests assert a full
// round-trip restores every field.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/backup_restore_screen.dart';
import 'package:pyre/services/regex_rules.dart';
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
  group('backup extras round-trip (settings category)', () {
    test('regexRules / folders / settings / profile survive export→import',
        () async {
      final src = AppStore(storage: _NoopBackend());
      src.regexRules = [
        RegexRule(id: 'r1', name: 'Strip', pattern: r'\*', replacement: ''),
      ];
      src.folders = [Folder(id: 'f1', name: 'Favorites')];
      src.liveSheetSettings = LiveSheetSettings()..autoEvery = 9;
      src.scriptSettings = ScriptSettings()..beatsCap = 5;
      src.guideSettings = GuideSettings()..enabled = false;
      src.botbooruUsername = 'ember';
      src.botbooruAboutMe = 'hi there';
      src.botbooruTitle = 'Creator';
      src.botbooruPronouns = 'they/them';

      // Export.
      final blob = <String, dynamic>{};
      writeBackupSettingsCategory(src, blob);

      // The keys must actually be present in the exported blob.
      expect(blob.containsKey('regexRules'), isTrue);
      expect(blob.containsKey('folders'), isTrue);
      expect(blob.containsKey('liveSheetSettings'), isTrue);
      expect(blob.containsKey('scriptSettings'), isTrue);
      expect(blob.containsKey('guideSettings'), isTrue);
      expect(blob['botbooruUsername'], 'ember');

      // Import into a fresh store.
      final dst = AppStore(storage: _NoopBackend());
      applyBackupSettingsCategory(dst, blob);

      expect(dst.regexRules.length, 1);
      expect(dst.regexRules.first.name, 'Strip');
      expect(dst.folders.length, 1);
      expect(dst.folders.first.name, 'Favorites');
      expect(dst.liveSheetSettings.autoEvery, 9);
      expect(dst.scriptSettings.beatsCap, 5);
      expect(dst.guideSettings.enabled, isFalse);
      expect(dst.botbooruUsername, 'ember');
      expect(dst.botbooruAboutMe, 'hi there');
      expect(dst.botbooruTitle, 'Creator');
      expect(dst.botbooruPronouns, 'they/them');
    });

    test('a blob missing the extra keys leaves the store untouched (merge)',
        () {
      final dst = AppStore(storage: _NoopBackend());
      dst.regexRules = [
        RegexRule(id: 'keep', name: 'Keep me', pattern: 'a', replacement: 'b'),
      ];
      dst.botbooruUsername = 'original';

      // Old-format blob: only the four legacy settings singletons present.
      applyBackupSettingsCategory(dst, {
        'modelSettings': ModelSettings().toJson(),
      });

      // Absent keys must NOT clobber existing data.
      expect(dst.regexRules.length, 1);
      expect(dst.regexRules.first.name, 'Keep me');
      expect(dst.botbooruUsername, 'original');
    });
  });
}
