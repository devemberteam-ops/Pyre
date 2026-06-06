import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/live_sheet.dart';
import 'package:pyre/services/memory.dart' show computePathHash;

void main() {
  group('LiveSheetFact', () {
    test('round-trips text + locked', () {
      final f = LiveSheetFact(text: 'demon horns', locked: true);
      final back = LiveSheetFact.fromJson(f.toJson());
      expect(back.text, 'demon horns');
      expect(back.locked, true);
    });
    test('locked omitted from json when false; default false on parse', () {
      expect(LiveSheetFact(text: 'x').toJson().containsKey('locked'), false);
      expect(LiveSheetFact.fromJson({'text': 'x'}).locked, false);
    });
  });
  group('LiveSheetSection labels', () {
    test('label + parse round-trip, case-insensitive', () {
      expect(LiveSheetSection.clothing.label, 'Clothing');
      expect(liveSheetSectionFromLabel('clothing'), LiveSheetSection.clothing);
      expect(liveSheetSectionFromLabel('  POSSESSIONS '), LiveSheetSection.possessions);
      expect(liveSheetSectionFromLabel('nonsense'), isNull);
    });
  });
  group('LiveSheetEntity', () {
    test('round-trips kind + sections', () {
      final e = LiveSheetEntity(id: 'e1', name: 'Ren', kind: LiveSheetEntityKind.user, sections: {
        LiveSheetSection.clothing: [LiveSheetFact(text: 'only underwear')],
        LiveSheetSection.conditions: [LiveSheetFact(text: 'pregnant (slime)', locked: true)],
      });
      final back = LiveSheetEntity.fromJson(e.toJson());
      expect(back.name, 'Ren');
      expect(back.kind, LiveSheetEntityKind.user);
      expect(back.sections[LiveSheetSection.clothing]!.first.text, 'only underwear');
      expect(back.sections[LiveSheetSection.conditions]!.first.locked, true);
      expect(back.sections[LiveSheetSection.facts], isEmpty);
    });
  });
  group('LiveSheetSnapshot', () {
    test('round-trips entities + anchor + pathHash', () {
      final s = LiveSheetSnapshot(id: 's1', anchorMessageId: 'm9', pathHash: 'h',
        entities: [LiveSheetEntity(id: 'e1', name: 'Ren', kind: LiveSheetEntityKind.char)]);
      final back = LiveSheetSnapshot.fromJson(s.toJson());
      expect(back.anchorMessageId, 'm9');
      expect(back.pathHash, 'h');
      expect(back.entities.single.name, 'Ren');
    });
    test('fromJson tolerates an unknown future "scene" key (forward-compat)', () {
      final j = {'id': 's1', 'anchorMessageId': 'm1', 'pathHash': '', 'entities': <dynamic>[],
        'scene': {'location': [{'text': 'temple'}]}};
      expect(LiveSheetSnapshot.fromJson(j).entities, isEmpty);
    });
  });
  group('LiveSheetSettings', () {
    test('defaults: autoEvery 10, prompts non-empty', () {
      final s = LiveSheetSettings.fromJson({});
      expect(s.autoEvery, 10);
      expect(s.updatePrompt.trim(), isNotEmpty);
      expect(s.seedPrompt.trim(), isNotEmpty);
    });
    test('round-trips', () {
      final s = LiveSheetSettings(autoEvery: 5, updatePrompt: 'u', seedPrompt: 'se');
      final back = LiveSheetSettings.fromJson(s.toJson());
      expect(back.autoEvery, 5);
      expect(back.updatePrompt, 'u');
      expect(back.seedPrompt, 'se');
    });
  });
  group('Chat live sheet fields', () {
    test('a NEW chat defaults Live Sheet to ENABLED', () {
      // Live Sheet is a strong feature; a freshly-created chat (constructor
      // path, e.g. startChatWith / chat import) should have it on by default.
      final c = Chat(id: 'c1', characterIds: const ['x']);
      expect(c.liveSheetEnabled, true);
      expect(c.liveSheetSnapshots, isEmpty);
    });
    test('an EXISTING saved chat with no field stays DISABLED (fromJson)', () {
      // Backwards-compat: a chat persisted before the default flip (the field
      // is absent) must NOT silently turn Live Sheet on.
      final c = Chat.fromJson({'id': 'c1'});
      expect(c.liveSheetSnapshots, isEmpty);
      expect(c.liveSheetEnabled, false);
    });
    test('a saved chat with the field set is honoured (fromJson)', () {
      expect(
          Chat.fromJson({'id': 'c1', 'liveSheetEnabled': true}).liveSheetEnabled,
          true);
      expect(
          Chat.fromJson({'id': 'c1', 'liveSheetEnabled': false})
              .liveSheetEnabled,
          false);
    });
    test('round-trips snapshots + enabled', () {
      final c = Chat.fromJson({'id': 'c1'})
        ..liveSheetEnabled = true
        ..liveSheetSnapshots.add(LiveSheetSnapshot(id: 's1', anchorMessageId: 'm0', pathHash: ''));
      final back = Chat.fromJson(c.toJson());
      expect(back.liveSheetEnabled, true);
      expect(back.liveSheetSnapshots.single.id, 's1');
    });
  });

  // -------------------------------------------------------------------------
  // Wave CY.18.171: pure functions
  // -------------------------------------------------------------------------

  group('parseLiveSheetDelta', () {
    test('NO_CHANGE → noChange, no ops', () {
      final d = parseLiveSheetDelta('NO_CHANGE');
      expect(d.noChange, true);
      expect(d.ops, isEmpty);
    });
    test('parses + / - per entity + section', () {
      final d = parseLiveSheetDelta(
          'ENTITY: Ren\n+ Conditions: pregnant (slime)\n- Possessions: phone\nENTITY: Vesna\n+ Appearance: demon horns\n');
      expect(d.noChange, false);
      expect(d.ops.length, 3);
      final ren = d.ops.where((o) => o.entityName == 'Ren').toList();
      expect(
          ren.any((o) =>
              o.isAdd &&
              o.section == LiveSheetSection.conditions &&
              o.text == 'pregnant (slime)'),
          true);
      expect(
          ren.any((o) =>
              !o.isAdd &&
              o.section == LiveSheetSection.possessions &&
              o.text == 'phone'),
          true);
    });
    test('tolerates markdown noise + unknown sections (skipped)', () {
      final d = parseLiveSheetDelta(
          '**ENTITY: Ren**\n+ **Clothing**: only underwear\n+ Mood: happy\n');
      expect(d.ops.length, 1);
      expect(d.ops.single.section, LiveSheetSection.clothing);
      expect(d.ops.single.text, 'only underwear');
    });
    test('lines before any ENTITY are ignored', () {
      expect(parseLiveSheetDelta('+ Clothing: x').ops, isEmpty);
    });
    test('fact text containing a colon is preserved', () {
      final d = parseLiveSheetDelta('ENTITY: Ren\n+ Possessions: key: brass');
      expect(d.ops.single.text, 'key: brass');
    });
  });

  group('applyLiveSheetDelta', () {
    LiveSheetSnapshot prev() => LiveSheetSnapshot(
            id: 's0',
            anchorMessageId: 'm0',
            pathHash: 'h0',
            entities: [
              LiveSheetEntity(
                  id: 'e1',
                  name: 'Ren',
                  kind: LiveSheetEntityKind.user,
                  sections: {
                    LiveSheetSection.possessions: [
                      LiveSheetFact(text: 'phone')
                    ],
                    LiveSheetSection.conditions: [
                      LiveSheetFact(text: 'cursed', locked: true)
                    ],
                  })
            ]);

    test('add + remove on a tracked entity', () {
      final d = parseLiveSheetDelta(
          'ENTITY: Ren\n+ Conditions: pregnant\n- Possessions: phone');
      final out = applyLiveSheetDelta(
          prev: prev(), delta: d, anchorMessageId: 'm5', pathHash: 'h5');
      final ren = out.entities.single;
      expect(ren.sections[LiveSheetSection.possessions]!, isEmpty);
      expect(ren.sections[LiveSheetSection.conditions]!.map((f) => f.text),
          contains('pregnant'));
      expect(out.anchorMessageId, 'm5');
      expect(out.pathHash, 'h5');
      expect(out.id, isNot('s0'));
    });

    test('locked fact is never removed', () {
      final d = parseLiveSheetDelta('ENTITY: Ren\n- Conditions: cursed');
      final out = applyLiveSheetDelta(
          prev: prev(), delta: d, anchorMessageId: 'm5', pathHash: 'h5');
      expect(
          out.entities.single.sections[LiveSheetSection.conditions]!
              .map((f) => f.text),
          contains('cursed'));
    });

    test('add dedups by normalized text', () {
      final d = parseLiveSheetDelta('ENTITY: Ren\n+ Possessions: PHONE');
      final out = applyLiveSheetDelta(
          prev: prev(), delta: d, anchorMessageId: 'm5', pathHash: 'h5');
      expect(
          out.entities.single.sections[LiveSheetSection.possessions]!.length,
          1);
    });

    // Wave CY.18.219: an ADD op naming an untracked character auto-creates it
    // as a new npc entity (newly-prominent NPC); a REMOVE op for an unknown
    // entity is still a no-op.
    test('add op for an unknown entity auto-creates it as an npc', () {
      final d = parseLiveSheetDelta(
          'ENTITY: Zasha\n+ Appearance: wolfkin delver, female\n+ Facts: of the Charter');
      final out = applyLiveSheetDelta(
          prev: prev(), delta: d, anchorMessageId: 'm5', pathHash: 'h5');
      expect(out.entities.length, 2);
      final zasha =
          out.entities.firstWhere((e) => e.name == 'Zasha');
      expect(zasha.kind, LiveSheetEntityKind.npc);
      expect(zasha.sections[LiveSheetSection.appearance]!.map((f) => f.text),
          contains('wolfkin delver, female'));
      expect(zasha.sections[LiveSheetSection.facts]!.map((f) => f.text),
          contains('of the Charter'));
    });

    test('remove op for an unknown entity is a no-op (no auto-create)', () {
      final d = parseLiveSheetDelta('ENTITY: Goblin\n- Facts: appeared');
      final out = applyLiveSheetDelta(
          prev: prev(), delta: d, anchorMessageId: 'm5', pathHash: 'h5');
      expect(out.entities.length, 1);
      expect(out.entities.single.name, 'Ren');
    });

    test('prev is not mutated', () {
      final p = prev();
      final d = parseLiveSheetDelta('ENTITY: Ren\n- Possessions: phone');
      applyLiveSheetDelta(
          prev: p, delta: d, anchorMessageId: 'm5', pathHash: 'h5');
      expect(
          p.entities.single.sections[LiveSheetSection.possessions]!.length, 1);
    });

    // Wave CY.18.244: a decorated/aliased op name for the user entity must
    // merge into the EXISTING user entity, never spawn a duplicate NPC.
    LiveSheetSnapshot userOnly(String name) => LiveSheetSnapshot(
            id: 's0',
            anchorMessageId: 'm0',
            pathHash: 'h0',
            entities: [
              LiveSheetEntity(
                  id: 'e1', name: name, kind: LiveSheetEntityKind.user)
            ]);

    test('decorated "You (the user / {{user}})" op merges into "You"', () {
      final d = parseLiveSheetDelta(
          'ENTITY: You (the user / {{user}})\n+ Clothing: only underwear');
      final out = applyLiveSheetDelta(
          prev: userOnly('You'),
          delta: d,
          anchorMessageId: 'm5',
          pathHash: 'h5');
      expect(out.entities.length, 1);
      final you = out.entities.single;
      expect(you.name, 'You');
      expect(you.kind, LiveSheetEntityKind.user);
      expect(you.sections[LiveSheetSection.clothing]!.map((f) => f.text),
          contains('only underwear'));
      // no decorated duplicate created
      expect(out.entities.any((e) => e.name.contains('(')), false);
    });

    test('decorated "Ren (the user / {{user}})" op merges into "Ren"', () {
      final d = parseLiveSheetDelta(
          'ENTITY: Ren (the user / {{user}})\n+ Conditions: exhausted');
      final out = applyLiveSheetDelta(
          prev: userOnly('Ren'),
          delta: d,
          anchorMessageId: 'm5',
          pathHash: 'h5');
      expect(out.entities.length, 1);
      expect(out.entities.single.name, 'Ren');
      expect(out.entities.single.sections[LiveSheetSection.conditions]!
          .map((f) => f.text), contains('exhausted'));
    });

    test('op named "{{user}}" maps to the existing user entity', () {
      final d = parseLiveSheetDelta('ENTITY: {{user}}\n+ Possessions: a torch');
      final out = applyLiveSheetDelta(
          prev: userOnly('Ren'),
          delta: d,
          anchorMessageId: 'm5',
          pathHash: 'h5');
      expect(out.entities.length, 1);
      expect(out.entities.single.name, 'Ren');
      expect(out.entities.single.sections[LiveSheetSection.possessions]!
          .map((f) => f.text), contains('a torch'));
    });

    test('op named "the user" maps to the existing user entity', () {
      final d = parseLiveSheetDelta('ENTITY: the user\n+ Conditions: wounded');
      final out = applyLiveSheetDelta(
          prev: userOnly('Ren'),
          delta: d,
          anchorMessageId: 'm5',
          pathHash: 'h5');
      expect(out.entities.length, 1);
      expect(out.entities.single.name, 'Ren');
      expect(out.entities.single.sections[LiveSheetSection.conditions]!
          .map((f) => f.text), contains('wounded'));
    });

    test('ADD op for a genuinely new name STILL auto-creates an npc', () {
      // NPC auto-add preserved even when a user entity is present.
      final d = parseLiveSheetDelta(
          'ENTITY: Sehka\n+ Appearance: scarred mercenary');
      final out = applyLiveSheetDelta(
          prev: userOnly('Ren'),
          delta: d,
          anchorMessageId: 'm5',
          pathHash: 'h5');
      expect(out.entities.length, 2);
      final sehka = out.entities.firstWhere((e) => e.name == 'Sehka');
      expect(sehka.kind, LiveSheetEntityKind.npc);
      expect(sehka.sections[LiveSheetSection.appearance]!.map((f) => f.text),
          contains('scarred mercenary'));
    });
  });

  group('activeLiveSheetSnapshot', () {
    Message msg(String id, MessageKind k) =>
        Message(id: id, kind: k, variants: ['x']);

    test('returns most-recent snapshot whose anchor is on the current path',
        () {
      final c = Chat.fromJson({'id': 'c1'});
      c.messages.addAll([
        msg('m0', MessageKind.user),
        msg('m1', MessageKind.char),
        msg('m2', MessageKind.user),
        msg('m3', MessageKind.char)
      ]);
      String ph(int i) => computePathHash(c.messages, i);
      c.liveSheetSnapshots.addAll([
        LiveSheetSnapshot(
            id: 'a', anchorMessageId: 'm1', pathHash: ph(1)),
        LiveSheetSnapshot(
            id: 'b', anchorMessageId: 'm3', pathHash: ph(3)),
      ]);
      expect(activeLiveSheetSnapshot(c)!.id, 'b');
    });

    test(
        'excludes snapshots whose anchor id is not in the current messages', () {
      final c = Chat.fromJson({'id': 'c1'});
      c.messages.addAll([
        msg('m0', MessageKind.user),
        msg('m1', MessageKind.char)
      ]);
      c.liveSheetSnapshots
          .add(LiveSheetSnapshot(id: 'a', anchorMessageId: 'GONE', pathHash: 'whatever'));
      expect(activeLiveSheetSnapshot(c), isNull);
    });

    test(
        'excludes snapshots whose pathHash no longer matches (branch diverged)',
        () {
      final c = Chat.fromJson({'id': 'c1'});
      c.messages.addAll([
        msg('m0', MessageKind.user),
        msg('m1', MessageKind.char)
      ]);
      c.liveSheetSnapshots
          .add(LiveSheetSnapshot(id: 'a', anchorMessageId: 'm1', pathHash: 'STALE'));
      expect(activeLiveSheetSnapshot(c), isNull);
    });

    test('empty path hash is treated as always-valid (legacy/manual)', () {
      final c = Chat.fromJson({'id': 'c1'});
      c.messages.addAll([msg('m0', MessageKind.user)]);
      c.liveSheetSnapshots
          .add(LiveSheetSnapshot(id: 'a', anchorMessageId: 'm0', pathHash: ''));
      expect(activeLiveSheetSnapshot(c)!.id, 'a');
    });
  });

  group('cadence', () {
    Message msg(String id, MessageKind k) =>
        Message(id: id, kind: k, variants: ['x']);

    test('counts assistant (char) turns after the active snapshot anchor', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([
        msg('m0', MessageKind.user),
        msg('m1', MessageKind.char),
        msg('m2', MessageKind.user),
        msg('m3', MessageKind.char),
        msg('m4', MessageKind.ooc),
        msg('m5', MessageKind.char)
      ]);
      c.liveSheetSnapshots.add(LiveSheetSnapshot(
          id: 'a',
          anchorMessageId: 'm1',
          pathHash: computePathHash(c.messages, 1)));
      expect(turnsSinceActiveSnapshot(c), 2);
    });

    test('no active snapshot → counts all char turns', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages
          .addAll([msg('m0', MessageKind.char), msg('m1', MessageKind.char)]);
      expect(turnsSinceActiveSnapshot(c), 2);
    });

    test('shouldUpdateLiveSheet honors enabled + autoEvery + no-snapshot guard',
        () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([msg('m0', MessageKind.char)]);
      expect(shouldUpdateLiveSheet(c, LiveSheetSettings(autoEvery: 1)),
          false); // no snapshot yet
      c.liveSheetSnapshots.add(LiveSheetSnapshot(
          id: 'a',
          anchorMessageId: 'm0',
          pathHash: computePathHash(c.messages, 0)));
      c.messages.add(msg('m1', MessageKind.char));
      expect(shouldUpdateLiveSheet(c, LiveSheetSettings(autoEvery: 1)), true);
      expect(shouldUpdateLiveSheet(c, LiveSheetSettings(autoEvery: 0)), false);
      c.liveSheetEnabled = false;
      expect(shouldUpdateLiveSheet(c, LiveSheetSettings(autoEvery: 1)), false);
    });
  });

  // Wave CY.18.245: predicate driving the manual "Update state now" branch.
  group('liveSheetHasNewMessages', () {
    Message msg(String id, MessageKind k) =>
        Message(id: id, kind: k, variants: ['x']);

    test('false when there are no snapshots', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([msg('m0', MessageKind.char), msg('m1', MessageKind.user)]);
      expect(liveSheetHasNewMessages(c), false);
    });

    test('false when the active snapshot is anchored at the LAST message', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([
        msg('m0', MessageKind.char),
        msg('m1', MessageKind.user),
      ]);
      // Anchor at the latest message (the enable-mid-chat case).
      c.liveSheetSnapshots.add(LiveSheetSnapshot(
          id: 'a',
          anchorMessageId: 'm1',
          pathHash: computePathHash(c.messages, 1)));
      expect(liveSheetHasNewMessages(c), false);
    });

    test('true when a message exists AFTER the active snapshot anchor', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([
        msg('m0', MessageKind.char),
        msg('m1', MessageKind.user),
        msg('m2', MessageKind.char),
      ]);
      // Anchor at an EARLIER message so a later message is unprocessed.
      c.liveSheetSnapshots.add(LiveSheetSnapshot(
          id: 'a',
          anchorMessageId: 'm1',
          pathHash: computePathHash(c.messages, 1)));
      expect(liveSheetHasNewMessages(c), true);
    });
  });

  group('buildLiveSheetBlock', () {
    Message msg(String id, MessageKind k) =>
        Message(id: id, kind: k, variants: ['x']);

    Chat chatWith(LiveSheetEntity e) {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.add(msg('m0', MessageKind.char));
      c.liveSheetSnapshots.add(LiveSheetSnapshot(
          id: 'a',
          anchorMessageId: 'm0',
          pathHash: computePathHash(c.messages, 0),
          entities: [e]));
      return c;
    }

    test('empty when disabled', () {
      final c = chatWith(LiveSheetEntity(
          id: 'e',
          name: 'Ren',
          kind: LiveSheetEntityKind.user,
          sections: {
            LiveSheetSection.clothing: [LiveSheetFact(text: 'naked')]
          }))
        ..liveSheetEnabled = false;
      expect(buildLiveSheetBlock(c), '');
    });

    test('empty when no active snapshot', () {
      expect(
          buildLiveSheetBlock(
              Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true),
          '');
    });

    test('renders header + entity + non-empty sections only', () {
      final c = chatWith(LiveSheetEntity(
          id: 'e',
          name: 'Ren',
          kind: LiveSheetEntityKind.user,
          sections: {
            LiveSheetSection.clothing: [LiveSheetFact(text: 'only underwear')],
            LiveSheetSection.conditions: [
              LiveSheetFact(text: 'pregnant (slime)')
            ],
          }));
      final out = buildLiveSheetBlock(c);
      expect(out, contains('Current state (authoritative'));
      expect(out, contains('[Ren] (you)'));
      expect(out, contains('Clothing: only underwear'));
      expect(out, contains('Conditions: pregnant (slime)'));
      expect(out, isNot(contains('Possessions')));
    });

    test('entity with no facts is skipped; all-empty → empty string', () {
      final c =
          chatWith(LiveSheetEntity(id: 'e', name: 'Ren', kind: LiveSheetEntityKind.char));
      expect(buildLiveSheetBlock(c), '');
    });
  });

  group('parseSeedSheet', () {
    test('parses labelled lines into sections; unknown labels ignored', () {
      final m = parseSeedSheet(
          "Appearance: 21yo femboy, pale\nClothing: hoodie, thigh-highs\nMood: anxious\nFacts: isekai'd outsider\n");
      expect(m[LiveSheetSection.appearance]!.single.text, '21yo femboy, pale');
      expect(m[LiveSheetSection.clothing]!.single.text, 'hoodie, thigh-highs');
      expect(m[LiveSheetSection.facts]!.single.text, "isekai'd outsider");
      expect(m[LiveSheetSection.conditions]!, isEmpty);
    });

    test('multiple lines under one section accumulate', () {
      final m = parseSeedSheet('Possessions: sword\nPossessions: shield');
      expect(m[LiveSheetSection.possessions]!.map((f) => f.text),
          ['sword', 'shield']);
    });
    test('seed fact text containing a colon is preserved', () {
      final m = parseSeedSheet('Possessions: potion: HP recovery');
      expect(m[LiveSheetSection.possessions]!.single.text, 'potion: HP recovery');
    });
    test('seed dedups identical facts in a section', () {
      final m = parseSeedSheet('Clothing: naked\nClothing: NAKED');
      expect(m[LiveSheetSection.clothing]!.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Wave CY.18.172: buildUpdateBody + seedInitialSnapshot
  // -------------------------------------------------------------------------

  group('buildUpdateBody', () {
    Message msg(String id, MessageKind k, String t) =>
        Message(id: id, kind: k, variants: [t]);
    test('serializes tracked entities (with [LOCKED]) + recent messages since anchor', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([
        msg('m0', MessageKind.char, 'opening'),
        msg('m1', MessageKind.user, 'I get dressed'),
        msg('m2', MessageKind.char, 'the slime lunges'),
      ]);
      final snap = LiveSheetSnapshot(id: 'a', anchorMessageId: 'm0', pathHash: computePathHash(c.messages, 0),
        entities: [LiveSheetEntity(id: 'e', name: 'Ren', kind: LiveSheetEntityKind.user, sections: {
          LiveSheetSection.conditions: [LiveSheetFact(text: 'cursed', locked: true)],
        })]);
      final body = buildUpdateBody(chat: c, active: snap);
      expect(body, contains('Ren'));
      expect(body, contains('[LOCKED]'));
      expect(body, contains('cursed'));
      expect(body, contains('I get dressed'));
      expect(body, contains('the slime lunges'));
      expect(body, isNot(contains('opening'))); // anchor message itself excluded
    });

    // Wave CY.18.244: the user entity's ENTITY label must be the BARE name
    // (so the model echoes it verbatim), with the "is the user" hint on a
    // SEPARATE annotation line.
    test('user entity label is a bare name + separate annotation', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([
        msg('m0', MessageKind.char, 'opening'),
        msg('m1', MessageKind.user, 'I look around'),
      ]);
      final snap = LiveSheetSnapshot(
          id: 'a',
          anchorMessageId: 'm0',
          pathHash: computePathHash(c.messages, 0),
          entities: [
            LiveSheetEntity(
                id: 'e', name: 'You', kind: LiveSheetEntityKind.user)
          ]);
      final body = buildUpdateBody(chat: c, active: snap);
      expect(body, contains('ENTITY: You'));
      expect(body, isNot(contains('ENTITY: You (the user / {{user}})')));
      expect(body, contains('this entity is the user'));
    });

    // chat-core-1-01: assistant <think> reasoning must not bleed into the
    // Live Sheet update source body.
    test('strips <think> from char turns; keeps user text intact', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.addAll([
        msg('m0', MessageKind.char, 'opening'),
        msg('m1', MessageKind.user, 'I draw my <think>not reasoning</think> blade'),
        msg('m2', MessageKind.char,
            '<think>she should react with fear</think>the slime lunges'),
      ]);
      final snap = LiveSheetSnapshot(
          id: 'a',
          anchorMessageId: 'm0',
          pathHash: computePathHash(c.messages, 0),
          entities: [
            LiveSheetEntity(id: 'e', name: 'Ren', kind: LiveSheetEntityKind.user)
          ]);
      final body = buildUpdateBody(chat: c, active: snap);
      // char turn reasoning is gone.
      expect(body, contains('the slime lunges'));
      expect(body, isNot(contains('she should react')));
      expect(body, isNot(contains('<think>she should react')));
      // user turn is left verbatim (only assistant bodies carry reasoning).
      expect(body, contains('I draw my <think>not reasoning</think> blade'));
    });
  });

  group('seedInitialSnapshot', () {
    test('builds an empty snapshot with the given entities anchored at head', () {
      final c = Chat.fromJson({'id': 'c1'})..liveSheetEnabled = true;
      c.messages.add(Message(id: 'm0', kind: MessageKind.char, variants: ['x']));
      final snap = seedInitialSnapshot(c, [LiveSheetEntity(id: 'e1', name: 'Ren', kind: LiveSheetEntityKind.user)]);
      expect(snap.anchorMessageId, 'm0');
      expect(snap.pathHash, computePathHash(c.messages, 0));
      expect(snap.entities.single.name, 'Ren');
      expect(snap.entities.single.hasAnyFact, false);
    });
  });

  // C-3: Live Sheet defaults ON for new chats but nothing seeded a snapshot, so
  // the default-ON flag was inert. ensureLiveSheetSeed (called at chat creation
  // + by the screen) must seed an active snapshot so the auto-updater can fire.
  group('buildLiveSheetEntities', () {
    test('persona becomes the user entity; characters become char entities', () {
      final ents = buildLiveSheetEntities(
        personaName: 'Ren',
        characters: [Character(id: 'a', name: 'Vesna')],
      );
      expect(ents.length, 2);
      expect(ents.first.name, 'Ren');
      expect(ents.first.kind, LiveSheetEntityKind.user);
      expect(ents[1].name, 'Vesna');
      expect(ents[1].kind, LiveSheetEntityKind.char);
    });

    test('null/blank persona falls back to "You"', () {
      expect(
        buildLiveSheetEntities(personaName: null, characters: const [])
            .single
            .name,
        'You',
      );
      expect(
        buildLiveSheetEntities(personaName: '   ', characters: const [])
            .single
            .name,
        'You',
      );
    });

    test('a narrator/scenario card is NOT seeded as a physical entity', () {
      final ents = buildLiveSheetEntities(
        personaName: 'Ren',
        characters: [
          Character(
              id: 's',
              name: 'The Sunken Gate',
              description: '<Narrator>\nYou are the omniscient narrator.'),
          Character(id: 'a', name: 'Vesna'),
        ],
      );
      // user + Vesna only; the narrator card is skipped.
      expect(ents.map((e) => e.name), ['Ren', 'Vesna']);
    });
  });

  group('ensureLiveSheetSeed', () {
    Chat newEnabledChat() {
      final c = Chat(id: 'c1', characterIds: const ['a']);
      c.messages
          .add(Message(id: 'm0', kind: MessageKind.char, variants: ['hi']));
      return c;
    }

    test('FAILING-BEFORE-FIX: a default-ON new chat has NO active snapshot '
        'until seeded; ensureLiveSheetSeed creates one', () {
      final c = newEnabledChat();
      // Reproduces the bug: liveSheetEnabled is true but nothing seeded.
      expect(c.liveSheetEnabled, true);
      expect(activeLiveSheetSnapshot(c), isNull);
      expect(shouldUpdateLiveSheet(c, LiveSheetSettings.fromJson({})), false,
          reason: 'no snapshot → the auto-updater can never fire (the bug)');

      final seeded = ensureLiveSheetSeed(
        chat: c,
        personaName: 'Ren',
        characters: [Character(id: 'a', name: 'Vesna')],
      );
      expect(seeded, true);
      expect(activeLiveSheetSnapshot(c), isNotNull,
          reason: 'the fix: an active snapshot now exists → tracking starts');
      expect(activeLiveSheetSnapshot(c)!.entities.map((e) => e.name),
          ['Ren', 'Vesna']);
    });

    test('idempotent: does NOT double-seed when a snapshot already exists', () {
      final c = newEnabledChat();
      expect(
          ensureLiveSheetSeed(
              chat: c, personaName: 'Ren', characters: const []),
          true);
      expect(c.liveSheetSnapshots.length, 1);
      // A second call is a no-op (active snapshot already present).
      expect(
          ensureLiveSheetSeed(
              chat: c, personaName: 'Ren', characters: const []),
          false);
      expect(c.liveSheetSnapshots.length, 1);
    });

    test('no-op when Live Sheet is disabled', () {
      final c = newEnabledChat()..liveSheetEnabled = false;
      expect(
          ensureLiveSheetSeed(
              chat: c, personaName: 'Ren', characters: const []),
          false);
      expect(c.liveSheetSnapshots, isEmpty);
    });
  });
}
