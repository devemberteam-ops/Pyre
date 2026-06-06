// C-5 (web-only): the web RemoteBackend splits the AppStore blob into "synced"
// (server-owned, /push) and "local" (SharedPreferences) fields. The device-
// local LATCH flags — `seenOnboarding`, `exampleContentSeeded`, and the one-
// time migration latches — were in NEITHER set, so web `save()` dropped them
// every time and they read back `?? false` → onboarding re-showed on every web
// launch and the example-seed gate re-evaluated each boot.
//
// `filterLocalBlob` is the pure local-split (extracted from save()) so the
// regression is pinned without a real SharedPreferences / network round-trip.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/remote_backend.dart';

void main() {
  group('filterLocalBlob — device-local latch flags survive (C-5)', () {
    test('FAILING-BEFORE-FIX: seenOnboarding + exampleContentSeeded persist',
        () {
      final blob = <String, dynamic>{
        // server-owned collections — must NOT leak into the local cache.
        'characters': <dynamic>[],
        'chats': <dynamic>[],
        // device-local latch flags (app_store omits these when false; here
        // they are latched true, the case that broke).
        'seenOnboarding': true,
        'exampleContentSeeded': true,
      };

      final local = filterLocalBlob(blob);

      expect(local['seenOnboarding'], true,
          reason: 'onboarding latch must survive a web save round-trip');
      expect(local['exampleContentSeeded'], true,
          reason: 'example-seed latch must survive a web save round-trip');
      // Synced collections never belong in the local cache.
      expect(local.containsKey('characters'), isFalse);
      expect(local.containsKey('chats'), isFalse);
    });

    test('the one-time migration latches also persist', () {
      final blob = <String, dynamic>{
        'vesnaExamplePersonaSwept': true,
        'personaDefaultsAdjustedV2': true,
        'personaDefaultsAdjustedV3': true,
      };

      final local = filterLocalBlob(blob);

      expect(local['vesnaExamplePersonaSwept'], true);
      expect(local['personaDefaultsAdjustedV2'], true);
      expect(local['personaDefaultsAdjustedV3'], true);
    });

    test('an unlatched (absent) flag is simply omitted (→ reads back false)',
        () {
      // app_store.toJson omits these when false, so they never reach the blob.
      // filterLocalBlob must not invent them.
      final local = filterLocalBlob(<String, dynamic>{
        'providers': <dynamic>[],
      });
      expect(local.containsKey('seenOnboarding'), isFalse);
      expect(local.containsKey('exampleContentSeeded'), isFalse);
      // existing local fields still pass through.
      expect(local['providers'], isA<List<dynamic>>());
    });

    test('existing local fields (uiPrefs, modelSettings) still pass through',
        () {
      final local = filterLocalBlob(<String, dynamic>{
        'uiPrefs': {'theme': 'dark'},
        'modelSettings': {'temperature': 0.8},
        'seenOnboarding': true,
      });
      expect(local['uiPrefs'], {'theme': 'dark'});
      expect(local['modelSettings'], {'temperature': 0.8});
      expect(local['seenOnboarding'], true);
    });
  });
}
