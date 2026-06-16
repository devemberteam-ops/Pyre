// 2026-06-15 — Creator alternate-greetings bug (Kuru report).
//
// Two symptoms, one root cause (contradictory/over-eager prompts):
//   1. The Creator generated alternate greetings UNSOLICITED (the structured
//      build's closing batch requested them every build, and the field prompt
//      said "fill 0-3 ... empty if none" — which invites the model to always
//      find a fit).
//   2. When the user DID ask, it couldn't do JUST alternates well, and another
//      prompt section literally told the model to REFUSE and point to the editor.
//
// Confirmed target (Kuru): NEVER auto-generate; ONLY when the user explicitly
// asks (conversationally, like edit-card mode); each greeting a DIFFERENT
// SITUATION; default empty.
//
// These tests lock the build-prompt contract: the alternate_greetings guidance
// the model receives must be (a) conditional on an explicit user request, with
// an empty-array default, and (b) require each greeting to be a DIFFERENT
// situation/scenario — not a restyle of first_mes.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_build_prompts.dart';
import 'package:pyre/services/creator_schema.dart';

String _greetingsGuidance(CreatorMode mode) {
  final turns = buildBatchTurns(
    mode: mode,
    batchKeys: const ['alternate_greetings'],
    transcript: const [],
  );
  return turns.map((t) => t.content).join('\n').toLowerCase();
}

void main() {
  // Distinctive phrases that appear ONLY in the alternate_greetings guidance —
  // chosen so they can't spuriously match the sheet's section list (which
  // contains the word "Scenario") or the generic "filling ONLY:" line.
  group('alternate_greetings build prompt is request-conditional', () {
    for (final mode in [CreatorMode.character, CreatorMode.scenario]) {
      test('[$mode] only generates when the user EXPLICITLY ASKED', () {
        final g = _greetingsGuidance(mode);
        expect(g.contains('explicitly asked') || g.contains('explicitly requested'),
            isTrue,
            reason: 'guidance must gate generation behind an explicit request');
      });

      test('[$mode] defaults to an empty array when not asked', () {
        final g = _greetingsGuidance(mode);
        expect(g.contains('empty array'), isTrue,
            reason: 'default (no request) must be an empty array');
      });

      test('[$mode] requires each greeting to be a DIFFERENT situation', () {
        final g = _greetingsGuidance(mode);
        expect(g.contains('different situation'), isTrue,
            reason: 'each alternate must be a distinct situation, not a '
                'restyle of first_mes');
      });

      // Regression guard (verifier V1/V4): the FIELD guidance and the JSON
      // shape hint are BOTH emitted in the request. Neither may carry the old
      // generate-framing ("0-3 ... empty list if none fit") that invited the
      // model to invent greetings on every build — otherwise it contradicts the
      // explicit-ask-only rule on the same request.
      test('[$mode] carries NO unconditional generate-framing', () {
        final g = _greetingsGuidance(mode);
        expect(g.contains('0-3'), isFalse,
            reason: 'no "0-3" count-framing (invites unsolicited generation)');
        expect(g.contains('if none fit'), isFalse,
            reason: 'no "empty if none fit" framing (invites generation '
                '"whenever some fit")');
      });
    }
  });
}
