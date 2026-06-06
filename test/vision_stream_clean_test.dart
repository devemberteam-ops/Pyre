// Regression for audit creator-02: vision image->profile leaked raw
// chain-of-thought on reasoning models because it used the one-shot
// `completeChat`. The fix routes the vision call through the streaming,
// reasoning-aware transport, which separates `delta.reasoning_content` /
// `delta.reasoning` into `<think>…</think>` and appends Pyre end-of-stream
// sentinels. `cleanVisionStreamedText` is the pure post-processor that
// strips those sentinels and the reasoning, leaving the clinical profile.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/image_describe.dart';

void main() {
  group('encodeImageDataUrl (creator-09 format sniffing)', () {
    String mime(Uint8List bytes) {
      final url = encodeImageDataUrl(bytes);
      // data:<mime>;base64,...
      return url.substring(5, url.indexOf(';'));
    }

    test('PNG magic → image/png', () {
      expect(mime(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D])),
          'image/png');
    });

    test('JPEG magic → image/jpeg', () {
      expect(mime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
    });

    test('BMP magic → image/bmp (previously mislabeled PNG)', () {
      expect(mime(Uint8List.fromList([0x42, 0x4D, 0x00, 0x00])), 'image/bmp');
    });

    test('HEIC ftyp box → image/heic (iOS gallery export)', () {
      // 4-byte size, "ftyp", "heic" brand.
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x18, // box size
        0x66, 0x74, 0x79, 0x70, // ftyp
        0x68, 0x65, 0x69, 0x63, // heic
        0x00, 0x00, 0x00, 0x00,
      ]);
      expect(mime(bytes), 'image/heic');
    });

    test('AVIF ftyp box → image/avif (modern Android export)', () {
      final bytes = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x1C, // box size
        0x66, 0x74, 0x79, 0x70, // ftyp
        0x61, 0x76, 0x69, 0x66, // avif
        0x00, 0x00, 0x00, 0x00,
      ]);
      expect(mime(bytes), 'image/avif');
    });

    test('truly unknown bytes still fall back to image/png (never throws)', () {
      expect(mime(Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05])),
          'image/png');
    });
  });

  group('cleanVisionStreamedText', () {
    test('strips a streamed <think> block the transport wrapped', () {
      // The streaming path wraps separated reasoning tokens in <think>…</think>.
      const streamed =
          '<think>Single subject. I will use the single template.</think>'
          'GENERAL PHYSICAL FEATURES\nHuman woman, athletic build.';
      final out = cleanVisionStreamedText(streamed);
      expect(out, startsWith('GENERAL PHYSICAL FEATURES'));
      expect(out, isNot(contains('think')));
      expect(out, isNot(contains('single template')));
    });

    test('strips the finish-reason sentinel emitted at stream end', () {
      const streamed = 'GENERAL PHYSICAL FEATURES\n'
          'Human, tall.<<__PYRE_FINISH__:stop__>>';
      final out = cleanVisionStreamedText(streamed);
      expect(out, isNot(contains('PYRE_FINISH')));
      expect(out, contains('Human, tall.'));
    });

    test('strips the dropped-frames sentinel', () {
      const streamed = 'GROUP COMPOSITION\nTwo characters.'
          '<<__PYRE_DROPPED__:3:FormatException__>>';
      final out = cleanVisionStreamedText(streamed);
      expect(out, isNot(contains('PYRE_DROPPED')));
      expect(out, startsWith('GROUP COMPOSITION'));
    });

    test('strips reasoning + both sentinels together, keeps the profile', () {
      const streamed = '<think>Three men in a sauna. Ensemble shape.</think>'
          'GROUP COMPOSITION\nThree men share the frame.\n\n'
          'CHARACTER A\nTall, dark hair.\n\nNEXT\nName the cast?'
          '<<__PYRE_DROPPED__:1:FormatException__>>'
          '<<__PYRE_FINISH__:stop__>>';
      final out = cleanVisionStreamedText(streamed);
      expect(out, startsWith('GROUP COMPOSITION'));
      expect(out, contains('CHARACTER A'));
      expect(out, contains('NEXT'));
      expect(out, isNot(contains('think')));
      expect(out, isNot(contains('Ensemble shape')));
      expect(out, isNot(contains('PYRE_FINISH')));
      expect(out, isNot(contains('PYRE_DROPPED')));
    });

    test('still drops leading plain-text CoT (no <think> delimiter)', () {
      // Worst case: a reasoning model that emits CoT as plain content with no
      // delimiter and no reasoning field. The leading-preamble net still
      // slices at the first recognised header.
      const streamed = 'The user wants an analysis. I will pick Ensemble.\n\n'
          'GROUP COMPOSITION\nTwo figures.<<__PYRE_FINISH__:stop__>>';
      final out = cleanVisionStreamedText(streamed);
      expect(out, startsWith('GROUP COMPOSITION'));
      expect(out, isNot(contains('The user wants')));
      expect(out, isNot(contains('PYRE_FINISH')));
    });

    test('leaves a clean profile (no sentinels/think) unchanged', () {
      const streamed = 'GENERAL PHYSICAL FEATURES\nHuman, tall.\n\n'
          'NEXT\nVoice?';
      expect(cleanVisionStreamedText(streamed), streamed.trim());
    });
  });
}
