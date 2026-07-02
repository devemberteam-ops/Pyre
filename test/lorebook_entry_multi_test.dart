import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart' show LoreSelectiveLogic;
import 'package:pyre/services/chat_api.dart' show ChatTurn;
import 'package:pyre/services/lorebook_architect_prompts.dart';
import 'package:pyre/services/lorebook_entry_build.dart';
import 'package:pyre/services/lorebook_entry_schema.dart';

void main() {
  test('architect prompt treats keywords as natural triggers, not tags', () {
    expect(kLorebookEntryArchitectPrompt, contains('A key is NOT a tag'));
    expect(kLorebookEntryArchitectPrompt, contains('Would the user'));
    expect(kLorebookEntryArchitectPrompt, contains('coverage with discipline'));
    expect(kLorebookEntryArchitectPrompt, contains('Use 4-8 keys'));
    expect(kLorebookEntryArchitectPrompt, contains('Use up to 10'));
    expect(kLorebookEntryArchitectPrompt, contains('Geothermal Sanctuaries'));
  });

  test(
    'explicit lorebook entry requests are detected outside lorebook mode',
    () {
      expect(
        isExplicitLorebookEntryRequest(
          'A fim de testes preciso que voce crie 5 entradas para lorebook',
        ),
        isTrue,
      );
      expect(
        isExplicitLorebookEntryRequest(
          'create 5 lorebook entries for this card',
        ),
        isTrue,
      );
      expect(
        isExplicitLorebookEntryRequest('crie um lorebook para essa card'),
        isTrue,
      );
      expect(
        isExplicitLorebookEntryRequest('preciso revisar o lorebook depois'),
        isFalse,
      );
      expect(
        isExplicitLorebookEntryRequest('nao crie um lorebook ainda'),
        isFalse,
      );
      expect(
        isExplicitLorebookEntryRequest('crie mais detalhes para o mundo'),
        isFalse,
      );
    },
  );

  test('entry build command does not hijack ordinary refinement prose', () {
    expect(isBuildEntryCommand('cria 5 entradas sobre a cidade'), isTrue);
    expect(isBuildEntryCommand('crie uma entrada para a linhagem'), isTrue);
    expect(isBuildEntryCommand('pode criar'), isTrue);
    expect(isBuildEntryCommand('cria uma faccao rival mais politica'), isFalse);
    expect(isBuildEntryCommand('gera uma versao melhor das keywords'), isFalse);
  });

  test('entryJsonToLoreEntries maps multiple advanced entries', () {
    final entries = entryJsonToLoreEntries({
      'entries': [
        {
          'keys': ['Ashveil', 'Cyprian Ashveil'],
          'secondaryKeys': ['sunlight', 'cinder'],
          'selectiveLogic': 'andAll',
          'content': 'Cyprian Ashveil avoids direct sunlight.',
          'constant': false,
          'enabled': true,
          'order': 75,
          'caseSensitive': false,
          'matchWholeWords': true,
          'probability': 80,
          'useProbability': true,
        },
        {
          'keys': ['Cinder Wastes'],
          'content': 'The Cinder Wastes surround the old road.',
          'constant': false,
          'order': 50,
        },
      ],
    });

    expect(entries.length, 2);
    expect(entries.first.secondaryKeys, ['sunlight', 'cinder']);
    expect(entries.first.selectiveLogic, LoreSelectiveLogic.andAll);
    expect(entries.first.order, 75);
    expect(entries.first.caseSensitive, isFalse);
    expect(entries.first.matchWholeWords, isTrue);
    expect(entries.first.probability, 80);
    expect(entries.first.useProbability, isTrue);
    expect(entries.last.keys, ['Cinder Wastes']);
    expect(entries.last.order, 50);
  });

  test('draftLoreEntries preserves every returned entry', () async {
    const multiJson =
        '{"entries":[{"keys":["Ashveil"],"secondaryKeys":["sunlight"],'
        '"selectiveLogic":"andAny","content":"Ashveil lore.",'
        '"constant":false,"order":50},{"keys":["Cinder Wastes"],'
        '"content":"Wastes lore.","constant":false}]}';

    final entries = await draftLoreEntries(
      turns: [ChatTurn('user', 'build two entries')],
      call: (_) async => multiJson,
    );

    expect(entries, isNotNull);
    expect(entries!.length, 2);
    expect(entries.first.secondaryKeys, ['sunlight']);
    expect(entries.first.selectiveLogic, LoreSelectiveLogic.andAny);
    expect(entries.first.order, 50);
  });
}
