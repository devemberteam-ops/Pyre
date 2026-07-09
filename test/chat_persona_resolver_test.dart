// State-order audit #2: `kExplicitNoPersonaId` must be honoured everywhere a
// chat resolves "who plays the user" — not just in chat_screen.dart's
// `_chatPersona`. Two inline copies (group_lorebooks_sheet.dart,
// chat_info_sheet.dart) silently substituted the global active persona back
// in for a no-persona chat, producing phantom "(persona)" inherited
// lorebooks. `chatPersonaFor` is now the ONE shared implementation; these
// tests pin its contract directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_persona.dart';
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
  group('chatPersonaFor', () {
    test('kExplicitNoPersonaId sentinel resolves to null, even with an '
        'active global persona set', () async {
      final store = AppStore(storage: _NoopBackend());
      final active = Persona(id: 'active', name: 'Ren');
      store.personas.add(active);
      store.activePersonaId = active.id;
      final chat = Chat(
        id: 'c1',
        characterIds: const ['x'],
        personaId: kExplicitNoPersonaId,
      );
      store.chats.add(chat);

      expect(chatPersonaFor(store, chat), isNull);
    });

    test('explicit valid persona id resolves to THAT persona, not the '
        'global active one', () async {
      final store = AppStore(storage: _NoopBackend());
      final active = Persona(id: 'active', name: 'Ren');
      final chosen = Persona(id: 'chosen', name: 'Vesna');
      store.personas.addAll([active, chosen]);
      store.activePersonaId = active.id;
      final chat = Chat(
        id: 'c1',
        characterIds: const ['x'],
        personaId: chosen.id,
      );
      store.chats.add(chat);

      expect(chatPersonaFor(store, chat)?.id, chosen.id);
    });

    test('a personaId pointing at a deleted/missing persona falls back to '
        'the global active persona', () async {
      final store = AppStore(storage: _NoopBackend());
      final active = Persona(id: 'active', name: 'Ren');
      store.personas.add(active);
      store.activePersonaId = active.id;
      final chat = Chat(
        id: 'c1',
        characterIds: const ['x'],
        personaId: 'gone-forever',
      );
      store.chats.add(chat);

      expect(chatPersonaFor(store, chat)?.id, active.id);
    });

    test('null personaId (legacy chat) falls back to the global active '
        'persona', () async {
      final store = AppStore(storage: _NoopBackend());
      final active = Persona(id: 'active', name: 'Ren');
      store.personas.add(active);
      store.activePersonaId = active.id;
      final chat = Chat(id: 'c1', characterIds: const ['x'], personaId: null);
      store.chats.add(chat);

      expect(chatPersonaFor(store, chat)?.id, active.id);
    });
  });
}
