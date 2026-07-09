// Shared per-chat persona resolver.
//
// Audit (state-order, 1.2.1 batch D, finding #2): every chat should resolve
// "who is the user in this chat" the SAME way. Several sites duplicated the
// resolution logic inline and two of them forgot to honour
// [kExplicitNoPersonaId] — the sentinel the new-chat / switch-persona picker
// stores when the user explicitly picks "No persona" for a chat, as distinct
// from `null` (= inherit the global active persona). Those two sites
// silently substituted the global active persona back in, which produced
// phantom "(persona)" inherited lorebooks for a chat the user deliberately
// made persona-less — and disabling that phantom wrote into
// `disabledInheritedLorebookIds`, which is id-keyed (not source-scoped) and
// so could kill the SAME book's real character binding too.
//
// This is now the ONE canonical implementation. Every call site that needs
// "the persona this chat plays as" should route through it.

import '../models/models.dart';
import '../state/app_store.dart';

/// Resolves the persona [chat] should use, honouring the per-chat
/// `personaId` override and the [kExplicitNoPersonaId] sentinel.
///
/// - `chat.personaId == kExplicitNoPersonaId` → `null` (user explicitly
///   chose no persona for this chat; never fall back to the global default).
/// - `chat.personaId` is a real id → that persona, if it still exists.
/// - the id points at a deleted persona → fall back to `store.activePersona`
///   (there has to be SOMEONE to play as).
/// - `chat.personaId == null` (legacy chats / never set) → `store.activePersona`.
Persona? chatPersonaFor(AppStore store, Chat chat) {
  final pid = chat.personaId;
  if (pid == kExplicitNoPersonaId) return null;
  if (pid != null) {
    final p = store.personaById(pid);
    if (p != null) return p;
    // pid points at a deleted persona — fall through to the global
    // active so the user has SOMEONE to play as.
  }
  return store.activePersona;
}
