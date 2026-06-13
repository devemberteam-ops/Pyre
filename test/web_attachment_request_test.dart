// Pyre 1.1.3 (Gui, web avatars): a card/persona avatar stored as a
// `pyre://attachment/<hash>` ref can't be read from disk in the browser, so the
// web client must fetch the bytes from the LAN server that served it
// (`GET /attachments/<hash>`, bearer-gated). `AttachmentStore.webAttachmentRequest`
// is the pure (url, headers) builder for that fetch. These tests pin its shape
// and its null cases (non-pyre url, unpaired client, empty hash).

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/attachment_store.dart';

void main() {
  const pyre = 'pyre://attachment/abc123';

  group('AttachmentStore.webAttachmentRequestFor (pure core)', () {
    test('builds the /attachments/<hash> URL + Bearer header', () {
      final r = AttachmentStore.webAttachmentRequestFor(
        pyre,
        baseUrl: 'http://192.168.0.5:6767',
        bearerToken: 'tok',
      );
      expect(r, isNotNull);
      expect(r!.url, 'http://192.168.0.5:6767/attachments/abc123');
      expect(r.headers['authorization'], 'Bearer tok');
    });

    test('strips a trailing slash on baseUrl (no double //)', () {
      final r = AttachmentStore.webAttachmentRequestFor(
        pyre,
        baseUrl: 'http://x:6767/',
        bearerToken: 'tok',
      );
      expect(r!.url, 'http://x:6767/attachments/abc123');
    });

    test('returns null for a non-pyre url (data: / http stay as-is)', () {
      expect(
        AttachmentStore.webAttachmentRequestFor('data:image/png;base64,AA',
            baseUrl: 'http://x', bearerToken: 't'),
        isNull,
      );
    });

    test('returns null when the client is not paired (no baseUrl / token)', () {
      expect(
        AttachmentStore.webAttachmentRequestFor(pyre,
            baseUrl: null, bearerToken: 'tok'),
        isNull,
      );
      expect(
        AttachmentStore.webAttachmentRequestFor(pyre,
            baseUrl: 'http://x', bearerToken: null),
        isNull,
      );
      expect(
        AttachmentStore.webAttachmentRequestFor(pyre,
            baseUrl: '', bearerToken: ''),
        isNull,
      );
    });

    test('returns null for an empty hash', () {
      expect(
        AttachmentStore.webAttachmentRequestFor('pyre://attachment/',
            baseUrl: 'http://x', bearerToken: 't'),
        isNull,
      );
    });
  });
}
