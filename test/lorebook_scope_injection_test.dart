// AUDIT (2026-07): "lorebook entries linked at CHARACTER, PERSONA and CHAT
// level don't seem to activate" — even always-active / constant ones.
//
// These are ACCEPTANCE tests for the canonical "secret code" scenario: a
// lorebook with ONE always-active/constant entry whose content is
// `The secret code is BLUEAPPLE.` (empty keyword list). We assert the
// ASSEMBLED `buildChatPrompt(...)` turns CONTAIN "BLUEAPPLE" — i.e. the
// entry reached the final prompt — for EACH binding scope SEPARATELY and
// all three at once. This distinguishes a real injection bug (entry NOT in
// the prompt) from a diagnostics/UX or platform-state issue.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  const secret = 'The secret code is BLUEAPPLE.';

  // A constant/always-active entry with NO keywords — the report's core case.
  LoreEntry constantSecret({String id = 'e-secret'}) => LoreEntry(
        id: id,
        keys: const [], // empty keyword list == "always" only via constant
        content: secret,
        constant: true,
      );

  Lorebook bookWith(LoreEntry e, {String id = 'lb-secret', String name = 'Secrets'}) =>
      Lorebook(id: id, name: name, entries: [e]);

  Message userMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.user, variants: [text], createdAt: 1);

  // The responder character (may or may not carry the book, per-scope).
  Character baseChar({List<String> lorebookIds = const []}) => Character(
        id: 'char-1',
        name: 'Vera',
        description: 'A quiet archivist.',
        lorebookIds: lorebookIds,
      );

  Persona basePersona({List<String> lorebookIds = const []}) => Persona(
        id: 'persona-1',
        name: 'Ash',
        description: 'A traveler.',
        lorebookIds: lorebookIds,
      );

  /// Build the prompt and return the full concatenated text of every turn
  /// (system + history + script + post-history) so a CONTAINS assertion is
  /// scope-agnostic about which turn carried the lore.
  String assembledText(ChatPromptInputs inputs) {
    final result = buildChatPrompt(inputs);
    return result.turns.map((t) => t.content).join('\n\n');
  }

  ChatPromptInputs inputsFor({
    required Chat chat,
    required Character? character,
    required Persona? persona,
    required Map<String, Lorebook> books,
    Map<String, Character> chars = const {},
  }) =>
      ChatPromptInputs(
        chat: chat,
        character: character,
        persona: persona,
        preset: null,
        responderId: character?.id,
        beatsCap: 0,
        lookupCharacter: (id) => chars[id],
        lookupBook: (id) => books[id],
      );

  group('secret-code constant entry injects — per scope', () {
    test('CHARACTER-bound only → BLUEAPPLE reaches the prompt', () {
      final book = bookWith(constantSecret());
      final char = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-char',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [userMsg('m1', 'hello there')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: null,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, contains('BLUEAPPLE'),
          reason: 'character-bound constant entry must inject');
    });

    test('PERSONA-bound only → BLUEAPPLE reaches the prompt', () {
      final book = bookWith(constantSecret());
      final persona = basePersona(lorebookIds: [book.id]);
      final char = baseChar();
      final chat = Chat(
        id: 'c-persona',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        personaId: persona.id,
        messages: [userMsg('m1', 'hello there')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: persona,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, contains('BLUEAPPLE'),
          reason: 'persona-bound constant entry must inject');
    });

    test('CHAT-bound only → BLUEAPPLE reaches the prompt', () {
      final book = bookWith(constantSecret());
      final char = baseChar();
      final chat = Chat(
        id: 'c-chat',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        attachedLorebookIds: [book.id],
        messages: [userMsg('m1', 'hello there')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: null,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, contains('BLUEAPPLE'),
          reason: 'chat-attached constant entry must inject');
    });

    test('ALL THREE scopes at once → injects, no scope suppresses another', () {
      // Three DISTINCT books (one per scope) each with its own sentinel, plus
      // one book bound to BOTH character and persona to prove dedup keeps it.
      final charBook = Lorebook(id: 'lb-char', name: 'CharBook', entries: [
        LoreEntry(id: 'e-c', content: 'CODE CHARCODE', constant: true),
      ]);
      final personaBook = Lorebook(id: 'lb-persona', name: 'PersonaBook', entries: [
        LoreEntry(id: 'e-p', content: 'CODE PERSONACODE', constant: true),
      ]);
      final chatBook = Lorebook(id: 'lb-chat', name: 'ChatBook', entries: [
        LoreEntry(id: 'e-h', content: 'CODE CHATCODE', constant: true),
      ]);
      final sharedBook = Lorebook(id: 'lb-shared', name: 'SharedBook', entries: [
        LoreEntry(id: 'e-s', content: 'CODE SHAREDCODE', constant: true),
      ]);
      final char = baseChar(lorebookIds: [charBook.id, sharedBook.id]);
      final persona = basePersona(lorebookIds: [personaBook.id, sharedBook.id]);
      final chat = Chat(
        id: 'c-all',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        personaId: persona.id,
        attachedLorebookIds: [chatBook.id],
        messages: [userMsg('m1', 'hello there')],
      );
      final result = buildChatPrompt(inputsFor(
        chat: chat,
        character: char,
        persona: persona,
        books: {
          charBook.id: charBook,
          personaBook.id: personaBook,
          chatBook.id: chatBook,
          sharedBook.id: sharedBook,
        },
        chars: {char.id: char},
      ));
      final text = result.turns.map((t) => t.content).join('\n\n');
      expect(text, contains('CHARCODE'), reason: 'character scope present');
      expect(text, contains('PERSONACODE'), reason: 'persona scope present');
      expect(text, contains('CHATCODE'), reason: 'chat scope present');
      expect(text, contains('SHAREDCODE'), reason: 'shared (char+persona) present');
      // Dedup must keep the shared book EXACTLY ONCE.
      final sharedHits =
          result.scan.hits.where((h) => h.id == 'e-s').length;
      expect(sharedHits, 1,
          reason: 'a book bound to two scopes must fire exactly once');
      // Four distinct entries fired total.
      expect(result.scan.hits.length, 4);
    });
  });

  group('trigger semantics', () {
    test('always-active entry WITH keywords still injects (keyword absent)', () {
      final book = bookWith(LoreEntry(
        id: 'e-kw',
        keys: const ['dragon'],
        content: 'CODE KEYCONST',
        constant: true, // constant beats the (absent) keyword
      ));
      final char = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-kwconst',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [userMsg('m1', 'no trigger word here')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: null,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, contains('KEYCONST'));
    });

    test('keyword entry does NOT inject when keyword absent', () {
      final book = bookWith(LoreEntry(
        id: 'e-kw2',
        keys: const ['dragon'],
        content: 'CODE DRAGONLORE',
        constant: false,
      ));
      final char = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-noword',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [userMsg('m1', 'a peaceful meadow')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: null,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, isNot(contains('DRAGONLORE')));
    });

    test('keyword entry DOES inject when keyword present', () {
      final book = bookWith(LoreEntry(
        id: 'e-kw3',
        keys: const ['dragon'],
        content: 'CODE DRAGONLORE',
        constant: false,
      ));
      final char = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-word',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [userMsg('m1', 'a dragon circles overhead')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: null,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, contains('DRAGONLORE'));
    });

    test('DISABLED entry does NOT inject', () {
      final book = bookWith(LoreEntry(
        id: 'e-off',
        content: 'CODE OFFCODE',
        constant: true,
        enabled: false,
      ));
      final char = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-off',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [userMsg('m1', 'hello')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: null,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, isNot(contains('OFFCODE')));
    });

    test('inherited book in disabledInheritedLorebookIds does NOT inject', () {
      // The closest real "disabled lorebook" concept: a character/persona
      // inherited book the user turned OFF for this chat. (Lorebook has no
      // `enabled` flag; suppression is per-chat + per-inherited-id.)
      final book = bookWith(constantSecret());
      final char = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-disabled-inherit',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        disabledInheritedLorebookIds: [book.id],
        messages: [userMsg('m1', 'hello')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: char,
        persona: null,
        books: {book.id: book},
        chars: {char.id: char},
      ));
      expect(text, isNot(contains('BLUEAPPLE')));
    });

    test('CHARACTER binding added AFTER the chat exists still injects '
        '(stale snapshot must not suppress live binding)', () {
      // Platform-state repro: the user binds a lorebook to a character AFTER a
      // chat with that character already exists. The chat froze a snapshot of
      // the character at creation time — BEFORE the binding — so the snapshot's
      // lorebookIds is EMPTY. The LIVE library character carries the binding.
      // `collectBoundLorebooks` must honour the live binding (config), not the
      // frozen snapshot, or the lore silently never activates in that chat.
      final book = bookWith(constantSecret());
      // Frozen snapshot: same character, but WITHOUT the later binding.
      final staleSnapshot = Character(
        id: 'char-1',
        name: 'Vera',
        description: 'A quiet archivist.',
        lorebookIds: const [], // predates the bind
      );
      // Live library character: NOW carries the binding.
      final liveChar = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-stale-snap',
        characterIds: [liveChar.id],
        characterSnapshots: {liveChar.id: staleSnapshot},
        messages: [userMsg('m1', 'hello there')],
      );
      final text = assembledText(inputsFor(
        chat: chat,
        character: liveChar,
        persona: null,
        books: {book.id: book},
        chars: {liveChar.id: liveChar}, // lookupCharacter → live binding
      ));
      expect(text, contains('BLUEAPPLE'),
          reason: 'a lorebook bound to the character after the chat was '
              'created must still activate (live binding beats stale snapshot)');
    });

    test('probability does NOT suppress a CONSTANT always-active entry', () {
      // A constant entry with useProbability + probability 0 must STILL fire:
      // constant short-circuits the probability gate.
      final book = bookWith(LoreEntry(
        id: 'e-prob',
        content: 'CODE PROBCONST',
        constant: true,
        useProbability: true,
        probability: 0,
      ));
      final char = baseChar(lorebookIds: [book.id]);
      final chat = Chat(
        id: 'c-prob',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        messages: [userMsg('m1', 'hello')],
      );
      // Seed the roll deterministically; it must be IGNORED for a constant.
      final result = buildChatPrompt(ChatPromptInputs(
        chat: chat,
        character: char,
        persona: null,
        preset: null,
        responderId: char.id,
        beatsCap: 0,
        lookupCharacter: (id) => id == char.id ? char : null,
        lookupBook: (id) => id == book.id ? book : null,
        loreSeed: 12345,
      ));
      final text = result.turns.map((t) => t.content).join('\n\n');
      expect(text, contains('PROBCONST'));
    });
  });
}
