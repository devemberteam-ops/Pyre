// BATCH P1-state — (G) coalesced streaming notifications.
//
// `updateMessageText` is called once per streamed token. Previously each
// call fired notifyListeners() synchronously, fanning a full-store rebuild
// out per token. We coalesce those notifications to ~frame cadence WITHOUT
// dropping any text: the model is mutated synchronously on every call (so
// the latest text is always readable), and a trailing notify is guaranteed
// so the final chunk paints.
//
// These tests prove (a) the full streamed text arrives intact in the model,
// (b) a burst of N chunks collapses to far fewer than N notifications, and
// (c) a notify always fires after the burst settles.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

/// In-memory backend so `flushPersist()` doesn't hit real disk / platform
/// channels in a unit test.
class _MemBackend implements StoreBackend {
  Map<String, dynamic>? blob;
  int saveCount = 0;

  @override
  Future<Map<String, dynamic>?> load() async => blob;

  @override
  Future<void> save(Map<String, dynamic> b) async {
    saveCount++;
    blob = b;
  }

  @override
  Future<void> clear() async {
    blob = null;
  }
}

void main() {
  group('(G) streaming notify coalescing', () {
    test('full streamed text arrives intact after a token burst', () async {
      final s = AppStore();
      final chat = s.addImportedChat(
          Chat(id: 'c1', characterIds: ['x']));
      s.addMessage(
          chat.id,
          Message(
            id: 'm1',
            kind: MessageKind.char,
            variants: [''],
            selectedVariant: 0,
          ));

      // Simulate a stream: each chunk appends one more word.
      const words = [
        'The', 'The quick', 'The quick brown', 'The quick brown fox',
        'The quick brown fox jumps',
      ];
      for (final w in words) {
        s.updateMessageText(chat.id, 'm1', w, variantIndex: 0);
        // The model must reflect the latest chunk SYNCHRONOUSLY (the bubble
        // reads message.text, not a buffered copy).
        final msg = chat.messages.firstWhere((m) => m.id == 'm1');
        expect(msg.variants[0], w);
      }

      // Let the coalesced notify timer flush.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final msg = chat.messages.firstWhere((m) => m.id == 'm1');
      expect(msg.variants[0], 'The quick brown fox jumps');
    });

    test('N chunks collapse to far fewer notifications', () async {
      final s = AppStore();
      final chat = s.addImportedChat(Chat(id: 'c1', characterIds: ['x']));
      s.addMessage(chat.id,
          Message(id: 'm1', kind: MessageKind.char, variants: ['']));

      var notifies = 0;
      s.addListener(() => notifies++);

      // 100 synchronous chunks in one event-loop turn.
      for (var i = 0; i < 100; i++) {
        s.updateMessageText(chat.id, 'm1', 'chunk $i', variantIndex: 0);
      }
      // Synchronously (before the timer fires) the burst must NOT have
      // produced ~100 notifications.
      expect(notifies, lessThan(100));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      // A trailing notify is guaranteed so the final text paints.
      expect(notifies, greaterThan(0));
      // And it stayed bounded — nowhere near one-per-chunk.
      expect(notifies, lessThan(20));
    });

    test('a notify fires after the burst settles (final paint guaranteed)',
        () async {
      final s = AppStore();
      final chat = s.addImportedChat(Chat(id: 'c1', characterIds: ['x']));
      s.addMessage(chat.id,
          Message(id: 'm1', kind: MessageKind.char, variants: ['']));

      var notifies = 0;
      s.addListener(() => notifies++);
      s.updateMessageText(chat.id, 'm1', 'final', variantIndex: 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifies, greaterThanOrEqualTo(1));
    });

    test('flushPersist forces the pending streamed write to the backend',
        () async {
      final backend = _MemBackend();
      final s = AppStore(storage: backend);
      final chat = s.addImportedChat(Chat(id: 'c1', characterIds: ['x']));
      s.addMessage(chat.id,
          Message(id: 'm1', kind: MessageKind.char, variants: ['']));
      s.updateMessageText(chat.id, 'm1', 'streamed text', variantIndex: 0);
      // flushPersist must fire the pending coalesced notify AND write once.
      await s.flushPersist();
      final msg = chat.messages.firstWhere((m) => m.id == 'm1');
      expect(msg.variants[0], 'streamed text');
      expect(backend.saveCount, greaterThanOrEqualTo(1));
    });
  });
}
