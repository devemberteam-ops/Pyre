// 2026-07-07 (Gui): configure the SELF-HOST hub's provider (URL/model/key)
// from the app UI instead of a compose/env file. Talks to the headless hub's
// pairing-gated `/admin/provider` endpoint (see pyre_server). Only meaningful
// when paired to a hub (LanClient.isPaired); a desktop hub has no such
// endpoint (404 → unsupported), so the UI degrades gracefully.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lan_client.dart';

/// Masked provider state as the hub reports it — never carries the key.
class HubProviderStatus {
  final bool configured;
  final String baseUrl;
  final String model;
  final bool hasKey;
  final double? temperature;
  final int? maxTokens;
  final String source; // 'stored' | 'env' | 'none'
  const HubProviderStatus({
    required this.configured,
    required this.baseUrl,
    required this.model,
    required this.hasKey,
    required this.source,
    this.temperature,
    this.maxTokens,
  });
}

/// Parse the hub's masked `/admin/provider` JSON.
HubProviderStatus parseHubProviderStatus(Map<String, dynamic> j) {
  final t = j['temperature'];
  final m = j['maxTokens'];
  return HubProviderStatus(
    configured: j['configured'] == true,
    baseUrl: (j['baseUrl'] as String?) ?? '',
    model: (j['model'] as String?) ?? '',
    hasKey: j['hasKey'] == true,
    source: (j['source'] as String?) ?? 'none',
    temperature: t is num ? t.toDouble() : null,
    maxTokens: m is num ? m.toInt() : null,
  );
}

/// Build the POST body for a provider update. Omits `apiKey` when blank so the
/// hub KEEPS its stored key (editing url/model without re-typing the secret).
/// Omits temperature/maxTokens when null (leave the hub's current values).
Map<String, dynamic> hubProviderUpdateBody({
  required String baseUrl,
  required String model,
  String apiKey = '',
  double? temperature,
  int? maxTokens,
}) =>
    <String, dynamic>{
      'baseUrl': baseUrl.trim(),
      'model': model.trim(),
      if (apiKey.trim().isNotEmpty) 'apiKey': apiKey.trim(),
      'temperature': ?temperature,
      'maxTokens': ?maxTokens,
    };

/// Result of a hub call: [supported] is false when the hub has no
/// `/admin/provider` (a desktop hub, or not paired). [error] is a
/// human-readable message on failure.
class HubProviderResult {
  final bool supported;
  final HubProviderStatus? status;
  final String? error;
  const HubProviderResult({required this.supported, this.status, this.error});
}

Uri? _adminUri() {
  final base = LanClient.instance.baseUrl;
  if (base == null) return null;
  return Uri.parse('$base/admin/provider');
}

Map<String, String> _authHeaders() => {
      'authorization': 'Bearer ${LanClient.instance.bearerToken ?? ''}',
      'content-type': 'application/json',
    };

/// Read the hub's current provider status. supported=false when not paired or
/// the hub is a desktop hub (404).
Future<HubProviderResult> fetchHubProvider() async {
  final uri = _adminUri();
  if (uri == null || !LanClient.instance.isPaired) {
    return const HubProviderResult(supported: false);
  }
  try {
    final resp = await http
        .get(uri, headers: _authHeaders())
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode == 404) {
      return const HubProviderResult(supported: false);
    }
    if (resp.statusCode != 200) {
      return HubProviderResult(
          supported: true, error: 'Server returned ${resp.statusCode}.');
    }
    final j = jsonDecode(resp.body);
    if (j is! Map) {
      return const HubProviderResult(supported: true, error: 'Invalid reply.');
    }
    return HubProviderResult(
        supported: true,
        status: parseHubProviderStatus(j.cast<String, dynamic>()));
  } catch (e) {
    return HubProviderResult(supported: true, error: 'Could not reach hub: $e');
  }
}

/// Set the hub's provider. Returns the updated status on success.
Future<HubProviderResult> setHubProvider({
  required String baseUrl,
  required String model,
  String apiKey = '',
  double? temperature,
  int? maxTokens,
}) async {
  final uri = _adminUri();
  if (uri == null || !LanClient.instance.isPaired) {
    return const HubProviderResult(
        supported: false, error: 'Not connected to a hub.');
  }
  try {
    final resp = await http
        .post(uri,
            headers: _authHeaders(),
            body: jsonEncode(hubProviderUpdateBody(
              baseUrl: baseUrl,
              model: model,
              apiKey: apiKey,
              temperature: temperature,
              maxTokens: maxTokens,
            )))
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode == 404) {
      return const HubProviderResult(supported: false);
    }
    if (resp.statusCode != 200) {
      String msg = 'Server returned ${resp.statusCode}.';
      try {
        final j = jsonDecode(resp.body);
        if (j is Map && j['error'] is String) msg = j['error'] as String;
      } catch (_) {}
      return HubProviderResult(supported: true, error: msg);
    }
    final j = jsonDecode(resp.body);
    return HubProviderResult(
        supported: true,
        status: (j is Map)
            ? parseHubProviderStatus(j.cast<String, dynamic>())
            : null);
  } catch (e) {
    return HubProviderResult(supported: true, error: 'Could not reach hub: $e');
  }
}
