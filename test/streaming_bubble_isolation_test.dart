@TestOn('vm')
library;

// Pyre 1.2 (2026-07 perf pass) — Fix 1/2/3/4/5: isolate the streaming
// bubble's repaints from the rest of the chat screen and keep its parse off
// the O(N^2) per-token path.
//
// Root cause (owner-reported #1 jank complaint): every SSE token called
// `AppStore.updateMessageText` -> a (coalesced, but still eventually GLOBAL)
// `notifyListeners()` -> `context.watch<AppStore>()` in `ChatScreen.build`
// rebuilt RootShell/nav/every bubble, and the growing streaming bubble's
// `ChatText` re-parsed its ENTIRE text from scratch each rebuild (O(N^2)
// over a long reply).
//
// This test drives a REAL `ChatScreen` through a real (mocked) SSE stream —
// same `debugHttpClientFactory` / `MockClient` harness as
// test/context_recovery_test.dart — and asserts:
//   1. A non-streaming SIBLING bubble's build count stays FLAT across the
//      whole stream while the streaming bubble's climbs (isolation).
//   2. The streaming bubble still renders FORMATTED text (an *italic* span
//      keeps its distinct style) during the stream — no plain-text-while-
//      streaming regression.
//   3. The 600ms debounced persist still fires DURING streaming (unchanged
//      cadence) — not only once at the very end.
//   4. At onDone, the final settled message text equals the full streamed
//      content and that exact text is what lands in the persisted blob.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_screen.dart';
import 'package:pyre/services/chat_api.dart' show debugHttpClientFactory;
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';
import 'package:pyre/widgets/chat_text.dart';

class _RecordingBackend implements StoreBackend {
  final List<Map<String, dynamic>> saves = [];

  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> blob) async {
    // Deep-ish copy so a later in-place mutation of the live blob can't
    // retroactively change what we already "saved" (mirrors how a real
    // disk write is a snapshot at call time).
    saves.add(jsonDecode(jsonEncode(blob)) as Map<String, dynamic>);
  }

  @override
  Future<void> clear() async {}
}

Widget _host(AppStore store, Widget screen) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: screen),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiProvider provider;

  tearDown(() {
    debugHttpClientFactory = null;
  });

  String sseChunk(String content) =>
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': content},
          }
        ]
      })}\n\n';
  String sseDone() => 'data: [DONE]\n\n';

  testWidgets(
      'streaming bubble isolation: sibling build count stays flat, '
      'streaming bubble renders formatted text, persist cadence unchanged, '
      'final text settles + persists', (tester) async {
    // A slow multi-chunk stream (many small chunks) so token-by-token
    // behavior is actually exercised, not just a single delta.
    final chunks = <String>[
      'The ',
      '"Sunken Gate" ',
      '*creaked* ',
      'open ',
      'slowly ',
      'as ',
      'Sera ',
      'stepped ',
      'through.',
    ];
    debugHttpClientFactory = () => MockClient((http.Request req) async {
          final body = chunks.map(sseChunk).join() + sseDone();
          return http.Response(
            body,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        });
    provider = ApiProvider(
      id: 'p1',
      name: 'Test Provider',
      baseUrl: 'http://fake-provider.test/v1',
      apiKey: 'sk-test',
      model: 'test-model',
    );

    final backend = _RecordingBackend();
    final store = AppStore(storage: backend);

    final character = Character(
      id: 'char-1',
      name: 'Sera',
      description: 'A quiet blacksmith.',
      personality: 'Reserved.',
      scenario: 'A forge.',
      createdAt: 0,
      updatedAt: 0,
    );
    store.characters.add(character);
    store.providers.add(provider);
    store.activeProviderId = provider.id;

    // The SIBLING message: a normal, already-settled char turn that must
    // NOT rebuild while the NEW assistant turn streams below it.
    final siblingId = 'sibling-msg';
    final chat = Chat(
      id: 'chat-1',
      characterIds: [character.id],
      characterSnapshots: {character.id: character},
      messages: [
        Message(
          id: 'u0',
          kind: MessageKind.user,
          variants: ['Hello Sera.'],
          createdAt: 0,
          mtime: 0,
        ),
        Message(
          id: siblingId,
          kind: MessageKind.char,
          characterId: character.id,
          variants: ['*Sera nods.* "Understood."'],
          createdAt: 0,
          mtime: 0,
        ),
      ],
      memoryEnabled: false,
      liveSheetEnabled: false,
      createdAt: 0,
      updatedAt: 0,
    );
    store.chats.add(chat);

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    debugResetBubbleBuildCounts();
    ChatText.debugClearParseCache();

    await tester.pumpWidget(_host(store, ChatScreen(chatId: chat.id)));
    await tester.pump();

    // Send a fresh message — this starts a NEW assistant turn/bubble that
    // will stream into place below the sibling.
    final fields = find.byType(TextField);
    expect(fields, findsWidgets);
    await tester.enterText(fields.first, 'Go on.');
    await tester.pump();
    final sendIcon = find.byIcon(Icons.arrow_upward);
    expect(sendIcon, findsOneWidget);
    await tester.tap(sendIcon);
    await tester.pump();

    // Snapshot the sibling's build count right here: the turn has started
    // (the new empty assistant bubble now exists, which — like any
    // `addMessage` — is a normal, ONE-TIME global notify that legitimately
    // rebuilds the whole visible list once). Everything from this point
    // forward is the per-TOKEN streaming path, which must NOT touch the
    // sibling again.
    final siblingBuildsAtStreamStart =
        debugBubbleBuildCounts[siblingId] ?? 0;
    expect(siblingBuildsAtStreamStart, greaterThanOrEqualTo(1),
        reason: 'sanity: the sibling must have painted at least once '
            'before we start measuring streaming-only rebuilds');

    // Let the stream begin landing chunks. Pump in small steps (well under
    // the 600ms persist debounce and past several 16ms coalesce windows) so
    // multiple coalesced flushes actually happen, mirroring real streaming.
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    // (1) Isolation: the sibling's build count must not have climbed AT ALL
    // since the stream started — it never touches the streaming notifier.
    final siblingBuildsDuringStream =
        (debugBubbleBuildCounts[siblingId] ?? 0) - siblingBuildsAtStreamStart;
    expect(siblingBuildsDuringStream, 0,
        reason: 'a non-streaming sibling bubble must not rebuild per '
            'streamed token — it should not repaint at all once the '
            'stream is isolated to just the active bubble');

    // The streaming bubble itself must have built at least once (it has to
    // paint SOMETHING), independent of how many times exactly — the point
    // of Fix 1 is that a rebuild of the streaming bubble does not fan out
    // to the sibling, not that the streaming bubble is forbidden to build.
    final newAssistantId = chat.messages
        .firstWhere((m) => m.kind == MessageKind.char && m.id != siblingId)
        .id;
    expect(debugBubbleBuildCounts[newAssistantId], greaterThanOrEqualTo(1));

    // (2) Formatting preserved during streaming: the *creaked* span must
    // still render as distinct (italic) styling, not literal asterisks or
    // plain text. Walk the rendered RichText tree looking for a TextSpan
    // whose style differs from plain body text (italic marker) containing
    // "creaked".
    bool foundItalicCreaked = false;
    void search(InlineSpan span) {
      if (span is TextSpan) {
        if ((span.text ?? '').contains('creaked') &&
            span.style?.fontStyle == FontStyle.italic) {
          foundItalicCreaked = true;
        }
        for (final c in span.children ?? const <InlineSpan>[]) {
          search(c);
        }
      }
    }

    for (final richText
        in tester.widgetList<RichText>(find.byType(RichText))) {
      search(richText.text);
    }
    expect(foundItalicCreaked, isTrue,
        reason: 'streaming text must still render with markdown '
            'formatting (italics), not plain text');

    // (3) Persist cadence unchanged: at least one save already landed
    // DURING streaming (the 600ms debounce fired mid-stream), not only at
    // the very end via the onDone flush.
    final savesDuringStream = backend.saves.length;
    expect(savesDuringStream, greaterThanOrEqualTo(1),
        reason: 'the existing 600ms debounced persist must still fire '
            'while the stream is in progress');

    // Let the stream finish completely (onDone flushes + settles).
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));

    // (4) Final settle: the message's stored text equals the full streamed
    // content, and the persisted blob (the actual "disk") carries the same
    // text — proving the synchronous-write + persist-cadence invariants
    // both held end to end.
    final finalMessage =
        chat.messages.firstWhere((m) => m.id == newAssistantId);
    final expectedFull = chunks.join();
    expect(finalMessage.text, expectedFull);

    expect(backend.saves, isNotEmpty);
    final lastBlob = backend.saves.last;
    final chats = lastBlob['chats'] as List;
    final savedChat =
        chats.firstWhere((c) => (c as Map)['id'] == chat.id) as Map;
    final savedMessages = savedChat['messages'] as List;
    final savedAssistant = savedMessages.firstWhere(
        (m) => (m as Map)['id'] == newAssistantId) as Map;
    final savedVariants = (savedAssistant['variants'] as List).cast<String>();
    expect(savedVariants[savedAssistant['selectedVariant'] as int? ?? 0],
        expectedFull,
        reason: 'the persisted blob must contain the exact final '
            'streamed text — the debounced persist must not have been '
            'skipped or shortened by the isolation path');
  });

  // REGRESSION (2026-07-02, owner-reported "streaming ficou em branco até o
  // fim"): the test above uses a BUFFERED MockClient that delivers the whole
  // SSE body + [DONE] in one burst, so onDone's global-notify render satisfies
  // its assertions even if the LIVE per-token path is dead. This test streams
  // chunks over time and asserts partial text is on screen BEFORE [DONE] —
  // i.e. the isolated ValueListenableBuilder actually reflects mid-stream
  // updates, not just the final settle.
  testWidgets('streaming bubble shows partial text mid-stream, before [DONE]',
      (tester) async {
    final controller = StreamController<List<int>>();
    debugHttpClientFactory = () => _ChunkedClient(controller.stream);

    provider = ApiProvider(
      id: 'p1',
      name: 'Test Provider',
      baseUrl: 'http://fake-provider.test/v1',
      apiKey: 'sk-test',
      model: 'test-model',
    );
    final backend = _RecordingBackend();
    final store = AppStore(storage: backend);
    final character = Character(
      id: 'char-1',
      name: 'Sera',
      description: 'A quiet blacksmith.',
      personality: 'Reserved.',
      scenario: 'A forge.',
      createdAt: 0,
      updatedAt: 0,
    );
    store.characters.add(character);
    store.providers.add(provider);
    store.activeProviderId = provider.id;
    final chat = Chat(
      id: 'chat-1',
      characterIds: [character.id],
      characterSnapshots: {character.id: character},
      messages: [
        Message(
            id: 'u0',
            kind: MessageKind.user,
            variants: ['Hello Sera.'],
            createdAt: 0,
            mtime: 0),
      ],
      memoryEnabled: false,
      liveSheetEnabled: false,
      createdAt: 0,
      updatedAt: 0,
    );
    store.chats.add(chat);

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    ChatText.debugClearParseCache();

    await tester.pumpWidget(_host(store, ChatScreen(chatId: chat.id)));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Go on.');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump(); // starts the turn + subscribes to the stream

    // Walk every rendered RichText for a needle (ChatText renders spans, not
    // a plain Text, so find.textContaining won't see it).
    bool renders(String needle) {
      var found = false;
      void search(InlineSpan span) {
        if (span is TextSpan) {
          if ((span.text ?? '').contains(needle)) found = true;
          for (final c in span.children ?? const <InlineSpan>[]) {
            search(c);
          }
        }
      }

      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        search(rt.text);
      }
      return found;
    }

    // Release ONE chunk, advance generously past the 16ms coalesce window —
    // the partial text MUST be on screen now, long before [DONE].
    controller.add(utf8.encode(sseChunk('The gate ')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // Diagnostic: did the MODEL receive the chunk (proving the stream was
    // processed) even if the SCREEN didn't show it? If model has it but the
    // screen is blank, the bug is the UI render path, not test timing.
    final liveMsg =
        chat.messages.lastWhere((m) => m.kind == MessageKind.char);
    expect(liveMsg.text, contains('The gate'),
        reason: 'sanity: the streamed chunk reached the model synchronously');
    expect(renders('The gate'), isTrue,
        reason: 'the streaming bubble must show text WHILE generating, not '
            'only after the response completes');

    // A second live chunk must append on screen, still before [DONE].
    controller.add(utf8.encode(sseChunk('creaked open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(renders('creaked open'), isTrue,
        reason: 'subsequent live tokens must keep updating the bubble');

    // Close out cleanly so no timers dangle into teardown.
    controller.add(utf8.encode(sseDone()));
    await controller.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
  });
}

/// A minimal streaming client whose response body is a caller-controlled
/// stream, so a test can release SSE chunks one at a time and assert the UI
/// updates BETWEEN chunks (unlike a buffered MockClient, which delivers the
/// whole body — and fires onDone — in a single burst).
class _ChunkedClient extends http.BaseClient {
  final Stream<List<int>> body;
  _ChunkedClient(this.body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      body,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}
