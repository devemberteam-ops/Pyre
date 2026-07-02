import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/services/param_policy.dart';

/// Slice D-1 (2026-07-02) — pure detector + extractor for context-overflow
/// 4xx errors. Mirrors the param_policy `isUnsupportedParamError` truth-table
/// style. These functions are provably INERT (no production caller yet) —
/// this file is the only place that exercises them.
void main() {
  group('isContextOverflowError — truth table (each signature hits)', () {
    test('maximum context length', () {
      expect(
        isContextOverflowError(
            "This model's maximum context length is 8192 tokens."),
        isTrue,
      );
    });

    test('context length exceeded', () {
      expect(
        isContextOverflowError('Error: context length exceeded for request'),
        isTrue,
      );
    });

    test('context_length_exceeded', () {
      expect(
        isContextOverflowError('{"error":{"code":"context_length_exceeded"}}'),
        isTrue,
      );
    });

    test('reduce the length of the messages', () {
      expect(
        isContextOverflowError(
            'Please reduce the length of the messages or completion.'),
        isTrue,
      );
    });

    test('context window', () {
      expect(
        isContextOverflowError('The request exceeds the context window.'),
        isTrue,
      );
    });

    test('exceeds the maximum', () {
      expect(
        isContextOverflowError('Your input exceeds the maximum allowed.'),
        isTrue,
      );
    });

    test('too many tokens', () {
      expect(
        isContextOverflowError('Request contains too many tokens.'),
        isTrue,
      );
    });

    test('prompt is too long (Anthropic)', () {
      expect(
        isContextOverflowError(
            'prompt is too long: 250000 tokens > 200000 maximum'),
        isTrue,
      );
    });

    test('input is too long', () {
      expect(
        isContextOverflowError('input is too long for this model'),
        isTrue,
      );
    });

    test('requested too many tokens', () {
      expect(
        isContextOverflowError('You requested too many tokens for completion.'),
        isTrue,
      );
    });

    test('is longer than the maximum', () {
      expect(
        isContextOverflowError(
            'Your message is longer than the maximum allowed length.'),
        isTrue,
      );
    });

    test('exceeds the context', () {
      expect(
        isContextOverflowError('This request exceeds the context limit.'),
        isTrue,
      );
    });

    test('decrease the number of tokens', () {
      expect(
        isContextOverflowError(
            'Please decrease the number of tokens in the prompt.'),
        isTrue,
      );
    });

    test('kv cache (low-confidence local)', () {
      expect(
        isContextOverflowError('llama.cpp: kv cache is full, cannot continue'),
        isTrue,
      );
    });

    test('n_ctx (low-confidence local)', () {
      expect(
        isContextOverflowError(
            'the request exceeds the available context size. try increasing n_ctx'),
        isTrue,
      );
    });

    test('is case-insensitive', () {
      expect(
        isContextOverflowError('CONTEXT LENGTH EXCEEDED'),
        isTrue,
      );
    });
  });

  group('isContextOverflowError — false cases (disjoint from other errors)', () {
    test('empty string', () {
      expect(isContextOverflowError(''), isFalse);
    });

    test('generic auth error', () {
      expect(
        isContextOverflowError(
            '{"error":{"message":"Incorrect API key provided.","code":"invalid_api_key"}}'),
        isFalse,
      );
    });

    test('rate-limit error', () {
      expect(
        isContextOverflowError(
            '{"error":{"message":"Rate limit reached for requests","type":"rate_limit_error"}}'),
        isFalse,
      );
    });

    test('model-not-found error', () {
      expect(
        isContextOverflowError(
            '{"error":{"message":"The model \'gpt-9\' does not exist","code":"model_not_found"}}'),
        isFalse,
      );
    });

    test('max_completion_tokens/max_tokens PARAM body is NOT overflow', () {
      const body =
          "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.";
      expect(isContextOverflowError(body), isFalse);
      // Confirming the two detectors don't collide: the same body IS a
      // param-shape rejection.
      expect(isUnsupportedParamError(body), isTrue);
    });
  });

  group('contextLimitFromError — extractor corpus (real error bodies)', () {
    test('OpenAI: maximum context length + "resulted in" requested tokens', () {
      const body =
          '{"error":{"message":"This model\'s maximum context length is 8192 tokens. '
          'However, your messages resulted in 9000 tokens. Please reduce the length of '
          'the messages.","code":"context_length_exceeded"}}';
      final result = contextLimitFromError(body);
      expect(result.maxTokens, 8192);
      expect(result.requestedTokens, 9000);
    });

    test('Anthropic: "prompt is too long: N tokens > M maximum"', () {
      const body =
          '{"type":"error","error":{"type":"invalid_request_error",'
          '"message":"prompt is too long: 250000 tokens > 200000 maximum"}}';
      final result = contextLimitFromError(body);
      expect(result.requestedTokens, 250000);
      expect(result.maxTokens, 200000);
    });

    test('vLLM: "maximum context length is N. However, you requested M"', () {
      const body =
          "This model's maximum context length is 4096 tokens. However, "
          'you requested 5000 tokens';
      final result = contextLimitFromError(body);
      expect(result.maxTokens, 4096);
      expect(result.requestedTokens, 5000);
    });

    test('no numbers present => (null, null)', () {
      const body = 'input is too long';
      final result = contextLimitFromError(body);
      expect(result.maxTokens, isNull);
      expect(result.requestedTokens, isNull);
    });

    test('empty body never throws => (null, null)', () {
      final result = contextLimitFromError('');
      expect(result.maxTokens, isNull);
      expect(result.requestedTokens, isNull);
    });

    test('garbage body never throws => (null, null)', () {
      final result = contextLimitFromError('not json at all {{{ [[[ \\');
      expect(result.maxTokens, isNull);
      expect(result.requestedTokens, isNull);
    });
  });
}
