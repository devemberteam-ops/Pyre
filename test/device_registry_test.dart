import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/services/device_registry.dart';

void main() {
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
