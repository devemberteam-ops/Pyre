// SillyTavern full-backup (.zip) import tests — the PURE layer.
//
// We build a SMALL synthetic in-memory zip with ZipEncoder (NO dependency on
// any machine-specific path) and assert that planStBackupCore:
//   - routes characters/ worlds/ OpenAI Settings/ chats/ + settings.json regex,
//   - SKIPS secrets.json and backgrounds/ (and never surfaces secrets),
//   - SKIPS nested sprite subfolders under characters/.
//
// chatFromStJsonl is tested directly (header skip, swipes→variants,
// swipe_id→selectedVariant, is_user/is_system→kind, single-`mes` fallback,
// garbage-line tolerance).
//
// regexRulesFromSettings is tested directly (array present → rules;
// missing / wrong-typed → empty, never throws).
//
// An OPTIONAL real-zip smoke test is guarded by File(...).existsSync() so it's
// a NO-OP skip on machines without the owner's sample backup.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/st_backup_import.dart';
import 'package:pyre/services/st_chat_import.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// CRC32 over [bytes] (PNG / zip table-driven). Used so the synthetic PNG's
/// chunks carry valid CRCs (the parser skips them, but a faithful fixture is
/// more robust).
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

void _writeUint32(BytesBuilder b, int v) {
  b.addByte((v >> 24) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte(v & 0xFF);
}

void _writeChunk(BytesBuilder out, String type, List<int> data) {
  _writeUint32(out, data.length);
  final typeBytes = ascii.encode(type);
  final body = <int>[...typeBytes, ...data];
  out.add(typeBytes);
  out.add(data);
  _writeUint32(out, _crc32(body));
}

/// Build a MINIMAL valid chara_card PNG: signature + IHDR + a `tEXt chara`
/// chunk holding the base64-encoded chara_card_v2 JSON + IEND.
Uint8List _charaPng(Map<String, dynamic> data) {
  final cardJson = jsonEncode({'spec': 'chara_card_v2', 'data': data});
  final b64 = base64Encode(utf8.encode(cardJson));
  final out = BytesBuilder();
  // PNG signature.
  out.add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  // IHDR — 1x1, 8-bit greyscale (content irrelevant to the chara parser).
  final ihdr = BytesBuilder();
  _writeUint32(ihdr, 1); // width
  _writeUint32(ihdr, 1); // height
  ihdr.addByte(8); // bit depth
  ihdr.addByte(0); // colour type
  ihdr.addByte(0); // compression
  ihdr.addByte(0); // filter
  ihdr.addByte(0); // interlace
  _writeChunk(out, 'IHDR', ihdr.toBytes());
  // tEXt: keyword "chara" \0 base64-json
  final text = <int>[...ascii.encode('chara'), 0, ...ascii.encode(b64)];
  _writeChunk(out, 'tEXt', text);
  // IEND.
  _writeChunk(out, 'IEND', const []);
  return out.toBytes();
}

/// Encode a backup-shaped zip from a path→bytes map.
Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, data) {
    archive.add(ArchiveFile.bytes(name, data));
  });
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

List<int> _jsonBytes(Object json) => utf8.encode(jsonEncode(json));

void main() {
  group('planStBackupCore — folder routing', () {
    late StBackupPlan plan;

    setUp(() {
      final zip = _zip({
        // A top-level character card (PNG).
        'characters/Aria.png': _charaPng({
          'name': 'Aria',
          'description': 'A bard.',
          'first_mes': 'Hello!',
        }),
        // A nested sprite subfolder — MUST be skipped (expression PNG).
        'characters/Aria/joy.png': _charaPng({'name': 'sprite'}),
        // A standalone world / lorebook.
        'worlds/Eldoria.json': _jsonBytes({
          'name': 'Eldoria Lore',
          'entries': {
            '0': {'key': ['Eldoria'], 'content': 'A kingdom.'},
          },
        }),
        // A chat-completion preset.
        'OpenAI Settings/MyPreset.json': _jsonBytes({
          'name': 'MyPreset',
          'temperature': 1.0,
          'prompts': [
            {'identifier': 'main', 'content': 'You are a writer.'},
            {'identifier': 'chatHistory', 'marker': true},
          ],
          'prompt_order': [
            {
              'character_id': 100000,
              'order': [
                {'identifier': 'main', 'enabled': true},
                {'identifier': 'chatHistory', 'enabled': true},
              ],
            },
          ],
        }),
        // settings.json with extension_settings.regex.
        'settings.json': _jsonBytes({
          'extension_settings': {
            'regex': [
              {
                'scriptName': 'Strip asterisks',
                'findRegex': '/\\*/g',
                'replaceString': '',
              },
            ],
          },
          // A decoy "secret" key inside settings — must NOT leak as a regex/etc.
          'api_key_should_be_ignored': 'sk-DEADBEEF-NEVER-SURFACE',
        }),
        // A chat log under the character's folder.
        'chats/Aria/2026-06-04.jsonl': utf8.encode([
          jsonEncode({'user_name': 'unused', 'character_name': 'unused'}),
          jsonEncode({'name': 'Aria', 'is_user': false, 'mes': 'Hi there.'}),
          jsonEncode({'name': 'You', 'is_user': true, 'mes': 'Hello!'}),
        ].join('\n')),
        // MUST be skipped — never read / surfaced.
        'secrets.json': _jsonBytes({
          'api_key_openai': 'sk-SECRET-OPENAI-KEY-DO-NOT-LEAK',
          'api_key_claude': 'sk-ant-SECRET-CLAUDE',
        }),
        // MUST be skipped — media.
        'backgrounds/b.jpg': List<int>.filled(64, 0xAB),
      });
      plan = planStBackupCore(zip);
    });

    test('routes one top-level character card', () {
      expect(plan.characters.length, 1);
      expect(plan.characters.first.name, 'Aria');
    });

    test('skips nested sprite subfolder under characters/', () {
      // Only the top-level Aria.png card — the nested joy.png is NOT a card.
      expect(plan.characters.length, 1);
    });

    test('routes one world → lorebook', () {
      expect(plan.lorebooks.length, 1);
      expect(plan.lorebooks.first.name, 'Eldoria Lore');
      expect(plan.lorebooks.first.entries.length, 1);
    });

    test('routes one chat-completion preset', () {
      expect(plan.presets.length, 1);
      expect(plan.presets.first.name, contains('MyPreset'));
    });

    test('pulls regex from settings.json extension_settings.regex', () {
      expect(plan.regexRules.length, 1);
      expect(plan.regexRules.first.name, 'Strip asterisks');
    });

    test('collects the chat log keyed by character folder', () {
      expect(plan.chats.length, 1);
      expect(plan.chats.first.characterFolder, 'Aria');
    });

    test('skips secrets.json and backgrounds/ (counted as skipped)', () {
      // 2 skipped: secrets.json + backgrounds/b.jpg (the sprite is also
      // skipped, so at least 3 — but never fewer than the secrets+bg pair).
      expect(plan.skippedEntries, greaterThanOrEqualTo(2));
    });

    test('NEVER surfaces any secret value anywhere in the plan', () {
      // Serialize every parsed artifact + raw chat lines and assert the secret
      // strings appear NOWHERE.
      final haystack = StringBuffer()
        ..writeAll(plan.characters.map((c) => jsonEncode(c.toJson())))
        ..writeAll(plan.lorebooks.map((l) => jsonEncode(l.toJson())))
        ..writeAll(plan.presets.map((p) => jsonEncode(p.toJson())))
        ..writeAll(plan.regexRules.map((r) => jsonEncode(r.toJson())))
        ..writeAll(plan.chats.expand((c) => c.lines));
      final text = haystack.toString();
      expect(text, isNot(contains('sk-SECRET-OPENAI-KEY-DO-NOT-LEAK')));
      expect(text, isNot(contains('sk-ant-SECRET-CLAUDE')));
      expect(text, isNot(contains('sk-DEADBEEF-NEVER-SURFACE')));
    });
  });

  group('planStBackupCore — resilience', () {
    test('a corrupt / non-zip blob yields an empty plan (no throw)', () {
      final plan =
          planStBackupCore(Uint8List.fromList(utf8.encode('not a zip at all')));
      expect(plan.characters, isEmpty);
      expect(plan.chats, isEmpty);
    });

    test('a bad card entry is counted as a parse error, not thrown', () {
      final zip = _zip({
        'characters/Broken.png': const [0x89, 0x50, 0x4e, 0x47], // truncated
        'characters/Good.png': _charaPng({'name': 'Good', 'first_mes': 'hi'}),
      });
      final plan = planStBackupCore(zip);
      expect(plan.characters.length, 1);
      expect(plan.characters.first.name, 'Good');
      expect(plan.parseErrors, greaterThanOrEqualTo(1));
    });
  });

  group('regexRulesFromSettings', () {
    test('array present → RegexRules', () {
      final rules = regexRulesFromSettings({
        'extension_settings': {
          'regex': [
            {'scriptName': 'a', 'findRegex': '/a/g', 'replaceString': ''},
            {'scriptName': 'b', 'findRegex': '/b/g', 'replaceString': 'B'},
          ],
        },
      });
      expect(rules.length, 2);
    });

    test('missing extension_settings → empty, no throw', () {
      expect(regexRulesFromSettings({'foo': 'bar'}), isEmpty);
    });

    test('extension_settings present but regex not a list → empty, no throw',
        () {
      expect(
        regexRulesFromSettings({
          'extension_settings': {'regex': 'oops-a-string'},
        }),
        isEmpty,
      );
    });

    test('non-map root → empty, no throw', () {
      expect(regexRulesFromSettings('not a map'), isEmpty);
      expect(regexRulesFromSettings(null), isEmpty);
      expect(regexRulesFromSettings(42), isEmpty);
    });
  });

  group('chatFromStJsonl', () {
    Character char() => Character(id: 'char_test', name: 'Aria');

    test('skips the metadata header line', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused', 'character_name': 'unused'}),
        jsonEncode({'is_user': false, 'mes': 'First real message.'}),
      ], character: char());
      expect(chat, isNotNull);
      expect(chat!.messages.length, 1);
      expect(chat.messages.first.text, 'First real message.');
    });

    test('swipes → variants and swipe_id → selectedVariant', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}), // header
        jsonEncode({
          'is_user': false,
          'mes': 'Option A',
          'swipes': ['Option A', 'Option B', 'Option C'],
          'swipe_id': 2,
        }),
      ], character: char());
      final m = chat!.messages.single;
      expect(m.variants, ['Option A', 'Option B', 'Option C']);
      expect(m.selectedVariant, 2);
      expect(m.text, 'Option C');
    });

    test('out-of-range swipe_id clamps to 0', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}),
        jsonEncode({
          'is_user': false,
          'swipes': ['only one'],
          'swipe_id': 9,
        }),
      ], character: char());
      expect(chat!.messages.single.selectedVariant, 0);
    });

    test('is_user → user kind; is_system → system kind; else char', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}),
        jsonEncode({'is_user': true, 'mes': 'me'}),
        jsonEncode({'is_system': true, 'mes': 'sys'}),
        jsonEncode({'is_user': false, 'mes': 'them'}),
      ], character: char());
      final kinds = chat!.messages.map((m) => m.kind).toList();
      expect(kinds, [MessageKind.user, MessageKind.system, MessageKind.char]);
    });

    test('single `mes` fallback when no swipes', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}),
        jsonEncode({'is_user': false, 'mes': 'just one'}),
      ], character: char());
      final m = chat!.messages.single;
      expect(m.variants, ['just one']);
      expect(m.selectedVariant, 0);
    });

    test('tolerates blank and garbage lines (skips them, no throw)', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}),
        '', // blank
        'this is not json {{{', // garbage
        '   ', // whitespace
        jsonEncode({'is_user': false, 'mes': 'survivor'}),
        '[not, a, message, object]', // valid JSON but not a Map → skipped
      ], character: char());
      expect(chat, isNotNull);
      expect(chat!.messages.single.text, 'survivor');
    });

    test('binds the chat to the passed character', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}),
        jsonEncode({'is_user': false, 'mes': 'hi'}),
      ], character: char());
      expect(chat!.characterIds, ['char_test']);
      expect(chat.characterSnapshots.containsKey('char_test'), isTrue);
      expect(chat.messages.single.characterId, 'char_test');
    });

    test('returns null when nothing usable parses out', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}), // only a header
        '',
      ], character: char());
      expect(chat, isNull);
    });

    test('send_date ISO → createdAt', () {
      final chat = chatFromStJsonl([
        jsonEncode({'user_name': 'unused'}),
        jsonEncode({
          'is_user': false,
          'mes': 'timed',
          'send_date': '2026-01-02T03:04:05.000Z',
        }),
      ], character: char());
      final expected =
          DateTime.parse('2026-01-02T03:04:05.000Z').millisecondsSinceEpoch;
      expect(chat!.messages.single.createdAt, expected);
    });
  });

  // ---------------------------------------------------------------------------
  // Personas (settings.json power_user + User Avatars/ + chat→persona linking).
  // ---------------------------------------------------------------------------
  group('planStBackupCore — personas', () {
    late StBackupPlan plan;
    // 4-byte fake PNG body — the persona avatar path stores raw bytes; the
    // backup core never decodes them, so any bytes are a faithful fixture.
    final avatarBytes = <int>[0x89, 0x50, 0x4e, 0x47];

    setUp(() {
      final zip = _zip({
        'characters/Aria.png': _charaPng({
          'name': 'Aria',
          'first_mes': 'Hello!',
        }),
        'settings.json': _jsonBytes({
          'power_user': {
            'personas': {
              'serena.png': 'Serena Aiko',
              'nameless.png': '', // empty name → dropped
            },
            'persona_descriptions': {
              'serena.png': {
                'description': 'A calm tactician.',
                'position': 0,
                'depth': 4,
                'role': 0,
                'lorebook': 'Eldoria Lore',
                'title': '',
              },
            },
            'default_persona': 'serena.png',
          },
        }),
        // The persona's avatar image (keyed by the bare filename).
        'User Avatars/serena.png': avatarBytes,
        // A standalone world so the optional lorebook binding has a target.
        'worlds/Eldoria.json': _jsonBytes({
          'name': 'Eldoria Lore',
          'entries': {
            '0': {'key': ['Eldoria'], 'content': 'A kingdom.'},
          },
        }),
        // A chat whose first is_user message identifies the persona.
        'chats/Aria/2026-06-04.jsonl': utf8.encode([
          jsonEncode({'user_name': 'unused', 'character_name': 'unused'}),
          jsonEncode({'name': 'Aria', 'is_user': false, 'mes': 'Hi there.'}),
          jsonEncode({
            'name': 'Serena Aiko',
            'is_user': true,
            'mes': 'Hello!',
            'force_avatar': '/thumbnail?type=persona&file=serena.png',
          }),
        ].join('\n')),
      });
      plan = planStBackupCore(zip);
    });

    test('parses the named persona (name + description), drops the nameless',
        () {
      expect(plan.personas.length, 1);
      final p = plan.personas.single;
      expect(p.name, 'Serena Aiko');
      expect(p.description, 'A calm tactician.');
      expect(p.avatar, isNull); // bytes externalised by the UI layer, not here
    });

    test('collects the persona avatar bytes keyed by bare filename', () {
      expect(plan.personaAvatarBytes.containsKey('serena.png'), isTrue);
      expect(plan.personaAvatarBytes['serena.png'], equals(avatarBytes));
    });

    test('maps the persona id → its avatar filename', () {
      final id = plan.personas.single.id;
      expect(plan.personaAvatarFileById[id], 'serena.png');
    });

    test('surfaces the persona lorebook name for optional binding', () {
      final id = plan.personas.single.id;
      expect(plan.personaLorebookNameById[id], 'Eldoria Lore');
    });

    test('the chat carries a persona hint (avatarFile + name)', () {
      expect(plan.chats.length, 1);
      final hint = plan.chats.single.personaHint;
      expect(hint.avatarFile, 'serena.png');
      expect(hint.name, 'Serena Aiko');
      expect(hint.isEmpty, isFalse);
    });

    test('a settings.json with no power_user → no personas, no throw', () {
      final zip = _zip({
        'settings.json': _jsonBytes({'extension_settings': {}}),
      });
      final p = planStBackupCore(zip);
      expect(p.personas, isEmpty);
      expect(p.personaAvatarBytes, isEmpty);
    });
  });

  group('personasFromSettings', () {
    test('builds a persona per named entry with its description', () {
      final parsed = personasFromSettings({
        'power_user': {
          'personas': {'a.png': 'Alice', 'b.png': 'Bob'},
          'persona_descriptions': {
            'a.png': {'description': 'desc A', 'lorebook': 'World A'},
          },
        },
      });
      expect(parsed.length, 2);
      final alice = parsed.firstWhere((p) => p.persona.name == 'Alice');
      expect(alice.persona.description, 'desc A');
      expect(alice.avatarFile, 'a.png');
      expect(alice.lorebookName, 'World A');
      final bob = parsed.firstWhere((p) => p.persona.name == 'Bob');
      expect(bob.persona.description, ''); // no description block
      expect(bob.lorebookName, '');
    });

    test('drops nameless / non-string entries; missing power_user → empty', () {
      expect(
        personasFromSettings({
          'power_user': {
            'personas': {'x.png': '', 'y.png': 42, 'z.png': 'Zed'},
          },
        }).map((p) => p.persona.name),
        ['Zed'],
      );
      expect(personasFromSettings({'foo': 'bar'}), isEmpty);
      expect(personasFromSettings('not a map'), isEmpty);
      expect(personasFromSettings(null), isEmpty);
    });

    test('persona_descriptions missing / wrong-typed → blank desc, no throw',
        () {
      final parsed = personasFromSettings({
        'power_user': {
          'personas': {'a.png': 'Alice'},
          'persona_descriptions': 'oops-a-string',
        },
      });
      expect(parsed.single.persona.description, '');
    });
  });

  group('stForceAvatarFile', () {
    test('parses the file= query param', () {
      expect(
        stForceAvatarFile('/thumbnail?type=persona&file=Serena.png'),
        'Serena.png',
      );
    });

    test('URL-decodes the file value', () {
      expect(
        stForceAvatarFile('/thumbnail?type=persona&file=My%20Avatar.png'),
        'My Avatar.png',
      );
    });

    test('no file= param → empty', () {
      expect(stForceAvatarFile('/thumbnail?type=persona'), '');
      expect(stForceAvatarFile(''), '');
      expect(stForceAvatarFile(null), '');
      expect(stForceAvatarFile(42), '');
    });
  });

  group('stPersonaHintFromJsonl', () {
    test('reads the FIRST is_user message name + force_avatar', () {
      final hint = stPersonaHintFromJsonl([
        jsonEncode({'user_name': 'unused'}), // header
        jsonEncode({'name': 'Char', 'is_user': false, 'mes': 'hi'}),
        jsonEncode({
          'name': 'Serena Aiko',
          'is_user': true,
          'force_avatar': '/thumbnail?type=persona&file=serena.png',
        }),
        jsonEncode({'name': 'Other', 'is_user': true, 'mes': 'later'}),
      ]);
      expect(hint.name, 'Serena Aiko');
      expect(hint.avatarFile, 'serena.png');
    });

    test('name-only when no force_avatar', () {
      final hint = stPersonaHintFromJsonl([
        jsonEncode({'name': 'Just Name', 'is_user': true, 'mes': 'hi'}),
      ]);
      expect(hint.name, 'Just Name');
      expect(hint.avatarFile, '');
      expect(hint.isEmpty, isFalse);
    });

    test('no user message → empty hint', () {
      final hint = stPersonaHintFromJsonl([
        jsonEncode({'name': 'Char', 'is_user': false, 'mes': 'hi'}),
        'garbage {{{',
        '',
      ]);
      expect(hint.isEmpty, isTrue);
    });
  });

  // OPTIONAL real-zip smoke test. NO-OP skip on any machine without the
  // owner's sample backup — keeps the suite portable.
  group('real backup smoke test (owner machine only)', () {
    final samplePath = 'C:/Users/Gui/Desktop/BotBooru chat app/SillyTavern/'
        'default-user-20260604-144714.zip';
    final exists = File(samplePath).existsSync();

    test('decodes the real backup with sane non-zero counts + no secrets',
        () {
      final bytes = File(samplePath).readAsBytesSync();
      final plan = planStBackupCore(Uint8List.fromList(bytes));
      // Sane counts per the design spec's expectations (~4 chars, 4 worlds,
      // >=1 preset, >=1 chat). We assert non-zero rather than exact so a
      // slightly different sample still passes.
      expect(plan.characters.length, greaterThanOrEqualTo(1));
      expect(plan.lorebooks.length, greaterThanOrEqualTo(1));
      expect(plan.presets.length, greaterThanOrEqualTo(1));
      expect(plan.chats.length, greaterThanOrEqualTo(1));

      // No secret material anywhere in the parsed plan. We can't enumerate the
      // real keys, but we can assert the secrets.json filename / common key
      // prefixes never surface in the serialized artifacts.
      final haystack = StringBuffer()
        ..writeAll(plan.characters.map((c) => jsonEncode(c.toJson())))
        ..writeAll(plan.lorebooks.map((l) => jsonEncode(l.toJson())))
        ..writeAll(plan.presets.map((p) => jsonEncode(p.toJson())))
        ..writeAll(plan.regexRules.map((r) => jsonEncode(r.toJson())))
        ..writeAll(plan.chats.expand((c) => c.lines));
      final text = haystack.toString();
      // ST secret keys are commonly named api_key_*; none should appear in
      // imported artifacts (they live only in the skipped secrets.json).
      expect(text, isNot(contains('api_key_')));
    }, skip: exists ? false : 'sample backup not present on this machine');
  });
}
