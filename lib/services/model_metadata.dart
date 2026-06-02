// Wave CY.18.100: best-effort context-window discovery for any
// OpenAI-compatible provider.
//
// There is NO single universal field for a model's context window — the
// OpenAI `/models` spec only guarantees `id`. But the providers Pyre
// talks to each expose it under a known key, so we scan a priority list:
//
//   context_length          OpenRouter, Together (top-level)
//   top_provider.context_length   OpenRouter (the served limit, nested)
//   context_window          some OpenAI-compatible gateways
//   max_context_length      misc
//   max_model_len           vLLM / many local servers
//   n_ctx                   llama.cpp-style
//
// When none match, we return null and the UI shows "unknown" — and the
// user can set ApiProvider.contextWindow manually as a universal escape
// hatch. Results are cached in-memory per (providerId|model) for the
// session so opening the token sheet repeatedly doesn't refetch.

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'chat_api.dart' show buildChatUrl;

/// Extract a context-window size (tokens) from a single `/models` entry,
/// scanning provider-specific field names in priority order. Pure; no
/// I/O — unit-tested in test/model_metadata_test.dart.
int? parseContextWindow(Map<String, dynamic> entry) {
  int? asPositiveInt(dynamic v) {
    if (v is int) return v > 0 ? v : null;
    if (v is num) return v > 0 ? v.toInt() : null;
    if (v is String) {
      final n = int.tryParse(v.trim());
      return (n != null && n > 0) ? n : null;
    }
    return null;
  }

  const topLevelKeys = [
    'context_length',
    'context_window',
    'max_context_length',
    'max_model_len',
    'n_ctx',
  ];
  for (final k in topLevelKeys) {
    final n = asPositiveInt(entry[k]);
    if (n != null) return n;
  }
  // OpenRouter nests the actually-served limit here.
  final tp = entry['top_provider'];
  if (tp is Map) {
    final n = asPositiveInt(tp['context_length']);
    if (n != null) return n;
  }
  return null;
}

/// Session cache: `providerId|model` → context window (or null when
/// we tried and the provider didn't expose it). `containsKey` is the
/// "already tried" signal so a null isn't refetched every sheet open.
final Map<String, int?> _cache = {};

/// Resolve the context window for [provider]'s active model.
/// Priority: manual override (ApiProvider.contextWindow) → cached →
/// fetched from `/models`. Returns null when unknown. Best-effort —
/// network / parse failures resolve to null, never throw.
Future<int?> fetchContextWindow(ApiProvider provider) async {
  // Manual override always wins — the universal fallback.
  if (provider.contextWindow != null && provider.contextWindow! > 0) {
    return provider.contextWindow;
  }
  if (provider.baseUrl.isEmpty || provider.model.isEmpty) return null;

  final cacheKey = '${provider.id}|${provider.model}';
  if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

  int? result;
  try {
    final url = buildChatUrl(provider.baseUrl, 'models');
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        if (provider.apiKey.isNotEmpty)
          'Authorization': 'Bearer ${provider.apiKey}',
        ..._sanitiseHeaders(provider.headers),
      },
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode < 400) {
      final body = jsonDecode(resp.body);
      final list = (body is Map && body['data'] is List)
          ? (body['data'] as List)
          : (body is List ? body : const []);
      for (final item in list) {
        if (item is Map && item['id'] == provider.model) {
          result = parseContextWindow(Map<String, dynamic>.from(item));
          break;
        }
      }
    }
  } catch (e) {
    debugPrint('[ModelMetadata] context-window fetch failed: $e');
  }
  _cache[cacheKey] = result;
  return result;
}

/// Drop a provider's cached window — call when the user edits the
/// provider (model/url/manual override may have changed).
void invalidateContextWindowCache(String providerId) {
  _cache.removeWhere((k, _) => k.startsWith('$providerId|'));
}

/// Strip headers that would corrupt a GET (mirrors chat_api's guard for
/// content-type / accept on a body-less request).
Map<String, String> _sanitiseHeaders(Map<String, String> headers) {
  final out = <String, String>{};
  headers.forEach((k, v) {
    final lk = k.toLowerCase();
    if (lk == 'content-type' || lk == 'content-length') return;
    out[k] = v;
  });
  return out;
}
