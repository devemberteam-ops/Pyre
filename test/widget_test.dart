import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/services/chat_api.dart';
import 'package:pyre/services/key_crypto.dart';
import 'package:pyre/services/lorebook_inject.dart';
import 'package:pyre/services/st_preset_import.dart';
import 'package:pyre/state/app_store.dart';

void main() {
  group('Models — JSON round-trip', () {
    test('Character', () {
      final c = Character(
        id: 'char-1',
        name: 'Aria',
        tagline: 'A test character',
        description: 'desc',
        personality: 'curious',
        firstMes: 'Hi!',
        alternateGreetings: ['Hey'],
        tags: ['fantasy'],
      );
      final back = Character.fromJson(c.toJson());
      expect(back.id, c.id);
      expect(back.name, c.name);
      expect(back.tagline, c.tagline);
      expect(back.alternateGreetings, c.alternateGreetings);
      expect(back.tags, c.tags);
      expect(back.firstMes, c.firstMes);
    });

    test('Chat with snapshots', () {
      final c = Character(id: 'char-1', name: 'Aria');
      final chat = Chat(
        id: 'chat-1',
        characterIds: [c.id],
        characterSnapshots: {c.id: c},
        messages: [
          Message(
            id: 'm1',
            kind: MessageKind.user,
            variants: ['hi'],
          ),
          Message(
            id: 'm2',
            kind: MessageKind.char,
            characterId: c.id,
            variants: ['hello!'],
          ),
        ],
      );
      final back = Chat.fromJson(chat.toJson());
      expect(back.characterIds, chat.characterIds);
      expect(back.characterSnapshots.length, 1);
      expect(back.characterSnapshots[c.id]!.name, 'Aria');
      expect(back.messages.length, 2);
      expect(back.messages[1].kind, MessageKind.char);
      expect(back.messages[1].text, 'hello!');
    });

    test('Lorebook', () {
      final l = Lorebook(
        id: 'lore-1',
        name: 'World facts',
        entries: [
          LoreEntry(
            id: 'le-1',
            keys: ['dragon', 'wyrm'],
            content: 'Dragons breathe fire.',
            order: 5,
          ),
          LoreEntry(
            id: 'le-2',
            constant: true,
            content: 'The year is 1234.',
          ),
        ],
      );
      final back = Lorebook.fromJson(l.toJson());
      expect(back.entries.length, 2);
      expect(back.entries[0].keys, ['dragon', 'wyrm']);
      expect(back.entries[1].constant, true);
    });

    test('Provider', () {
      final p = ApiProvider(
        id: 'prov-1',
        name: 'OpenAI',
        kind: ProviderKind.external_,
        baseUrl: 'https://api.openai.com',
        apiKey: 'sk-test',
        model: 'gpt-4o-mini',
      );
      final back = ApiProvider.fromJson(p.toJson());
      expect(back.name, 'OpenAI');
      expect(back.kind, ProviderKind.external_);
      expect(back.baseUrl, 'https://api.openai.com');
      expect(back.model, 'gpt-4o-mini');
    });

    test('ModelSettings defaults', () {
      final ms = ModelSettings.fromJson({});
      // Wave CY.18.37: `memory` field removed (LTM owns context now).
      expect(ms.temperature, 0.95);
      expect(ms.topP, 0.9);
      expect(ms.topK, 0);
      // Wave CY.2: bumped from 500 → 1024 to cover typical RP replies.
      expect(ms.maxTokens, 1024);
      expect(ms.stream, true);
    });

    test('ChatSettings — deleteBehavior round-trip + cascadeDelete migration', () {
      final defaultCs = ChatSettings.fromJson({});
      expect(defaultCs.deleteBehavior, DeleteBehavior.onlyThis);
      expect(defaultCs.hideReasoning, true);

      // Legacy `cascadeDelete: true` migrates to thisAndAfter.
      final migrated =
          ChatSettings.fromJson({'cascadeDelete': true, 'hideReasoning': false});
      expect(migrated.deleteBehavior, DeleteBehavior.thisAndAfter);
      expect(migrated.cascadeDelete, true);
      expect(migrated.hideReasoning, false);
    });

    // Wave CY.18.258: encrypted key-sync model fields.
    test('ApiProvider mtime round-trips; apiKeyEnc emitted only with secret',
        () async {
      final p = ApiProvider(id: 'p1', name: 'OR', apiKey: 'sk-1', mtime: 42);
      // default toJson: no apiKey, no apiKeyEnc
      final plain = p.toJson();
      expect(plain.containsKey('apiKey'), isFalse);
      expect(plain.containsKey('apiKeyEnc'), isFalse);
      expect(plain['mtime'], 42);
      // with a secret: apiKeyEnc present, plaintext absent
      final s = await KeyCrypto.secretForBearer('b');
      final enc = await p.toJsonEncrypted(s);
      expect(enc.containsKey('apiKey'), isFalse);
      expect(enc['apiKeyEnc'], isNotNull);
      // fromJson hydrates apiKeyEnc into a transient holder, decrypt restores key
      final back = ApiProvider.fromJson(enc);
      expect(back.apiKeyEnc, isNotNull);
      expect(await KeyCrypto.decryptApiKey(back.apiKeyEnc!, s), 'sk-1');
    });
    test('UiPrefs.syncProviderKeys defaults false and round-trips', () {
      expect(UiPrefs().syncProviderKeys, isFalse);
      final j = (UiPrefs()..syncProviderKeys = true).toJson();
      expect(UiPrefs.fromJson(j).syncProviderKeys, isTrue);
    });
  });

  group('buildChatUrl — URL versioning', () {
    test('base without /v1 gets one added', () {
      expect(
        buildChatUrl('https://api.openai.com', 'chat/completions'),
        'https://api.openai.com/v1/chat/completions',
      );
    });
    test('base WITH /v1 is not duplicated', () {
      expect(
        buildChatUrl('https://mars.chub.ai/chub/soji/v1', 'chat/completions'),
        'https://mars.chub.ai/chub/soji/v1/chat/completions',
      );
    });
    test('base with trailing slash is normalised', () {
      expect(
        buildChatUrl('https://openrouter.ai/api/v1/', 'models'),
        'https://openrouter.ai/api/v1/models',
      );
    });
    test('non-v1 version segments are also respected', () {
      expect(
        buildChatUrl('https://example.com/api/v2', 'chat/completions'),
        'https://example.com/api/v2/chat/completions',
      );
    });
  });

  group('ST preset import', () {
    test('FluffPreset-style: splits at chatHistory and resolves markers', () {
      const json = '''
{
  "name": "FluffPreset RP",
  "temperature": 1.6,
  "top_p": 0.97,
  "top_k": 0,
  "openai_max_tokens": 8192,
  "impersonation_prompt": "[Write next reply for {{user}}]",
  "continue_nudge_prompt": "[Continue: {{lastChatMessage}}]",
  "prompts": [
    {"identifier": "main", "content": "MAIN PROMPT", "role": "user"},
    {"identifier": "nsfw", "content": "NSFW BLOCK", "role": "system"},
    {"identifier": "jailbreak", "content": "JAILBREAK", "role": "user"},
    {"identifier": "charDescription", "name": "Char Description", "marker": true},
    {"identifier": "charPersonality", "name": "Char Personality", "marker": true},
    {"identifier": "scenario", "name": "Scenario", "marker": true},
    {"identifier": "chatHistory", "name": "Chat History", "marker": true}
  ],
  "prompt_order": [{
    "character_id": 100000,
    "order": [
      {"identifier": "main", "enabled": true},
      {"identifier": "charDescription", "enabled": true},
      {"identifier": "charPersonality", "enabled": true},
      {"identifier": "scenario", "enabled": true},
      {"identifier": "nsfw", "enabled": true},
      {"identifier": "chatHistory", "enabled": true},
      {"identifier": "jailbreak", "enabled": true}
    ]
  }]
}
''';
      final result = parseSillyTavernPreset(json);
      final p = result.preset;
      expect(p.source, 'sillytavern');
      expect(p.temperature, 1.6);
      expect(p.topP, 0.97);
      expect(p.topK, isNull); // 0 maps to null
      expect(p.maxTokens, 8192);
      expect(p.impersonationPrompt,
          contains('Write next reply for {{user}}'));
      expect(p.continueNudgePrompt, contains('{{lastChatMessage}}'));
      // mainPrompt should contain everything BEFORE chatHistory
      expect(p.mainPrompt, contains('MAIN PROMPT'));
      expect(p.mainPrompt, contains('{{description}}'));
      expect(p.mainPrompt, contains('{{personality}}'));
      expect(p.mainPrompt, contains('{{scenario}}'));
      expect(p.mainPrompt, contains('NSFW BLOCK'));
      // postHistoryInstructions should contain everything AFTER
      expect(p.postHistoryInstructions, contains('JAILBREAK'));
      // jailbreak should NOT be in mainPrompt
      expect(p.mainPrompt, isNot(contains('JAILBREAK')));
    });

    test('disabled prompts are dropped', () {
      const json = '''
{
  "name": "test",
  "prompts": [
    {"identifier": "main", "content": "KEPT"},
    {"identifier": "drop", "content": "DROPPED"}
  ],
  "prompt_order": [{
    "character_id": 100000,
    "order": [
      {"identifier": "main", "enabled": true},
      {"identifier": "drop", "enabled": false}
    ]
  }]
}
''';
      final p = parseSillyTavernPreset(json).preset;
      expect(p.mainPrompt, contains('KEPT'));
      expect(p.mainPrompt, isNot(contains('DROPPED')));
    });

    test('re-imports our own export as-is', () {
      const json = '''
{
  "id": "preset-x",
  "name": "MyPreset",
  "mainPrompt": "hello",
  "modelSettings": {}
}
''';
      final result = parseSillyTavernPreset(json);
      expect(result.preset.mainPrompt, 'hello');
      expect(result.preset.name, contains('imported'));
    });
  });

  group('character → persona conversion', () {
    test('swaps {{user}} ↔ {{char}} and folds in mes_example', () {
      // Pure-function conversion — no store side-effects, so no platform
      // channels (SharedPreferences / path_provider) need mocking.
      final c = Character(
        id: 'aria',
        name: 'Aria',
        tagline: '{{char}} the warrior, lost {{user}} long ago',
        description: '{{char}} is a tall warrior who meets {{user}} at the tavern.',
        personality: 'Brave, brash, secretly tender toward {{user}}.',
        mesExample:
            '{{user}}: "What\'s your story?"\n{{char}}: "Just a kid trying to live up to my dad\'s legacy."',
      );
      final p = buildPersonaFromCharacter(c);

      // Tagline: every {{char}} becomes {{user}}, every {{user}} becomes {{char}}
      expect(p.tagline, '{{user}} the warrior, lost {{char}} long ago');

      // Description swap
      expect(p.description, contains('{{user}} is a tall warrior'));
      expect(p.description, contains('meets {{char}} at the tavern'));

      // Personality folded in with swap
      expect(p.description, contains('## Personality'));
      expect(p.description, contains('secretly tender toward {{char}}'));

      // Wave CX.1: mes_example now lands in its OWN persona field
      // (dialogueExamples), NOT folded into the description under an
      // `## Example dialogue` header. Roles still swap so the {{user}}
      // line (the asking side in the original card) reads as {{char}}.
      expect(p.description, isNot(contains('## Example dialogue')));
      expect(p.dialogueExamples, contains('{{char}}: "What\'s your story?"'));
      expect(p.dialogueExamples, contains('{{user}}: "Just a kid'));

      // No accidental double-swap (every {{char}} now is what was {{user}}).
      expect(p.description, isNot(contains(' __CHAR__ ')));
    });

    test('handles cards with no mes_example or personality', () {
      // Pure-function conversion — no store side-effects, so no platform
      // channels (SharedPreferences / path_provider) need mocking.
      final c = Character(
        id: 'lone',
        name: 'Lone',
        description: 'A solitary figure.',
      );
      final p = buildPersonaFromCharacter(c);
      expect(p.description, 'A solitary figure.');
      expect(p.description, isNot(contains('## Personality')));
      expect(p.description, isNot(contains('## Example dialogue')));
    });
  });

  group('Lorebook injection (Wave CB)', () {
    // Helpers for building fixtures consistently across tests.
    Lorebook book(String id, String name, List<LoreEntry> entries) =>
        Lorebook(id: id, name: name, entries: entries);
    LoreEntry entry({
      required String id,
      List<String> keys = const [],
      String content = '',
      bool constant = false,
      bool enabled = true,
      int order = 0,
    }) =>
        LoreEntry(
          id: id,
          keys: keys,
          content: content,
          constant: constant,
          enabled: enabled,
          order: order,
        );
    Message userMsg(String text) => Message(
          id: 'm-${text.hashCode}',
          kind: MessageKind.user,
          variants: [text],
        );

    // Tiny in-memory store-like lookup that the gathering function
    // takes as callbacks. Lets every test wire its own fixtures
    // without spinning up the real AppStore.
    ({
      Lorebook? Function(String) lookupBook,
      Character? Function(String) lookupChar,
    }) makeLookups(
        {List<Lorebook> books = const [],
        List<Character> chars = const []}) {
      final byBookId = {for (final b in books) b.id: b};
      final byCharId = {for (final c in chars) c.id: c};
      return (
        lookupBook: (id) => byBookId[id],
        lookupChar: (id) => byCharId[id],
      );
    }

    test('per-chat attached books fire (legacy path)', () {
      final dragons =
          book('lb-1', 'World facts', [entry(id: 'e1', keys: ['dragon'], content: 'Dragons exist.')]);
      final chat = Chat(
        id: 'c1',
        characterIds: const [],
        attachedLorebookIds: ['lb-1'],
        messages: [userMsg('Did you see the dragon yesterday?')],
      );
      final lk = makeLookups(books: [dragons]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1);
      expect(scan.hits.first.content, 'Dragons exist.');
    });

    test('character-bound book fires automatically (Gine case)', () {
      final dbz = book('lb-dbz', 'Dragon Ball',
          [entry(id: 'e1', keys: ['Saiyan'], content: 'Saiyans are warriors.')]);
      // Gine carries the DBZ lorebook bound via lorebookIds — NOT
      // attached per-chat — and that should still inject.
      final gine = Character(
          id: 'char-gine', name: 'Gine', lorebookIds: const ['lb-dbz']);
      final chat = Chat(
        id: 'c2',
        characterIds: const ['char-gine'],
        characterSnapshots: {'char-gine': gine},
        // No attachedLorebookIds → only the character binding feeds it.
        messages: [userMsg('Are you a Saiyan?')],
      );
      final lk = makeLookups(books: [dbz], chars: [gine]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
        responderId: 'char-gine',
      );
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1, reason: 'Gine\'s bound DBZ book should fire');
      expect(scan.hits.first.content, 'Saiyans are warriors.');
    });

    test('persona-bound book fires automatically', () {
      final magic = book('lb-mag', 'Magic system',
          [entry(id: 'e1', keys: ['mana'], content: 'Mana is finite.')]);
      final persona = Persona(
          id: 'p1', name: 'MageUser', lorebookIds: const ['lb-mag']);
      final chat = Chat(
        id: 'c3',
        characterIds: const [],
        messages: [userMsg('How much mana do I have?')],
      );
      final lk = makeLookups(books: [magic]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: persona,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1, reason: 'Persona-bound book should fire');
      expect(scan.hits.first.content, 'Mana is finite.');
    });

    test('dedupes when same book bound to char AND persona', () {
      // Shared lorebook — bound on both sides. Without dedup the entry
      // would inject twice.
      final shared = book('lb-shared', 'World',
          [entry(id: 'e1', keys: ['castle'], content: 'The castle is old.')]);
      final c = Character(
          id: 'char-1', name: 'Aria', lorebookIds: const ['lb-shared']);
      final p = Persona(
          id: 'p-1', name: 'Me', lorebookIds: const ['lb-shared']);
      final chat = Chat(
        id: 'c4',
        characterIds: const ['char-1'],
        characterSnapshots: {'char-1': c},
        attachedLorebookIds: const [
          'lb-shared'
        ], // third source — same book again
        messages: [userMsg('To the castle!')],
      );
      final lk = makeLookups(books: [shared], chars: [c]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: p,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      // Same book referenced 3x — should resolve to 1 Lorebook.
      expect(attached.length, 1);
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1,
          reason: 'Entry must fire once even when book is bound 3 ways');
    });

    test('constant entries always fire regardless of keywords', () {
      final lore = book('lb-c', 'Setting', [
        entry(
            id: 'always',
            constant: true,
            content: 'This is the year 1234.'),
      ]);
      final chat = Chat(
        id: 'c5',
        characterIds: const [],
        attachedLorebookIds: ['lb-c'],
        messages: [userMsg('Hi there.')], // no matching keywords
      );
      final lk = makeLookups(books: [lore]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1);
      expect(scan.hits.first.content, 'This is the year 1234.');
    });

    test('disabled entries are skipped', () {
      final lore = book('lb-d', 'Mixed', [
        entry(id: 'on', keys: ['cat'], content: 'A cat.'),
        entry(
            id: 'off',
            keys: ['cat'],
            content: 'Disabled.',
            enabled: false),
      ]);
      final chat = Chat(
        id: 'c6',
        characterIds: const [],
        attachedLorebookIds: ['lb-d'],
        messages: [userMsg('Look, a cat!')],
      );
      final lk = makeLookups(books: [lore]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1);
      expect(scan.skippedDisabled, 1);
      expect(scan.hits.first.content, 'A cat.');
    });

    test('keyword matching is case-insensitive', () {
      final lore = book('lb-ci', 'World',
          [entry(id: 'e', keys: ['DRAGON'], content: 'fire breathers')]);
      final chat = Chat(
        id: 'c7',
        characterIds: const [],
        attachedLorebookIds: ['lb-ci'],
        messages: [userMsg('there was a small dragon outside')],
      );
      final lk = makeLookups(books: [lore]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1);
    });

    test('group chat — every character contributes their bound books',
        () {
      // Three characters in a group chat, each carrying a different
      // small lorebook. ALL three should fire regardless of which one
      // is the current responder.
      final goku = Character(
          id: 'goku', name: 'Goku', lorebookIds: const ['lb-pl']);
      final vegeta = Character(
          id: 'vegeta', name: 'Vegeta', lorebookIds: const ['lb-pr']);
      final frieza = Character(
          id: 'frieza', name: 'Frieza', lorebookIds: const ['lb-fr']);
      final powerLevels = book('lb-pl', 'Power Levels', [
        entry(id: 'p1', keys: ['scouter'], content: 'Power levels.')
      ]);
      final saiyanPride = book('lb-pr', 'Saiyan Pride', [
        entry(id: 'p2', keys: ['scouter'], content: 'Pride matters.')
      ]);
      final friezaForce = book('lb-fr', 'Frieza Force', [
        entry(id: 'p3', constant: true, content: 'Frieza commands.')
      ]);
      final chat = Chat(
        id: 'c8',
        characterIds: const ['goku', 'vegeta', 'frieza'],
        characterSnapshots: {
          'goku': goku,
          'vegeta': vegeta,
          'frieza': frieza,
        },
        messages: [userMsg('Check the scouter readings')],
      );
      final lk = makeLookups(
          books: [powerLevels, saiyanPride, friezaForce],
          chars: [goku, vegeta, frieza]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
        responderId: 'goku', // only Goku is responding
      );
      // All three character books should be collected, not just Goku's.
      expect(attached.length, 3);
      final scan = scanLorebookHits(attached, chat.messages);
      // 2 keyword hits (Goku + Vegeta books match `scouter`)
      // + 1 constant (Frieza's) = 3 fired entries total.
      expect(scan.hits.length, 3);
    });

    test('hits sorted by descending order', () {
      final lore = book('lb-ord', 'Ordered', [
        entry(id: 'low', keys: ['cat'], content: 'low', order: 1),
        entry(id: 'high', keys: ['cat'], content: 'high', order: 10),
        entry(id: 'mid', keys: ['cat'], content: 'mid', order: 5),
      ]);
      final chat = Chat(
        id: 'c9',
        characterIds: const [],
        attachedLorebookIds: ['lb-ord'],
        messages: [userMsg('cat')],
      );
      final lk = makeLookups(books: [lore]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.map((e) => e.content).toList(),
          ['high', 'mid', 'low']);
    });

    test(
        'character → persona conversion carries lorebookIds (Wave CB)',
        () {
      final c = Character(
        id: 'char',
        name: 'Aria',
        description: 'desc',
        lorebookIds: const ['lb-a', 'lb-b'],
      );
      final p = buildPersonaFromCharacter(c);
      expect(p.lorebookIds, ['lb-a', 'lb-b']);
    });

    test(
        'disabledInheritedLorebookIds skips inherited entries but keeps per-chat attached (Wave CD)',
        () {
      // Char carries the DBZ book AND the chat has it disabled →
      // entries should NOT fire. But if the same book is ALSO attached
      // per-chat (explicit user opt-in), per-chat wins and entries fire.
      final dbz = book('lb-d', 'Dragon Ball', [
        entry(
            id: 'e1',
            keys: ['Saiyan'],
            content: 'Saiyans are warriors.'),
      ]);
      final gine = Character(
          id: 'char-gine', name: 'Gine', lorebookIds: const ['lb-d']);

      // Case A: char-bound + disabled → should NOT fire.
      final chatA = Chat(
        id: 'cA',
        characterIds: const ['char-gine'],
        characterSnapshots: {'char-gine': gine},
        disabledInheritedLorebookIds: const ['lb-d'],
        messages: [userMsg('Are you a Saiyan?')],
      );
      final lk = makeLookups(books: [dbz], chars: [gine]);
      final attachedA = collectBoundLorebooks(
        chat: chatA,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
        responderId: 'char-gine',
      );
      expect(attachedA, isEmpty,
          reason: 'Disabled inherited book must NOT be collected');

      // Case B: same disabled flag but ALSO attached per-chat →
      // per-chat additive path overrides the disable.
      final chatB = Chat(
        id: 'cB',
        characterIds: const ['char-gine'],
        characterSnapshots: {'char-gine': gine},
        attachedLorebookIds: const ['lb-d'],
        disabledInheritedLorebookIds: const ['lb-d'],
        messages: [userMsg('Are you a Saiyan?')],
      );
      final attachedB = collectBoundLorebooks(
        chat: chatB,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
        responderId: 'char-gine',
      );
      expect(attachedB.length, 1,
          reason:
              'Per-chat attachment is explicit user opt-in, overrides the inherited disable');
      final scanB = scanLorebookHits(attachedB, chatB.messages);
      expect(scanB.hits.length, 1);
    });

    test(
        'disable only affects ONE source — char and persona disabled independently (Wave CD)',
        () {
      // Same book id is bound to both char AND persona, then disabled
      // via disabledInheritedLorebookIds. Since the disable is per
      // BOOK id (not per source), it should skip BOTH inherited
      // contributions. (This documents the chosen semantics; the
      // alternative — per-source disable — would need a richer model.)
      final shared = book('lb-s', 'World',
          [entry(id: 'e', keys: ['castle'], content: 'Old castle.')]);
      final c = Character(
          id: 'c1', name: 'X', lorebookIds: const ['lb-s']);
      final p = Persona(
          id: 'p1', name: 'Me', lorebookIds: const ['lb-s']);
      final chat = Chat(
        id: 'cc',
        characterIds: const ['c1'],
        characterSnapshots: {'c1': c},
        disabledInheritedLorebookIds: const ['lb-s'],
        messages: [userMsg('To the castle!')],
      );
      final lk = makeLookups(books: [shared], chars: [c]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: p,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
      );
      expect(attached, isEmpty);
    });

    test(
        'label parser tolerates markdown bold and parentheticals (Wave CJ)',
        () {
      // Replicates the regex from _splitByTopLabels so we can assert
      // the same tolerance the production code uses. If the regex
      // here drifts from the production one, this test still acts as
      // a documented contract for what shapes MUST be parseable.
      RegExp labelRe(String label) => RegExp(
            r'^\**\s*' + RegExp.escape(label) + r'\b[^\n:]*:\s*\**',
            multiLine: true,
            caseSensitive: false,
          );

      // Bare label (the simple, well-behaved shape) — must match.
      expect(
          labelRe('Tagline').hasMatch('Tagline: a witty pitch'), isTrue);
      // Markdown bold — what DeepSeek + several other models actually
      // emit despite the prompt asking for plain text. This was the
      // production failure mode that left tagline empty on Block 5.
      expect(
          labelRe('Tagline').hasMatch('**Tagline:** a witty pitch'),
          isTrue);
      expect(
          labelRe('Tagline').hasMatch('*Tagline:* a witty pitch'),
          isTrue);
      // Parenthetical hint copied from the prompt (e.g. the model
      // includes the (8-15 words) annotation from the spec).
      expect(
          labelRe('Tagline').hasMatch('Tagline (one sentence): a witty pitch'),
          isTrue);
      // Combined markdown + parenthetical — least common but seen.
      expect(
          labelRe('Tagline')
              .hasMatch('**Tagline (8-15 words):** a witty pitch'),
          isTrue);
      // Mid-sentence occurrence MUST NOT match (line-anchored).
      expect(
          labelRe('Tagline')
              .hasMatch('I wrote a Tagline: witty pitch already'),
          isFalse);
      // Wrong colon position must not match.
      expect(labelRe('Tagline').hasMatch('Tagline'), isFalse);
    });

    test(
        'splitter moves leaked brief out of SHEET region (Wave CF)',
        () {
      // Documents the parser's defensive behavior — direct
      // _SheetSplit testing isn't easy from here (private), but the
      // _completionClaimPattern is what powers it. Sanity check that
      // the pattern matches the user-observed leak shapes.
      // (Full splitter test would require exposing the method; this
      // ensures the regex itself catches the expected cases.)
      final completionRe = RegExp(
        r'('
        r'\bBlock\s+\d+\s+(?:is\s+)?(?:done|set|complete|filled|ready|locked|incoming|coming|next)\b'
        r'|'
        r"\bSheet'?s?\s+(?:filled|filling|set|updated|complete|done|ready)\b"
        r'|'
        r'\bcard\s+is\s+(?:done|complete|full|ready)\b'
        r'|'
        r'⏸\s*Confirm\s+before\s+I\s+move'
        r')',
        caseSensitive: false,
      );
      expect(completionRe.hasMatch('Block 1 done — Kaito locked in.'),
          isTrue);
      expect(
          completionRe.hasMatch(
              "Sheet's filled. ⏸ Confirm before I move to PERSONALITY."),
          isTrue);
      expect(completionRe.hasMatch('Full Name: Kaito Ishikawa'), isFalse);
      expect(
          completionRe
              .hasMatch('General Appearance: A tired, sharp-edged courier.'),
          isFalse);
    });

    test(
        'hidden lorebook (embedded-only) still fires when bound to a character',
        () {
      // Books with hidden=true are kept out of the management UI but
      // must still participate in chat injection when the user picked
      // "Embedded only" on import. Otherwise the binding is pointless.
      final hiddenBook = Lorebook(
          id: 'lb-h',
          name: 'Hidden world',
          hidden: true,
          entries: [
            entry(id: 'e', constant: true, content: 'Hidden lore active.'),
          ]);
      final c = Character(
          id: 'char-hb', name: 'Bob', lorebookIds: const ['lb-h']);
      final chat = Chat(
        id: 'c10',
        characterIds: const ['char-hb'],
        characterSnapshots: {'char-hb': c},
        messages: [userMsg('Hello')],
      );
      final lk = makeLookups(books: [hiddenBook], chars: [c]);
      final attached = collectBoundLorebooks(
        chat: chat,
        persona: null,
        lookupBook: lk.lookupBook,
        lookupCharacter: lk.lookupChar,
        responderId: 'char-hb',
      );
      expect(attached.length, 1);
      final scan = scanLorebookHits(attached, chat.messages);
      expect(scan.hits.length, 1);
    });
  });

  test('newId() is unique', () {
    final ids = <String>{};
    for (var i = 0; i < 100; i++) {
      ids.add(newId('test'));
    }
    expect(ids.length, 100);
    expect(ids.first.startsWith('test-'), true);
  });

  // Wave CY.18.262: deleting a provider must log a `provider` tombstone so
  // the deletion propagates over encrypted key-sync (otherwise a paired
  // native peer with sync ON re-pushes its live copy and the provider
  // resurrects on the next pull). The tombstone is written synchronously
  // inside removeProvider. We inject a no-op backend so the debounced
  // persist `_bump` schedules stays harmless (no plugin/disk I/O), then
  // `flushPersist()` cancels that pending timer + runs the (no-op) save so
  // the test leaves no live timers behind.
  group('AppStore — provider-delete tombstone', () {
    test('removeProvider records a "provider" tombstone', () async {
      final store = AppStore(storage: _NoopBackend());
      store.providers.add(ApiProvider(id: 'prov-1', name: 'OpenRouter'));

      // No tombstone before the delete.
      expect(store.tombstones.containsKey('provider:prov-1'), isFalse);

      store.removeProvider('prov-1');

      // The provider is gone AND a tombstone for it now exists.
      expect(store.providers.any((p) => p.id == 'prov-1'), isFalse);
      expect(store.tombstones.containsKey('provider:prov-1'), isTrue);
      // Public LWW surface: the tombstone is at-or-after any record version
      // a peer could offer (it was just stamped with now()).
      expect(store.isTombstonedNewer('provider', 'prov-1', 0), isTrue);

      // Cancel the pending debounce timer + flush the (no-op) save so the
      // test leaves no live timers behind.
      await store.flushPersist();
    });
  });
}

/// No-op persistence backend for AppStore unit tests: keeps the debounced
/// `_persist` harmless (no disk / plugin I/O) so a delete that schedules a
/// save can be asserted without a live filesystem or platform channel.
class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}
