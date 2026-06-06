// Non-destructive Recrop: Character/Persona now keep BOTH images.
//
// `avatar` holds the DISPLAYED image (the crop after a recrop, or the full
// image when never cropped). `avatarOriginal` holds the UNCROPPED full image
// (a `pyre://attachment/<hash>` ref) — or null when the avatar was never
// cropped (in which case `avatar` IS the full image). These tests pin:
//   1. `avatarOriginal` round-trips through fromJson(toJson()) when set, and
//      is OMITTED from JSON (back-compat) when null.
//   2. The persona<->character conversions + duplicate carry it through.
//   3. `collectReferencedAttachmentHashes` keeps the original blob alive
//      (GC + sync attachment-push coverage).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/attachment_refs.dart';
import 'package:pyre/services/attachment_store.dart';
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
  group('avatarOriginal round-trip', () {
    test('Character: present value survives fromJson(toJson())', () {
      final c = Character(
        id: 'c1',
        name: 'Ren',
        avatar: 'pyre://attachment/cropped',
        avatarOriginal: 'pyre://attachment/full',
      );
      final restored = Character.fromJson(c.toJson());
      expect(restored.avatar, 'pyre://attachment/cropped');
      expect(restored.avatarOriginal, 'pyre://attachment/full');
    });

    test('Character: null is OMITTED from JSON + parses back to null', () {
      final c = Character(id: 'c1', name: 'Ren', avatar: 'pyre://attachment/x');
      final json = c.toJson();
      // Omit-when-null so existing backups + the common case stay lean.
      expect(json.containsKey('avatarOriginal'), isFalse);
      final restored = Character.fromJson(json);
      expect(restored.avatarOriginal, isNull);
    });

    test('Character: absent key parses to null (back-compat)', () {
      final restored = Character.fromJson({'id': 'c1', 'name': 'Ren'});
      expect(restored.avatarOriginal, isNull);
    });

    test('Character: default constructor leaves avatarOriginal null', () {
      expect(Character(id: 'c1', name: 'Ren').avatarOriginal, isNull);
    });

    test('Persona: present value survives fromJson(toJson())', () {
      final p = Persona(
        id: 'p1',
        name: 'You',
        avatar: 'pyre://attachment/cropped',
        avatarOriginal: 'pyre://attachment/full',
      );
      final restored = Persona.fromJson(p.toJson());
      expect(restored.avatar, 'pyre://attachment/cropped');
      expect(restored.avatarOriginal, 'pyre://attachment/full');
    });

    test('Persona: null is OMITTED from JSON + parses back to null', () {
      final p = Persona(id: 'p1', name: 'You', avatar: 'pyre://attachment/x');
      final json = p.toJson();
      expect(json.containsKey('avatarOriginal'), isFalse);
      final restored = Persona.fromJson(json);
      expect(restored.avatarOriginal, isNull);
    });

    test('Persona: absent key parses to null (back-compat)', () {
      final restored = Persona.fromJson({'id': 'p1', 'name': 'You'});
      expect(restored.avatarOriginal, isNull);
    });
  });

  group('avatarOriginal carried through conversions', () {
    test('buildPersonaFromCharacter carries avatarOriginal', () {
      final c = Character(
        id: 'c1',
        name: 'Ren',
        avatar: 'pyre://attachment/cropped',
        avatarOriginal: 'pyre://attachment/full',
      );
      final p = buildPersonaFromCharacter(c);
      expect(p.avatar, 'pyre://attachment/cropped');
      expect(p.avatarOriginal, 'pyre://attachment/full');
    });

    test('duplicateCharacter carries avatarOriginal', () async {
      final store = AppStore(storage: _NoopBackend());
      store.characters.add(Character(
        id: 'c1',
        name: 'Ren',
        avatar: 'pyre://attachment/cropped',
        avatarOriginal: 'pyre://attachment/full',
      ));
      final clone = store.duplicateCharacter('c1');
      expect(clone, isNotNull);
      expect(clone!.avatar, 'pyre://attachment/cropped');
      expect(clone.avatarOriginal, 'pyre://attachment/full');
      await store.flushPersist();
    });

    test('duplicatePersona carries avatarOriginal', () async {
      final store = AppStore(storage: _NoopBackend());
      store.personas.add(Persona(
        id: 'p1',
        name: 'You',
        avatar: 'pyre://attachment/cropped',
        avatarOriginal: 'pyre://attachment/full',
      ));
      final clone = store.duplicatePersona('p1');
      expect(clone, isNotNull);
      expect(clone!.avatar, 'pyre://attachment/cropped');
      expect(clone.avatarOriginal, 'pyre://attachment/full');
      await store.flushPersist();
    });
  });

  group('collectReferencedAttachmentHashes includes avatarOriginal', () {
    String url(String h) => '${AttachmentStore.urlPrefix}$h';

    test('keeps both the cropped + the original blob alive', () {
      final s = AppStore();
      s.characters.add(Character(
        id: 'c1',
        name: 'C',
        avatar: url('CROP_C'),
        avatarOriginal: url('FULL_C'),
      ));
      s.personas.add(Persona(
        id: 'p1',
        name: 'P',
        avatar: url('CROP_P'),
        avatarOriginal: url('FULL_P'),
      ));
      final refs = collectReferencedAttachmentHashes(s);
      // The displayed crop AND the uncropped original are both referenced —
      // the original must NOT be GC'd, and the LAN sync push (same set) ships
      // it to paired devices.
      expect(refs, containsAll(<String>{'CROP_C', 'FULL_C', 'CROP_P', 'FULL_P'}));
    });

    test('null avatarOriginal adds nothing extra', () {
      final s = AppStore();
      s.characters.add(Character(id: 'c1', name: 'C', avatar: url('ONLY_C')));
      s.personas.add(Persona(id: 'p1', name: 'P', avatar: url('ONLY_P')));
      final refs = collectReferencedAttachmentHashes(s);
      expect(refs, {'ONLY_C', 'ONLY_P'});
    });

    test('keeps the BotBooru profile avatar + its original alive', () {
      final s = AppStore();
      s.botbooruAvatar = url('BB_CROP');
      s.botbooruAvatarOriginal = url('BB_FULL');
      final refs = collectReferencedAttachmentHashes(s);
      expect(refs, containsAll(<String>{'BB_CROP', 'BB_FULL'}));
    });
  });

  group('BotBooru profile recrop is non-destructive', () {
    test('recropBotbooruAvatar preserves the pre-crop avatar as original', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruAvatar = 'pyre://attachment/full';
      // First recrop: original is null → captured from the passed pre-crop ref.
      store.recropBotbooruAvatar('pyre://attachment/crop1',
          original: store.botbooruAvatar);
      expect(store.botbooruAvatar, 'pyre://attachment/crop1');
      expect(store.botbooruAvatarOriginal, 'pyre://attachment/full');

      // Second recrop: original is preserved (NOT clobbered by the crop).
      store.recropBotbooruAvatar('pyre://attachment/crop2',
          original: store.botbooruAvatar);
      expect(store.botbooruAvatar, 'pyre://attachment/crop2');
      expect(store.botbooruAvatarOriginal, 'pyre://attachment/full');
    });

    test('setBotbooruAvatar (fresh pick / remove) clears the original', () {
      final store = AppStore(storage: _NoopBackend());
      store.botbooruAvatar = 'pyre://attachment/crop';
      store.botbooruAvatarOriginal = 'pyre://attachment/full';
      // Picking a new image is a fresh full image → original must reset.
      store.setBotbooruAvatar('pyre://attachment/new');
      expect(store.botbooruAvatar, 'pyre://attachment/new');
      expect(store.botbooruAvatarOriginal, isNull);
      // Removing also clears.
      store.botbooruAvatarOriginal = 'pyre://attachment/x';
      store.setBotbooruAvatar(null);
      expect(store.botbooruAvatar, isNull);
      expect(store.botbooruAvatarOriginal, isNull);
    });
  });
}
