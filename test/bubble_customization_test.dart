@TestOn('vm')
library;

// Customization audit follow-up (2026-07-15, owner-approved features):
// per-character bubble tint + bubble font family — model-side pins.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Character.bubbleColor round-trips and omits at default', () {
    final c = Character(
        id: 'c', name: 'Sera', description: 'd', createdAt: 0, updatedAt: 0,
        bubbleColor: 0xFF1A2230);
    final back = Character.fromJson(c.toJson());
    expect(back.bubbleColor, 0xFF1A2230);
    final plain = Character(
        id: 'p', name: 'Ren', description: 'd', createdAt: 0, updatedAt: 0);
    expect(plain.toJson().containsKey('bubbleColor'), isFalse,
        reason: 'existing cards stay byte-identical');
    // The editor round-trips via fromJson(toJson()) — the tint must survive.
    expect(Character.fromJson(plain.toJson()).bubbleColor, isNull);
  });
}
