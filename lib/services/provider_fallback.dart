// Wave CY.18.99: pure helpers for the smart provider fallback chain.
// No I/O — AppStore wraps these with the live provider list + refusal
// history. Kept pure so they're unit-testable without platform channels.

import '../models/models.dart';

/// The ordered list of providers to try for a chat generation.
/// Primary (the active/CHAT provider) first, then every other provider
/// in list order. Deduped (primary never appears twice). When [enabled]
/// is false the chain collapses to just the primary — i.e. exactly the
/// pre-fallback behavior.
List<ApiProvider> buildFallbackChain({
  required List<ApiProvider> all,
  required String? primaryId,
  required bool enabled,
}) {
  ApiProvider? primary;
  for (final p in all) {
    if (p.id == primaryId) {
      primary = p;
      break;
    }
  }
  if (!enabled) {
    return primary == null ? const [] : [primary];
  }
  final chain = <ApiProvider>[];
  if (primary != null) chain.add(primary);
  for (final p in all) {
    if (p.id != primary?.id) chain.add(p);
  }
  return chain;
}

/// Pick the first candidate with a clean (zero) refusal record, skipping
/// [excludeId]. Used by the refusal card to suggest a provider that
/// "tends to handle this better" when the next-in-chain itself has a
/// refusal history. Returns null when no clean alternative exists.
ApiProvider? pickCleanAlternative({
  required List<ApiProvider> candidates,
  required Map<String, int> refusals,
  required String excludeId,
}) {
  for (final p in candidates) {
    if (p.id == excludeId) continue;
    if ((refusals[p.id] ?? 0) == 0) return p;
  }
  return null;
}

/// Web + paired-to-a-hub: browser chats stream through the hub's
/// `/llm/stream` and the HOST proxies with its OWN provider — the browser
/// needs no local provider record (1.1.2 even deliberately omits providerId
/// from the proxy body). But every send-path gate demands a non-null
/// provider, so a fresh web profile died with "No provider configured"
/// before ever reaching the proxy. This synthetic satisfies the gate + the
/// proxy's kind-based timeout heuristics only; it never enters `providers`,
/// never persists, never syncs.
ApiProvider hubProxyProvider() => ApiProvider(
      id: '__hub_proxy__',
      name: 'PC (paired)',
    );

/// Pure seam for [AppStore.activeProvider]'s web fallback (kIsWeb is a
/// compile-time const, so the branch itself can't be driven in VM tests —
/// this function can). Native behavior is untouched: a resolved local
/// provider always wins, and off-web the fallback never fires.
ApiProvider? effectiveActiveProvider({
  required ApiProvider? local,
  required bool isWeb,
  required bool isPaired,
}) {
  if (local != null) return local;
  if (isWeb && isPaired) return hubProxyProvider();
  return null;
}
