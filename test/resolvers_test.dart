import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/resolvers.dart';

void main() {
  group('isPublicHost — public hosts', () {
    test('normal DNS hostnames are public', () {
      expect(isPublicHost('files.catbox.moe'), isTrue);
      expect(isPublicHost('pixeldrain.com'), isTrue);
      expect(isPublicHost('example.com'), isTrue);
      expect(isPublicHost('CDN.Example.COM'), isTrue); // case-insensitive
    });

    test('public IPv4 literals are public', () {
      expect(isPublicHost('8.8.8.8'), isTrue);
      expect(isPublicHost('1.1.1.1'), isTrue);
      expect(isPublicHost('172.15.0.1'), isTrue); // just below 172.16/12
      expect(isPublicHost('172.32.0.1'), isTrue); // just above 172.31
      expect(isPublicHost('192.167.0.1'), isTrue); // not 192.168
    });

    test('public IPv6 literals are public', () {
      expect(isPublicHost('[2606:4700:4700::1111]'), isTrue); // brackets
      expect(isPublicHost('2606:4700:4700::1111'), isTrue);
      expect(isPublicHost('2001:4860:4860::8888'), isTrue);
    });
  });

  group('isPublicHost — loopback / unspecified', () {
    test('localhost names are rejected', () {
      expect(isPublicHost('localhost'), isFalse);
      expect(isPublicHost('LOCALHOST'), isFalse);
      expect(isPublicHost('localhost.localdomain'), isFalse);
      expect(isPublicHost('foo.localhost'), isFalse);
    });

    test('IPv4 loopback 127.0.0.0/8 is rejected', () {
      expect(isPublicHost('127.0.0.1'), isFalse);
      expect(isPublicHost('127.255.255.254'), isFalse);
    });

    test('0.0.0.0 / 0.0.0.0/8 is rejected', () {
      expect(isPublicHost('0.0.0.0'), isFalse);
      expect(isPublicHost('0.1.2.3'), isFalse);
    });

    test('IPv6 loopback ::1 and unspecified :: are rejected', () {
      expect(isPublicHost('::1'), isFalse);
      expect(isPublicHost('[::1]'), isFalse);
      expect(isPublicHost('::'), isFalse);
      expect(isPublicHost('[::]'), isFalse);
    });
  });

  group('isPublicHost — IPv4 private ranges', () {
    test('10.0.0.0/8 is rejected', () {
      expect(isPublicHost('10.0.0.1'), isFalse);
      expect(isPublicHost('10.255.255.255'), isFalse);
    });

    test('172.16.0.0/12 is rejected (and only that range)', () {
      expect(isPublicHost('172.16.0.1'), isFalse);
      expect(isPublicHost('172.31.255.255'), isFalse);
      expect(isPublicHost('172.20.10.5'), isFalse);
    });

    test('192.168.0.0/16 is rejected', () {
      expect(isPublicHost('192.168.0.1'), isFalse);
      expect(isPublicHost('192.168.255.255'), isFalse);
    });

    test('169.254.0.0/16 link-local is rejected', () {
      expect(isPublicHost('169.254.0.1'), isFalse);
      expect(isPublicHost('169.254.169.254'), isFalse); // cloud metadata
    });
  });

  group('isPublicHost — IPv6 private ranges', () {
    test('ULA fc00::/7 is rejected', () {
      expect(isPublicHost('fc00::1'), isFalse);
      expect(isPublicHost('fd12:3456:789a::1'), isFalse);
      expect(isPublicHost('[fd00::1]'), isFalse);
    });

    test('link-local fe80::/10 is rejected (incl. zone id)', () {
      expect(isPublicHost('fe80::1'), isFalse);
      expect(isPublicHost('[fe80::1]'), isFalse);
      expect(isPublicHost('fe80::1%eth0'), isFalse); // zone id stripped
    });

    test('IPv4-mapped IPv6 is judged by the embedded IPv4', () {
      expect(isPublicHost('::ffff:127.0.0.1'), isFalse); // mapped loopback
      expect(isPublicHost('::ffff:192.168.0.1'), isFalse); // mapped private
      expect(isPublicHost('::ffff:8.8.8.8'), isTrue); // mapped public
    });
  });

  group('isPublicHost — malformed input', () {
    test('empty / blank is not public', () {
      expect(isPublicHost(''), isFalse);
      expect(isPublicHost('   '), isFalse);
    });

    test('unparseable IPv6-looking input is rejected, not assumed public', () {
      expect(isPublicHost('::ggance'), isFalse);
      expect(isPublicHost('1:2:3:4:5:6:7:8:9'), isFalse); // too many groups
    });

    test('out-of-range IPv4 octet falls through to hostname (public)', () {
      // 999.1.1.1 is not a valid IPv4 literal, so it is treated as a
      // (nonsense) DNS hostname → public. The fetch would simply fail DNS.
      expect(isPublicHost('999.1.1.1'), isTrue);
    });
  });

  group('resolveCommunityUrl — direct file links', () {
    test('a direct .png link resolves to source "direct"', () async {
      final r = await resolveCommunityUrl(
          'https://files.catbox.moe/abc123.png');
      expect(r, isNotNull);
      expect(r!.source, 'direct');
      expect(r.pngUrl.toString(), 'https://files.catbox.moe/abc123.png');
      expect(r.bytes, isNull);
    });

    test('a direct .json link resolves to source "direct"', () async {
      final r = await resolveCommunityUrl(
          'https://files.catbox.moe/abc123.json');
      expect(r, isNotNull);
      expect(r!.source, 'direct');
      expect(r.pngUrl.toString(), 'https://files.catbox.moe/abc123.json');
    });

    test('extension match is case-insensitive (.PNG / .JSON)', () async {
      final png = await resolveCommunityUrl('https://x.example/Card.PNG');
      expect(png?.source, 'direct');
      final json = await resolveCommunityUrl('https://x.example/Card.JSON');
      expect(json?.source, 'direct');
    });

    test('pixeldrain api file link resolves to source "direct"', () async {
      final r = await resolveCommunityUrl(
          'https://pixeldrain.com/api/file/abc123.png');
      expect(r?.source, 'direct');
    });

    test('a non-card direct link does not resolve as direct', () async {
      // No .png/.json extension and not a known community host → null.
      final r = await resolveCommunityUrl('https://files.catbox.moe/abc123');
      expect(r, isNull);
    });
  });

  group('resolveCommunityUrl — community pages still work', () {
    test('botbooru post page resolves to the PNG download endpoint',
        () async {
      final r =
          await resolveCommunityUrl('https://botbooru.com/post/42');
      expect(r, isNotNull);
      expect(r!.source, 'botbooru');
      expect(r.pngUrl.toString(), 'https://botbooru.com/download/png/42');
    });

    // Wave CY.18.149: the Windows webview's Download-PNG hook posts the
    // ALREADY-resolved `/download/png/{id}` URL. The resolver must tag it
    // `source: 'botbooru'` (not fall through to null) or the gallery import
    // gate in _importFromUrl drops the mini-gallery even though the card
    // still imports via the trusted-host fetch.
    test('botbooru direct download URL is tagged source=botbooru',
        () async {
      final r = await resolveCommunityUrl(
          'https://botbooru.com/download/png/31932');
      expect(r, isNotNull);
      expect(r!.source, 'botbooru');
      expect(
          r.pngUrl.toString(), 'https://botbooru.com/download/png/31932');
    });

    test('chub.ai character page resolves to the charhub CDN PNG',
        () async {
      final r = await resolveCommunityUrl(
          'https://chub.ai/characters/author/my-slug');
      expect(r, isNotNull);
      expect(r!.source, 'chub');
      expect(
        r.pngUrl.toString(),
        'https://avatars.charhub.io/avatars/author/my-slug/chara_card_v2.png',
      );
    });

    test('a hostile botbooru lookalike host is rejected', () async {
      final r =
          await resolveCommunityUrl('https://evilbotbooru.com/post/42');
      expect(r, isNull);
    });
  });

  // Frontend-only lorebook rework: the app must NEVER resolve a BotBooru
  // lorebook page/API URL to an `/api/lorebooks/.../download.json` fetch
  // target. The webview's authenticated JS hook captures the JSON bytes and
  // posts the TEXT to native, which parses it directly — the resolver/fetch
  // path is no longer involved for lorebooks. So the resolver must NOT map a
  // `/lorebook/{id}` page to an `/api/` URL.
  group('resolveCommunityUrl — BotBooru lorebook (frontend-only: no API map)',
      () {
    test('existing character paths still default to kind=character',
        () async {
      final post = await resolveCommunityUrl('https://botbooru.com/post/42');
      expect(post!.kind, ResolvedKind.character);
      final dl =
          await resolveCommunityUrl('https://botbooru.com/download/png/42');
      expect(dl!.kind, ResolvedKind.character);
      final direct =
          await resolveCommunityUrl('https://files.catbox.moe/abc.png');
      expect(direct!.kind, ResolvedKind.character);
    });

    test('a /lorebook/{id} page does NOT resolve to an /api download URL',
        () async {
      // It must not map to `/api/lorebooks/.../download.json` (that would be
      // the app calling the API). It resolves to null — the paste-URL handler
      // detects the lorebook page and tells the user to use Download JSON.
      final r = await resolveCommunityUrl('https://botbooru.com/lorebook/119');
      expect(r, isNull);
    });

    test('the app never produces an /api/lorebooks download URL', () async {
      // Belt-and-braces: across the lorebook page, the www variant, and even a
      // pasted /api URL, no ResolvedCard may carry an `/api/lorebooks/` target.
      final urls = [
        'https://botbooru.com/lorebook/119',
        'https://www.botbooru.com/lorebook/7',
      ];
      for (final u in urls) {
        final r = await resolveCommunityUrl(u);
        if (r != null) {
          expect(r.pngUrl.toString(), isNot(contains('/api/lorebooks/')));
        }
      }
    });

    test('a pasted /api/lorebooks download.json URL ends in .json → direct',
        () async {
      // A user could paste the raw API URL. The generic direct-.json branch
      // tags it source='direct' (kind=character) — it is NOT a trusted
      // BotBooru lorebook fetch, and the paste-URL handler in Discover detects
      // the botbooru lorebook shape and refuses to fetch it from the app.
      final r = await resolveCommunityUrl(
          'https://botbooru.com/api/lorebooks/119/download.json');
      // Whatever it resolves to, it must NOT be tagged as a botbooru lorebook.
      expect(r?.source == 'botbooru' && r?.kind == ResolvedKind.lorebook,
          isFalse);
    });
  });

  // The paste-URL gate: a BotBooru lorebook page/API URL must be DETECTED so
  // Discover can show the "use Download JSON" hint instead of fetching it.
  group('isBotbooruLorebookUrl (paste-URL gate)', () {
    test('a /lorebook/{id} page is detected', () {
      expect(isBotbooruLorebookUrl('https://botbooru.com/lorebook/119'), isTrue);
      expect(isBotbooruLorebookUrl('https://www.botbooru.com/lorebook/7'),
          isTrue);
    });

    test('an /api/lorebooks/.../download.json URL is detected', () {
      expect(
          isBotbooruLorebookUrl(
              'https://botbooru.com/api/lorebooks/119/download.json'),
          isTrue);
    });

    test('a botbooru character page / direct PNG is NOT a lorebook URL', () {
      expect(isBotbooruLorebookUrl('https://botbooru.com/post/42'), isFalse);
      expect(isBotbooruLorebookUrl('https://botbooru.com/download/png/42'),
          isFalse);
    });

    test('a lookalike host is NOT treated as a botbooru lorebook URL', () {
      expect(isBotbooruLorebookUrl('https://evilbotbooru.com/lorebook/119'),
          isFalse);
      expect(
          isBotbooruLorebookUrl(
              'https://botbooru.com.evil.io/api/lorebooks/119/download.json'),
          isFalse);
    });

    test('garbage / empty input is not a lorebook URL', () {
      expect(isBotbooruLorebookUrl(''), isFalse);
      expect(isBotbooruLorebookUrl('not a url'), isFalse);
    });
  });

  group('resolveCommunityUrl — RisuRealm', () {
    const uuid = '05edf2e9-c98a-4777-9002-b09216d635c7';

    test('character page resolves to the png-v2 download endpoint',
        () async {
      final r = await resolveCommunityUrl(
          'https://realm.risuai.net/character/$uuid');
      expect(r, isNotNull);
      expect(r!.source, 'risurealm');
      expect(
        r.pngUrl.toString(),
        'https://realm.risuai.net/api/v1/download/png-v2/$uuid',
      );
      expect(r.bytes, isNull);
    });

    test('a direct png-v2 download API URL passes through', () async {
      final url = 'https://realm.risuai.net/api/v1/download/png-v2/$uuid';
      final r = await resolveCommunityUrl(url);
      expect(r, isNotNull);
      expect(r!.source, 'risurealm');
      expect(r.pngUrl.toString(), url);
    });

    test('a hostile RisuRealm lookalike host is rejected', () async {
      final r = await resolveCommunityUrl(
          'https://realm.risuai.net.evil.com/character/$uuid');
      expect(r, isNull);
    });

    test('a non-character RisuRealm path does not resolve', () async {
      final r =
          await resolveCommunityUrl('https://realm.risuai.net/explore');
      expect(r, isNull);
    });
  });

  group('kCardFileHostAllowlist', () {
    test('contains the common file-hosts', () {
      expect(kCardFileHostAllowlist, contains('files.catbox.moe'));
      expect(kCardFileHostAllowlist, contains('catbox.moe'));
      expect(kCardFileHostAllowlist, contains('pixeldrain.com'));
    });
  });

  // Mega-audit 2026-06-05 (H-7): SSRF gate for provider Browse / Test /
  // launch-time warm-up.
  group('isProviderHostAllowed', () {
    test('localhost kind is always allowed (LM Studio / Ollama)', () {
      // The explicit localhost provider kind exists to reach a local/LAN
      // server, so private/loopback targets MUST stay allowed.
      expect(
          isProviderHostAllowed('http://localhost:1234',
              isLocalhostKind: true),
          isTrue);
      expect(
          isProviderHostAllowed('http://127.0.0.1:11434',
              isLocalhostKind: true),
          isTrue);
      expect(
          isProviderHostAllowed('http://192.168.1.50:1234',
              isLocalhostKind: true),
          isTrue);
      // Even a public URL on the localhost kind is fine.
      expect(
          isProviderHostAllowed('https://api.openai.com',
              isLocalhostKind: true),
          isTrue);
    });

    test('External kind to a public host is allowed', () {
      expect(
          isProviderHostAllowed('https://api.openai.com/v1',
              isLocalhostKind: false),
          isTrue);
      expect(
          isProviderHostAllowed('https://openrouter.ai/api/v1',
              isLocalhostKind: false),
          isTrue);
      expect(
          isProviderHostAllowed('https://mars.chub.ai/chub/soji/v1',
              isLocalhostKind: false),
          isTrue);
    });

    test('External kind to a private / loopback / internal host is refused',
        () {
      expect(
          isProviderHostAllowed('http://127.0.0.1:8080/v1',
              isLocalhostKind: false),
          isFalse);
      expect(
          isProviderHostAllowed('http://localhost:8080/v1',
              isLocalhostKind: false),
          isFalse);
      expect(
          isProviderHostAllowed('http://192.168.1.50:8080/v1',
              isLocalhostKind: false),
          isFalse);
      expect(
          isProviderHostAllowed('http://10.0.0.5/v1', isLocalhostKind: false),
          isFalse);
      // 169.254.169.254 = the classic cloud metadata endpoint.
      expect(
          isProviderHostAllowed('http://169.254.169.254/latest/meta-data',
              isLocalhostKind: false),
          isFalse);
      expect(
          isProviderHostAllowed('http://[::1]:8080/v1',
              isLocalhostKind: false),
          isFalse);
    });

    test('External kind with an empty / unparseable URL is refused', () {
      expect(isProviderHostAllowed('', isLocalhostKind: false), isFalse);
      expect(isProviderHostAllowed('   ', isLocalhostKind: false), isFalse);
      // No host component (relative-looking) → refused.
      expect(
          isProviderHostAllowed('not a url', isLocalhostKind: false), isFalse);
    });
  });
}
