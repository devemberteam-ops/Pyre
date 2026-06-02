import 'package:flutter_test/flutter_test.dart';
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
}
