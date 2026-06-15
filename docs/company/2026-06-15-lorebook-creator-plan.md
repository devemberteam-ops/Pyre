# Lorebook Creator (per-entry) + card integrations — plan

> Founder greenlit per-entry build, but asked to FIRST think about placement
> (must live in Lorebooks) + integrations with cards (embedded lorebooks /
> create a lorebook for an existing card / join a standalone lorebook into a
> card as embedded). Spike passed (good keyword + content quality on a strong
> model). Branch release/1.1.3.

## Grounding (verified in code)
- `Character.lorebookIds` (models.dart:327) = the bind. Injection (lorebook_inject.dart:66) merges char + chat + persona books, deduped. This is what "the card carries a lorebook" means.
- `Lorebook.hidden` (models.dart:1687) = ONLY declutters the More→Lorebooks list (lorebooks_screen.dart:29 filters `!hidden`). Binding pickers STILL show hidden books (labelled "embedded"). So hidden ≠ embedded; it's just "don't list this for reuse."
- Import: `handleEmbeddedBookForCharacter` (lorebook_import.dart:452) already does it right — dialog (Extract / Embedded-only / Skip) → creates a book with `hidden` per choice → appends id to `lorebookIds`.
- **GAP (real bug):** EXPORT never embeds bound books. `encodeCharaCardPng` accepts `{Lorebook? lorebook}` (png_encoder.dart:133) and writes `character_book` only if passed — but the call site (characters_screen.dart:676) NEVER passes one. The model comment claims "on export all bound books merge into character_book" — that is ASPIRATIONAL, unimplemented. So today a card's bound lorebook does NOT travel when you export/share the card. "Embedded" is currently cosmetic on export.
- lorebooks_screen actions: AppBar = Import + New(+); per-book kebab = Edit/Rename/Copy/Export/Delete. No "AI" and no "Embed into a card."
- `lorebook_binding_section.dart` binds EXISTING books only — no "create new" path.

## Design

### Placement (per founder: in Lorebooks)
- lorebooks_screen AppBar: add **"New lorebook with AI"** (3rd action by Import/New) → opens the per-entry Lorebook Creator with a fresh target book.
- Inside an existing lorebook (LorebookEditScreen): **"Add entries with AI"** → same Creator, appends to that book.

### The Creator (per-entry, from the approved architect plan)
Its own screen (`lorebook_creator_screen.dart`) — NEVER touch the character_assistant god-file. Chat about ONE topic → architect proposes keys + writes content → `[[BUILD_ENTRY]]` + one JSON object → maps to LoreEntry → appended to the target Lorebook via addLorebook/updateLorebook → loop. Reuse creator_json + the marker pattern + LoreEntry model + save path. Harden the prompt for weak models (Qwen): duplicate the key guardrails (no bare broad keys, reference-not-story, single-line JSON) NEXT TO the emission marker + defensive JSON repair in the drafter. New pure files: lorebook_entry_schema, lorebook_entry_build, lorebook_architect_prompts.

### Card integrations (the 3 the founder named)
1. **Create a lorebook FOR a card** (existing card): from `lorebook_binding_section` add a **"Create with AI"** action → opens the Creator → builds a new book → binds it (adds to lorebookIds). Works both in the Character editor and in the Creator-save flow → also covers "embedded lorebook while making a card."
2. **Join a standalone lorebook INTO a card as embedded**: per-book kebab in lorebooks_screen → **"Embed into a card…"** → pick a character → add the book id to that char's lorebookIds (+ optionally set hidden=true to declutter). 
3. **PREREQUISITE so "embedded" actually means something:** wire the export call site to pass the card's bound book(s) into `character_book` so they TRAVEL on export (fix the gap). Decision needed: which books travel (recommend: all non-deleted bound books, merged) + whether export auto-embeds always or asks.

### Embedded vs shared (the semantic)
A book bound to a card can be: **shared** (hidden=false, reusable across cards, shows in Lorebooks) or **card-only/embedded** (hidden=true, decluttered, just rides with that card). Both already supported by the data model; the Creator/bind flows should let the user pick, with a sensible default.

## Decisions for the founder
- D1: default when creating a lorebook for a card — **shared** (reusable) vs **embedded/card-only** (hidden). (Recommend: ask once with a clear toggle; default to shared since it's reusable + still travels on export once D3 is fixed.)
- D2: do all 3 integrations now, or ship the Creator-in-Lorebooks first and add the card integrations in a 2nd wave? (Recommend: Creator-in-Lorebooks first → then integrations.)
- D3: the export-travel fix — recommend doing it regardless (it's a real gap; bound lorebooks SHOULD travel when you share a card). Confirm "all bound books merge into character_book on export."

## Build order (proposed)
Wave 1 (foundation, pure BE): lorebook_entry_schema + lorebook_architect_prompts + lorebook_entry_build (+ tests). 
Wave 2 (FE): lorebook_creator_screen + the "New lorebook with AI" / "Add entries with AI" entry points.
Wave 3 (integrations): "Create with AI" in binding section + "Embed into a card" kebab + the export-travel fix.
Each wave: CEO green gate + independent verify.
