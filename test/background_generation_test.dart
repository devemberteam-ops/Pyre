@TestOn('vm')
library;

// Background generation (2026-07-13, owner request; REDESIGNED 2026-07-15
// after Codex review). The service state is DERIVED — desired ⟺ heavyRefs>0
// OR (backgroundGeneration && lightRefs>0) — instead of a promoted-refs
// ledger, which mismatched under mixed cohorts (a light started before the
// toggle and one after: the unpromoted stop drained the promoted ref and
// killed the service mid-stream). These pin the derived semantics, including
// Codex's exact interleaving. (The plugin never runs in VM tests — the
// platform gate bails — so `serviceDesiredForTest` is the observable.)

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/generation_keepalive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(GenerationKeepAlive.resetForTest);
  tearDown(GenerationKeepAlive.resetForTest);

  test('setting OFF: light streams never want the service', () async {
    await GenerationKeepAlive.start(); // light
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
    await GenerationKeepAlive.stop();
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
  });

  test('heavy streams want the service regardless of the setting', () async {
    await GenerationKeepAlive.start(heavy: true);
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue);
    await GenerationKeepAlive.stop(heavy: true);
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
  });

  test('setting ON: light streams hold the service; symmetric release',
      () async {
    GenerationKeepAlive.promoteAllToHeavy = true;
    await GenerationKeepAlive.start(); // chat reply
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue);
    await GenerationKeepAlive.start(heavy: true); // creator cascade
    await GenerationKeepAlive.stop(); // chat reply done
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue,
        reason: 'the heavy cascade still holds it');
    await GenerationKeepAlive.stop(heavy: true);
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
  });

  test('Codex interleaving: mixed cohorts cannot kill a protected stream',
      () async {
    // 1. Light A starts with the toggle OFF (not protected).
    await GenerationKeepAlive.start();
    // 2. Toggle ON. 3. Light B starts (protected).
    GenerationKeepAlive.promoteAllToHeavy = true;
    await GenerationKeepAlive.start();
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue);
    // 4. A finishes FIRST. Old ledger design: A's stop drained B's promoted
    // ref and stopped the service while B was still generating.
    await GenerationKeepAlive.stop();
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue,
        reason: 'B is still in flight and the setting is ON — the service '
            'must survive A\'s stop');
    await GenerationKeepAlive.stop();
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
  });

  test('toggling mid-stream takes effect on the CURRENT generation', () async {
    GenerationKeepAlive.promoteAllToHeavy = true;
    await GenerationKeepAlive.start(); // protected light
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue);
    // User turns the setting OFF mid-reply: the protection drops NOW —
    // coherent with what they just asked for (documented behaviour).
    GenerationKeepAlive.promoteAllToHeavy = false;
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
    // And back ON: the in-flight reply regains it.
    GenerationKeepAlive.promoteAllToHeavy = true;
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue);
    await GenerationKeepAlive.stop();
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
  });

  test('double-stop cannot underflow into a stuck state', () async {
    GenerationKeepAlive.promoteAllToHeavy = true;
    await GenerationKeepAlive.start();
    await GenerationKeepAlive.stop();
    await GenerationKeepAlive.stop(); // buggy extra stop — guarded
    await GenerationKeepAlive.start();
    expect(GenerationKeepAlive.serviceDesiredForTest, isTrue,
        reason: 'refs must not have gone negative');
    await GenerationKeepAlive.stop();
    expect(GenerationKeepAlive.serviceDesiredForTest, isFalse);
  });

  test('UiPrefs.backgroundGeneration defaults ON and round-trips', () {
    final fresh = UiPrefs.fromJson(const {});
    expect(fresh.backgroundGeneration, isTrue,
        reason: 'default ON — losing replies to backgrounding is the worse '
            'default; the notification is silent');
    expect(fresh.toJson().containsKey('backgroundGeneration'), isFalse,
        reason: 'default is omitted from the blob (byte-clean)');
    fresh.backgroundGeneration = false;
    expect(UiPrefs.fromJson(fresh.toJson()).backgroundGeneration, isFalse);
  });
}
