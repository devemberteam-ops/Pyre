// 2026-07-03 (Gui): "adding characters to a chat gives a mini menu with all
// the options, when it should take you to the normal screen that already has
// folders and better organization." The pickers now share the LIBRARY's
// organization: folder visibility (via topLevelVisibleCharacters), tombstone
// exclusion, favorites floated first, and the library's sort keys — applied
// through this pure helper so the behavior is locked without widgets.
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_picker_screens.dart';

Character _c(
  String id, {
  String? name,
  bool favorite = false,
  bool deleted = false,
  String tagline = '',
  List<String> tags = const [],
}) {
  final c = Character(id: id, name: name ?? id)
    ..favorite = favorite
    ..deleted = deleted
    ..tagline = tagline;
  c.tags.addAll(tags);
  return c;
}

void main() {
  group('organizePickerCharacters', () {
    test('excludes excludeIds and tombstoned characters', () {
      final r = organizePickerCharacters(
        all: [_c('a'), _c('b'), _c('dead', deleted: true)],
        folders: const [],
        excludeIds: {'a'},
      );
      expect([...r.favs, ...r.rest].map((c) => c.id), ['b']);
    });

    test('home view hides filed characters; folder view scopes to members',
        () {
      final folder = Folder(id: 'f', name: 'RPG', characterIds: ['filed']);
      final all = [_c('filed'), _c('loose')];

      final home = organizePickerCharacters(
        all: all,
        folders: [folder],
        excludeIds: const {},
      );
      expect(home.rest.map((c) => c.id), ['loose']);

      final inFolder = organizePickerCharacters(
        all: all,
        folders: [folder],
        excludeIds: const {},
        folderId: 'f',
      );
      expect(inFolder.rest.map((c) => c.id), ['filed']);
    });

    test('a query searches ALL characters (filed ones are reachable)', () {
      final folder = Folder(id: 'f', name: 'RPG', characterIds: ['filed']);
      final r = organizePickerCharacters(
        all: [_c('filed', name: 'Vael'), _c('loose', name: 'Ren')],
        folders: [folder],
        excludeIds: const {},
        query: 'vael',
      );
      expect(r.rest.map((c) => c.id), ['filed']);
    });

    test('query matches tagline and tags too', () {
      final r = organizePickerCharacters(
        all: [
          _c('a', name: 'Ren', tagline: 'space pirate'),
          _c('b', name: 'Vael', tags: ['vampire']),
          _c('x', name: 'Zed'),
        ],
        folders: const [],
        excludeIds: const {},
        query: 'pirate',
      );
      expect(r.rest.map((c) => c.id), ['a']);
    });

    test('favorites float into favs; alpha sort applies within each group',
        () {
      final r = organizePickerCharacters(
        all: [
          _c('z', name: 'Zed'),
          _c('a', name: 'Ana', favorite: true),
          _c('m', name: 'Mia'),
          _c('b', name: 'Bo', favorite: true),
        ],
        folders: const [],
        excludeIds: const {},
        sortKey: 'alpha',
      );
      expect(r.favs.map((c) => c.name), ['Ana', 'Bo']);
      expect(r.rest.map((c) => c.name), ['Mia', 'Zed']);
    });

    test('recent sort uses the lastUsedAt map (never-used sink to bottom)',
        () {
      final r = organizePickerCharacters(
        all: [_c('old'), _c('hot'), _c('never')],
        folders: const [],
        excludeIds: const {},
        sortKey: 'recent',
        lastUsedAt: {'old': 100, 'hot': 900},
      );
      expect(r.rest.map((c) => c.id), ['hot', 'old', 'never']);
    });
  });
}
