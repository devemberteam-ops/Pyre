import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/services/device_registry.dart';
import 'package:pyre/services/pyre_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('markNative — legacy isNative self-heal (Item 3 / Finding 2)', () {
    test('flips a legacy non-native device to native and is idempotent',
        () async {
      // A device paired before the native flag existed migrates to false.
      final legacy = PairedDevice(
        id: 'legacy-1',
        name: 'Old phone',
        bearerHash: 'e' * 64,
        pairedAt: 1,
        lastSeen: 1,
        // isNative defaults to false.
      );
      expect(legacy.isNative, isFalse);
      // Before the heal the provider gate excludes it even with the host
      // opted in — exactly the reported "keys not syncing" trap.
      expect(shouldSyncProviders(true, legacy.isNative), isFalse);

      // The header-driven heal flips the flag (persist failure in the test
      // env is swallowed by _save's try/catch; the in-memory flag still flips).
      final changed = await DeviceRegistry.instance.markNative(legacy);
      expect(changed, isTrue);
      expect(legacy.isNative, isTrue);
      // Now the gate passes — the legacy device receives keys.
      expect(shouldSyncProviders(true, legacy.isNative), isTrue);

      // Idempotent: a second call is a no-op (already native).
      final again = await DeviceRegistry.instance.markNative(legacy);
      expect(again, isFalse);
      expect(legacy.isNative, isTrue);
    });

    test('already-native device is never re-saved (returns false)', () async {
      final native = PairedDevice(
        id: 'native-1',
        name: 'New phone',
        bearerHash: 'f' * 64,
        pairedAt: 1,
        lastSeen: 1,
        isNative: true,
      );
      expect(await DeviceRegistry.instance.markNative(native), isFalse);
      expect(native.isNative, isTrue);
    });
  });

  group('PairedDevice — isNative round-trip (Wave CY.18.259)', () {
    test('isNative round-trips through toJson/fromJson', () {
      final d = PairedDevice(
        id: 'dev-1',
        name: 'Phone',
        bearerHash: 'a' * 64,
        pairedAt: 100,
        lastSeen: 200,
        isNative: true,
      );
      final json = d.toJson();
      expect(json['isNative'], isTrue);
      final back = PairedDevice.fromJson(json);
      expect(back.isNative, isTrue);
    });

    test('isNative=false is omitted from toJson (conditional write)', () {
      final d = PairedDevice(
        id: 'dev-2',
        name: 'Web',
        bearerHash: 'b' * 64,
        pairedAt: 100,
        lastSeen: 200,
        // isNative defaults to false
      );
      final json = d.toJson();
      expect(json.containsKey('isNative'), isFalse);
      final back = PairedDevice.fromJson(json);
      expect(back.isNative, isFalse);
    });

    test('JSON WITHOUT isNative decodes to false (fail-closed)', () {
      // Simulates an old-format record (pre-Wave-259) with no isNative key.
      final legacy = <String, dynamic>{
        'id': 'dev-3',
        'name': 'Legacy device',
        'bearerHash': 'c' * 64,
        'pairedAt': 100,
        'lastSeen': 200,
      };
      final back = PairedDevice.fromJson(legacy);
      expect(back.isNative, isFalse);
    });

    test('default constructor leaves isNative false', () {
      final d = PairedDevice(
        id: 'dev-4',
        name: 'Default',
        bearerHash: 'd' * 64,
        pairedAt: 1,
        lastSeen: 1,
      );
      expect(d.isNative, isFalse);
    });
  });
}
