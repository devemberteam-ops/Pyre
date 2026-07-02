import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/chat_api.dart';

void main() {
  group('LAN proxy multimodal message wire format', () {
    test('preserves image attachments instead of flattening to text', () {
      final turn = ChatTurn(
        'user',
        'Describe this reference.',
        imageDataUrls: const ['data:image/png;base64,AAAA'],
      );

      final wire = lanProxyMessageJson(turn);
      expect(wire['role'], 'user');
      expect(wire['content'], isA<List>());
      final blocks = wire['content'] as List;
      expect(blocks.first, {'type': 'text', 'text': 'Describe this reference.'});
      expect(blocks.last, {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AAAA'},
      });

      final back = chatTurnFromLanProxyJson(wire);
      expect(back.role, 'user');
      expect(back.content, 'Describe this reference.');
      expect(back.imageDataUrls, ['data:image/png;base64,AAAA']);
    });

    test('still accepts the legacy string-content shape', () {
      final back = chatTurnFromLanProxyJson({
        'role': 'assistant',
        'content': 'Plain text reply',
      });

      expect(back.role, 'assistant');
      expect(back.content, 'Plain text reply');
      expect(back.imageDataUrls, isNull);
    });
  });
}
