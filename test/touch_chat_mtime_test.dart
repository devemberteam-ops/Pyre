// Mega-audit 2026-06-05 — sync-drift batch (F1/F5).
//
// The big regression: per-chat sub-state (memory checkpoints, Live Sheet
// snapshots + the liveSheetEnabled / memoryEnabled toggles, story beats,
// scene/background fields, per-chat background override, title, disabled
// inherited lorebooks) is serialized in `Chat.toJson`, but the edit paths
// mutated `chat.X` directly and only called `notifyAndPersist()` — never
// bumping `chat.mtime`. LAN sync only ships records where `mtime > since`,
// so those edits saved to disk but NEVER propagated.
//
// The fix funnels every per-chat sub-state mutation through
// `AppStore.touchChat(chat)`, which bumps `mtime` (+ `updatedAt`) and
// persists/notifies once. These tests assert that touching each KIND of
// per-chat sub-state bumps `chat.mtime` so the record enters the dirty set.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/live_sheet.dart' as lsheet;
import 'package:pyre/services/memory.dart' as ltm;
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/services/story_roadmap.dart' as roadmap;
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

Chat _chat() => Chat(id: 'c1', characterIds: const ['x']);

void main() {
  group('AppStore.touchChat', () {
    test('bumps mtime + updatedAt and notifies once', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = _chat()..mtime = 0..updatedAt = 0;
      store.chats.add(chat);

      var notifies = 0;
      store.addListener(() => notifies++);

      store.touchChat(chat);

      expect(chat.mtime, greaterThan(0));
      expect(chat.updatedAt, equals(chat.mtime));
      expect(notifies, 1);
      await store.flushPersist();
    });

    test('a second touch advances (or holds) mtime monotonically', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = _chat();
      store.chats.add(chat);
      store.touchChat(chat);
      final first = chat.mtime;
      store.touchChat(chat);
      expect(chat.mtime, greaterThanOrEqualTo(first));
      await store.flushPersist();
    });
  });

  // Each block mutates a kind of per-chat sub-state via the pure mutator,
  // then funnels through touchChat — exactly the screen/pipeline pattern.
  group('per-chat sub-state edits bump chat.mtime (enter the dirty set)', () {
    late AppStore store;
    late Chat chat;

    setUp(() {
      store = AppStore(storage: _NoopBackend());
      chat = _chat()..mtime = 0;
      store.chats.add(chat);
    });

    test('memory checkpoint append', () async {
      ltm.applyCheckpoint(
        chat,
        MemoryCheckpoint(
            id: 'mc1', summary: 's', anchorMessageIdx: 0, pathHash: 'h'),
      );
      store.touchChat(chat);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('Live Sheet snapshot append', () async {
      lsheet.appendLiveSheetSnapshot(
        chat,
        LiveSheetSnapshot(
            id: 'ls1', anchorMessageId: '', pathHash: '', entities: const []),
      );
      store.touchChat(chat);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('liveSheetEnabled toggle', () async {
      chat.liveSheetEnabled = true;
      store.touchChat(chat);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('memoryEnabled toggle', () async {
      chat.memoryEnabled = false;
      store.touchChat(chat);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('story beat append', () async {
      roadmap.appendStoryBeat(chat, 'a beat');
      store.touchChat(chat);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('scene background fields', () async {
      chat.sceneBgFile = 'tavern.jpg';
      chat.sceneSetting = 'medieval_fantasy';
      chat.sceneLocation = 'The Guild';
      store.touchChat(chat);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('per-chat background override', () async {
      chat.backgroundSource = ChatBackgroundSource.custom;
      chat.customBackgroundDataUrl = 'data:image/png;base64,AAAA';
      chat.backgroundOpacity = 0.5;
      store.touchChat(chat);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });
  });

  group('disabled-inherited-lorebook toggle bumps chat.mtime', () {
    test('disable bumps mtime', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = _chat()..mtime = 0;
      store.chats.add(chat);
      store.disableInheritedLorebookForChat('c1', 'lore1');
      expect(chat.disabledInheritedLorebookIds, contains('lore1'));
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('re-enable bumps mtime', () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = _chat()
        ..mtime = 0
        ..disabledInheritedLorebookIds.add('lore1');
      store.chats.add(chat);
      store.enableInheritedLorebookForChat('c1', 'lore1');
      expect(chat.disabledInheritedLorebookIds, isEmpty);
      expect(chat.mtime, greaterThan(0));
      await store.flushPersist();
    });

    test('disabling an already-disabled book is a no-op (mtime unchanged)',
        () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = _chat()
        ..mtime = 0
        ..disabledInheritedLorebookIds.add('lore1');
      store.chats.add(chat);
      store.disableInheritedLorebookForChat('c1', 'lore1');
      expect(chat.mtime, 0); // unchanged — idempotent guard short-circuits
      await store.flushPersist();
    });
  });
}
