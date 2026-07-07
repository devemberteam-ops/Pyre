// 2026-07-07 (Gui): pure-image picks route through image_pick.dart so phones
// get the native gallery. The picker calls themselves are platform channels
// (not unit-testable here), but PickedImage's derived fields are pure.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/image_pick.dart';

void main() {
  group('PickedImage.ext', () {
    PickedImage p(String name) =>
        PickedImage(name: name, bytes: Uint8List(0));

    test('parses the lowercase extension', () {
      expect(p('photo.PNG').ext, 'png');
      expect(p('a.b.jpeg').ext, 'jpeg');
    });

    test('empty when there is no dot', () {
      expect(p('noextension').ext, '');
    });
  });
}
