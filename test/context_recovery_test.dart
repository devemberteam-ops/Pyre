@TestOn('vm')
library;

// Pyre 1.2 (Motor refactor) — Slice D-3: reactive context-recovery loop.
//
// Exercises the ONLY send-path slice of Slice D end-to-end through the real
// `ChatScreen` widget, using `MockClient` (package:http/testing.dart) as the
// `debugHttpClientFactory` seam — mirrors test/lorebook_creator_widget_test.dart.
// MockClient is IN-MEMORY (no real socket, no dart:io HttpClient), which is
// essential here: `TestWidgetsFlutterBinding` installs a global fake
// `HttpOverrides` that makes any REAL `dart:io` HttpClient's `Timer`-based
// features (the SSE stall-timeout transform in `streamChatCompletion`)
// interact pathologically with the fake test clock (reproduced as a spurious
// `StackOverflowError` while building this test, and separately as a hung
// real connect() that never returned even inside `runAsync`). MockClient
// sidesteps the whole class of problem: no sockets, no OS timers tied to
// wall-clock networking — just an in-memory `Future`/`Stream` your handler
// controls directly, which composes cleanly with `tester.pump()`.
//
// Four scenarios:
//   1. Fit path — byte-neutral. A normal SSE reply on the very first attempt
//      never enters the recovery branch; `recordContextLimit` is never
//      called; the request carries the full history.
//   2. Overflow -> trim -> retry. First attempt 4xx overflow (with a real
//      "maximum context length is N" number), second attempt succeeds with
//      an SSE stream. Asserts the learned limit was recorded with the parsed
//      number, the second request has FEWER history turns than the first,
//      and the leading system/card turn is byte-identical between attempts.
//   3. Bound/floor — an always-overflowing mock never hangs: it stops at
//      kMaxContextTrims or the floor and reaches the existing failure path
//      (a SnackBar), never looping forever.
//   4. Builder window unit test — buildChatPrompt with maxHistoryMessages:N
//      drops exactly the oldest history turns and leaves every non-history
//      segment byte-identical to the full (untrimmed) build.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/chat_screen.dart';
import 'package:pyre/services/chat_api.dart'
    show ChatTurn, debugHttpClientFactory;
import 'package:pyre/services/chat_prompt_builder.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _MemoryBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> blob) async {}

  @override
  Future<void> clear() async {}
}

Widget _host(AppStore store, Widget screen) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: screen),
    );

/// MockClient's handler resolves synchronously-ish (in-memory, no real I/O),
/// so a plain bounded `pump` loop is all that's needed to let the whole
/// send -> stream -> (maybe retry) -> settle chain play out.
Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  int maxIterations = 200,
  String reason = 'condition was not met',
}) async {
  for (var i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail(reason);
}

/// One captured request: the decoded JSON body's `messages` array (role +
/// content only — enough to assert on turn counts / leading-turn identity
/// without depending on unrelated body fields like sampling params).
class _CapturedRequest {
  final List<Map<String, String>> messages;
  _CapturedRequest(this.messages);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiProvider provider;
  late List<_CapturedRequest> captured;

  /// Arms `debugHttpClientFactory` with a `MockClient` whose responses come
  /// from [handler]. [handler] receives the 0-based request index and the
  /// decoded body, and returns (statusCode, responseBody, contentType).
  /// Every request is recorded into [captured] regardless of outcome.
  void startMock(
    (int, String, String) Function(int index, Map<String, dynamic> body)
        handler,
  ) {
    captured = [];
    var index = 0;
    debugHttpClientFactory = () => MockClient((http.Request req) async {
          final decoded =
              jsonDecode(req.body) as Map<String, dynamic>;
          final msgs = (decoded['messages'] as List)
              .map<Map<String, String>>((m) => {
                    'role': (m as Map)['role'] as String,
                    'content': m['content'] as String,
                  })
              .toList();
          captured.add(_CapturedRequest(msgs));
          final (status, body, contentType) = handler(index++, decoded);
          return http.Response(
            body,
            status,
            headers: {'content-type': contentType},
          );
        });
    provider = ApiProvider(
      id: 'p1',
      name: 'Test Provider',
      baseUrl: 'http://fake-provider.test/v1',
      apiKey: 'sk-test',
      model: 'test-model',
    );
  }

  String sseChunk(String content) =>
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': content},
          }
        ]
      })}\n\n';

  String sseDone() => 'data: [DONE]\n\n';

  const overflowBody = '{"error":{"message":'
      '"This model\'s maximum context length is 8000 tokens. '
      'However you requested 12000 tokens. Please reduce the length of '
      'the messages."}}';

  tearDown(() {
    debugHttpClientFactory = null;
  });

  /// Builds a store + chat with [historyCount] prior user/char message
  /// pairs (so the total history is `historyCount * 2` messages) plus a
  /// character/persona/provider all wired up, and pumps `ChatScreen` for it.
  /// Returns the store and chat id.
  Future<(AppStore, String)> pumpChat(
    WidgetTester tester, {
    int historyPairs = 40,
  }) async {
    final backend = _MemoryBackend();
    final store = AppStore(storage: backend);

    final character = Character(
      id: 'char-1',
      name: 'Sera',
      description: 'A quiet blacksmith with soot-stained hands. ' * 20,
      personality: 'Reserved, dry humor, fiercely loyal.',
      scenario: 'A small forge at the edge of town.',
      createdAt: 0,
      updatedAt: 0,
    );
    final persona = Persona(
      id: 'persona-1',
      name: 'Alex',
      description: 'A traveling merchant, curious and talkative.',
      createdAt: 0,
      updatedAt: 0,
    );
    store.characters.add(character);
    store.personas.add(persona);
    store.providers.add(provider);
    store.activeProviderId = provider.id;

    final messages = <Message>[];
    for (var i = 0; i < historyPairs; i++) {
      messages.add(Message(
        id: 'u$i',
        kind: MessageKind.user,
        variants: ['User turn number $i, filling out some history text.'],
        createdAt: 0,
        mtime: 0,
      ));
      messages.add(Message(
        id: 'c$i',
        kind: MessageKind.char,
        characterId: character.id,
        variants: ['*Sera nods.* "Turn $i, understood."'],
        createdAt: 0,
        mtime: 0,
      ));
    }

    final chat = Chat(
      id: 'chat-1',
      characterIds: [character.id],
      characterSnapshots: {character.id: character},
      personaId: persona.id,
      messages: messages,
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

    await tester.pumpWidget(_host(store, ChatScreen(chatId: chat.id)));
    await tester.pump();

    return (store, chat.id);
  }

  Future<void> sendMessage(WidgetTester tester, String text) async {
    final fields = find.byType(TextField);
    expect(fields, findsWidgets, reason: 'no TextField found at all');
    await tester.enterText(fields.first, text);
    await tester.pump();
    final sendIcon = find.byIcon(Icons.arrow_upward);
    expect(sendIcon, findsOneWidget,
        reason: 'the send button (arrow_upward icon) was not found');
    await tester.tap(sendIcon);
    await tester.pump();
  }

  group('Slice D-3 — reactive context recovery', () {
    testWidgets('fit path is byte-neutral: no recovery branch, one request',
        (tester) async {
      startMock((index, body) {
        return (200, '${sseChunk('Hello there.')}${sseDone()}',
            'text/event-stream');
      });

      final (store, _) = await pumpChat(tester, historyPairs: 40);
      await sendMessage(tester, 'Hi Sera.');

      await _pumpUntilCondition(tester, () => captured.isNotEmpty,
          reason: 'the request never reached the fake provider');
      // Let the stream fully settle (onDone / persistence / auto-memory /
      // AppStore's internal debounce timers) so no Timer is left pending
      // when the test tears down the widget tree.
      await tester.pump(const Duration(milliseconds: 700));

      expect(captured.length, 1,
          reason: 'a fitting request must never trigger a retry');
      expect(store.learnedContextLimits, isEmpty,
          reason: 'recordContextLimit must never fire on the fit path');
    });

    testWidgets('overflow then trim then retry succeeds', (tester) async {
      startMock((index, body) {
        if (index == 0) {
          return (400, overflowBody, 'application/json');
        }
        return (200, '${sseChunk('Recovered reply.')}${sseDone()}',
            'text/event-stream');
      });

      final (store, chatId) = await pumpChat(tester, historyPairs: 40);
      await sendMessage(tester, 'Tell me a long story.');

      await _pumpUntilCondition(tester, () => captured.length >= 2,
          reason: 'the retry never reached the fake provider');
      // Let the stream fully settle (onDone / persistence / debounce timers).
      await tester.pump(const Duration(milliseconds: 700));

      expect(captured.length, 2,
          reason: 'exactly one retry: overflow then a fitting request');

      // (ii) recordContextLimit called with the parsed number (8000).
      final key = '${provider.id}|${provider.model}';
      expect(store.learnedContextLimits[key], 8000);

      // (iii) the 2nd request carries FEWER history turns than the 1st.
      // History turns are the user/assistant turns EXCLUDING the leading
      // system/card turn(s) — count user-role + assistant-role turns.
      int historyTurnCount(_CapturedRequest r) => r.messages
          .where((m) => m['role'] == 'user' || m['role'] == 'assistant')
          .length;
      final firstHistoryCount = historyTurnCount(captured[0]);
      final secondHistoryCount = historyTurnCount(captured[1]);
      expect(secondHistoryCount, lessThan(firstHistoryCount));

      // (iv) the leading system/card turn is byte-identical between
      // attempts (the card must never be touched by the trim).
      final firstSystem =
          captured[0].messages.firstWhere((m) => m['role'] == 'system');
      final secondSystem =
          captured[1].messages.firstWhere((m) => m['role'] == 'system');
      expect(secondSystem['content'], firstSystem['content']);

      // (v) the stream ultimately succeeds: the recovered reply landed in
      // the chat's message store (checked at the data layer — reading it
      // back via the widget tree is subject to unrelated scroll/layout
      // flakiness that isn't this slice's concern).
      final chat = store.chats.firstWhere((c) => c.id == chatId);
      expect(chat.messages.last.text, contains('Recovered reply.'));
    });

    testWidgets('always-overflow stops at the bound, no infinite loop',
        (tester) async {
      startMock((index, body) {
        return (400, overflowBody, 'application/json');
      });

      // A short history so the window floor is reached quickly regardless
      // of kMaxContextTrims — proves BOTH stops are safe independently.
      await pumpChat(tester, historyPairs: 2);
      await sendMessage(tester, 'Hi.');

      // Bounded wait: if this were an infinite loop the request count would
      // keep climbing forever and `_pumpUntilCondition`'s own iteration cap
      // would eventually `fail()` this test — instead we wait for the UI to
      // settle into the failure state (a SnackBar showing).
      await _pumpUntilCondition(
        tester,
        () => find.byType(SnackBar).evaluate().isNotEmpty,
        reason: 'never reached the failure snackbar — possible infinite loop',
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Must have stopped: no more than kMaxContextTrims+1 total attempts
      // (initial + up to kMaxContextTrims retries).
      expect(captured.length, lessThanOrEqualTo(5));
      expect(captured.length, greaterThanOrEqualTo(1));
      // The existing failure path fired (a SnackBar is showing).
      expect(find.byType(SnackBar), findsWidgets);
    });
  });

  group('Slice D-3 — builder window cut (unit)', () {
    Character? Function(String) charLookup(List<Character> chars) {
      final byId = {for (final c in chars) c.id: c};
      return (id) => byId[id];
    }

    test('maxHistoryMessages drops exactly the oldest N-excess turns; '
        'every non-history segment is byte-identical', () {
      final character = Character(
        id: 'w-char-1',
        name: 'Sera',
        description: 'A quiet blacksmith.',
        personality: 'Reserved.',
        scenario: 'A forge.',
        createdAt: 0,
        updatedAt: 0,
      );
      final persona = Persona(
        id: 'w-persona-1',
        name: 'Alex',
        description: 'A merchant.',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        for (var i = 0; i < 10; i++)
          Message(
            id: 'w-m$i',
            kind: i.isEven ? MessageKind.user : MessageKind.char,
            characterId: i.isEven ? null : character.id,
            variants: ['Message number $i'],
            createdAt: 0,
            mtime: 0,
          ),
      ];
      final chat = Chat(
        id: 'w-chat-1',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        personaId: persona.id,
        messages: messages,
        memoryEnabled: false,
        liveSheetEnabled: false,
        createdAt: 0,
        updatedAt: 0,
      );

      ChatPromptInputs baseInputs({int? maxHistoryMessages}) => ChatPromptInputs(
            chat: chat,
            character: character,
            persona: persona,
            preset: null,
            responderId: character.id,
            beatsCap: 3,
            lookupCharacter: charLookup([character]),
            lookupBook: (_) => null,
            inFlightMessageId: null,
            maxHistoryMessages: maxHistoryMessages,
          );

      final full = buildChatPrompt(baseInputs());
      final trimmed = buildChatPrompt(baseInputs(maxHistoryMessages: 4));

      List<ChatTurn> historyOnly(List<ChatTurn> turns) => turns
          .where((t) =>
              t.content.startsWith('Message number') ||
              t.content.contains('*Message number'))
          .toList();

      // The trimmed build keeps exactly the last 4 of the 10 messages
      // (oldest 6 dropped).
      final fullHistory = full.turns
          .where((t) => RegExp(r'Message number \d').hasMatch(t.content))
          .toList();
      final trimmedHistory = trimmed.turns
          .where((t) => RegExp(r'Message number \d').hasMatch(t.content))
          .toList();
      expect(fullHistory, hasLength(10));
      expect(trimmedHistory, hasLength(4));
      expect(
        trimmedHistory.map((t) => t.content).toList(),
        fullHistory.skip(6).map((t) => t.content).toList(),
      );

      // Every non-history turn (leading system/card block, persona, etc.)
      // is byte-identical between the full and trimmed build. Approximate
      // "non-history" as any turn whose content does NOT mention "Message
      // number" — since only history turns ever do.
      List<ChatTurn> nonHistory(List<ChatTurn> turns) => turns
          .where((t) => !RegExp(r'Message number \d').hasMatch(t.content))
          .toList();
      final fullNonHistory = nonHistory(full.turns);
      final trimmedNonHistory = nonHistory(trimmed.turns);
      expect(trimmedNonHistory.length, fullNonHistory.length);
      for (var i = 0; i < fullNonHistory.length; i++) {
        expect(trimmedNonHistory[i].role, fullNonHistory[i].role);
        expect(trimmedNonHistory[i].content, fullNonHistory[i].content);
      }

      // Sanity: unused helper kept for readability of the intent above.
      expect(historyOnly(full.turns).length, greaterThanOrEqualTo(0));
    });

    test('floor: never drops below the last message of the window', () {
      final character = Character(
        id: 'f-char-1',
        name: 'Sera',
        createdAt: 0,
        updatedAt: 0,
      );
      final messages = <Message>[
        Message(
            id: 'f-m0',
            kind: MessageKind.user,
            variants: ['Only message'],
            createdAt: 0,
            mtime: 0),
      ];
      final chat = Chat(
        id: 'f-chat-1',
        characterIds: [character.id],
        characterSnapshots: {character.id: character},
        messages: messages,
        memoryEnabled: false,
        liveSheetEnabled: false,
        createdAt: 0,
        updatedAt: 0,
      );
      final inputs = ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: null,
        responderId: character.id,
        beatsCap: 3,
        lookupCharacter: charLookup([character]),
        lookupBook: (_) => null,
        inFlightMessageId: null,
        maxHistoryMessages: 0, // request below the floor
      );
      final result = buildChatPrompt(inputs);
      final historyTurns = result.turns
          .where((t) => t.content.contains('Only message'))
          .toList();
      expect(historyTurns, hasLength(1),
          reason: 'the floor must keep at least the last message');
    });
  });
}
