import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/story_roadmap.dart';

void main() {
  group('StoryBeat', () {
    test('round-trips text + done + mtime', () {
      final b = StoryBeat(id: 'b1', text: 'guild ambush', done: true, mtime: 7);
      final back = StoryBeat.fromJson(b.toJson());
      expect(back.id, 'b1');
      expect(back.text, 'guild ambush');
      expect(back.done, true);
      expect(back.mtime, 7);
    });
    test('done omitted from json when false; defaults on parse', () {
      expect(StoryBeat(id: 'b', text: 'x').toJson().containsKey('done'), false);
      final p = StoryBeat.fromJson({'text': 'x'});
      expect(p.done, false);
      expect(p.id, isNotEmpty);
    });
  });

  group('Chat.storyBeats', () {
    test('defaults empty', () {
      expect(Chat.fromJson({'id': 'c1'}).storyBeats, isEmpty);
    });
    test('round-trips text + done + mtime through Chat.toJson/fromJson', () {
      final c = Chat.fromJson({'id': 'c1'})
        ..storyBeats.add(StoryBeat(id: 'b1', text: 'reveal', done: true, mtime: 42));
      final back = Chat.fromJson(c.toJson());
      expect(back.storyBeats.single.text, 'reveal');
      expect(back.storyBeats.single.done, true);
      expect(back.storyBeats.single.mtime, 42);
    });
  });

  group('buildStoryRoadmapBlock', () {
    Chat chatWith(List<StoryBeat> beats) =>
        Chat.fromJson({'id': 'c1'})..storyBeats.addAll(beats);

    test('empty when no beats', () {
      expect(buildStoryRoadmapBlock(Chat.fromJson({'id': 'c1'})), '');
    });
    test('empty when all beats done or blank', () {
      final c = chatWith([
        StoryBeat(id: 'a', text: 'x', done: true),
        StoryBeat(id: 'b', text: '   '),
      ]);
      expect(buildStoryRoadmapBlock(c), '');
    });
    test('includes active beats with framing; excludes done', () {
      final c = chatWith([
        StoryBeat(id: 'a', text: 'guild ambush'),
        StoryBeat(id: 'b', text: 'mystery woman reveal', done: true),
        StoryBeat(id: 'c', text: 'the baby is half-X'),
      ]);
      final out = buildStoryRoadmapBlock(c);
      expect(out, contains('roadmap'));
      expect(out, contains('GRADUALLY'));
      expect(out, contains('guild ambush'));
      expect(out, contains('the baby is half-X'));
      expect(out, isNot(contains('mystery woman reveal')));
    });
    // Wave CY.18.221: beat specifics must be withheld until the condition.
    test('framing instructs to withhold a beat\'s specific payload', () {
      final c = chatWith([StoryBeat(id: 'a', text: 'a beat')]);
      final out = buildStoryRoadmapBlock(c);
      expect(out, contains('do NOT state'));
      expect(out, contains('SPECIFIC payload'));
    });
  });

  group('buildStoryRoadmapBlock beatsCap', () {
    Chat chatWith(List<StoryBeat> beats) =>
        Chat.fromJson({'id': 'c1'})..storyBeats.addAll(beats);

    test('beatsCap=0 includes all active beats', () {
      final c = chatWith([
        StoryBeat(id: 'a', text: 'beat 1'),
        StoryBeat(id: 'b', text: 'beat 2'),
        StoryBeat(id: 'c', text: 'beat 3'),
      ]);
      final out = buildStoryRoadmapBlock(c, beatsCap: 0);
      expect(out, contains('beat 1'));
      expect(out, contains('beat 2'));
      expect(out, contains('beat 3'));
    });
    test('beatsCap=2 only includes first 2 active beats', () {
      final c = chatWith([
        StoryBeat(id: 'a', text: 'beat 1'),
        StoryBeat(id: 'b', text: 'beat 2'),
        StoryBeat(id: 'c', text: 'beat 3'),
      ]);
      final out = buildStoryRoadmapBlock(c, beatsCap: 2);
      expect(out, contains('beat 1'));
      expect(out, contains('beat 2'));
      expect(out, isNot(contains('beat 3')));
    });
    test('beatsCap larger than list includes all', () {
      final c = chatWith([
        StoryBeat(id: 'a', text: 'only beat'),
      ]);
      final out = buildStoryRoadmapBlock(c, beatsCap: 10);
      expect(out, contains('only beat'));
    });
    test('beatsCap respects done filter before cap', () {
      final c = chatWith([
        StoryBeat(id: 'a', text: 'active 1'),
        StoryBeat(id: 'b', text: 'done beat', done: true),
        StoryBeat(id: 'c', text: 'active 2'),
        StoryBeat(id: 'd', text: 'active 3'),
      ]);
      // cap=2 from the active set (not the raw list)
      final out = buildStoryRoadmapBlock(c, beatsCap: 2);
      expect(out, contains('active 1'));
      expect(out, contains('active 2'));
      expect(out, isNot(contains('active 3')));
      expect(out, isNot(contains('done beat')));
    });
  });

  group('appendStoryBeat', () {
    test('appends an active beat with trimmed text; returns it', () {
      final c = Chat.fromJson({'id': 'c1'});
      final b = appendStoryBeat(c, '  ao chegar na guilda...  ');
      expect(b, isNotNull);
      expect(c.storyBeats.single.text, 'ao chegar na guilda...');
      expect(c.storyBeats.single.done, false);
    });
    test('blank text is a no-op (returns null)', () {
      final c = Chat.fromJson({'id': 'c1'});
      expect(appendStoryBeat(c, '   '), isNull);
      expect(c.storyBeats, isEmpty);
    });
  });

  group('ScriptSettings', () {
    test('default beatsCap is 0', () {
      expect(ScriptSettings().beatsCap, 0);
    });
    test('round-trips beatsCap through JSON', () {
      final s = ScriptSettings(beatsCap: 5);
      final back = ScriptSettings.fromJson(s.toJson());
      expect(back.beatsCap, 5);
    });
    test('fromJson with missing key falls back to 0', () {
      expect(ScriptSettings.fromJson({}).beatsCap, 0);
    });
    test('fromJson with explicit 0 yields 0', () {
      expect(ScriptSettings.fromJson({'beatsCap': 0}).beatsCap, 0);
    });
  });
}
