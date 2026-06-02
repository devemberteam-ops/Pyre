// Wave CY.18.261: unit tests for the CLIENT-side provider sync apply logic.
//
// The decrypt-and-parse step is factored into the pure top-level helper
// `decodeIncomingProvider` (lib/services/sync_engine.dart) so it can be
// exercised without a live peer / SecureKeys / AppStore. These tests cover:
//   - a valid envelope round-trips: config parses + key decrypts
//   - absent apiKeyEnc → key null, config intact
//   - garbled apiKeyEnc → key null, config intact (never throws, never wipes)
//   - the LWW predicate the apply uses (older incoming mtime is ignorable)

import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/models/models.dart';
import 'package:pyre/services/key_crypto.dart';
import 'package:pyre/services/sync_engine.dart';

void main() {
  group('decodeIncomingProvider (client provider-sync apply)', () {
    const bearer = 'pair-bearer-XYZ_123';

    test('valid envelope: config parses and key decrypts', () async {
      final secret = await KeyCrypto.secretForBearer(bearer);
      // Build the wire record exactly as a peer would: toJsonEncrypted with
      // the SAME secret both peers derive from the shared bearer.
      final source = ApiProvider(
        id: 'prov-1',
        name: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'sk-live-SECRET-42',
        model: 'anthropic/claude',
        mtime: 100,
      );
      final wire = await source.toJsonEncrypted(secret);
      // The plaintext key must never be on the wire — only the envelope.
      expect(wire.containsKey('apiKey'), isFalse);
      expect(wire['apiKeyEnc'], isNotNull);

      final (provider, key) = await decodeIncomingProvider(wire, secret);
      // Config landed.
      expect(provider.id, 'prov-1');
      expect(provider.name, 'OpenRouter');
      expect(provider.baseUrl, 'https://openrouter.ai/api/v1');
      expect(provider.model, 'anthropic/claude');
      expect(provider.mtime, 100);
      // Key decrypted out-of-band (helper never touches the provider.apiKey
      // field — the caller decides whether to adopt it).
      expect(key, 'sk-live-SECRET-42');
      expect(provider.apiKey, isEmpty);
    });

    test('absent apiKeyEnc: key null, config intact', () async {
      final secret = await KeyCrypto.secretForBearer(bearer);
      // An empty-keyed provider emits no apiKeyEnc field at all.
      final source = ApiProvider(
        id: 'prov-2',
        name: 'Local LM Studio',
        baseUrl: 'http://localhost:1234/v1',
        apiKey: '',
        mtime: 5,
      );
      final wire = await source.toJsonEncrypted(secret);
      expect(wire.containsKey('apiKeyEnc'), isFalse);

      final (provider, key) = await decodeIncomingProvider(wire, secret);
      expect(key, isNull);
      expect(provider.id, 'prov-2');
      expect(provider.name, 'Local LM Studio');
      expect(provider.baseUrl, 'http://localhost:1234/v1');
      expect(provider.mtime, 5);
    });

    test('garbled apiKeyEnc: key null, config intact (never throws)',
        () async {
      final secret = await KeyCrypto.secretForBearer(bearer);
      // A record whose envelope is junk (not even JSON) — decryptApiKey
      // returns null, the helper hands back a null key and the parsed config.
      final wire = <String, dynamic>{
        'id': 'prov-3',
        'name': 'Tampered',
        'baseUrl': 'https://example.com/v1',
        'model': 'x',
        'mtime': 7,
        'apiKeyEnc': 'this is not a valid envelope',
      };

      final (provider, key) = await decodeIncomingProvider(wire, secret);
      expect(key, isNull);
      expect(provider.id, 'prov-3');
      expect(provider.name, 'Tampered');
      expect(provider.baseUrl, 'https://example.com/v1');
      expect(provider.mtime, 7);
    });

    test('wrong-secret envelope: key null, config intact', () async {
      final mine = await KeyCrypto.secretForBearer(bearer);
      final theirs = await KeyCrypto.secretForBearer('a-different-bearer');
      final source = ApiProvider(
        id: 'prov-4',
        name: 'CrossPeer',
        apiKey: 'sk-cannot-read',
        mtime: 9,
      );
      // Encrypted with a DIFFERENT secret than the one we decode with.
      final wire = await source.toJsonEncrypted(theirs);
      expect(wire['apiKeyEnc'], isNotNull);

      final (provider, key) = await decodeIncomingProvider(wire, mine);
      expect(key, isNull); // GCM auth fails → null, never a garbage string
      expect(provider.id, 'prov-4');
      expect(provider.name, 'CrossPeer');
      expect(provider.mtime, 9);
    });

    test('LWW predicate: an existing record at/after incoming mtime is '
        'ignorable', () {
      // This is the exact gate the apply loop uses to decide whether to skip
      // an incoming provider record:
      //   idx >= 0 && store.providers[idx].mtime >= incomingMtime  → skip
      bool isIgnorable(int existingMtime, int incomingMtime) =>
          existingMtime >= incomingMtime;

      // Older incoming loses (skip).
      expect(isIgnorable(100, 50), isTrue);
      // Equal mtime loses (skip — first writer holds; no churn).
      expect(isIgnorable(100, 100), isTrue);
      // Newer incoming wins (apply).
      expect(isIgnorable(100, 200), isFalse);
    });
  });
}
