// Wave CY.18.265: ModelSettings.creatorDescriptionSize round-trip + defaults.
// The desired Creator Description size persists as the enum NAME, defaults to
// `standard` (the original ~5,000-token behaviour), and is omitted from JSON
// when standard so untouched setups serialise byte-identically to before.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/creator_schema.dart';

void main() {
  group('ModelSettings.creatorDescriptionSize', () {
    test('defaults to standard', () {
      expect(ModelSettings().creatorDescriptionSize,
          CreatorDescriptionSize.standard);
    });

    test('standard is OMITTED from toJson (byte-identical legacy backups)', () {
      final json = ModelSettings().toJson();
      expect(json.containsKey('creatorDescriptionSize'), isFalse);
    });

    test('a non-default size is emitted as its enum name + round-trips', () {
      final ms = ModelSettings()
        ..creatorDescriptionSize = CreatorDescriptionSize.detailed;
      final json = ms.toJson();
      expect(json['creatorDescriptionSize'], 'detailed');

      final back = ModelSettings.fromJson(json);
      expect(back.creatorDescriptionSize, CreatorDescriptionSize.detailed);
    });

    test('every size value round-trips through JSON', () {
      for (final size in CreatorDescriptionSize.values) {
        final ms = ModelSettings()..creatorDescriptionSize = size;
        final back = ModelSettings.fromJson(ms.toJson());
        expect(back.creatorDescriptionSize, size, reason: 'failed for $size');
      }
    });

    test('copy() preserves the chosen size', () {
      final ms = ModelSettings()
        ..creatorDescriptionSize = CreatorDescriptionSize.veryDetailed;
      expect(ms.copy().creatorDescriptionSize,
          CreatorDescriptionSize.veryDetailed);
    });

    test('unknown / legacy value fails closed to standard', () {
      final back = ModelSettings.fromJson({'creatorDescriptionSize': 'huge'});
      expect(back.creatorDescriptionSize, CreatorDescriptionSize.standard);
      final missing = ModelSettings.fromJson({});
      expect(missing.creatorDescriptionSize, CreatorDescriptionSize.standard);
    });
  });
}
