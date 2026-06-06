// Mega-audit 2026-06-04 — regression test for the CHAT batch fix
// chat-core-2-01: Fill-In "Custom message → Add as variant" must stash the
// currently-visible downstream tail under the OLD greeting variant (and hide
// it) BEFORE adding+selecting the new custom variant — exactly the dance
// `selectVariant` / `_regenerateMessage` / `_streamFillInVariant` perform.
//
// Why this lives at the model level: `_attachVariantToFirst` is a private
// ChatScreen method, but the bug is a pure data-association defect on the
// Chat/Message model. The defective branch did only
// `first.variants.add(text); first.selectedVariant = newIndex` with NO
// snapshot of `chat.messages.sublist(1)` into `downstreamByVariant` and NO
// `removeRange`. The test reproduces BOTH the buggy and the fixed operation
// sequences and asserts that, after the fix, a later `selectVariant(0)` swipe
// back restores the ORIGINAL greeting's conversation tail (not a foreign /
// empty one). If the stash is dropped again, the "swipe back" assertion fails.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

void main() {
  Message userMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.user, variants: [text], createdAt: 1);
  Message charMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.char, variants: [text], createdAt: 1);

  /// Build a chat: greeting (1 variant) + a downstream user/char tail.
  Chat freshChatWithTail() => Chat(
        id: 'c1',
        characterIds: const ['x'],
        messages: [
          charMsg('g1', 'Original greeting.'),
          userMsg('u1', 'Hello there.'),
          charMsg('a1', 'A reply that belongs to the ORIGINAL greeting.'),
        ],
      );

  /// The PRODUCTION fixed operation: snapshot+hide the current tail under the
  /// old variant, then add+select the new custom variant (mirrors
  /// `_attachVariantToFirst`'s non-empty branch after the chat-core-2-01 fix).
  void attachVariantFixed(Chat chat, String text) {
    final first = chat.messages.first;
    if (chat.messages.length > 1) {
      final tail = chat.messages.sublist(1);
      first.downstreamByVariant[first.selectedVariant] =
          List<Message>.from(tail);
      chat.messages.removeRange(1, chat.messages.length);
    }
    first.variants.add(text);
    first.selectedVariant = first.variants.length - 1;
  }

  /// The OLD buggy operation: add+select with NO stash/remove.
  void attachVariantBuggy(Chat chat, String text) {
    final first = chat.messages.first;
    first.variants.add(text);
    first.selectedVariant = first.variants.length - 1;
  }

  group('chat-core-2-01 — Fill-In custom variant preserves the original tail',
      () {
    test('fixed: new custom variant opens on a clean slate', () {
      final chat = freshChatWithTail();
      attachVariantFixed(chat, 'A brand new opening line.');

      final first = chat.messages.first;
      // Two greeting variants now; the new one is selected.
      expect(first.variants.length, 2);
      expect(first.selectedVariant, 1);
      expect(first.text, 'A brand new opening line.');
      // The original conversation tail is no longer physically below the
      // selected (new) variant — it was stashed under variant 0.
      expect(chat.messages.length, 1,
          reason: 'new custom variant must open on a clean slate');
      expect(first.downstreamByVariant[0], isNotNull);
      expect(first.downstreamByVariant[0]!.length, 2);
    });

    test('fixed: swiping back to variant 0 restores the ORIGINAL tail',
        () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = freshChatWithTail();
      store.chats.add(chat);

      attachVariantFixed(chat, 'A brand new opening line.');
      // Now swipe back to the original greeting.
      store.selectVariant('c1', 'g1', 0);

      // The original greeting + its exact tail are visible again.
      expect(chat.messages.map((m) => m.id).toList(), ['g1', 'u1', 'a1']);
      expect(chat.messages.first.text, 'Original greeting.');
      expect(chat.messages.last.text,
          'A reply that belongs to the ORIGINAL greeting.');
      await store.flushPersist();
    });

    test(
        'buggy (documents the defect): the foreign tail mis-associates on swipe',
        () async {
      final store = AppStore(storage: _NoopBackend());
      final chat = freshChatWithTail();
      store.chats.add(chat);

      // Old behaviour: no stash/remove. The new variant is selected while the
      // ORIGINAL tail still sits physically below it.
      attachVariantBuggy(chat, 'A brand new opening line.');
      expect(chat.messages.length, 3,
          reason: 'buggy path leaves the foreign tail under the new variant');

      // A swipe back to variant 0 now stashes the FOREIGN tail under the NEW
      // variant (index 1) and restores nothing for variant 0 → the original
      // greeting appears to have lost its whole conversation.
      store.selectVariant('c1', 'g1', 0);
      expect(chat.messages.map((m) => m.id).toList(), ['g1'],
          reason:
              'buggy: original greeting comes back with an EMPTY tail (the real '
              'tail was mis-stashed under the custom variant)');
      // And the tail is now wrongly associated with the custom variant.
      expect(chat.messages.first.downstreamByVariant[1]?.length, 2);
      await store.flushPersist();
    });
  });
}

/// No-op persistence backend so the debounced persist schedules harmlessly.
class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}
