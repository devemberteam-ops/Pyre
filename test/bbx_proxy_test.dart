// Tests for the /bbx proxy pure helpers in lib/services/bbx_utils.dart.
//
// Covers v1 legacy helpers (retained) AND v2 new helpers:
//   - bbxHostLocked:                  host-lock guard (open-relay defence)
//   - rewriteBotbooruHtml:            LEGACY — same-origin /bbx/ prefix rewrite
//   - bbxIframeUrlToBotbooru:         LEGACY — iframe URL → botbooru URL
//   - botbooruUrlToBbxPath:           LEGACY — botbooru URL → /bbx/ proxy path
//   - bbxCorsOriginFor:               v2 — CORS origin gate (port==mainPort only)
//   - rewriteBotbooruHtmlDedicated:   v2 — dedicated-origin rewrite + shim
//   - bbxOriginUrlToBotbooru:         v2 — bbxOrigin URL → botbooru URL
//   - decodeBbxCardB64:               v3 — base64 card payload decoder (Download-PNG hook)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/bbx_utils.dart';

void main() {
  // -------------------------------------------------------------------------
  // bbxHostLocked
  // -------------------------------------------------------------------------
  group('bbxHostLocked — accepted', () {
    test('botbooru.com https is accepted', () {
      expect(
        bbxHostLocked(Uri.parse('https://botbooru.com/character/123')),
        isTrue,
      );
    });

    test('root path is accepted', () {
      expect(
        bbxHostLocked(Uri.parse('https://botbooru.com/')),
        isTrue,
      );
    });

    test('path with query string is accepted', () {
      expect(
        bbxHostLocked(
            Uri.parse('https://botbooru.com/search?q=test&page=2')),
        isTrue,
      );
    });
  });

  group('bbxHostLocked — rejected', () {
    test('www.botbooru.com is NOT accepted (exact host only)', () {
      expect(
        bbxHostLocked(Uri.parse('https://www.botbooru.com/character/1')),
        isFalse,
      );
    });

    test('evil.com is rejected', () {
      expect(
        bbxHostLocked(Uri.parse('https://evil.com/something')),
        isFalse,
      );
    });

    test('botbooru.com.evil.com is rejected (lookalike)', () {
      expect(
        bbxHostLocked(Uri.parse('https://botbooru.com.evil.com/')),
        isFalse,
      );
    });

    test('http (non-https) is rejected', () {
      expect(
        bbxHostLocked(Uri.parse('http://botbooru.com/character/123')),
        isFalse,
      );
    });

    test('empty host is rejected', () {
      expect(
        bbxHostLocked(Uri.parse('https:///character/123')),
        isFalse,
      );
    });

    test('file:// scheme is rejected', () {
      expect(
        bbxHostLocked(Uri.parse('file:///etc/passwd')),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // v2: bbxCorsOriginFor
  // -------------------------------------------------------------------------
  group('bbxCorsOriginFor — returns origin when port matches mainPort', () {
    test('exact match → returns the origin', () {
      expect(
        bbxCorsOriginFor('http://192.168.1.10:4848', 4848),
        equals('http://192.168.1.10:4848'),
      );
    });

    test('localhost with matching port → returns origin', () {
      expect(
        bbxCorsOriginFor('http://localhost:5000', 5000),
        equals('http://localhost:5000'),
      );
    });
  });

  group('bbxCorsOriginFor — returns null when port does NOT match', () {
    test('bbx port (mainPort+1) → null', () {
      // The bbx server itself must not grant itself CORS.
      expect(
        bbxCorsOriginFor('http://192.168.1.10:4849', 4848),
        isNull,
      );
    });

    test('completely different port → null', () {
      expect(
        bbxCorsOriginFor('http://192.168.1.10:9999', 4848),
        isNull,
      );
    });

    test('no explicit port in origin (defaults to 80/443) → null', () {
      // Uri.port returns 0 when no port is in the string;
      // we treat that as "unknown", not as mainPort.
      expect(
        bbxCorsOriginFor('http://192.168.1.10', 80),
        isNull,
      );
    });

    test('empty origin → null', () {
      expect(bbxCorsOriginFor('', 4848), isNull);
    });

    test('malformed origin → null', () {
      expect(bbxCorsOriginFor('not-a-uri', 4848), isNull);
    });

    test('never returns * — wrong port returns null, not wildcard', () {
      final result = bbxCorsOriginFor('http://evil.com:9999', 4848);
      expect(result, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // v2: rewriteBotbooruHtmlDedicated
  // -------------------------------------------------------------------------
  group('rewriteBotbooruHtmlDedicated — absolute URL rewrite', () {
    test('absolute https://botbooru.com/ is replaced with /', () {
      final out = rewriteBotbooruHtmlDedicated(
          '<a href="https://botbooru.com/character/1">x</a>');
      expect(out, contains('href="/character/1"'));
      expect(out, isNot(contains('https://botbooru.com/')));
    });

    test('root-relative /character/1 is NOT changed (already correct)', () {
      final out = rewriteBotbooruHtmlDedicated('<a href="/character/1">x</a>');
      // Should NOT add /bbx/ prefix (dedicated-mode never does)
      expect(out, contains('href="/character/1"'));
      expect(out, isNot(contains('/bbx/')));
    });

    test('does NOT add /bbx/ prefix anywhere', () {
      final out = rewriteBotbooruHtmlDedicated(
          '<html><head></head><body><img src="/img/x.png"></body></html>');
      expect(out, isNot(contains('/bbx/')));
    });
  });

  group('rewriteBotbooruHtmlDedicated — postMessage shim injection', () {
    test('shim is injected after <head>', () {
      const html = '<html><head><title>T</title></head><body></body></html>';
      final out = rewriteBotbooruHtmlDedicated(html);
      expect(out, contains('<head><script>'));
      expect(out, contains('pyre-bbx-loc'));
    });

    test('shim is prepended when there is no <head>', () {
      const html = '<div>hello</div>';
      final out = rewriteBotbooruHtmlDedicated(html);
      expect(out.trimLeft(), startsWith('<script>'));
      expect(out, contains('<div>hello</div>'));
    });

    test('shim sends pyre-bbx-loc on load', () {
      final out = rewriteBotbooruHtmlDedicated('<head></head>');
      expect(out, contains("type:'pyre-bbx-loc'"));
      expect(out, contains('location.href'));
    });

    test('shim listens for pyre-bbx-back to call history.back()', () {
      final out = rewriteBotbooruHtmlDedicated('<head></head>');
      expect(out, contains("type==='pyre-bbx-back'"));
      expect(out, contains('history.back()'));
    });

    test('shim patches history.pushState and replaceState', () {
      final out = rewriteBotbooruHtmlDedicated('<head></head>');
      expect(out, contains('history.pushState'));
      expect(out, contains('history.replaceState'));
    });

    test('shim uses JSON.stringify for the outbound message', () {
      final out = rewriteBotbooruHtmlDedicated('<head></head>');
      // Messages are JSON strings so Dart can parse them with plain jsonDecode.
      expect(out, contains('JSON.stringify'));
    });

    test('shim uses targetOrigin * for outbound postMessage (not a secret URL)', () {
      final out = rewriteBotbooruHtmlDedicated('<head></head>');
      // The outbound message uses '*' because href is not a secret
      // and the PARENT validates the sender origin.
      expect(out, contains("'*'"));
    });
  });

  // -------------------------------------------------------------------------
  // v2: bbxOriginUrlToBotbooru
  // -------------------------------------------------------------------------
  group('bbxOriginUrlToBotbooru — happy paths', () {
    const bbxOrigin = 'http://192.168.1.10:4849';

    test('character page maps correctly', () {
      final result = bbxOriginUrlToBotbooru(
        'http://192.168.1.10:4849/character/12345',
        bbxOrigin,
      );
      expect(result, equals('https://botbooru.com/character/12345'));
    });

    test('post page maps correctly', () {
      final result = bbxOriginUrlToBotbooru(
        'http://192.168.1.10:4849/post/99',
        bbxOrigin,
      );
      expect(result, equals('https://botbooru.com/post/99'));
    });

    test('lorebook page maps correctly', () {
      final result = bbxOriginUrlToBotbooru(
        'http://192.168.1.10:4849/lorebook/42',
        bbxOrigin,
      );
      expect(result, equals('https://botbooru.com/lorebook/42'));
    });

    test('path with query string is preserved', () {
      final result = bbxOriginUrlToBotbooru(
        'http://192.168.1.10:4849/search?q=elf&page=2',
        bbxOrigin,
      );
      expect(result, equals('https://botbooru.com/search?q=elf&page=2'));
    });

    test('bbxOrigin with trailing slash is normalised', () {
      final result = bbxOriginUrlToBotbooru(
        'http://192.168.1.10:4849/character/7',
        'http://192.168.1.10:4849/',
      );
      expect(result, equals('https://botbooru.com/character/7'));
    });
  });

  group('bbxOriginUrlToBotbooru — rejected / null', () {
    const bbxOrigin = 'http://192.168.1.10:4849';

    test('root (empty rest) returns null', () {
      final result = bbxOriginUrlToBotbooru(
        'http://192.168.1.10:4849/',
        bbxOrigin,
      );
      expect(result, isNull);
    });

    test('different host returns null', () {
      final result = bbxOriginUrlToBotbooru(
        'http://10.0.0.1:4849/character/1',
        bbxOrigin,
      );
      expect(result, isNull);
    });

    test('different port (main origin port, not bbx port) returns null', () {
      final result = bbxOriginUrlToBotbooru(
        'http://192.168.1.10:4848/character/1',
        bbxOrigin,
      );
      expect(result, isNull);
    });

    test('external botbooru URL (no bbxOrigin prefix) returns null', () {
      final result = bbxOriginUrlToBotbooru(
        'https://botbooru.com/character/1',
        bbxOrigin,
      );
      expect(result, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Security invariant: dedicated-mode rewrite does NOT use /bbx/ prefix
  // -------------------------------------------------------------------------
  group('Security: dedicated-mode vs legacy-mode rewrite are distinct', () {
    test('dedicated rewrite never produces /bbx/ in output', () {
      const html = '<html><head></head><body>'
          '<a href="/character/1">c</a>'
          '<img src="https://botbooru.com/img/x.png">'
          '</body></html>';
      final out = rewriteBotbooruHtmlDedicated(html);
      expect(out, isNot(contains('/bbx/')));
    });

    test('legacy rewrite produces /bbx/ prefix for root-relative URLs', () {
      // Legacy behaviour is unchanged — keep this as a regression guard.
      final out = rewriteBotbooruHtml('<a href="/character/1">c</a>');
      expect(out, contains('href="/bbx/character/1"'));
    });
  });

  // -------------------------------------------------------------------------
  // LEGACY: rewriteBotbooruHtml (v1 — retained, unchanged)
  // -------------------------------------------------------------------------
  group('rewriteBotbooruHtml — attribute rewrites', () {
    test('double-quoted href is rewritten', () {
      final out = rewriteBotbooruHtml('<a href="/character/1">x</a>');
      expect(out, contains('href="/bbx/character/1"'));
    });

    test('double-quoted src is rewritten', () {
      final out = rewriteBotbooruHtml('<img src="/images/x.png">');
      expect(out, contains('src="/bbx/images/x.png"'));
    });

    test('single-quoted href is rewritten', () {
      final out = rewriteBotbooruHtml("<a href='/page'>x</a>");
      expect(out, contains("href='/bbx/page'"));
    });

    test('single-quoted src is rewritten', () {
      final out = rewriteBotbooruHtml("<img src='/img/y.jpg'>");
      expect(out, contains("src='/bbx/img/y.jpg'"));
    });

    test('absolute href is NOT triple-rewritten', () {
      final out = rewriteBotbooruHtml('<a href="/bbx/character/1">x</a>');
      expect(out, isNot(contains('href="/bbx/bbx/bbx/')));
    });
  });

  group('rewriteBotbooruHtml — shim injection', () {
    test('shim is injected after <head>', () {
      const html = '<html><head><title>T</title></head><body></body></html>';
      final out = rewriteBotbooruHtml(html);
      expect(out, contains('<head><script>'));
      expect(out, contains("var P='/bbx/'"));
    });

    test('shim is prepended when there is no <head>', () {
      const html = '<div>hello</div>';
      final out = rewriteBotbooruHtml(html);
      expect(out.trimLeft(), startsWith('<script>'));
      expect(out, contains('<div>hello</div>'));
    });

    test('shim rewrites https://botbooru.com/ URLs at runtime', () {
      final out = rewriteBotbooruHtml('<head></head>');
      expect(out, contains("u.indexOf('https://botbooru.com/')===0"));
    });

    test('shim patches window.fetch', () {
      final out = rewriteBotbooruHtml('<head></head>');
      expect(out, contains('window.fetch=function'));
    });
  });

  // -------------------------------------------------------------------------
  // LEGACY: bbxIframeUrlToBotbooru (v1 — retained, unchanged)
  // -------------------------------------------------------------------------
  group('bbxIframeUrlToBotbooru — happy paths', () {
    const origin = 'http://192.168.1.10:4848';

    test('character page maps correctly', () {
      final result = bbxIframeUrlToBotbooru(
        'http://192.168.1.10:4848/bbx/character/12345',
        origin,
      );
      expect(result, equals('https://botbooru.com/character/12345'));
    });

    test('post page maps correctly', () {
      final result = bbxIframeUrlToBotbooru(
        'http://192.168.1.10:4848/bbx/post/99',
        origin,
      );
      expect(result, equals('https://botbooru.com/post/99'));
    });

    test('lorebook page maps correctly', () {
      final result = bbxIframeUrlToBotbooru(
        'http://192.168.1.10:4848/bbx/lorebook/42',
        origin,
      );
      expect(result, equals('https://botbooru.com/lorebook/42'));
    });

    test('path with query string is preserved', () {
      final result = bbxIframeUrlToBotbooru(
        'http://192.168.1.10:4848/bbx/search?q=elf&page=2',
        origin,
      );
      expect(result, equals('https://botbooru.com/search?q=elf&page=2'));
    });

    test('origin with trailing slash is normalised', () {
      final result = bbxIframeUrlToBotbooru(
        'http://192.168.1.10:4848/bbx/character/7',
        'http://192.168.1.10:4848/',
      );
      expect(result, equals('https://botbooru.com/character/7'));
    });
  });

  group('bbxIframeUrlToBotbooru — rejected / null', () {
    const origin = 'http://192.168.1.10:4848';

    test('root /bbx/ (empty rest) returns null', () {
      final result = bbxIframeUrlToBotbooru(
        'http://192.168.1.10:4848/bbx/',
        origin,
      );
      expect(result, isNull);
    });

    test('non-bbx path returns null', () {
      final result = bbxIframeUrlToBotbooru(
        'http://192.168.1.10:4848/settings',
        origin,
      );
      expect(result, isNull);
    });

    test('different origin returns null', () {
      final result = bbxIframeUrlToBotbooru(
        'http://10.0.0.1:1234/bbx/character/1',
        origin,
      );
      expect(result, isNull);
    });

    test('external URL returns null', () {
      final result = bbxIframeUrlToBotbooru(
        'https://botbooru.com/character/1',
        origin,
      );
      expect(result, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // LEGACY: botbooruUrlToBbxPath (v1 — retained, unchanged)
  // -------------------------------------------------------------------------
  group('botbooruUrlToBbxPath — happy paths', () {
    const origin = 'http://192.168.1.10:4848';

    test('download/png URL is proxied', () {
      final result = botbooruUrlToBbxPath(
        'https://botbooru.com/download/png/12345',
        origin,
      );
      expect(
        result,
        equals('http://192.168.1.10:4848/bbx/download/png/12345'),
      );
    });

    test('character page URL is proxied', () {
      final result = botbooruUrlToBbxPath(
        'https://botbooru.com/character/99',
        origin,
      );
      expect(result, equals('http://192.168.1.10:4848/bbx/character/99'));
    });

    test('origin with trailing slash is normalised', () {
      final result = botbooruUrlToBbxPath(
        'https://botbooru.com/character/5',
        'http://192.168.1.10:4848/',
      );
      expect(result, equals('http://192.168.1.10:4848/bbx/character/5'));
    });
  });

  group('botbooruUrlToBbxPath — rejected / null', () {
    const origin = 'http://192.168.1.10:4848';

    test('non-botbooru URL returns null', () {
      final result = botbooruUrlToBbxPath(
        'https://evil.com/download/png/1',
        origin,
      );
      expect(result, isNull);
    });

    test('http (non-https) botbooru returns null', () {
      final result = botbooruUrlToBbxPath(
        'http://botbooru.com/character/1',
        origin,
      );
      expect(result, isNull);
    });

    test('empty URL returns null', () {
      final result = botbooruUrlToBbxPath('', origin);
      expect(result, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // kBbxMaxResponseBytes constant sanity check
  // -------------------------------------------------------------------------
  test('kBbxMaxResponseBytes is 25 MB', () {
    expect(kBbxMaxResponseBytes, equals(25 * 1024 * 1024));
  });

  // -------------------------------------------------------------------------
  // decodeBbxCardB64
  // -------------------------------------------------------------------------
  group('decodeBbxCardB64 — valid inputs', () {
    test('valid base64 of known bytes returns those exact bytes', () {
      final input = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      final encoded = base64Encode(input);
      final result = decodeBbxCardB64(encoded);
      expect(result, isNotNull);
      expect(result!.toList(), equals(input));
    });

    test('data:image/png;base64, prefix is stripped and bytes match', () {
      final input = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      final encoded = 'data:image/png;base64,${base64Encode(input)}';
      final result = decodeBbxCardB64(encoded);
      expect(result, isNotNull);
      expect(result!.toList(), equals(input));
    });

    test('data: prefix with arbitrary mime type is stripped', () {
      final input = [1, 2, 3, 4, 5];
      final encoded = 'data:application/octet-stream;base64,${base64Encode(input)}';
      final result = decodeBbxCardB64(encoded);
      expect(result, isNotNull);
      expect(result!.toList(), equals(input));
    });
  });

  group('decodeBbxCardB64 — null inputs', () {
    test('empty string returns null', () {
      expect(decodeBbxCardB64(''), isNull);
    });

    test('whitespace-only returns null', () {
      expect(decodeBbxCardB64('   \t\n  '), isNull);
    });

    test('invalid base64 returns null', () {
      expect(decodeBbxCardB64('!!!!'), isNull);
    });

    test('oversize string returns null (larger than 25MB cap)', () {
      // kBbxMaxResponseBytes = 25*1024*1024. The length bound in decodeBbxCardB64
      // is (cap ~/ 3) * 4 + 16. Build a string just beyond that.
      final cap = kBbxMaxResponseBytes;
      final limit = (cap ~/ 3) * 4 + 16;
      // Build a valid-charset string that is clearly over the limit.
      final oversized = 'A' * (limit + 1);
      expect(decodeBbxCardB64(oversized), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // rewriteBotbooruHtmlDedicated — Download-PNG hook regression
  // -------------------------------------------------------------------------
  group('rewriteBotbooruHtmlDedicated — Download-PNG hook', () {
    const html = '<html><head></head><body></body></html>';

    test('existing pyre-bbx-loc shim is still present (regression)', () {
      final out = rewriteBotbooruHtmlDedicated(html);
      expect(out, contains('pyre-bbx-loc'));
    });

    test('new pyre-bbx-card message type is present in the shim', () {
      final out = rewriteBotbooruHtmlDedicated(html);
      expect(out, contains('pyre-bbx-card'));
    });

    test('download-png-btn id is referenced in findCardId', () {
      final out = rewriteBotbooruHtmlDedicated(html);
      expect(out, contains('download-png-btn'));
    });

    test('fetch with credentials:include is present (in-iframe fetch)', () {
      final out = rewriteBotbooruHtmlDedicated(html);
      expect(out, contains('credentials'));
    });
  });
}
