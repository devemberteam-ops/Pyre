// 2026-07-03 (Gui): build COST GUARDRAIL. The structured build is the most
// expensive thing the app does (multi-pass, worst case dozens of LLM calls).
// The old cascade had an `exhausted` flag that stopped automatic re-fires
// after a failure; the deterministic-build rewrite dropped it. This re-adds
// the protection as a per-session persisted flag on the canvas:
//   - a FAILED build sets the flag;
//   - while set, the [[BUILD_SHEET]] marker must NOT auto-fire (a Retry of
//     the old marker reply, or a re-stream on reopen, would silently re-burn
//     the whole build against a provider that is probably still broken);
//   - a NEW real user message clears it (fresh intent = fresh consent — the
//     architect's next marker fires normally);
//   - manual /build always runs (deliberate) and a successful build clears it.
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/creator_cascade.dart';

void main() {
  group('creator build-failed flag (canvas persisted)', () {
    test('absent key → not failed', () {
      expect(creatorLastBuildFailed(<String, dynamic>{}), isFalse);
      expect(creatorLastBuildFailed({'name': 'Vael'}), isFalse);
    });

    test('junk values are not treated as failed', () {
      expect(
        creatorLastBuildFailed({kCanvasBuildFailedKey: 'yes'}),
        isFalse,
      );
      expect(creatorLastBuildFailed({kCanvasBuildFailedKey: 1}), isFalse);
      expect(creatorLastBuildFailed({kCanvasBuildFailedKey: null}), isFalse);
    });

    test('set → failed; clear → key removed (not just false)', () {
      final set = withCreatorLastBuildFailed({'name': 'Vael'}, true);
      expect(creatorLastBuildFailed(set), isTrue);
      expect(set['name'], 'Vael');

      final cleared = withCreatorLastBuildFailed(set, false);
      expect(creatorLastBuildFailed(cleared), isFalse);
      // Removed, not written as false — the canvas is exported/synced and
      // shouldn't accumulate stale internal keys.
      expect(cleared.containsKey(kCanvasBuildFailedKey), isFalse);
      expect(cleared['name'], 'Vael');
    });

    test('does not mutate the input map', () {
      final original = <String, dynamic>{'name': 'Vael'};
      withCreatorLastBuildFailed(original, true);
      expect(original.containsKey(kCanvasBuildFailedKey), isFalse);
    });
  });

  group('marker auto-fire gate', () {
    test('fires when the last build did not fail', () {
      expect(
        shouldMarkerAutoFireBuild(lastBuildFailed: false),
        isTrue,
      );
    });

    test('blocked while the failed flag is set', () {
      expect(
        shouldMarkerAutoFireBuild(lastBuildFailed: true),
        isFalse,
      );
    });
  });
}
