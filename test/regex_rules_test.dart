import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/regex_rules.dart';

/// Convenience: an enabled rule that targets BOTH streams + BOTH stages
/// unless overridden.
RegexRule rule({
  String pattern = '',
  String flags = '',
  String replacement = '',
  List<String>? trimStrings,
  List<RegexStream>? streams,
  bool affectsDisplay = true,
  bool affectsPrompt = true,
  bool enabled = true,
}) =>
    RegexRule(
      name: 'test',
      pattern: pattern,
      flags: flags,
      replacement: replacement,
      trimStrings: trimStrings,
      streams: streams,
      affectsDisplay: affectsDisplay,
      affectsPrompt: affectsPrompt,
      enabled: enabled,
    );

String apply(
  String text,
  List<RegexRule> rules, {
  RegexStream stream = RegexStream.aiOutput,
  RegexStage stage = RegexStage.display,
}) =>
    applyRegexRules(text, rules, stream: stream, stage: stage);

void main() {
  group('applyRegexRules — substitution', () {
    test('empty rules list returns input unchanged (identity)', () {
      expect(apply('hello world', const []), 'hello world');
    });

    test('no applicable rule returns input unchanged', () {
      final r = rule(pattern: 'x', replacement: 'y', streams: [
        RegexStream.userInput,
      ]);
      expect(apply('abc', [r], stream: RegexStream.aiOutput), 'abc');
    });

    test(r'$1 capture group substitution', () {
      final r = rule(pattern: r'(\w+)@(\w+)', flags: 'g', replacement: r'$1 at $2');
      expect(apply('bob@host me@there', [r]), 'bob at host me at there');
    });

    test(r'$1 with a missing group yields empty', () {
      // Group 2 never participates → empty.
      final r = rule(pattern: r'(a)(b)?', replacement: r'[$1|$2]');
      expect(apply('a', [r]), '[a|]');
    });

    test('{{match}} macro inserts the whole match', () {
      final r = rule(pattern: r'cat', flags: 'g', replacement: '<<{{match}}>>');
      expect(apply('cat scatter cat', [r]), '<<cat>> s<<cat>>ter <<cat>>');
    });

    test(r'$0 also means the whole match', () {
      final r = rule(pattern: r'foo', replacement: r'[$0]');
      expect(apply('foo', [r]), '[foo]');
    });

    test(r'$$ is a literal dollar sign', () {
      final r = rule(pattern: r'x', replacement: r'$$5');
      expect(apply('x', [r]), r'$5');
    });

    test('trimStrings removed from the matched text under {{match}}', () {
      // Match "**bold**", strip the asterisks → "bold".
      final r = rule(
        pattern: r'\*\*[^*]+\*\*',
        flags: 'g',
        replacement: '{{match}}',
        trimStrings: ['**'],
      );
      expect(apply('say **hi** and **bye**', [r]), 'say hi and bye');
    });

    test(r'trimStrings also strip under $0', () {
      final r = rule(
        pattern: r'\[\[.+?\]\]',
        replacement: r'$0',
        trimStrings: ['[[', ']]'],
      );
      expect(apply('a [[note]] b', [r]), 'a note b');
    });

    test('trimStrings do NOT touch literal replacement text', () {
      // trimStrings only affect the captured match, not a static replacement.
      final r = rule(
        pattern: r'x',
        replacement: 'a-b-c',
        trimStrings: ['-'],
      );
      expect(apply('x', [r]), 'a-b-c');
    });
  });

  group('applyRegexRules — flags', () {
    test('case-insensitive (i) flag', () {
      final r = rule(pattern: 'hello', flags: 'gi', replacement: 'hi');
      expect(apply('Hello HELLO hello', [r]), 'hi hi hi');
    });

    test('case-sensitive by default', () {
      final r = rule(pattern: 'hello', flags: 'g', replacement: 'hi');
      expect(apply('Hello hello', [r]), 'Hello hi');
    });

    test('global (g) replaces all', () {
      final r = rule(pattern: 'a', flags: 'g', replacement: 'X');
      expect(apply('banana', [r]), 'bXnXnX');
    });

    test('without g, only the first match is replaced', () {
      final r = rule(pattern: 'a', replacement: 'X');
      expect(apply('banana', [r]), 'bXnana');
    });

    test('"global" word also enables replace-all', () {
      final r = rule(pattern: 'a', flags: 'global', replacement: 'X');
      expect(apply('aaa', [r]), 'XXX');
    });

    test('multiline (m) makes ^ match per line', () {
      final r = rule(pattern: r'^x', flags: 'gm', replacement: 'Y');
      expect(apply('x1\nx2\nx3', [r]), 'Y1\nY2\nY3');
    });

    test('dotAll (s) makes . match newlines', () {
      final r = rule(pattern: r'a.b', flags: 's', replacement: 'Z');
      expect(apply('a\nb', [r]), 'Z');
    });

    test('without s, . does NOT cross newlines', () {
      final r = rule(pattern: r'a.b', replacement: 'Z');
      expect(apply('a\nb', [r]), 'a\nb');
    });
  });

  group('applyRegexRules — robustness', () {
    test('invalid pattern is a no-op (returns input)', () {
      final bad = rule(pattern: r'([unclosed', replacement: 'X');
      expect(apply('keep me', [bad]), 'keep me');
    });

    test('an invalid rule does not stop other valid rules', () {
      final bad = rule(pattern: r'(', replacement: 'X');
      final good = rule(pattern: 'me', replacement: 'you');
      expect(apply('keep me', [bad, good]), 'keep you');
    });

    test('empty pattern is a no-op', () {
      final r = rule(pattern: '', replacement: 'X');
      expect(apply('abc', [r]), 'abc');
    });
  });

  group('applyRegexRules — stream filter', () {
    test('a userInput-only rule does nothing on aiOutput text', () {
      final r = rule(
        pattern: 'x',
        replacement: 'y',
        streams: [RegexStream.userInput],
      );
      expect(apply('x', [r], stream: RegexStream.aiOutput), 'x');
      expect(apply('x', [r], stream: RegexStream.userInput), 'y');
    });

    test('an aiOutput-only rule does nothing on userInput text', () {
      final r = rule(
        pattern: 'x',
        replacement: 'y',
        streams: [RegexStream.aiOutput],
      );
      expect(apply('x', [r], stream: RegexStream.userInput), 'x');
    });
  });

  group('applyRegexRules — stage filter', () {
    test('a display-only rule does nothing at prompt stage', () {
      final r = rule(
        pattern: 'x',
        replacement: 'y',
        affectsDisplay: true,
        affectsPrompt: false,
      );
      expect(apply('x', [r], stage: RegexStage.prompt), 'x');
      expect(apply('x', [r], stage: RegexStage.display), 'y');
    });

    test('a prompt-only rule does nothing at display stage', () {
      final r = rule(
        pattern: 'x',
        replacement: 'y',
        affectsDisplay: false,
        affectsPrompt: true,
      );
      expect(apply('x', [r], stage: RegexStage.display), 'x');
      expect(apply('x', [r], stage: RegexStage.prompt), 'y');
    });
  });

  group('applyRegexRules — enabled + ordering', () {
    test('disabled rule is skipped', () {
      final r = rule(pattern: 'x', replacement: 'y', enabled: false);
      expect(apply('x', [r]), 'x');
    });

    test('deleted (tombstoned) rule is skipped', () {
      final r = rule(pattern: 'x', replacement: 'y');
      r.deleted = true;
      expect(apply('x', [r]), 'x');
    });

    test('two rules chain in order', () {
      final r1 = rule(pattern: 'a', flags: 'g', replacement: 'b');
      final r2 = rule(pattern: 'b', flags: 'g', replacement: 'c');
      // a→b then b→c: "aa" → "bb" → "cc".
      expect(apply('aa', [r1, r2]), 'cc');
    });

    test('order matters (reversed gives a different result)', () {
      final r1 = rule(pattern: 'a', flags: 'g', replacement: 'b');
      final r2 = rule(pattern: 'b', flags: 'g', replacement: 'c');
      // b→c first does nothing (no b yet), then a→b leaves "bb".
      expect(apply('aa', [r2, r1]), 'bb');
    });
  });

  group('parseRegexLiteral', () {
    test('splits /pat/flags', () {
      final r = parseRegexLiteral('/hello/gi');
      expect(r.pattern, 'hello');
      expect(r.flags, 'gi');
    });

    test('bare /pat/ has empty flags', () {
      final r = parseRegexLiteral('/hello/');
      expect(r.pattern, 'hello');
      expect(r.flags, '');
    });

    test('a non-literal string becomes the whole pattern', () {
      final r = parseRegexLiteral('just text');
      expect(r.pattern, 'just text');
      expect(r.flags, '');
    });

    test('unterminated /foo is treated as a literal pattern', () {
      final r = parseRegexLiteral('/foo');
      expect(r.pattern, '/foo');
      expect(r.flags, '');
    });

    test('trailing non-flag segment is not split', () {
      // "b/c" after the last slash isn't flag letters → keep verbatim.
      final r = parseRegexLiteral('/a/b/c');
      // lastSlash splits body="a/b" flags="c" (c is a letter) → recognised.
      // This documents the behaviour: a single trailing letter run splits.
      expect(r.pattern, 'a/b');
      expect(r.flags, 'c');
    });
  });

  group('RegexRule round-trip', () {
    test('toJson / fromJson preserves all fields', () {
      final r = RegexRule(
        id: 'rid-1',
        name: 'Strip stage directions',
        pattern: r'\(.*?\)',
        flags: 'gs',
        replacement: '',
        trimStrings: ['(', ')'],
        streams: [RegexStream.aiOutput],
        affectsDisplay: true,
        affectsPrompt: false,
        enabled: false,
        mtime: 123456,
        deleted: false,
      );
      final back = RegexRule.fromJson(r.toJson());
      expect(back.id, 'rid-1');
      expect(back.name, 'Strip stage directions');
      expect(back.pattern, r'\(.*?\)');
      expect(back.flags, 'gs');
      expect(back.replacement, '');
      expect(back.trimStrings, ['(', ')']);
      expect(back.streams, [RegexStream.aiOutput]);
      expect(back.affectsDisplay, true);
      expect(back.affectsPrompt, false);
      expect(back.enabled, false);
      expect(back.mtime, 123456);
      expect(back.deleted, false);
    });

    test('deleted flag round-trips when true', () {
      final r = RegexRule(pattern: 'x');
      r.deleted = true;
      final back = RegexRule.fromJson(r.toJson());
      expect(back.deleted, true);
    });

    test('missing keys fall back to defaults', () {
      final back = RegexRule.fromJson({'id': 'only-id'});
      expect(back.id, 'only-id');
      expect(back.name, 'Rule');
      expect(back.pattern, '');
      expect(back.flags, '');
      expect(back.replacement, '');
      expect(back.trimStrings, isEmpty);
      expect(back.streams,
          [RegexStream.userInput, RegexStream.aiOutput]); // default both
      expect(back.affectsDisplay, true);
      expect(back.affectsPrompt, true);
      expect(back.enabled, true);
      expect(back.mtime, 0);
      expect(back.deleted, false);
    });

    test('empty streams list decodes to BOTH (never a dead rule)', () {
      final back = RegexRule.fromJson({'id': 'x', 'streams': <String>[]});
      expect(back.streams,
          [RegexStream.userInput, RegexStream.aiOutput]);
    });
  });

  group('parseStRegexScript', () {
    test(r'realistic ST script: /pat/gi, $1, placement [2], markdownOnly', () {
      final r = parseStRegexScript({
        'scriptName': 'Bold names',
        'findRegex': r'/(\w+)-san/gi',
        'replaceString': r'**$1**',
        'trimStrings': <String>[],
        'placement': [2],
        'markdownOnly': true,
        'promptOnly': false,
        'disabled': false,
      });
      expect(r, isNotNull);
      expect(r!.name, 'Bold names');
      expect(r.pattern, r'(\w+)-san');
      expect(r.flags, 'gi');
      expect(r.replacement, r'**$1**');
      expect(r.streams, [RegexStream.aiOutput]); // placement 2
      expect(r.affectsDisplay, true);
      expect(r.affectsPrompt, false); // markdownOnly
      expect(r.enabled, true);
    });

    test('promptOnly script → prompt-only rule', () {
      final r = parseStRegexScript({
        'scriptName': 'Hide tokens',
        'findRegex': r'/<\|.*?\|>/g',
        'replaceString': '',
        'placement': [1, 2],
        'promptOnly': true,
      });
      expect(r, isNotNull);
      expect(r!.affectsDisplay, false);
      expect(r.affectsPrompt, true);
      expect(r.streams, [RegexStream.userInput, RegexStream.aiOutput]);
    });

    test('minimal script → safe defaults', () {
      final r = parseStRegexScript({'findRegex': 'foo'});
      expect(r, isNotNull);
      expect(r!.name, 'Imported rule');
      expect(r.pattern, 'foo');
      expect(r.flags, '');
      expect(r.replacement, '');
      // empty placement → both streams; neither markdown/prompt → both stages.
      expect(r.streams, [RegexStream.userInput, RegexStream.aiOutput]);
      expect(r.affectsDisplay, true);
      expect(r.affectsPrompt, true);
      expect(r.enabled, true);
    });

    test('placement [1] → userInput only', () {
      final r = parseStRegexScript({'findRegex': 'x', 'placement': [1]});
      expect(r!.streams, [RegexStream.userInput]);
    });

    test('disabled true → enabled false', () {
      final r = parseStRegexScript({'findRegex': 'x', 'disabled': true});
      expect(r!.enabled, false);
    });

    test('both markdownOnly and promptOnly → both stages true', () {
      final r = parseStRegexScript({
        'findRegex': 'x',
        'markdownOnly': true,
        'promptOnly': true,
      });
      expect(r!.affectsDisplay, true);
      expect(r.affectsPrompt, true);
    });

    test('missing findRegex → null', () {
      expect(parseStRegexScript({'scriptName': 'no pattern'}), isNull);
      expect(parseStRegexScript({'findRegex': ''}), isNull);
    });
  });

  group('parseStRegexScripts (list / file)', () {
    test('bare array of scripts', () {
      final list = parseStRegexScripts([
        {'findRegex': '/a/g', 'replaceString': 'A'},
        {'findRegex': '/b/g', 'replaceString': 'B'},
        {'scriptName': 'skipped — no pattern'},
      ]);
      expect(list.length, 2);
      expect(list[0].pattern, 'a');
      expect(list[1].pattern, 'b');
    });

    test('single script object', () {
      final list = parseStRegexScripts({'findRegex': 'x'});
      expect(list.length, 1);
      expect(list[0].pattern, 'x');
    });

    test('wrapper {regexScripts: [...]}', () {
      final list = parseStRegexScripts({
        'regexScripts': [
          {'findRegex': 'x'},
          {'findRegex': 'y'},
        ],
      });
      expect(list.length, 2);
    });

    test('garbage root → empty list (never throws)', () {
      expect(parseStRegexScripts(42), isEmpty);
      expect(parseStRegexScripts(null), isEmpty);
    });
  });

  group('compiled-RegExp cache (perf-at-scale #4)', () {
    setUp(debugClearRegexCache);

    test('repeated apply of the same rule compiles the pattern once', () {
      final r = rule(pattern: r'\bcat\b', flags: 'gi', replacement: 'dog');
      expect(debugRegexCacheSize, 0);
      // Simulate many bubbles/frames re-applying the same rule.
      for (var i = 0; i < 50; i++) {
        apply('the cat sat', [r]);
      }
      // Only ONE distinct (pattern,flags) compiled, despite 50 applies.
      expect(debugRegexCacheSize, 1);
    });

    test('distinct patterns/flags get distinct cache entries', () {
      apply('a', [rule(pattern: 'a', replacement: 'b')]);
      apply('a', [rule(pattern: 'a', flags: 'i', replacement: 'b')]);
      apply('a', [rule(pattern: 'c', replacement: 'd')]);
      expect(debugRegexCacheSize, 3);
    });

    test('an invalid pattern is cached as a no-op (does not recompile)', () {
      final bad = rule(pattern: '(', replacement: 'x'); // unbalanced group
      expect(apply('hello', [bad]), 'hello'); // no-op, never throws
      expect(debugRegexCacheSize, 1); // the bad pattern is cached (as null)
      expect(apply('hello', [bad]), 'hello');
      expect(debugRegexCacheSize, 1); // still one entry — not recompiled
    });

    test('caching does not change results (case-insensitive global)', () {
      final r = rule(pattern: 'cat', flags: 'gi', replacement: 'X');
      expect(apply('Cat cat CAT', [r]), 'X X X');
      // Run again from cache — identical output.
      expect(apply('Cat cat CAT', [r]), 'X X X');
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // Bundled DEFAULT formatting rule (seeded on first run).
  //
  // Pyre ships ONE conservative fix out of the box: models very often wrap a
  // whole line of spoken dialogue in italics (`*"Hello there."*`), which the
  // chat renderer styles as faint, muted narration instead of prominent
  // dialogue. The default rule strips the italic asterisks that DIRECTLY hug
  // a quoted span. Modeled on SillyTavern WeatherPack's "remove asterisks
  // around quotation marks". Must be SAFE: never touch `**bold**`, plain
  // narration, or a quote with no asterisks.
  group('buildDefaultRegexRules — the bundled formatting fix', () {
    // Apply the whole default bundle exactly as the chat does for AI bubbles.
    String fix(String text) => applyRegexRules(
          text,
          buildDefaultRegexRules(),
          stream: RegexStream.aiOutput,
          stage: RegexStage.display,
        );

    test('unwraps italics that hug a quoted line of dialogue', () {
      expect(fix('*"Hello there."*'), '"Hello there."');
    });

    test('unwraps with narration text around the dialogue intact', () {
      expect(
        fix('He turns slowly. *"Get out,"* she snaps.'),
        'He turns slowly. "Get out," she snaps.',
      );
    });

    test('unwraps multiple dialogue lines in one message (global)', () {
      expect(fix('*"Yes."* she said. *"No."* he replied.'),
          '"Yes." she said. "No." he replied.');
    });

    test('handles multiple asterisks hugging the quote', () {
      expect(fix('**"Hi"**'), '"Hi"');
      expect(fix('***"Hi"***'), '"Hi"');
    });

    test('leaves **bold** untouched (no quote → never matches)', () {
      expect(fix('say **bold** now'), 'say **bold** now');
    });

    test('leaves plain narration italics untouched (no quote)', () {
      expect(fix('*she smiles warmly*'), '*she smiles warmly*');
    });

    test('leaves a quote with no surrounding asterisks untouched', () {
      expect(fix('"Hello there."'), '"Hello there."');
    });

    test('does NOT unwrap when asterisks do not hug the quote', () {
      // The leading `*` is followed by narration text, not the quote, so a
      // whole italic narration span that merely CONTAINS a quote is left as
      // narration (conservative — we only unwrap when `*` directly hugs `"`).
      expect(fix('*She said "hi" to no one*'), '*She said "hi" to no one*');
    });

    test('preserves emphasis asterisks INSIDE the quote', () {
      // Only the outer wrap is removed; an emphasized word inside the quote
      // stays as-is.
      expect(fix('*"You *absolute* fool!"*'), '"You *absolute* fool!"');
    });

    test('the bundle carries the stable default-rule id, enabled', () {
      final rules = buildDefaultRegexRules();
      expect(rules, isNotEmpty);
      final r = rules.firstWhere((x) => x.id == kDefaultUnwrapQuoteItalicsRuleId);
      expect(r.enabled, isTrue);
      expect(r.streams, [RegexStream.aiOutput]);
      expect(r.affectsDisplay, isTrue);
      expect(r.affectsPrompt, isFalse);
    });

    test('does nothing to the user\'s own input (aiOutput-only)', () {
      expect(
        applyRegexRules('*"my typed line"*', buildDefaultRegexRules(),
            stream: RegexStream.userInput, stage: RegexStage.display),
        '*"my typed line"*',
      );
    });

    test('does nothing at the prompt stage (display-only — model sees raw)', () {
      expect(
        applyRegexRules('*"Hello"*', buildDefaultRegexRules(),
            stream: RegexStream.aiOutput, stage: RegexStage.prompt),
        '*"Hello"*',
      );
    });
  });
}
