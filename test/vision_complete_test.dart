// H-11: vision profiles can exceed the output-token cap and silently cut
// off mid-CHARACTER C. `visionProfileLooksComplete` is the pure, soft
// completeness check that decides whether to surface a non-blocking
// "this may be cut off" note near the generated profile.
//
// IMPORTANT: this is a SOFT signal only — it never auto-retries (a
// continuation/resume loop was deliberately reverted in Wave 117 because
// reasoning models re-dump chain-of-thought when asked to "continue").
// So it must be CONSERVATIVE: a false "truncated" verdict shows a benign
// note the user can ignore, but we still avoid crying wolf on a
// valid-but-unusual profile.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/image_describe.dart';

void main() {
  group('visionProfileLooksComplete', () {
    test('a full single-character profile ending in NEXT → complete', () {
      const profile = '''GENERAL PHYSICAL FEATURES
Human woman, athletic build.

FACE
Heart-shaped, green eyes.

BODY
Slim waist, broad shoulders.

EXPOSURE SUMMARY
Shoulders bare, rest covered.

UNCERTAINTIES
Open to user direction on backstory.

NEXT
What does her voice sound like?''';
      expect(visionProfileLooksComplete(profile), isTrue);
    });

    test('a full ensemble profile (CHARACTER A/B/C + NEXT) → complete', () {
      const profile = '''GROUP COMPOSITION
Three men share the frame in the steam.

CHARACTER A
Tall, broad-shouldered, dark hair.

CHARACTER B
Lean, blond, scarred forearm.

CHARACTER C
Stocky, red beard, towel low on the hips.

GROUP DYNAMICS
Easy camaraderie, the blond leans on the redhead.

UNCERTAINTIES
Their names are open.

NEXT
Want to name the cast?''';
      expect(visionProfileLooksComplete(profile), isTrue);
    });

    test('truncated mid-CHARACTER C (no NEXT marker) → NOT complete', () {
      // The exact failure mode H-11 targets: a 3-character ensemble that
      // ran out of output budget partway through the last character. No
      // UNCERTAINTIES, no NEXT — and it ends mid-sentence.
      const profile = '''GROUP COMPOSITION
Three men share the frame in the steam.

CHARACTER A
Tall, broad-shouldered, dark hair.

CHARACTER B
Lean, blond, scarred forearm.

CHARACTER C
Stocky build, a red beard, and a towel slung low across the''';
      expect(visionProfileLooksComplete(profile), isFalse);
    });

    test('ends mid-word with no closing section → NOT complete', () {
      const profile = '''GENERAL PHYSICAL FEATURES
Human woman, athletic build with broad shoulders and a narrow wa''';
      expect(visionProfileLooksComplete(profile), isFalse);
    });

    test('a body sentence starting "Next, ..." is NOT mistaken for the NEXT marker',
        () {
      // "Next," as prose inside a body must not satisfy the closing-marker
      // check — otherwise a truncation right after such a sentence would
      // read as complete.
      const profile = '''GENERAL PHYSICAL FEATURES
Human woman. Next, the lighting falls across her left shoulder and the''';
      expect(visionProfileLooksComplete(profile), isFalse);
    });

    test('NEXT header followed by its handoff sentence → complete', () {
      // Lowercase / markdown-decorated NEXT header should still count as a
      // real closing marker, so we don't false-positive on valid styling.
      const profile = '''LOCATION TYPE
A ruined cathedral, roof open to the sky.

ATMOSPHERE / MOOD
Cold dawn light, damp stone.

UNCERTAINTIES
Open to user direction on era.

**NEXT**
What kind of scenes happen here?''';
      expect(visionProfileLooksComplete(profile), isTrue);
    });

    test('empty / whitespace input → NOT complete (no profile at all)', () {
      expect(visionProfileLooksComplete(''), isFalse);
      expect(visionProfileLooksComplete('   \n  \n'), isFalse);
    });

    test('a bare NEXT header with no handoff sentence → NOT complete', () {
      // If the stream cut off right at the NEXT header (header present but
      // no sentence after it), treat it as truncated.
      const profile = '''GENERAL PHYSICAL FEATURES
Human, tall.

UNCERTAINTIES
None.

NEXT''';
      expect(visionProfileLooksComplete(profile), isFalse);
    });
  });
}
