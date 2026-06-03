import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/dev_flavor.dart';

void main() {
  group('pyreDataDirNameFor', () {
    test('production (dev=false) keeps the exact legacy EmberChat path', () {
      // CRITICAL: protects the production user's real on-disk data dir.
      expect(pyreDataDirNameFor(false), 'EmberChat');
    });

    test('dev (dev=true) uses a fully separate EmberChat-dev folder', () {
      expect(pyreDataDirNameFor(true), 'EmberChat-dev');
    });
  });
}
