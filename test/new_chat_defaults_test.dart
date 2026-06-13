// Feature (B): global "start NEW chats with Checkpoints / Live Sheet ON or OFF".
// MemorySettings.newChatsEnabled / LiveSheetSettings.newChatsEnabled are the
// per-feature defaults that `startChatWith` reads when building a fresh chat.
// Default true → today's behaviour (both on for new chats). Flip off → a new
// chat starts with the feature disabled (the per-chat manual toggle, and manual
// "Summarise now" / "Update state now", still work).

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

void main() {
  group('new-chat default settings round-trip', () {
    test('MemorySettings.newChatsEnabled defaults true + round-trips', () {
      expect(MemorySettings().newChatsEnabled, isTrue);
      expect(MemorySettings.fromJson(const {}).newChatsEnabled, isTrue);
      final off = MemorySettings(newChatsEnabled: false);
      expect(MemorySettings.fromJson(off.toJson()).newChatsEnabled, isFalse);
    });

    test('LiveSheetSettings.newChatsEnabled defaults true + round-trips', () {
      expect(LiveSheetSettings().newChatsEnabled, isTrue);
      expect(LiveSheetSettings.fromJson(const {}).newChatsEnabled, isTrue);
      final off = LiveSheetSettings(newChatsEnabled: false);
      expect(
          LiveSheetSettings.fromJson(off.toJson()).newChatsEnabled, isFalse);
    });
  });

  group('startChatWith honours the new-chat defaults', () {
    test('defaults (true) → new chat has both features ON', () {
      final store = AppStore(storage: _NoopBackend());
      final chat = store.startChatWith(Character(id: 'c1', name: 'A'));
      expect(chat.memoryEnabled, isTrue);
      expect(chat.liveSheetEnabled, isTrue);
    });

    test('defaults OFF → new chat starts with both features OFF', () {
      final store = AppStore(storage: _NoopBackend());
      store.memorySettings.newChatsEnabled = false;
      store.liveSheetSettings.newChatsEnabled = false;
      final chat = store.startChatWith(Character(id: 'c1', name: 'A'));
      expect(chat.memoryEnabled, isFalse);
      expect(chat.liveSheetEnabled, isFalse);
    });
  });
}
