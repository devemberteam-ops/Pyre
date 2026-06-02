// Encrypted API-key sync crypto (Wave CY.18.257).
//
// The pairing bearer is the only secret both peers share: the client holds
// the raw bearer; the server stores sha256(utf8(bearer)) as hex
// (device_registry._hashBearer). Both can therefore compute the same 32-byte
// IKM = sha256(utf8(bearer)). We derive an AES-256-GCM key from it via
// HKDF-SHA256 with a domain-separation `info` so the derived key is NOT the
// stored bearer-hash (can't be replayed as an auth bearer).
//
// Envelope (stored in ApiProvider.apiKeyEnc): {"v":1,"n":<nonce b64>,"c":<ct+tag b64>}.
// All functions are best-effort: decrypt returns null on ANY failure, never throws.

import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

class KeyCrypto {
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static const _info = 'pyre-keysync-v1';

  /// 32-byte IKM from a raw bearer = sha256(utf8(bearer)).
  static List<int> _ikmFromBearer(String bearer) =>
      crypto.sha256.convert(utf8.encode(bearer)).bytes;

  /// 32-byte IKM from the server's stored hex bearer-hash.
  static List<int> _ikmFromHashHex(String hashHex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hashHex.length; i += 2) {
      out.add(int.parse(hashHex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  static Future<SecretKey> _derive(List<int> ikm) => _hkdf.deriveKey(
        secretKey: SecretKey(ikm),
        info: utf8.encode(_info),
        nonce: const <int>[], // salt empty by design (see spec)
      );

  /// Client path: secret from the raw bearer.
  static Future<SecretKey> secretForBearer(String bearer) =>
      _derive(_ikmFromBearer(bearer));

  /// Server path: secret from the stored hex bearer-hash.
  static Future<SecretKey> secretForBearerHashHex(String hashHex) =>
      _derive(_ikmFromHashHex(hashHex));

  /// Test hook: the hex the server would have stored for this bearer.
  static String debugBearerHashHex(String bearer) =>
      crypto.sha256.convert(utf8.encode(bearer)).toString();

  static Future<String> encryptApiKey(String plaintext, SecretKey secret) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(utf8.encode(plaintext),
        secretKey: secret, nonce: nonce);
    // concat ciphertext + mac so decode is a single field
    final ct = <int>[...box.cipherText, ...box.mac.bytes];
    return jsonEncode({
      'v': 1,
      'n': base64Url.encode(nonce),
      'c': base64Url.encode(ct),
    });
  }

  /// Returns the plaintext key, or null on any failure (bad json, wrong
  /// version, wrong key, tampering).
  static Future<String?> decryptApiKey(String envelope, SecretKey secret) async {
    try {
      final j = jsonDecode(envelope);
      if (j is! Map || j['v'] != 1) return null;
      final nonce = base64Url.decode(j['n'] as String);
      final raw = base64Url.decode(j['c'] as String);
      if (raw.length < 16) return null;
      final macBytes = raw.sublist(raw.length - 16);
      final ct = raw.sublist(0, raw.length - 16);
      final box = SecretBox(ct, nonce: nonce, mac: Mac(macBytes));
      final clear = await _aes.decrypt(box, secretKey: secret);
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }
}
