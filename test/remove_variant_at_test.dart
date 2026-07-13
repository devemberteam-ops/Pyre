@TestOn('vm')
library;

// Chat core (audit round 11) — CRITICAL: a Stop / error after a mid-stream swipe
// must drop the PINNED empty stream variant, never the GOOD reply the user
// swiped to (+ its downstream tail). `removeMessageVariantAt` is the pinned-aware
// remove that `_dropEmptyStreamPlaceholder` now uses.

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

Message _u(String id, String text) =>
    Message(id: id, kind: MessageKind.user, variants: [text]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('removing the PINNED non-selected variant keeps the good reply + tail',
      () {
    final store = AppStore(storage: _NoopBackend());
    // Regenerate created variant 1 (the empty pinned placeholder); the user
    // swiped BACK to variant 0 (a good reply) whose active tail is `t1`.
    final msg = Message(
      id: 'm1',
      kind: MessageKind.char,
      variants: ['GOOD reply', ''],
      selectedVariant: 0,
    );
    final chat = Chat(
      id: 'ch',
      characterIds: ['c'],
      messages: [_u('u0', 'hi'), msg, _u('t1', 'a follow-up to the good reply')],
      createdAt: 0,
      updatedAt: 0,
    );
    store.chats.add(chat);

    // Stop-before-first-token drops the PINNED variant (index 1), NOT selected 0.
    store.removeMessageVariantAt('ch', 'm1', 1);

    expect(msg.variants, ['GOOD reply'],
        reason: 'the good reply must survive; the empty placeholder is removed');
    expect(msg.selectedVariant, 0);
    expect(msg.text, 'GOOD reply');
    expect(chat.messages.any((m) => m.id == 't1'), isTrue,
        reason: "the selected variant's active downstream tail must be kept");
  });

  test('removing a variant BELOW the selected shifts selection to same content',
      () {
    final store = AppStore(storage: _NoopBackend());
    final msg = Message(
      id: 'm',
      kind: MessageKind.char,
      variants: ['A', 'B', 'C'],
      selectedVariant: 2, // C is selected
    );
    final chat = Chat(
        id: 'ch', characterIds: ['c'], messages: [msg],
        createdAt: 0, updatedAt: 0);
    store.chats.add(chat);

    store.removeMessageVariantAt('ch', 'm', 0); // remove A (below selection)

    expect(msg.variants, ['B', 'C']);
    expect(msg.selectedVariant, 1, reason: 'still pointing at C');
    expect(msg.text, 'C');
  });

  test('removing the SELECTED variant delegates to the neighbour-picking path',
      () {
    final store = AppStore(storage: _NoopBackend());
    final msg = Message(
      id: 'm',
      kind: MessageKind.char,
      variants: ['A', 'B'],
      selectedVariant: 1,
    );
    final chat = Chat(
        id: 'ch', characterIds: ['c'], messages: [msg],
        createdAt: 0, updatedAt: 0);
    store.chats.add(chat);

    store.removeMessageVariantAt('ch', 'm', 1); // == selected → delegates

    expect(msg.variants, ['A']);
    expect(msg.selectedVariant, 0);
  });

  test('single-variant and out-of-range are no-ops', () {
    final store = AppStore(storage: _NoopBackend());
    final msg = Message(id: 'm', kind: MessageKind.char, variants: ['only']);
    final chat = Chat(
        id: 'ch', characterIds: ['c'], messages: [msg],
        createdAt: 0, updatedAt: 0);
    store.chats.add(chat);

    store.removeMessageVariantAt('ch', 'm', 0); // single variant → no-op
    expect(msg.variants, ['only']);

    final msg2 = Message(
        id: 'm2', kind: MessageKind.char, variants: ['A', 'B'], selectedVariant: 0);
    chat.messages.add(msg2);
    store.removeMessageVariantAt('ch', 'm2', 9); // out of range → no-op
    expect(msg2.variants, ['A', 'B']);
  });
}
