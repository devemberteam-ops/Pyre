import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/key_crypto.dart';

void main() {
  group('key_crypto', () {
    const bearer = 'abc123_DEF-456';
    test('round-trips a key', () async {
      final s = await KeyCrypto.secretForBearer(bearer);
      final env = await KeyCrypto.encryptApiKey('sk-live-XYZ', s);
      expect(env, isNotEmpty);
      expect(env.contains('sk-live-XYZ'), isFalse); // ciphertext, not plaintext
      final out = await KeyCrypto.decryptApiKey(env, s);
      expect(out, 'sk-live-XYZ');
    });
    test('nonce is unique per call', () async {
      final s = await KeyCrypto.secretForBearer(bearer);
      final a = await KeyCrypto.encryptApiKey('k', s);
      final b = await KeyCrypto.encryptApiKey('k', s);
      expect(a, isNot(equals(b)));
    });
    test('wrong bearer cannot decrypt', () async {
      final s1 = await KeyCrypto.secretForBearer(bearer);
      final s2 = await KeyCrypto.secretForBearer('different-bearer');
      final env = await KeyCrypto.encryptApiKey('k', s1);
      expect(await KeyCrypto.decryptApiKey(env, s2), isNull);
    });
    test('tampered ciphertext fails (GCM auth)', () async {
      final s = await KeyCrypto.secretForBearer(bearer);
      final env = await KeyCrypto.encryptApiKey('hello', s);
      final tampered = env.replaceRange(env.length - 6, env.length - 4, 'AA');
      expect(await KeyCrypto.decryptApiKey(tampered, s), isNull);
    });
    test('malformed envelope returns null, never throws', () async {
      final s = await KeyCrypto.secretForBearer(bearer);
      expect(await KeyCrypto.decryptApiKey('not json', s), isNull);
      expect(await KeyCrypto.decryptApiKey('{"v":2}', s), isNull);
    });
    test('server-side hex IKM matches client raw-bearer IKM', () async {
      // device_registry stores sha256(utf8(bearer)) as hex. The server
      // path derives from that hex; both must yield the same secret.
      final fromBearer = await KeyCrypto.secretForBearer(bearer);
      final hex = KeyCrypto.debugBearerHashHex(bearer);
      final fromHex = await KeyCrypto.secretForBearerHashHex(hex);
      final env = await KeyCrypto.encryptApiKey('match', fromBearer);
      expect(await KeyCrypto.decryptApiKey(env, fromHex), 'match');
    });
  });
}
