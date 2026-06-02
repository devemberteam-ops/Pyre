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
