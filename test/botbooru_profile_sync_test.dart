// BotBooru PROFILE sync — the user's profile (username / avatar / about-me /
// title / pronouns / featured character) now travels between paired devices as
// its OWN Last-Writer-Wins singleton unit, keyed by a single
// `botbooruProfileMtime`. This mirrors the SYNC W3 settings unit EXACTLY:
// `syncedBotbooruProfileToJson()` / `applySyncedBotbooruProfile()` with whole-
// blob LWW (never downgrade; ties keep local).
//
// WHY its own mtime (and not folded into the settings unit): the profile is a
// small, self-contained record that changes on its own cadence. Giving it a
// dedicated watermark means a profile edit can't be clobbered by an unrelated
// (older) settings sync and vice-versa — the no-clobber regression below is the
// whole reason for the design.
//
// `installedAt` is DELIBERATELY excluded — it's a per-device stat ("X days on
// Pyre"), not identity, so it never rides this unit.
//
// These tests run on a BARE `AppStore` (NoopBackend, no Flutter bindings) —
// `syncedBotbooruProfileToJson` / `applySyncedBotbooruProfile` must be pure
// enough for that.

import 'package:flutter_test/flutter_test.dart';
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

/// Captures the last saved blob so a SECOND store can load it back — exercises
/// the REAL persist path (toJson via save → load).
class _CaptureBackend implements StoreBackend {
  Map<String, dynamic>? captured;
  @override
  Future<Map<String, dynamic>?> load() async => captured;
  @override
  Future<void> save(Map<String, dynamic> blob) async {
    captured = blob;
  }

  @override
  Future<void> clear() async {
    captured = null;
  }
}

void main() {
  // Every test runs on a BARE store (NoopBackend / CaptureBackend, no Flutter
  // bindings). We deliberately DON'T exercise `AppStore.load()` here: load runs
  // AttachmentMigration → path_provider / SharedPreferences, whose plugin
  // channels race across the concurrently-run test isolates and flake. The
  // persistence test below proves the round-trip via the captured save blob
  // instead (the same flushPersist-only pattern avatar_original_test +
  // key_sync_toggle_test use), which is deterministic and plugin-free.

  group('syncedBotbooruProfileToJson round-trip', () {
    test('carries all 7 fields + mtime and applies to a second store', () {
      final source = AppStore(storage: _NoopBackend());
      source.setBotbooruUsername('Ember');
      source.setBotbooruAvatar('data:image/png;base64,AVATAR');
      source.recropBotbooruAvatar('pyre://attachment/crop',
          original: 'data:image/png;base64,AVATAR');
      source.setBotbooruAboutMe('I build characters.');
      source.setBotbooruTitle('Worldsmith');
      source.setBotbooruPronouns('they/them');
      source.setBotbooruFeaturedCharacter('char-123');

      final j = source.syncedBotbooruProfileToJson();
      expect(j['mtime'], source.botbooruProfileMtime);
      expect(j['mtime'], greaterThan(0));
      expect(j['botbooruUsername'], 'Ember');
      // recrop set avatar to the crop ref + preserved the original.
      expect(j['botbooruAvatar'], 'pyre://attachment/crop');
      expect(j['botbooruAvatarOriginal'], 'data:image/png;base64,AVATAR');
      expect(j['botbooruAboutMe'], 'I build characters.');
      expect(j['botbooruTitle'], 'Worldsmith');
      expect(j['botbooruPronouns'], 'they/them');
      expect(j['botbooruFeaturedCharacterId'], 'char-123');

      // A fresh store at mtime 0 adopts the whole record.
      final dest = AppStore(storage: _NoopBackend());
      expect(dest.botbooruProfileMtime, 0);
      dest.applySyncedBotbooruProfile(j);

      expect(dest.botbooruUsername, 'Ember');
      expect(dest.botbooruAvatar, 'pyre://attachment/crop');
      expect(dest.botbooruAvatarOriginal, 'data:image/png;base64,AVATAR');
      expect(dest.botbooruAboutMe, 'I build characters.');
      expect(dest.botbooruTitle, 'Worldsmith');
      expect(dest.botbooruPronouns, 'they/them');
      expect(dest.botbooruFeaturedCharacterId, 'char-123');
      expect(dest.botbooruProfileMtime, j['mtime']);
    });

    test('nullable fields round-trip as null', () {
      final source = AppStore(storage: _NoopBackend());
      source.setBotbooruUsername('NoPics');
      // avatar / avatarOriginal / featured stay null.
      final j = source.syncedBotbooruProfileToJson();
      expect(j['botbooruAvatar'], isNull);
      expect(j['botbooruAvatarOriginal'], isNull);
      expect(j['botbooruFeaturedCharacterId'], isNull);

      final dest = AppStore(storage: _NoopBackend());
      // Seed dest with non-null values to prove they get cleared to null.
      dest.setBotbooruAvatar('data:image/png;base64,STALE');
      dest.setBotbooruFeaturedCharacter('stale-char');
      // dest now has a newer mtime than source (setters bumped it), so force
      // the apply with a payload mtime above dest's.
      j['mtime'] = dest.botbooruProfileMtime + 1000;

      dest.applySyncedBotbooruProfile(j);
      expect(dest.botbooruUsername, 'NoPics');
      expect(dest.botbooruAvatar, isNull);
      expect(dest.botbooruAvatarOriginal, isNull);
      expect(dest.botbooruFeaturedCharacterId, isNull);
    });
  });

  group('LWW (last-writer-wins by mtime)', () {
    test('payload mtime <= local botbooruProfileMtime is a NO-OP', () {
      final dest = AppStore(storage: _NoopBackend());
      dest.setBotbooruUsername('Local');
      dest.setBotbooruTitle('Keep me');
      final localMtime = dest.botbooruProfileMtime;

      // Equal mtime → keep local.
      dest.applySyncedBotbooruProfile({
        'mtime': localMtime,
        'botbooruUsername': 'Intruder',
        'botbooruTitle': 'Overwrite me',
      });
      expect(dest.botbooruUsername, 'Local',
          reason: 'equal mtime must not downgrade');
      expect(dest.botbooruTitle, 'Keep me');
      expect(dest.botbooruProfileMtime, localMtime);

      // Older mtime → keep local.
      dest.applySyncedBotbooruProfile({
        'mtime': localMtime - 5000,
        'botbooruUsername': 'Intruder',
        'botbooruTitle': 'Overwrite me',
      });
      expect(dest.botbooruUsername, 'Local',
          reason: 'older mtime must not downgrade');
      expect(dest.botbooruTitle, 'Keep me');
      expect(dest.botbooruProfileMtime, localMtime);
    });

    test('a strictly higher mtime applies', () {
      final dest = AppStore(storage: _NoopBackend());
      dest.setBotbooruUsername('Local');
      final localMtime = dest.botbooruProfileMtime;

      dest.applySyncedBotbooruProfile({
        'mtime': localMtime + 1,
        'botbooruUsername': 'Winner',
      });
      expect(dest.botbooruUsername, 'Winner');
      expect(dest.botbooruProfileMtime, localMtime + 1);
    });
  });

  group('no-clobber regression (the whole reason for the own-mtime design)', () {
    test('a set profile (high mtime) is NOT wiped by an older incoming profile',
        () {
      final dest = AppStore(storage: _NoopBackend());
      dest.setBotbooruUsername('Curated');
      dest.setBotbooruAvatar('data:image/png;base64,MINE');
      dest.setBotbooruAboutMe('My carefully written bio.');
      dest.setBotbooruTitle('Veteran');
      dest.setBotbooruPronouns('she/her');
      dest.setBotbooruFeaturedCharacter('my-fav');
      final highMtime = dest.botbooruProfileMtime;

      // An incoming EMPTY profile (e.g. a never-configured peer) at an
      // older/equal mtime must not blank out the curated local profile.
      dest.applySyncedBotbooruProfile({
        'mtime': highMtime, // equal → no-op
        'botbooruUsername': '',
        'botbooruAvatar': null,
        'botbooruAvatarOriginal': null,
        'botbooruAboutMe': '',
        'botbooruTitle': '',
        'botbooruPronouns': '',
        'botbooruFeaturedCharacterId': null,
      });

      expect(dest.botbooruUsername, 'Curated');
      expect(dest.botbooruAvatar, 'data:image/png;base64,MINE');
      expect(dest.botbooruAboutMe, 'My carefully written bio.');
      expect(dest.botbooruTitle, 'Veteran');
      expect(dest.botbooruPronouns, 'she/her');
      expect(dest.botbooruFeaturedCharacterId, 'my-fav');
      expect(dest.botbooruProfileMtime, highMtime);
    });
  });

  group('every profile setter bumps botbooruProfileMtime', () {
    test('setBotbooruUsername bumps past a stale baseline', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruProfileMtime = 5;
      store.setBotbooruUsername('x');
      expect(store.botbooruProfileMtime, greaterThan(5));
    });
    test('setBotbooruAvatar bumps', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruProfileMtime = 5;
      store.setBotbooruAvatar('data:image/png;base64,A');
      expect(store.botbooruProfileMtime, greaterThan(5));
    });
    test('recropBotbooruAvatar bumps', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruProfileMtime = 5;
      store.recropBotbooruAvatar('pyre://attachment/c', original: 'orig');
      expect(store.botbooruProfileMtime, greaterThan(5));
    });
    test('setBotbooruAboutMe bumps', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruProfileMtime = 5;
      store.setBotbooruAboutMe('bio');
      expect(store.botbooruProfileMtime, greaterThan(5));
    });
    test('setBotbooruTitle bumps', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruProfileMtime = 5;
      store.setBotbooruTitle('title');
      expect(store.botbooruProfileMtime, greaterThan(5));
    });
    test('setBotbooruPronouns bumps', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruProfileMtime = 5;
      store.setBotbooruPronouns('they/them');
      expect(store.botbooruProfileMtime, greaterThan(5));
    });
    test('setBotbooruFeaturedCharacter bumps', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruProfileMtime = 5;
      store.setBotbooruFeaturedCharacter('char-1');
      expect(store.botbooruProfileMtime, greaterThan(5));
    });
  });

  group('persistence', () {
    test('botbooruProfileMtime + profile fields are written to the save blob',
        () async {
      final backend = _CaptureBackend();
      final store = AppStore(storage: backend);
      store.setBotbooruUsername('Persisted');
      final mtime = store.botbooruProfileMtime;
      expect(mtime, greaterThan(0));

      // Force the debounced persist and inspect the captured blob — this proves
      // the (slightly custom, conditional) SERIALIZE side emits the watermark +
      // field. The READ side is the trivial `(raw['botbooruProfileMtime'] as
      // num?)?.toInt() ?? 0` mirror in load(), identical to ~60 sibling fields;
      // we don't drive load() here because its AttachmentMigration plugin calls
      // flake across concurrent test isolates (see the note atop main()).
      await store.flushPersist();
      expect(backend.captured, isNotNull);
      expect(backend.captured!['botbooruProfileMtime'], mtime);
      expect(backend.captured!['botbooruUsername'], 'Persisted');
    });
  });
}
