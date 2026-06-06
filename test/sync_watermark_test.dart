import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/sync_engine.dart';

// SYNC W1: the sync watermark (sync.lastServerTime) is a per-server cursor, but
// it was stored globally and survived a re-pair. After a factory-reset PC
// (a brand-new, empty server) the phone still thought it was "caught up" and
// only pushed records newer than the old cursor — so only some cards/chats/
// presets came over. The watermark must reset to 0 whenever we're paired to a
// DIFFERENT server identity than the cursor was built against.
void main() {
  group('syncWatermarkMustReset', () {
    test('different server id → reset (re-pair / factory-reset server)', () {
      expect(syncWatermarkMustReset('dev-NEW', 'dev-OLD'), isTrue);
    });

    test('same server id → keep the watermark', () {
      expect(syncWatermarkMustReset('dev-SAME', 'dev-SAME'), isFalse);
    });

    test('no stored id yet (first ever pair) → reset (harmless, since is 0)',
        () {
      expect(syncWatermarkMustReset('dev-NEW', null), isTrue);
    });

    test('not paired / unknown current id → do NOT touch the watermark', () {
      expect(syncWatermarkMustReset(null, 'dev-OLD'), isFalse);
      expect(syncWatermarkMustReset(null, null), isFalse);
    });
  });
}
