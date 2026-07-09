// Tests for the PYRE_DATA_DIR override seam (1.2.1 item #6).
//
// Only the PURE decision function is tested here. `pyreDataParent()` /
// `pyreDataRoot()` wrap `Platform.environment` + `path_provider` and are
// thin delegation over `resolveDataParentPath` — no independent logic to
// verify.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/data_dir.dart';

void main() {
  group('resolveDataParentPath', () {
    test('env null returns the documents path unchanged', () {
      expect(resolveDataParentPath(null, '/docs'), '/docs');
    });

    test('env blank (whitespace only) returns the documents path', () {
      expect(resolveDataParentPath('   ', '/docs'), '/docs');
    });

    test('env set wins over the documents path', () {
      expect(
        resolveDataParentPath('/home/u/PyreData', '/docs'),
        '/home/u/PyreData',
      );
    });

    test('env with surrounding whitespace is trimmed', () {
      expect(resolveDataParentPath('  /data  ', '/docs'), '/data');
    });
  });
}
