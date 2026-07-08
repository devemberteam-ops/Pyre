// 2026-07-07 (Gui): pure pieces of the self-host hub provider config client.
// The HTTP calls need a live hub (covered by pyre_server integration tests);
// here we lock the JSON parse + the update-body shape (esp. the key-omit rule).
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/hub_provider.dart';

void main() {
  group('parseHubProviderStatus', () {
    test('reads the masked fields', () {
      final s = parseHubProviderStatus({
        'configured': true,
        'baseUrl': 'https://inference.chub.ai/soji/v1',
        'model': 'soji',
        'hasKey': true,
        'source': 'stored',
        'temperature': 0.8,
        'maxTokens': 512,
      });
      expect(s.configured, isTrue);
      expect(s.baseUrl, 'https://inference.chub.ai/soji/v1');
      expect(s.model, 'soji');
      expect(s.hasKey, isTrue);
      expect(s.source, 'stored');
      expect(s.temperature, 0.8);
      expect(s.maxTokens, 512);
    });

    test('tolerates a bare not-configured reply', () {
      final s = parseHubProviderStatus(
          {'configured': false, 'hasKey': false, 'source': 'none'});
      expect(s.configured, isFalse);
      expect(s.baseUrl, '');
      expect(s.temperature, isNull);
    });
  });

  group('hubProviderUpdateBody', () {
    test('includes a non-blank apiKey', () {
      final b = hubProviderUpdateBody(
          baseUrl: 'https://x/v1', model: 'm', apiKey: 'sk-1');
      expect(b['apiKey'], 'sk-1');
      expect(b['baseUrl'], 'https://x/v1');
      expect(b['model'], 'm');
    });

    test('OMITS a blank apiKey so the hub keeps its stored key', () {
      final b = hubProviderUpdateBody(baseUrl: 'x', model: 'm', apiKey: '   ');
      expect(b.containsKey('apiKey'), isFalse);
    });

    test('omits temperature/maxTokens when null; trims url/model', () {
      final b = hubProviderUpdateBody(baseUrl: ' x ', model: ' m ');
      expect(b['baseUrl'], 'x');
      expect(b['model'], 'm');
      expect(b.containsKey('temperature'), isFalse);
      expect(b.containsKey('maxTokens'), isFalse);
    });
  });
}
