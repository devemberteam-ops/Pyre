import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/param_policy.dart';

/// Mega-audit 2026-06-04 (cross-model compat). Pure-function tests for the
/// universal param-error survival path + the proactive per-kind/host allowlist.
void main() {
  group('isUnsupportedParamError', () {
    test('matches OpenAI reasoning "Unsupported parameter" 400', () {
      expect(
        isUnsupportedParamError(
            "{\"error\":{\"message\":\"Unsupported parameter: 'temperature' is not supported with this model.\"}}"),
        isTrue,
      );
    });

    test('matches Mistral "Extra inputs are not permitted" 422', () {
      expect(
        isUnsupportedParamError(
            '{"detail":[{"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}'),
        isTrue,
      );
    });

    test('matches "unrecognized request argument"', () {
      expect(
        isUnsupportedParamError(
            'Unrecognized request argument supplied: top_k'),
        isTrue,
      );
    });

    test('matches "does not support the parameter"', () {
      expect(
        isUnsupportedParamError(
            'This model does not support the parameter top_p'),
        isTrue,
      );
    });

    test('matches "unsupported_value"', () {
      expect(
        isUnsupportedParamError('{"error":{"code":"unsupported_value"}}'),
        isTrue,
      );
    });

    test('matches "extra fields not permitted"', () {
      expect(
        isUnsupportedParamError('extra fields not permitted'),
        isTrue,
      );
    });

    test('matches max_completion_tokens rename hint', () {
      expect(
        isUnsupportedParamError(
            "Use 'max_completion_tokens' instead of 'max_tokens'."),
        isTrue,
      );
    });

    test('matches a bare max_tokens complaint', () {
      expect(
        isUnsupportedParamError(
            "Unsupported parameter: 'max_tokens' is not supported."),
        isTrue,
      );
    });

    test('is case-insensitive', () {
      expect(
        isUnsupportedParamError('UNSUPPORTED PARAMETER: temperature'),
        isTrue,
      );
    });

    test('does NOT match a generic auth error', () {
      expect(
        isUnsupportedParamError(
            '{"error":{"message":"Invalid API key provided"}}'),
        isFalse,
      );
    });

    test('does NOT match a generic rate-limit error', () {
      expect(
        isUnsupportedParamError('Rate limit exceeded, please slow down'),
        isFalse,
      );
    });

    test('empty body is not a param error', () {
      expect(isUnsupportedParamError(''), isFalse);
    });
  });

  group('minimalRetryBody', () {
    final full = <String, dynamic>{
      'model': 'gpt-5',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
      'temperature': 0.9,
      'top_p': 0.95,
      'max_tokens': 4096,
      'top_k': 40,
      'frequency_penalty': 0.2,
      'response_format': {'type': 'json_object'},
      'reasoning': {'effort': 'low'},
      'stream': true,
    };

    test('keeps only model, messages, stream + the token cap (both names)',
        () {
      final out = minimalRetryBody(full);
      expect(out['model'], 'gpt-5');
      expect(out['messages'], full['messages']);
      expect(out['stream'], true);
      // Token cap is sent under BOTH names so whichever the provider wants is
      // present (the other is ignored by permissive providers).
      expect(out['max_tokens'], 4096);
      expect(out['max_completion_tokens'], 4096);
      // Everything else is dropped.
      expect(out.containsKey('temperature'), isFalse);
      expect(out.containsKey('top_p'), isFalse);
      expect(out.containsKey('top_k'), isFalse);
      expect(out.containsKey('frequency_penalty'), isFalse);
      expect(out.containsKey('response_format'), isFalse);
      expect(out.containsKey('reasoning'), isFalse);
    });

    test('reads the token cap from max_completion_tokens if max_tokens absent',
        () {
      final body = <String, dynamic>{
        'model': 'o3',
        'messages': const [],
        'max_completion_tokens': 2048,
        'stream': false,
      };
      final out = minimalRetryBody(body);
      expect(out['max_tokens'], 2048);
      expect(out['max_completion_tokens'], 2048);
    });

    test('omits the token cap entirely when neither name is present', () {
      final body = <String, dynamic>{
        'model': 'm',
        'messages': const [],
        'stream': true,
      };
      final out = minimalRetryBody(body);
      expect(out.containsKey('max_tokens'), isFalse);
      expect(out.containsKey('max_completion_tokens'), isFalse);
    });

    test('preserves the original stream flag', () {
      final out = minimalRetryBody({...full, 'stream': false});
      expect(out['stream'], false);
    });

    test('does not mutate the input map', () {
      final copy = Map<String, dynamic>.from(full);
      minimalRetryBody(full);
      expect(full, copy);
    });
  });

  group('safeBodyFor — proactive allowlist', () {
    ApiProvider provider(String baseUrl, {ProviderKind? kind}) => ApiProvider(
          id: 'p',
          name: 'p',
          kind: kind ?? ProviderKind.external_,
          baseUrl: baseUrl,
        );

    Map<String, dynamic> sampleBody() => <String, dynamic>{
          'model': 'm',
          'messages': const [],
          'temperature': 0.9,
          'top_p': 0.95,
          'max_tokens': 4096,
          'top_k': 40,
          'min_p': 0.05,
          'top_a': 0.1,
          'repetition_penalty': 1.1,
          'frequency_penalty': 0.2,
          'presence_penalty': 0.1,
          'stream': true,
        };

    test('default/unknown provider sends EVERYTHING unchanged', () {
      final body = sampleBody();
      final out = safeBodyFor(
        provider('https://openrouter.ai/api/v1'),
        'anthropic/claude-3.5',
        body,
      );
      expect(out, body);
    });

    test('localhost provider is never regressed (sends everything)', () {
      final body = sampleBody();
      final out = safeBodyFor(
        provider('http://localhost:1234/v1', kind: ProviderKind.localhost),
        'some-local-model',
        body,
      );
      expect(out, body);
    });

    test('OpenAI reasoning model drops sampling + renames the token cap', () {
      final body = sampleBody();
      final out = safeBodyFor(
        provider('https://api.openai.com/v1'),
        'o3-mini',
        body,
      );
      expect(out.containsKey('temperature'), isFalse);
      expect(out.containsKey('top_p'), isFalse);
      expect(out.containsKey('frequency_penalty'), isFalse);
      expect(out.containsKey('presence_penalty'), isFalse);
      expect(out.containsKey('top_k'), isFalse);
      // max_tokens renamed to max_completion_tokens.
      expect(out.containsKey('max_tokens'), isFalse);
      expect(out['max_completion_tokens'], 4096);
      // Core fields intact.
      expect(out['model'], 'm');
      expect(out['stream'], true);
    });

    test('OpenAI non-reasoning model (gpt-4o) is left permissive', () {
      final body = sampleBody();
      final out = safeBodyFor(
        provider('https://api.openai.com/v1'),
        'gpt-4o',
        body,
      );
      // Standard chat models accept temperature/top_p/max_tokens.
      expect(out['temperature'], 0.9);
      expect(out['top_p'], 0.95);
      expect(out['max_tokens'], 4096);
    });

    test('gpt-5 is treated as a reasoning model', () {
      final out = safeBodyFor(
        provider('https://api.openai.com/v1'),
        'gpt-5',
        sampleBody(),
      );
      expect(out.containsKey('temperature'), isFalse);
      expect(out['max_completion_tokens'], 4096);
    });

    test('Mistral host drops extended samplers but keeps core sampling', () {
      final body = sampleBody();
      final out = safeBodyFor(
        provider('https://api.mistral.ai/v1'),
        'mistral-large-latest',
        body,
      );
      // Extended samplers Mistral 422s on are dropped.
      expect(out.containsKey('top_k'), isFalse);
      expect(out.containsKey('min_p'), isFalse);
      expect(out.containsKey('top_a'), isFalse);
      expect(out.containsKey('repetition_penalty'), isFalse);
      // Mistral keeps max_tokens (NOT max_completion_tokens) + core sampling.
      expect(out['max_tokens'], 4096);
      expect(out.containsKey('max_completion_tokens'), isFalse);
      expect(out['temperature'], 0.9);
      expect(out['top_p'], 0.95);
    });

    test('Mistral host drops unknown extraParams-style fields', () {
      final body = sampleBody()..['some_custom_unknown'] = 'x';
      final out = safeBodyFor(
        provider('https://api.mistral.ai/v1'),
        'mistral-small',
        body,
      );
      expect(out.containsKey('some_custom_unknown'), isFalse);
    });

    test('does not mutate the input body', () {
      final body = sampleBody();
      final copy = Map<String, dynamic>.from(body);
      safeBodyFor(provider('https://api.openai.com/v1'), 'o3', body);
      expect(body, copy);
    });
  });

  group('extractReasoningDetailsText — OpenRouter reasoning_details[]', () {
    test('concatenates .text fields', () {
      final out = extractReasoningDetailsText([
        {'type': 'reasoning.text', 'text': 'first '},
        {'type': 'reasoning.text', 'text': 'second'},
      ]);
      expect(out, 'first second');
    });

    test('concatenates .summary fields', () {
      final out = extractReasoningDetailsText([
        {'type': 'reasoning.summary', 'summary': 'sum-a '},
        {'type': 'reasoning.summary', 'summary': 'sum-b'},
      ]);
      expect(out, 'sum-a sum-b');
    });

    test('mixes text + summary in order', () {
      final out = extractReasoningDetailsText([
        {'text': 'a'},
        {'summary': 'b'},
        {'text': 'c'},
      ]);
      expect(out, 'abc');
    });

    test('ignores entries with neither text nor summary', () {
      final out = extractReasoningDetailsText([
        {'type': 'reasoning.encrypted', 'data': 'xxx'},
        {'text': 'visible'},
      ]);
      expect(out, 'visible');
    });

    test('returns null for a non-list / empty / all-empty input', () {
      expect(extractReasoningDetailsText(null), isNull);
      expect(extractReasoningDetailsText(const []), isNull);
      expect(extractReasoningDetailsText('not a list'), isNull);
      expect(
        extractReasoningDetailsText([
          {'type': 'x'},
          {'data': 'y'},
        ]),
        isNull,
      );
    });
  });
}
