# Fix: Creator generated alternate greetings unsolicited + couldn't do only-on-request

> Branch release/1.1.3. Kuru report: "ele faz as alternativas sem pedir e não
> sabe fazer só alternativas quando é pedido." first_mes quality is FINE — the
> whole bug is alternate greetings. Target (Kuru-confirmed): never auto; ONLY on
> explicit request (conversational, like edit-card); each a DIFFERENT situation.

## Root cause (confirmed in code)
Two symptoms, one tangle of contradictory/over-eager prompt instructions.

1. **Unsolicited generation.** The live Creator build runs
   `runStructuredBuild(batches: batchesFor(mode))` (character_assistant_screen.dart
   ~959). The always-run *closing* batch includes `'alternate_greetings'`
   UNCONDITIONALLY (creator_schema.dart:710 char, :805 scenario), and the field
   guidance said "a JSON array of 0-3 strings … empty array [] if no good
   alternate fits" — which invites the model to always find a fit. So EVERY
   build produced alternates, solicited or not. (Introduced by Wave CY.18.270,
   which over-corrected an earlier "add-when-asked did nothing" bug by adding the
   field to the always-run batch.)

2. **Can't do only-alternates-when-asked.** The Edit-with-AI prompt
   (`kCardEditorFreeFormPrompt`, card_assist_prompts.dart) contained a section
   "## ALTERNATIVE GREETINGS — NOT PART OF THE BUILD" that told the model to
   REFUSE and point the user to the manual editor — directly contradicting the
   build/Block-6 path that emits them. With instructions fighting, the model had
   no clean way to generate *just* alternates on request.

The character architect prompt (`kCardAssistantPrompt`) does NOT mention
alternate greetings — so create-mode unsolicited generation came purely from the
build's closing-batch field guidance.

## Fix (prompt coherence — no UI, no new trigger; matches "igual edit card")
- **creator_build_prompts.dart** `_shapeHint` greetingsList (PRIMARY, live +
  unit-tested): rewrote to "Do NOT invent these. ONLY produce … if the user
  EXPLICITLY ASKED … else an empty array [] on a new card, or leave any existing
  greetings UNCHANGED when editing — never fabricate. When they DID ask: emit the
  number requested (2-3 if unspecified), each a COMPLETE standalone opening in
  first_mes's voice, but each a genuinely DIFFERENT SITUATION." The build passes
  the conversation transcript, so the model conditions on whether the user asked.
- **card_assist_prompts.dart** `kCardEditorFreeFormPrompt` (live edit prompt):
  replaced the contradictory "NOT PART OF THE BUILD / refuse / point to editor"
  section with "OFF BY DEFAULT, ON REQUEST ONLY" + the different-situation rule.
- **card_assist_prompts.dart** Block 6 in `kCardUpdaterPrompt`: strengthened to
  "emit ONLY when explicitly asked, else SKIP" + different-situation. NOTE:
  `kCardUpdaterPrompt` is VESTIGIAL ("the old per-turn" prompt, no live caller) —
  this edit is coherent but inert; kept for consistency.
- Kept `alternate_greetings` IN `batchesFor` (so the edit-card conversational
  flow still works); it's now harmless because the field guidance returns [] /
  unchanged unless the user asked.

## Why this matches Kuru's "só dizer e funciona, igual edit card"
The user converses ("quero alternate greetings de tal jeito"); the edit/build
sees the request in the transcript and produces ONLY the alternates (edit-framing
keeps every other field verbatim), each a different situation. No request →
empty (new card) or untouched (edit).

## Mode-safety (no data loss)
The guidance deliberately says "empty array [] on a NEW card, or leave existing
greetings UNCHANGED when editing" so an unrelated edit can't wipe a card's
existing alternates. It avoids the literal phrases "current value"/"THIS IS AN
EDIT" so the create-mode H1 test invariant holds.

## Tests
`test/creator_greetings_conditional_test.dart` (6 tests, char+scenario): the
build greetings guidance must be request-conditional ("explicitly asked"),
default empty ("empty array"), and require a "different situation". Existing
H1 edit-framing + alternate_greetings tests stay green. flutter analyze clean ·
1682 tests · prompt-lab goldens regenerated (the architect goldens are unchanged
— they don't render the build-batch or edit-prompt sections that changed).

## Note
This is a prompt fix — behavior is LLM-driven, so it can't be unit-proven that a
given model will always obey "only when asked". The contradictions (the main
driver) are removed and the instruction is now crisp + single-voiced. Real
confirmation = Kuru tries it in the Creator on his model (create → no alternates;
ask "add 2 alternate greetings in different situations" → 2 distinct ones).
