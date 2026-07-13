@TestOn('vm')
library;

// Background generation (2026-07-13, owner: "find another way to keep the app
// alive in background"). Chat replies are LIGHT keepalive calls, which were
// deliberate no-ops for the foreground service (Wave CY.18.35) — so Android
// killed them off-focus. `promoteAllToHeavy` (driven by
// UiPrefs.backgroundGeneration, default ON) promotes light calls to the
// service. These pin the refcount bookkeeping: promotion, symmetric drain,
// and toggle-mid-stream balance. (The plugin itself never runs in VM tests —
// the platform gate bails — so the refcounts ARE the observable behaviour.)

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/generation_keepalive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(GenerationKeepAlive.resetForTest);
  tearDown(GenerationKeepAlive.resetForTest);

  test('promotion OFF: light start/stop never touch the heavy count', () async {
    await GenerationKeepAlive.start(); // light
    expect(GenerationKeepAlive.heavyRefsForTest, 0);
    await GenerationKeepAlive.stop();
    expect(GenerationKeepAlive.heavyRefsForTest, 0);
  });

  test('promotion ON: light calls ride the service and drain symmetrically',
      () async {
    GenerationKeepAlive.promoteAllToHeavy = true;
    await GenerationKeepAlive.start(); // promoted chat reply
    expect(GenerationKeepAlive.heavyRefsForTest, 1);
    await GenerationKeepAlive.start(heavy: true); // creator cascade
    expect(GenerationKeepAlive.heavyRefsForTest, 2);
    await GenerationKeepAlive.stop(); // light stop drains the promoted ref
    expect(GenerationKeepAlive.heavyRefsForTest, 1);
    await GenerationKeepAlive.stop(heavy: true);
    expect(GenerationKeepAlive.heavyRefsForTest, 0);
  });

  test('toggling OFF mid-stream still balances back to zero', () async {
    GenerationKeepAlive.promoteAllToHeavy = true;
    await GenerationKeepAlive.start(); // promoted
    GenerationKeepAlive.promoteAllToHeavy = false; // user flips it mid-reply
    await GenerationKeepAlive.stop(); // drains the outstanding promoted ref
    expect(GenerationKeepAlive.heavyRefsForTest, 0);
    // And a light pair AFTER the flip is a plain no-op again.
    await GenerationKeepAlive.start();
    expect(GenerationKeepAlive.heavyRefsForTest, 0);
    await GenerationKeepAlive.stop();
    expect(GenerationKeepAlive.heavyRefsForTest, 0);
  });

  test('toggling ON mid-stream cannot underflow the heavy count', () async {
    await GenerationKeepAlive.start(); // light, NOT promoted
    GenerationKeepAlive.promoteAllToHeavy = true; // flipped mid-reply
    await GenerationKeepAlive.stop(); // no promoted ref outstanding → no-op
    expect(GenerationKeepAlive.heavyRefsForTest, 0);
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
