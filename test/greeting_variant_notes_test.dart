@TestOn('vm')
library;

// Fill-In scenario-note binding (owner-reported 2026-07-13: after deleting a
// Fill-In greeting and making a NEW one, the OLD "Scenario:" note stayed and
// duplicated — two identical bubbles). Root cause: a scenario note sits ABOVE
// the greeting and pins to a greeting-variant INDEX via `greetingVariant`, but
// `removeMessageVariant`/`removeMessageVariantAt` reindexed only
// `downstreamByVariant`, never the bound notes — so deleting the greeting
// variant orphaned its note. These pin the fix: the bound note is dropped, and
// higher-bound notes shift down, exactly like the downstream reindex.

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

Message _note(String id, int? gv) =>
    Message(id: id, kind: MessageKind.ooc, variants: ['Scenario: a scene'])
      ..greetingVariant = gv;

Message _greeting(List<String> variants, {int sel = 0}) => Message(
    id: 'greet', kind: MessageKind.char, variants: variants, selectedVariant: sel);

AppStore _storeWith(List<Message> messages) {
  final store = AppStore(storage: _NoopBackend());
  store.chats.add(Chat(
      id: 'ch', characterIds: ['c'], messages: messages, createdAt: 0, updatedAt: 0));
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deleting the greeting variant drops its bound scenario note', () {
    // Card greeting at v0, a Fill-In opener at v1 with its scenario note bound
    // to v1. Deleting v1 (the selected one) must take the note with it.
    final store = _storeWith([
      _note('note1', 1),
      _greeting(['card greeting', 'fill-in opener'], sel: 1),
    ]);

    store.removeMessageVariant('ch', 'greet');

    final chat = store.chats.first;
    expect(chat.messages.any((m) => m.id == 'note1'), isFalse,
        reason: 'the note bound to the deleted greeting variant is removed — '
            'so it can no longer duplicate on the next Fill-In');
    expect(
        (chat.messages.firstWhere((m) => m.id == 'greet')).variants,
        ['card greeting']);
  });

  test('higher-bound notes shift down when a lower greeting variant is deleted',
      () {
    final store = _storeWith([
      _note('n1', 1),
      _note('n2', 2),
      _greeting(['v0', 'v1', 'v2'], sel: 1),
    ]);

    store.removeMessageVariant('ch', 'greet'); // removes selected v1

    final chat = store.chats.first;
    expect(chat.messages.any((m) => m.id == 'n1'), isFalse,
        reason: 'note bound to the deleted v1 is gone');
    expect(chat.messages.firstWhere((m) => m.id == 'n2').greetingVariant, 1,
        reason: 'note that was bound to v2 now follows its greeting at v1');
  });

  test('notes bound to lower variants + unbound manual OOC are untouched', () {
    final store = _storeWith([
      _note('low', 0), // bound to v0 (below the deletion)
      _note('manual', null), // a hand-written OOC, never bound
      _greeting(['v0', 'v1'], sel: 1),
    ]);

    store.removeMessageVariant('ch', 'greet'); // removes v1

    final chat = store.chats.first;
    expect(chat.messages.firstWhere((m) => m.id == 'low').greetingVariant, 0,
        reason: 'a note below the deleted variant keeps its index');
    expect(chat.messages.any((m) => m.id == 'manual'), isTrue,
        reason: 'an unbound (null greetingVariant) note is never swept');
  });

  test('removing a NON-greeting message variant leaves greeting notes alone', () {
    final store = _storeWith([
      _note('note', 1),
      _greeting(['v0', 'v1'], sel: 0),
      Message(id: 'u', kind: MessageKind.user, variants: ['hi']),
      Message(
          id: 'later', kind: MessageKind.char, variants: ['A', 'B'], selectedVariant: 1),
    ]);

    // Delete a variant of a LATER char message — greetingVariant binds to the
    // GREETING, so this must not touch the note.
    store.removeMessageVariant('ch', 'later');

    final chat = store.chats.first;
    expect(chat.messages.any((m) => m.id == 'note'), isTrue);
    expect(chat.messages.firstWhere((m) => m.id == 'note').greetingVariant, 1,
        reason: 'a non-greeting variant removal must not reindex greeting notes');
  });

  test('removeMessageVariantAt (non-selected) also maintains bound notes', () {
    // Greeting selected at v0; delete the NON-selected v1 by index.
    final store = _storeWith([
      _note('n1', 1),
      _note('n2', 2),
      _greeting(['v0', 'v1', 'v2'], sel: 0),
    ]);

    store.removeMessageVariantAt('ch', 'greet', 1);

    final chat = store.chats.first;
    expect(chat.messages.any((m) => m.id == 'n1'), isFalse);
    expect(chat.messages.firstWhere((m) => m.id == 'n2').greetingVariant, 1);
  });
}
