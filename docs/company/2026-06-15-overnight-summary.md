# Overnight 2026-06-15 — summary (for Kuru)

Branch release/1.1.3. Everything LOCAL, NOTHING published. All green:
flutter analyze 0 + 1651 tests. Tree clean.

## Commits while you slept (newest first)
- 8f6ca0f — Lorebook Creator Wave 3: card integrations + export-travel fix
- d8f19e4 — Checkpoints + Live Sheet HIGH audit fixes
- c372bcf — Lorebook Creator UI (per-entry) + entry points
- 2d34593 — Lorebook Creator foundation (pure back-end)
(earlier this session: 6805e6f creator HIGH fixes · bedea69 folders + lorebook editor · c516c9b themes + botbooru fix)

## 1. Lorebook Creator — FULL feature shipped (Waves 1-3)
AI builds a lorebook ONE entry at a time. Lives in Lorebooks: "New lorebook with
AI" + "Add entries with AI". You chat about a topic; it proposes trigger keywords
+ writes the entry; you tweak + save; loop. Built as its OWN screen (the character
Creator was never touched). Spike validated keyword/content quality on a STRONG
model (your Qwen/Venice not yet tested — see Open items).
Card integrations (you chose "always ask shared vs embedded"):
- "Create with AI" in a card's lorebook binding → builds + binds.
- "Embed into a card..." in the lorebook kebab → bind to a chosen card.
- EXPORT-TRAVEL FIX (you approved): exporting a card/persona now embeds its bound
  lorebooks inside the PNG (character_book) — this was a real pre-existing gap;
  bound lorebooks never traveled when sharing a card before.

## 2. The audit you asked for (Checkpoints · Live Sheet · Chat Tree)
Found real bugs; fixed the HIGH ones (doc: 2026-06-15-checkpoints-livesheet-chattree-audit.md).
- CHECKPOINTS: (C1) concurrent manual+auto summarize made DUPLICATE checkpoints →
  fixed with a shared service-level lock. (C2/C5) a checkpoint could bind to the
  WRONG branch if you swapped a variant mid-summary → fixed (hash snapshot before
  the call). (C3) deleting/editing a checkpoint while a retry ran could lose data
  → fixed. (C4) the "Summarise now" button looked alive during a retry → fixed.
- LIVE SHEET: (L1, worst) "Generate from chat" was DESTROYING your LOCKED and
  hand-typed facts → fixed (lock-preserving merge: locked facts always kept). (L4)
  stale text could overwrite a different fact after an auto-update → fixed.
- CHAT TREE: SOUND — jump logic + the recent OOC/Scene change verified correct.
  Only 2 LOW edge cases (corrupted/hand-edited data; concurrent chat deletion) —
  flagged, not fixed.

## Open items / needs your call
- LIVE SHEET semantic (flippable): a NEW seeded fact is APPENDED even next to a
  locked one (no data loss; you prune). Say if you'd rather "a locked section is
  fully hands-off."
- LIVE SHEET L3: an un-blurred edit can be lost if an auto-update fires while you
  type (needs a chat-screen hook) — DEFERRED; the silent-corruption part is fixed.
- LOREBOOK CREATOR on YOUR model: spike was a strong model. Worth a real test on
  Qwen/Venice (or I hand you the prompt to paste).
- CHAT TREE T1/T2 (LOW): fix only if you want.
- NONE of this batch is runtime-tested on the live GUI — the hands-on visual pass
  is still gated to whenever you want it. I can also build the .dev (Windows+APK)
  so you can try it all on waking.
