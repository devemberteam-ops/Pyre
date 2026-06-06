// M-4: the persona picker must NOT surface soft-deleted (tombstoned)
// personas, and `setChatPersona` must never PIN a deleted persona (whose text
// would keep injecting until GC). The picker filter is `!p.deleted` (mirrors
// the main list in characters_screen `_applyFiltersAndSort`); we exercise the
// same predicate here plus the store-level guard.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
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

// Mirrors the persona picker's inline filter (chat_picker_screens.dart):
// `store.personas.where((p) => !p.deleted)` then optional query match.
List<Persona> pickerVisible(List<Persona> all, [String query = '']) {
  final q = query.trim().toLowerCase();
  final live = all.where((p) => !p.deleted);
  if (q.isEmpty) return live.toList();
  return live.where((p) {
    final hay = '${p.name} ${p.tagline ?? ''} ${p.description}'.toLowerCase();
    return hay.contains(q);
  }).toList();
}

void main() {
  group('M-4: persona picker excludes soft-deleted personas', () {
    test('the filtered list drops deleted personas', () {
      final personas = [
        Persona(id: 'live1', name: 'Ren'),
        Persona(id: 'gone', name: 'Ghost', deleted: true),
        Persona(id: 'live2', name: 'Vesna'),
      ];
      final visible = pickerVisible(personas);
      expect(visible.map((p) => p.id), ['live1', 'live2']);
      expect(visible.any((p) => p.deleted), isFalse);
    });

    test('a deleted persona is excluded even when it matches the query', () {
      final personas = [
        Persona(id: 'live', name: 'Aria'),
        Persona(id: 'gone', name: 'Aria Clone', deleted: true),
      ];
      final visible = pickerVisible(personas, 'aria');
      expect(visible.map((p) => p.id), ['live']);
    });
  });

  group('M-4: setChatPersona never pins a deleted persona', () {
    test('selecting a deleted persona id falls back to explicit No-persona',
        () async {
      final store = AppStore(storage: _NoopBackend());
      store.personas.add(Persona(id: 'gone', name: 'Ghost', deleted: true));
      final chat = Chat(id: 'c1', characterIds: const ['x']);
      store.chats.add(chat);

      store.setChatPersona('c1', 'gone');
      // The deleted id must NOT latch — it collapses to the No-persona
      // sentinel so no tombstoned persona text injects.
      expect(chat.personaId, kExplicitNoPersonaId);

      await store.flushPersist();
    });

    test('a live persona id pins normally', () async {
      final store = AppStore(storage: _NoopBackend());
      store.personas.add(Persona(id: 'live', name: 'Ren'));
      final chat = Chat(id: 'c1', characterIds: const ['x']);
      store.chats.add(chat);

      store.setChatPersona('c1', 'live');
      expect(chat.personaId, 'live');

      await store.flushPersist();
    });

    test('explicit No-persona sentinel passes through untouched', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = Chat(id: 'c1', characterIds: const ['x']);
      store.chats.add(chat);

      store.setChatPersona('c1', kExplicitNoPersonaId);
      expect(chat.personaId, kExplicitNoPersonaId);

      await store.flushPersist();
    });
  });
}
