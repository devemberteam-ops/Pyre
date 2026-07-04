// 2026-07-04 (Gui): "os checkpoints nunca funcionaram direito — não dispara
// quando devia e o resumo não conta uma história que dê para entender por si
// só." Two structural causes, two fixes locked here:
//
// 1. QUALITY: the v2 prompt wrote each checkpoint as "the NEXT paragraph —
//    never re-introduce anyone" — so individual checkpoints were connective
//    fragments, and once the prompt window trimmed the oldest ones, both the
//    user AND the model got paragraphs referencing people never introduced.
//    v3 flips the design to a SELF-CONTAINED ROLLING RECAP: each new
//    checkpoint retells the whole story so far (prior recap compressed + new
//    events folded in) and stands alone. New checkpoints carry
//    `selfContained: true`; injection uses ONLY the newest self-contained
//    recap (it subsumes the chain). Legacy checkpoints keep the old
//    concatenation path byte-identically (golden 03 guards it).
//
// 2. TRIGGER: the counter counts CHARACTER replies only (deliberate), but the
//    default of 20 meant ~40+ total messages before the first checkpoint —
//    perceived as "never fires". Default drops to 10 (~20 total messages),
//    with a one-time migration for installs still on the old stock 20.
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/memory.dart';

Message _m(String id, MessageKind kind, String text) => Message(
      id: id,
      kind: kind,
      variants: [text],
      createdAt: 0,
    );

void main() {
  group('MemoryCheckpoint.selfContained', () {
    test('defaults false and is OMITTED from json (legacy blobs identical)',
        () {
      final c = MemoryCheckpoint(
        id: 'c1',
        summary: 's',
        anchorMessageIdx: 0,
        pathHash: '',
      );
      expect(c.selfContained, isFalse);
      expect(c.toJson().containsKey('selfContained'), isFalse);
    });

    test('round-trips true', () {
      final c = MemoryCheckpoint(
        id: 'c1',
        summary: 's',
        anchorMessageIdx: 0,
        pathHash: '',
        selfContained: true,
      );
      final back = MemoryCheckpoint.fromJson(c.toJson());
      expect(back.selfContained, isTrue);
    });
  });

  group('buildRecapBlock', () {
    Chat chatWith(List<MemoryCheckpoint> ckpts) => Chat(
          id: 'c',
          characterIds: const ['x'],
          messages: [
            _m('m1', MessageKind.user, 'a'),
            _m('m2', MessageKind.char, 'b'),
            _m('m3', MessageKind.user, 'c'),
            _m('m4', MessageKind.char, 'd'),
          ],
          memoryCheckpoints: ckpts,
          memoryEnabled: true,
          createdAt: 0,
          updatedAt: 0,
        );

    test('legacy checkpoints keep the concatenation (old behavior)', () {
      final block = buildRecapBlock(chatWith([
        MemoryCheckpoint(
            id: 'a', summary: 'First part.', anchorMessageIdx: 1, pathHash: ''),
        MemoryCheckpoint(
            id: 'b', summary: 'Second part.', anchorMessageIdx: 3, pathHash: ''),
      ]));
      expect(block, 'First part.\n\nSecond part.');
    });

    test('a newest SELF-CONTAINED recap is injected ALONE (it subsumes the '
        'chain)', () {
      final block = buildRecapBlock(chatWith([
        MemoryCheckpoint(
            id: 'a',
            summary: 'Old fragment.',
            anchorMessageIdx: 1,
            pathHash: ''),
        MemoryCheckpoint(
            id: 'b',
            summary: 'The whole story so far, standalone.',
            anchorMessageIdx: 3,
            pathHash: '',
            selfContained: true),
      ]));
      expect(block, 'The whole story so far, standalone.');
    });

    test('a self-contained recap that is NOT the newest keeps the legacy '
        'concatenation', () {
      final block = buildRecapBlock(chatWith([
        MemoryCheckpoint(
            id: 'a',
            summary: 'Standalone but older.',
            anchorMessageIdx: 1,
            pathHash: '',
            selfContained: true),
        MemoryCheckpoint(
            id: 'b',
            summary: 'Legacy tail.',
            anchorMessageIdx: 3,
            pathHash: ''),
      ]));
      expect(block, 'Standalone but older.\n\nLegacy tail.');
    });
  });

  group('trigger default + migration (autoEvery 20 → 10)', () {
    test('fresh install defaults to 10', () {
      expect(MemorySettings().autoEvery, 10);
      expect(MemorySettings.fromJson(const {}).autoEvery, 10);
    });

    test('an install still on the OLD STOCK 20 from an old version is '
        'migrated to 10 once', () {
      final m = MemorySettings.fromJson({
        'autoEvery': 20,
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion - 1,
      });
      expect(m.autoEvery, 10);
    });

    test('a DELIBERATE non-stock value is preserved across the migration', () {
      final m = MemorySettings.fromJson({
        'autoEvery': 35,
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion - 1,
      });
      expect(m.autoEvery, 35);
    });

    test('20 chosen ON the current version is respected', () {
      final m = MemorySettings.fromJson({
        'autoEvery': 20,
        'summaryPromptVersion': MemorySettings.kSummaryPromptVersion,
      });
      expect(m.autoEvery, 20);
    });
  });

  group('summariser body (v3 self-contained framing)', () {
    final chat = Chat(
      id: 'c',
      characterIds: const ['x'],
      messages: [
        _m('m1', MessageKind.user, 'hello'),
        _m('m2', MessageKind.char, 'reply one'),
        _m('m3', MessageKind.user, 'more'),
        _m('m4', MessageKind.char, 'reply two'),
      ],
      createdAt: 0,
      updatedAt: 0,
    );

    test('with a prior recap: asks for a REPLACEMENT retelling, not a '
        'continuation paragraph', () {
      final body = buildSummariserBodyForTest(
        chat: chat,
        startExclusive: 1,
        endInclusive: 3,
        priorContext: [
          MemoryCheckpoint(
              id: 'a', summary: 'Prior story.', anchorMessageIdx: 1,
              pathHash: ''),
        ],
      );
      expect(body, contains('Previous recap'));
      expect(body, contains('REPLACES'));
      expect(body, contains('Prior story.'));
      // The old "next paragraph" contract is gone.
      expect(body, isNot(contains('your NEW paragraph must continue')));
    });

    test('without a prior recap: asks for a complete self-contained story',
        () {
      final body = buildSummariserBodyForTest(
        chat: chat,
        startExclusive: -1,
        endInclusive: 3,
        priorContext: const [],
      );
      expect(body.toLowerCase(), contains('self-contained'));
    });
  });
}
