import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/memory.dart';

void main() {
  group('recapLooksComplete', () {
    // --- true cases (sentence-final punctuation) ---

    test('ends with period → true', () {
      expect(
        recapLooksComplete('They crossed the bridge and reached the keep.'),
        isTrue,
      );
    });

    test('ends with exclamation mark → true', () {
      expect(
        recapLooksComplete('The gate exploded open with a thunderous crash!'),
        isTrue,
      );
    });

    test('ends with question mark → true', () {
      expect(
        recapLooksComplete('Would they ever find their way back?'),
        isTrue,
      );
    });

    test('ends with ellipsis → true', () {
      expect(
        recapLooksComplete('She hesitated, her hand on the door…'),
        isTrue,
      );
    });

    test('ends with period + right double quote → true', () {
      expect(
        recapLooksComplete('He muttered, "I never wanted any of this."'),
        isTrue,
      );
    });

    test('ends with exclamation + right double quote → true', () {
      expect(
        recapLooksComplete('"Run!" she screamed.'),
        // Last char here is '.' so this should be true.
        isTrue,
      );
    });

    test('ends with period + ASCII double quote → true', () {
      expect(
        recapLooksComplete('She said "goodbye."'),
        isTrue,
      );
    });

    test('ends with period + ASCII single quote → true', () {
      expect(
        recapLooksComplete("He answered 'never.'"),
        isTrue,
      );
    });

    test('ends with question + right double quote → true', () {
      expect(
        recapLooksComplete('He asked, "Are you sure?"'),
        isTrue,
      );
    });

    test('trailing whitespace is ignored before check → true', () {
      expect(
        recapLooksComplete('The chapter closed on a moment of silence.   '),
        isTrue,
      );
    });

    // --- false cases (truncated / no sentence-final punctuation) ---

    test('ends mid-word → false', () {
      expect(
        recapLooksComplete('They ran through the fores'),
        isFalse,
      );
    });

    test('ends with comma → false', () {
      expect(
        recapLooksComplete('She looked around, unsure,'),
        isFalse,
      );
    });

    test('ends with a letter after space → false', () {
      expect(
        recapLooksComplete('The wind was cold and the night was dark and'),
        isFalse,
      );
    });

    test('empty string → false', () {
      expect(recapLooksComplete(''), isFalse);
    });

    test('whitespace-only string → false', () {
      expect(recapLooksComplete('   '), isFalse);
    });

    test('closing quote with no preceding sentence-final char → false', () {
      // E.g. a quote that ends mid-sentence: `"she ran`
      // This should not be flagged as complete.
      expect(
        recapLooksComplete('"she ran'),
        isFalse,
      );
    });

    test('closing quote preceded by comma → false', () {
      expect(
        recapLooksComplete('He said, "I think,"'),
        isFalse,
      );
    });

    test('lone closing quote (length=1) → false', () {
      expect(recapLooksComplete('"'), isFalse);
    });
  });

  // Wave CY.18.220: recency-biased recap bound.
  group('recencyBoundedRecap', () {
    String para(String tag, int len) => '$tag ${'x' * len}.';

    test('empty list → empty string', () {
      expect(recencyBoundedRecap([], charBudget: 1000), '');
    });

    test('blank entries are dropped', () {
      expect(
        recencyBoundedRecap(['   ', '', 'real recap'], charBudget: 1000),
        'real recap',
      );
    });

    test('under budget → all checkpoints kept, oldest-first order', () {
      final out = recencyBoundedRecap(
        ['oldest', 'middle', 'newest'],
        charBudget: 10000,
      );
      expect(out, 'oldest\n\nmiddle\n\nnewest');
    });

    test(
        'over budget → newest kept WHOLE, oldest trimmed first, under cap',
        () {
      // 4 long checkpoints; cap fits ~2.something of them.
      final oldest = para('OLDEST', 3000);
      final older = para('OLDER', 3000);
      final newer = para('NEWER', 3000);
      final newest = para('NEWEST', 3000);
      const cap = 7000;
      final out = recencyBoundedRecap(
        [oldest, older, newer, newest],
        charBudget: cap,
        alwaysWholeNewest: 2,
      );
      // Newest two present, intact:
      expect(out, contains(newest));
      expect(out, contains(newer));
      // Oldest trimmed away (oldest-first):
      expect(out, isNot(contains('OLDEST')));
      // Block stays under the cap:
      expect(out.length, lessThanOrEqualTo(cap));
    });

    test('newest is ALWAYS kept whole even if it alone exceeds the cap', () {
      final huge = para('NEWEST', 20000);
      final out = recencyBoundedRecap(
        ['short older one', huge],
        charBudget: 5000,
        alwaysWholeNewest: 1,
      );
      expect(out, contains(huge)); // never truncated mid-text
      expect(out, isNot(contains('short older one')));
    });
  });

  // Wave CY.18.270 (BUG 2): the summariser system prompt must be a
  // contextualized NARRATIVE ARC ("story so far"), PAST tense, in BOTH the
  // custom-prompt branch and the no-prior-recap branch — NOT a flat event
  // list. Two regressions were fixed: (a) the rich narrative branch was dead
  // code (the default summaryPrompt is non-empty, so the custom branch always
  // ran with the terser default text), and (b) the anti-continuation block
  // ended with a flattening "every sentence … nothing more" clause that
  // forced one-sentence-per-event enumeration.
  group('resolveSystemPrompt (BUG 2 — narrative arc framing)', () {
    // The flattening clause that used to force a flat event list. It must be
    // GONE from every resolved prompt now.
    const flattenClause = 'nothing more';

    test('no prior recap → arc framing, no flattening clause, past tense', () {
      final out = resolveSystemPrompt(
        hasPriorContext: false,
        memorySettings: MemorySettings(),
      );
      // Arc framing present.
      expect(out.toLowerCase(), contains('story so far'));
      expect(out.toLowerCase(), contains('situation'));
      expect(out.toLowerCase(), contains('setup'));
      // Past-tense framing present, flattening clause gone.
      expect(out.toLowerCase(), contains('past tense'));
      expect(out, isNot(contains(flattenClause)));
    });

    test('with prior recap → arc framing, no flattening clause, past tense',
        () {
      final out = resolveSystemPrompt(
        hasPriorContext: true,
        memorySettings: MemorySettings(),
      );
      expect(out.toLowerCase(), contains('story so far'));
      expect(out.toLowerCase(), contains('situation'));
      expect(out.toLowerCase(), contains('setup'));
      expect(out.toLowerCase(), contains('past tense'));
      expect(out, isNot(contains(flattenClause)));
    });

    test('null memorySettings → still arc framing (default fallback)', () {
      final out = resolveSystemPrompt(
        hasPriorContext: false,
        memorySettings: null,
      );
      expect(out.toLowerCase(), contains('story so far'));
      expect(out, isNot(contains(flattenClause)));
      expect(out.toLowerCase(), contains('past tense'));
    });

    test('custom summaryPrompt branch still gets arc framing + guardrail', () {
      // A user with their own template still receives the anti-continuation
      // arc-framing guardrail prepended, and the flattening clause is gone.
      final out = resolveSystemPrompt(
        hasPriorContext: true,
        memorySettings: MemorySettings(
          summaryPrompt: 'Recap the last {{words}} words however you like.',
        ),
      );
      // The custom template body is honoured...
      expect(out, contains('Recap the last'));
      // ...and the prepended guardrail still frames it as flowing narrative.
      expect(out.toLowerCase(), contains('story so far'));
      expect(out, isNot(contains(flattenClause)));
    });

    test('{{words}} macro is substituted from memoryLimit', () {
      final out = resolveSystemPrompt(
        hasPriorContext: false,
        memorySettings: MemorySettings(memoryLimit: 250),
      );
      expect(out, isNot(contains('{{words}}')));
      expect(out, contains('250'));
    });

    test('anti-continuation guardrail is preserved (recap not continuation)',
        () {
      final out = resolveSystemPrompt(
        hasPriorContext: false,
        memorySettings: MemorySettings(),
      );
      // The core guardrail survives the softening.
      expect(out, contains('NOT A STORY CONTINUATION'));
      expect(out.toLowerCase(), contains('do not advance the plot'));
      // ...but now explicitly asks for flowing prose, not a bulleted log.
      expect(out.toLowerCase(), contains('flowing narrative prose'));
      expect(out.toLowerCase(), contains('not a bulleted log'));
    });
  });

  // Diagnostic companion to shouldSummarize. The verdict MUST stay
  // byte-identical to shouldSummarize (which now delegates here); the extra
  // fields are pure observability for the export-only LTM trace.
  group('summarizeDecision (diagnostic companion to shouldSummarize)', () {
    Message charMsg() => Message(id: 'm-${newId('x')}', kind: MessageKind.char);
    Message userMsg() => Message(id: 'm-${newId('x')}', kind: MessageKind.user);

    Chat chatWith(List<Message> msgs,
            {List<MemoryCheckpoint>? ckpts, bool memoryEnabled = true}) =>
        Chat(
          id: 'c1',
          characterIds: const ['char1'],
          messages: msgs,
          memoryCheckpoints: ckpts,
          memoryEnabled: memoryEnabled,
        );

    test('verdict equals shouldSummarize across a range of states', () {
      // Build several chats and assert the booleans agree everywhere.
      final cases = <Chat>[
        chatWith([]),
        chatWith([for (var i = 0; i < 5; i++) charMsg()]),
        chatWith([for (var i = 0; i < 20; i++) charMsg()]),
        chatWith([for (var i = 0; i < 25; i++) charMsg()]),
        chatWith([for (var i = 0; i < 30; i++) charMsg()],
            memoryEnabled: false),
      ];
      for (final settings in [
        null,
        MemorySettings(autoEvery: 0),
        MemorySettings(autoEvery: 5),
        MemorySettings(autoEvery: 20),
      ]) {
        for (final chat in cases) {
          expect(
            summarizeDecision(chat, memorySettings: settings).shouldSummarize,
            shouldSummarize(chat, memorySettings: settings),
            reason: 'mismatch for autoEvery=${settings?.autoEvery}',
          );
        }
      }
    });

    test('default threshold (20): 19 char msgs → false, 20 → true', () {
      final under = chatWith([for (var i = 0; i < 19; i++) charMsg()]);
      final at = chatWith([for (var i = 0; i < 20; i++) charMsg()]);
      final d19 = summarizeDecision(under);
      final d20 = summarizeDecision(at);
      expect(d19.shouldSummarize, isFalse);
      expect(d19.newCharMsgs, 19);
      expect(d19.threshold, 20);
      expect(d20.shouldSummarize, isTrue);
      expect(d20.newCharMsgs, 20);
    });

    test('only MessageKind.char counts toward newCharMsgs', () {
      // 20 user turns interleaved with 5 char turns → only 5 count.
      final msgs = <Message>[];
      for (var i = 0; i < 5; i++) {
        msgs..add(userMsg())..add(userMsg())..add(userMsg())..add(charMsg());
      }
      final d = summarizeDecision(msgs.isEmpty ? chatWith([]) : chatWith(msgs),
          memorySettings: MemorySettings(autoEvery: 5));
      expect(d.newCharMsgs, 5);
      expect(d.totalMessages, 20);
      expect(d.shouldSummarize, isTrue);
    });

    test(
        'SECOND-checkpoint scenario: anchor at 20, only 4 new char msgs past it '
        '→ false with correct numbers', () {
      // 30 char messages; a valid checkpoint anchored at index 19 (covers the
      // first 20). The path hash must match the current branch to be valid.
      final msgs = [for (var i = 0; i < 30; i++) charMsg()];
      final chat = chatWith(msgs);
      final anchor = 19;
      final ckpt = MemoryCheckpoint(
        id: 'mc1',
        summary: 'first recap',
        anchorMessageIdx: anchor,
        pathHash: computePathHash(msgs, anchor),
      );
      chat.memoryCheckpoints.add(ckpt);
      final d = summarizeDecision(chat, memorySettings: MemorySettings(autoEvery: 20));
      expect(d.lastAnchor, 19);
      expect(d.validCount, 1);
      // 30 total, indices 20..29 past the anchor → 10 new char msgs.
      expect(d.newCharMsgs, 10);
      expect(d.threshold, 20);
      expect(d.shouldSummarize, isFalse); // 10 < 20
      expect(d.shouldSummarize, shouldSummarize(chat, memorySettings: MemorySettings(autoEvery: 20)));
    });

    test('autoEvery==0 kill-switch → false even when well past threshold', () {
      final chat = chatWith([for (var i = 0; i < 50; i++) charMsg()]);
      final d = summarizeDecision(chat, memorySettings: MemorySettings(autoEvery: 0));
      expect(d.shouldSummarize, isFalse);
      // Numbers still computed honestly even though the kill-switch wins.
      expect(d.newCharMsgs, 50);
    });

    test('memoryEnabled==false → false regardless of counts', () {
      final chat = chatWith([for (var i = 0; i < 50; i++) charMsg()],
          memoryEnabled: false);
      final d = summarizeDecision(chat);
      expect(d.shouldSummarize, isFalse);
      expect(d.newCharMsgs, 50);
    });
  });

  // memory-livesheet-script-scene-01: when memory is OFF the recap is
  // suppressed (buildRecapBlock returns ''), so the replay window MUST start
  // at 0 — otherwise the pre-anchor messages are neither summarised nor
  // replayed and the model silently loses all context before the last anchor.
  group('firstUncoveredIndex — memory-OFF gate', () {
    Message charMsg(String id) =>
        Message(id: id, kind: MessageKind.char, variants: const ['x']);

    Chat chatWithAnchor({required bool memoryEnabled}) {
      final msgs = [for (var i = 0; i < 10; i++) charMsg('m$i')];
      final anchor = 4;
      return Chat(
        id: 'c1',
        characterIds: const ['char1'],
        messages: msgs,
        memoryEnabled: memoryEnabled,
        memoryCheckpoints: [
          MemoryCheckpoint(
            id: 'mc1',
            summary: 'covers 0..4',
            anchorMessageIdx: anchor,
            pathHash: computePathHash(msgs, anchor),
          ),
        ],
      );
    }

    test('memory ON → window starts after the last valid anchor', () {
      final chat = chatWithAnchor(memoryEnabled: true);
      expect(firstUncoveredIndex(chat), 5); // anchor 4 + 1
    });

    test('memory OFF → window clamps to 0 (full history replays)', () {
      final chat = chatWithAnchor(memoryEnabled: false);
      // With memory off the recap is suppressed, so the full conversation
      // must be replayed instead of being silently dropped.
      expect(buildRecapBlock(chat), isEmpty);
      expect(firstUncoveredIndex(chat), 0);
    });
  });

  // chat-core-1-01: the summariser's source body must not carry assistant
  // <think> reasoning into the recap input.
  group('buildSummariserBodyForTest — <think> stripped from char turns', () {
    test('a char turn with reasoning contributes only the visible prose', () {
      final chat = Chat(
        id: 'c1',
        characterIds: const ['char1'],
        messages: [
          Message(id: 'm0', kind: MessageKind.user, variants: const ['hi']),
          Message(
              id: 'm1',
              kind: MessageKind.char,
              variants: const [
                '<think>plan the reply carefully</think>She waves back.'
              ]),
        ],
      );
      final body = buildSummariserBodyForTest(
        chat: chat,
        startExclusive: -1,
        endInclusive: 1,
        priorContext: const [],
      );
      expect(body, contains('She waves back.'));
      expect(body, isNot(contains('<think>')));
      expect(body, isNot(contains('plan the reply')));
      // user turns are untouched.
      expect(body, contains('hi'));
    });
  });
}
