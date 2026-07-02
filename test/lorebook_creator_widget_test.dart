@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/screens/lorebook_creator_screen.dart';
import 'package:pyre/services/chat_api.dart' show debugHttpClientFactory;
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _MemoryBackend implements StoreBackend {
  Map<String, dynamic>? lastSaved;
  int saveCount = 0;

  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> blob) async {
    saveCount += 1;
    lastSaved = Map<String, dynamic>.from(blob);
  }

  @override
  Future<void> clear() async {
    lastSaved = null;
  }
}

Widget _host(AppStore store, Widget screen) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(home: screen),
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition was not met',
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail(reason);
}

String _chatJson(String content) => jsonEncode({
  'choices': [
    {
      'message': {'role': 'assistant', 'content': content},
      'finish_reason': 'stop',
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemoryBackend backend;
  late AppStore store;
  var requests = 0;

  setUp(() async {
    backend = _MemoryBackend();
    store = AppStore(storage: backend);

    debugHttpClientFactory = () => MockClient((http.Request req) async {
      expect(req.url.path, '/v1/chat/completions');
      expect(jsonDecode(req.body), isA<Map<String, dynamic>>());
      final response = switch (requests++) {
        0 => _chatJson(
          'Hello! I can help build "Test Lorebook". '
          'What should the first entry cover?',
        ),
        _ => _chatJson(
          'Entry ready.\n'
          '[[BUILD_ENTRY]]\n'
          '{"keys":["Ember Gate","the gate"],'
          '"content":"The Ember Gate is a half-buried transit arch that '
          'opens only when its basalt runes are warmed by living flame.",'
          '"constant":false,'
          '"comment":"Location: Ember Gate"}',
        ),
      };
      return http.Response(
        response,
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final provider = ApiProvider(
      id: 'provider-test',
      name: 'Local fake provider',
      kind: ProviderKind.localhost,
      baseUrl: 'http://fake-provider.test/v1',
      apiKey: 'sk-test',
      model: 'fake-model',
    );
    store.providers.add(provider);
    store.activeProviderId = provider.id;
  });

  tearDown(() {
    debugHttpClientFactory = null;
  });

  testWidgets(
    'creates and persists a new lorebook after the architect returns a draft',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        _host(
          store,
          const LorebookCreatorScreen(initialBookName: 'Test Lorebook'),
        ),
      );

      await _pumpUntilCondition(
        tester,
        () => requests >= 1,
        reason: 'the greeting request did not reach the fake provider',
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).first, '/entry');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await _pumpUntil(tester, find.text('Save to new lorebook'));

      await tester.tap(find.text('Save to new lorebook'));
      await tester.pump(const Duration(milliseconds: 700));

      expect(store.lorebooks, hasLength(1));
      final book = store.lorebooks.single;
      expect(book.name, 'Test Lorebook');
      expect(book.entries, hasLength(1));
      expect(book.entries.single.keys, contains('Ember Gate'));
      expect(book.entries.single.content, contains('half-buried transit arch'));
      expect(backend.saveCount, greaterThanOrEqualTo(1));
      expect(
        backend.lastSaved?['lorebooks'],
        isA<List>().having((l) => l.length, 'length', 1),
      );
    },
  );
}
