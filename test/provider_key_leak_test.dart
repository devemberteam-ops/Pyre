@TestOn('vm')
library;

// Security (audit round 16 + Codex review): the API key saved for one provider
// host must NEVER be transmitted to a DIFFERENT (or unverifiable) host. All three
// editor egress points — Test connection, Browse models, Save — gate on
// `providerKeyStaleForChangedHost`, which FAILS CLOSED. These unit tests pin the
// predicate + its origin comparison, incl. the fail-closed bypass cases Codex
// found and the honest "same key stays blocked" semantics.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/api_connections_screen.dart';

ApiProvider _prov({
  String baseUrl = 'https://api.openai.com/v1',
  String apiKey = 'sk-secret',
}) =>
    ApiProvider(id: 'p1', name: 'P', baseUrl: baseUrl, apiKey: apiKey, model: 'm');

void main() {
  group('sameHttpOrigin', () {
    test('same origin, path/query differences still match', () {
      expect(
          sameHttpOrigin(
              'https://api.openai.com/v1', 'https://api.openai.com/v1/'),
          isTrue);
      expect(
          sameHttpOrigin(
              'https://api.openai.com/v1', 'https://api.openai.com/v2?x=1'),
          isTrue);
    });
    test('scheme default port matches an explicit default port', () {
      expect(sameHttpOrigin('https://a.com', 'https://a.com:443'), isTrue);
      expect(sameHttpOrigin('http://a.com', 'http://a.com:80'), isTrue);
    });
    test('different host / scheme / port do NOT match', () {
      expect(sameHttpOrigin('https://api.openai.com', 'https://evil.example.com'),
          isFalse);
      expect(sameHttpOrigin('https://a.com', 'http://a.com'), isFalse);
      expect(sameHttpOrigin('https://a.com', 'https://a.com:8443'), isFalse);
    });
    test('userinfo does not mask the effective host', () {
      // `https://api.good.com@evil.com` has host=evil.com — must NOT match the
      // real api.good.com origin (classic credential-phish shape).
      expect(
          sameHttpOrigin(
              'https://api.good.com', 'https://api.good.com@evil.com'),
          isFalse);
    });
    test('non-http(s) scheme, host-less, and unparseable all fail closed', () {
      expect(sameHttpOrigin('https://a.com', 'ftp://a.com'), isFalse);
      expect(sameHttpOrigin('file:///x', 'file:///x'), isFalse);
      expect(sameHttpOrigin('https://a.com', 'a.com'), isFalse);
      expect(sameHttpOrigin('https://a.com', 'not a url'), isFalse);
    });
  });

  group('providerKeyStaleForChangedHost (fail-closed leak guard)', () {
    test('LEAK: editing, host changed, key still the stored one → blocked', () {
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(
              baseUrl: 'https://api.openai.com/v1', apiKey: 'sk-secret'),
          currentUrl: 'https://evil.example.com/v1',
          currentKey: 'sk-secret',
        ),
        isTrue,
      );
    });
    test('same key RE-PASTED to a new host stays blocked (honest copy)', () {
      // Deleting + pasting the SAME key does not unblock — the field value is
      // still the stored key. Copy must say "enter a DIFFERENT key or clear it".
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(apiKey: 'sk-secret'),
          currentUrl: 'https://evil.example.com',
          currentKey: '  sk-secret  ', // re-pasted, whitespace-trimmed equal
        ),
        isTrue,
      );
    });
    test('a genuinely different key for the new host is allowed', () {
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(apiKey: 'sk-secret'),
          currentUrl: 'https://evil.example.com/v1',
          currentKey: 'sk-brand-new',
        ),
        isFalse,
      );
    });
    test('same origin (path-only change), key unchanged → allowed', () {
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(
              baseUrl: 'https://api.openai.com/v1', apiKey: 'sk-secret'),
          currentUrl: 'https://api.openai.com/v2',
          currentKey: 'sk-secret',
        ),
        isFalse,
      );
    });
    test('byte-unchanged URL never false-blocks a no-op edit (odd stored URL)',
        () {
      // A legit provider whose stored URL is not a clean http(s) origin must
      // still be editable when the URL itself is untouched.
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(baseUrl: 'localhost:1234', apiKey: 'sk-secret'),
          currentUrl: 'localhost:1234',
          currentKey: 'sk-secret',
        ),
        isFalse,
      );
    });
    test('FAIL-CLOSED step 1: changing host to a malformed URL is blocked', () {
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(baseUrl: 'https://api.good.com', apiKey: 'sk-secret'),
          currentUrl: 'garbage-no-host',
          currentKey: 'sk-secret',
        ),
        isTrue,
      );
    });
    test('FAIL-CLOSED step 2: stored origin unverifiable + host change blocked',
        () {
      // Even if a malformed URL somehow got stored, changing to evil.com with the
      // inherited key must still be blocked (the two-step bypass Codex found).
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(baseUrl: 'garbage-no-host', apiKey: 'sk-secret'),
          currentUrl: 'https://evil.example.com',
          currentKey: 'sk-secret',
        ),
        isTrue,
      );
    });
    test('new provider (no existing) → allowed', () {
      expect(
        providerKeyStaleForChangedHost(
          existing: null,
          currentUrl: 'https://evil.example.com',
          currentKey: 'sk-x',
        ),
        isFalse,
      );
    });
    test('existing with no stored key → allowed (nothing to leak)', () {
      expect(
        providerKeyStaleForChangedHost(
          existing: _prov(apiKey: ''),
          currentUrl: 'https://evil.example.com',
          currentKey: '',
        ),
        isFalse,
      );
    });
  });
}
