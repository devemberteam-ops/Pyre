// Community bug (2026-07): a SillyTavern migrant bound ST-imported
// lorebooks (with always-active/constant entries) to their persona — the
// model never saw ANY of it. Root cause: fired lore text reaches the
// assembled prompt ONLY two ways — (a) `fill()` substituting a literal
// `{{wiBefore}}` marker somewhere the preset text is filled, or (b)
// `injectCardFallback()`, which is gated to run ONLY when the preset is
// null, OR when it's a MODULAR preset (`promptBlocks.isNotEmpty`) whose
// assembled system text references NO card marker at all. A preset that
// references >=1 OTHER card marker (e.g. `{{description}}`) but not
// `{{wiBefore}}` — exactly the shape ST's modular import produces when its
// `worldInfoBefore` prompt-order entry was absent/disabled — falls through
// BOTH doors and silently drops every fired lore entry. Same hole for a FLAT
// preset (`promptBlocks` empty), which never runs the fallback at all.
//
// These tests assert the RESULT MATRIX for that gap: unchanged behaviour on
// every existing path, and the two previously-broken shapes now inject the
// lore exactly once.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/chat_prompt_builder.dart';

void main() {
  const secret = 'The secret code is BLUEAPPLE.';
  const needle = 'BLUEAPPLE';

  LoreEntry constantSecret({String id = 'e-secret'}) => LoreEntry(
        id: id,
        keys: const [],
        content: secret,
        constant: true,
      );

  Lorebook bookWith(LoreEntry e, {String id = 'lb-secret', String name = 'Secrets'}) =>
      Lorebook(id: id, name: name, entries: [e]);

  Message userMsg(String id, String text) =>
      Message(id: id, kind: MessageKind.user, variants: [text], createdAt: 1);

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

  /// The chat used by every case: the sentinel lorebook is CHAT-attached
  /// (collection scope isn't the bug — injection is), one member, one
  /// user message. `withLore: false` builds the "no lore fired" control
  /// used by the byte-identical guard rows.
  Chat chatWith({required Character char, required bool withLore}) => Chat(
        id: 'c-${withLore ? "lore" : "nolore"}',
        characterIds: [char.id],
        characterSnapshots: {char.id: char},
        attachedLorebookIds: withLore ? ['lb-secret'] : const [],
        messages: [userMsg('m1', 'hello there')],
      );

  String assembledText(ChatPromptInputs inputs) {
    final result = buildChatPrompt(inputs);
    return result.turns.map((t) => t.content).join('\n\n');
  }

  int countOccurrences(String haystack, String candidate) {
    if (candidate.isEmpty) return 0;
    var count = 0;
    var idx = 0;
    while (true) {
      final i = haystack.indexOf(candidate, idx);
      if (i == -1) break;
      count++;
      idx = i + candidate.length;
    }
    return count;
  }

  ChatPromptInputs inputsFor({
    required Chat chat,
    required Character? character,
    required Preset? preset,
    Map<String, Lorebook> books = const {},
  }) =>
      ChatPromptInputs(
        chat: chat,
        character: character,
        persona: null,
        preset: preset,
        responderId: character?.id,
        beatsCap: 0,
        lookupCharacter: (id) => id == character?.id ? character : null,
        lookupBook: (id) => books[id],
      );

  final book = bookWith(constantSecret());
  final books = {book.id: book};

  group('result matrix — unchanged (existing) paths', () {
    test('no preset → fallback injects lore (unchanged)', () {
      final char = baseChar();
      final chat = chatWith(char: char, withLore: true);
      final text = assembledText(inputsFor(chat: chat, character: char, preset: null, books: books));
      expect(countOccurrences(text, needle), 1);
      expect(text, contains('--- Lore ---'));
    });

    test('flat preset WITH {{wiBefore}} in mainPrompt → marker consumes it, '
        'no duplicate standalone block', () {
      final char = baseChar();
      final chat = chatWith(char: char, withLore: true);
      final preset = Preset(
        id: 'preset-flat-wib',
        name: 'FlatWiB',
        mainPrompt: 'System framing.\n{{wiBefore}}',
      );
      final text = assembledText(inputsFor(chat: chat, character: char, preset: preset, books: books));
      expect(countOccurrences(text, needle), 1,
          reason: 'the marker consumes the lore — must appear exactly once');
      expect(text, isNot(contains('--- Lore ---')),
          reason: 'no standalone fallback block when the marker already consumed it');
    });

    test('modular preset, NO card markers at all → fallback injects lore once (unchanged)', () {
      final char = baseChar();
      final chat = chatWith(char: char, withLore: true);
      final preset = Preset(
        id: 'preset-nomarkers',
        name: 'NoMarkers',
        promptBlocks: [
          PromptBlock(id: 'b1', name: 'b1', content: 'You are a helpful roleplay assistant.'),
        ],
      );
      final text = assembledText(inputsFor(chat: chat, character: char, preset: preset, books: books));
      expect(countOccurrences(text, needle), 1);
      expect(text, contains('--- Lore ---'));
    });

    test('{{wiBefore}} living ONLY in a before-history TURN (not systemPrompt) → '
        'the turn consumes it, no standalone block added', () {
      final char = baseChar();
      final chat = chatWith(char: char, withLore: true);
      final preset = Preset(
        id: 'preset-turn-wib',
        name: 'TurnWiB',
        promptBlocks: [
          // System-role block: carries a card marker (so the OLD fallback gate
          // does NOT fire) but no {{wiBefore}}.
          PromptBlock(
            id: 'b1',
            name: 'sys',
            content: 'You are {{char}}. {{description}}',
          ),
          // A role:'user' block becomes a beforeTurn (Prompt Manager Core),
          // not part of asm.systemPrompt — the anywhere-scan must still catch
          // its {{wiBefore}} reference.
          PromptBlock(
            id: 'b2',
            name: 'lore-turn',
            content: 'Lore: {{wiBefore}}',
            role: 'user',
          ),
        ],
      );
      final text = assembledText(inputsFor(chat: chat, character: char, preset: preset, books: books));
      expect(countOccurrences(text, needle), 1,
          reason: 'the turn marker consumes the lore exactly once');
      expect(text, isNot(contains('--- Lore ---')),
          reason: 'the anywhere-scan must see the turn-level marker and skip the standalone inject');
    });

    test('no fired lore at all → no standalone lore block appears, even on the '
        'previously-buggy preset shape (guard: injectLoreSegment no-ops on empty loreText)', () {
      final char = baseChar();
      final chat = chatWith(char: char, withLore: false); // no lorebook attached
      final preset = Preset(
        id: 'preset-desc-only-nolore',
        name: 'DescOnlyNoLore',
        promptBlocks: [
          PromptBlock(id: 'b1', name: 'b1', content: 'You are {{char}}.\n{{description}}'),
        ],
      );
      final text = assembledText(inputsFor(chat: chat, character: char, preset: preset, books: books));
      expect(text, isNot(contains(needle)));
      expect(text, isNot(contains('--- Lore ---')));
    });
  });

  group('result matrix — THE BUG (previously dropped, now fixed)', () {
    test('modular preset WITH {{description}} but NO {{wiBefore}} → lore is '
        'injected (was: silently dropped)', () {
      final char = baseChar();
      final chat = chatWith(char: char, withLore: true);
      final preset = Preset(
        id: 'preset-desc-only',
        name: 'DescOnly',
        promptBlocks: [
          PromptBlock(id: 'b1', name: 'b1', content: 'You are {{char}}.\n{{description}}'),
        ],
      );
      final text = assembledText(inputsFor(chat: chat, character: char, preset: preset, books: books));
      expect(countOccurrences(text, needle), 1,
          reason: 'THE BUG: a card-marker preset without {{wiBefore}} used to drop fired lore');
      expect(text, contains('--- Lore ---'));
      // Sanity: the card marker itself still resolved (unrelated to the fix).
      expect(text, contains('A quiet archivist.'));
    });

    test('FLAT preset (empty promptBlocks) without {{wiBefore}} → lore is '
        'injected (was: silently dropped)', () {
      final char = baseChar();
      final chat = chatWith(char: char, withLore: true);
      final preset = Preset(
        id: 'preset-flat-nomarker',
        name: 'FlatNoMarker',
        mainPrompt: 'Be a helpful assistant.',
      );
      final text = assembledText(inputsFor(chat: chat, character: char, preset: preset, books: books));
      expect(countOccurrences(text, needle), 1,
          reason: 'THE BUG: a flat preset without {{wiBefore}} used to drop fired lore');
      expect(text, contains('--- Lore ---'));
    });
  });
}
