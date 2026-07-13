@TestOn('vm')
library;

// Security/data-loss (audit round 18): the pre-factory-reset safety backup used
// to silently skip any referenced image whose `.bin` was missing, then the wipe
// deleted it for good — the backup reported success while dropping images. The
// factory reset now surfaces `missingBackupAttachmentHashes` in the final confirm
// so the loss is EXPLICIT (never silent), without hard-aborting (a blob may only
// live on another synced device). These unit tests pin that detector.

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/screens/backup_restore_screen.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('missingBackupAttachmentHashes', () {
    test('no attachment refs → nothing missing', () {
      expect(
          missingBackupAttachmentHashes({
            'characters': [
              {'name': 'x'}
            ]
          }),
          isEmpty);
    });

    test('every referenced hash embedded → nothing missing (complete backup)',
        () {
      final blob = {
        'characters': [
          {'avatar': 'pyre://attachment/abc123'}
        ],
        'attachments': {'abc123': 'AAAA'},
      };
      expect(missingBackupAttachmentHashes(blob), isEmpty);
    });

    test('a referenced hash absent from the embedded map is reported missing',
        () {
      final blob = {
        'characters': [
          {'avatar': 'pyre://attachment/abc123'}
        ],
        // embedBackupAttachments skipped it because the .bin was gone
        'attachments': <String, dynamic>{},
      };
      expect(missingBackupAttachmentHashes(blob), {'abc123'});
    });

    test('nested refs (chat character snapshot) are counted; partial embed '
        'reports only the truly-missing one', () {
      final blob = {
        'characters': [
          {'avatar': 'pyre://attachment/aaa'}
        ],
        'chats': [
          {
            'characterSnapshots': {
              'c': {
                'gallery': ['pyre://attachment/bbb']
              }
            }
          }
        ],
        'attachments': {'aaa': 'AAAA'}, // bbb's .bin was missing
      };
      expect(missingBackupAttachmentHashes(blob), {'bbb'});
    });

    test('a DRAFT image whose .bin is missing is now detected (was invisible)',
        () {
      // characterDrafts are now exported, so the whole-JSON scan sees their
      // refs — a draft image that can't be backed up is no longer a silent loss.
      final blob = {
        'characterDrafts': [
          {'avatar': 'pyre://attachment/ddd'}
        ],
        'attachments': <String, dynamic>{},
      };
      expect(missingBackupAttachmentHashes(blob), {'ddd'});
    });
  });

  group('attachmentBytesMatchHash (integrity — last net before wipe)', () {
    test('true only when the bytes actually hash to the content-addressed name',
        () {
      final bytes = utf8.encode('a real avatar payload');
      final hash = sha256.convert(bytes).toString();
      expect(attachmentBytesMatchHash(hash, bytes), isTrue);
      // A corrupt .bin (content no longer matches its name) must be rejected so
      // the missing-hash detector turns it into an explicit warning.
      expect(attachmentBytesMatchHash(hash, utf8.encode('corrupted')), isFalse);
    });
  });

  group('buildExportBlob completeness (audit round 18)', () {
    test('includes characterDrafts + surfaces their attachment refs', () {
      final store = AppStore(storage: _NoopBackend());
      store.characterDrafts.add(Character(
        id: 'd1',
        name: 'Draft',
        description: '',
        personality: '',
        scenario: '',
        avatar: 'pyre://attachment/ddd',
        createdAt: 0,
        updatedAt: 0,
      ));
      final blob = buildExportBlob(store,
          include: {'characters'}, includeApiKeys: false);
      expect(blob['characterDrafts'], isA<List>());
      expect(blob['characterDrafts'] as List, hasLength(1));
      // The draft's image is now visible to the wipe-safety detector.
      expect(collectBackupAttachmentHashes(blob), contains('ddd'));
    });
  });
}
