# Creator — fresh audit (2026-06-14)

> Founder asked for a fresh audit of the AI character Creator. 3 read-only
> finders on disjoint slices (conversation/session · build pipeline ·
> render/edit/save). Several findings empirically confirmed by the finders;
> the CEO must re-verify each before it becomes a fix (verify != produce).
> Already-fixed (NOT re-reported): decompose paragraph drop, trailing-comma
> JSON, JSON-continuation re-emit, preset depth, OOC/Scene, vision leak.

## HIGH

### H1 — Edit-with-AI silently REGENERATES first_mes / dialogue examples / tags / creator_notes (data loss on the most common edit)
- Files: character_assistant_screen.dart:822-858 (the `existing` map) + creator_build.dart:85-93 (starts from empty) + creator_build_prompts.dart:284-318 (edit framing only seeds keys present in `existing`).
- Mechanism: on edit, `existing` is built ONLY from `decomposeDescription(...)` — i.e. only fields living inside the Description. Top-level fields (first_mes, mes_example/dialogueExamples, tags, creator_notes, tagline, alternate_greetings; for scenario also name/scenario/post_history) are absent from `existing`, so the edit prompt gives the model no current value → it INVENTS fresh content, which renders + saves over the user's hand-written values. The scenario fix at line ~849 seeded ONE field (scenario) in ONE mode (character) — the rest are unprotected. The blank-guard (1005-1011) only stops EMPTY rebuilds, not regenerated non-empty ones.
- Repro: edit any card with AI → "make her 25 instead of 30" → /build → Save. First Message / Dialogue Examples / Tags come back rewritten.
- Fix shape: seed `existing` from the canvas with first_mes, mes_example, tags, creator_notes, tagline, alternate_greetings (+ scenario name/scenario/post_history) so the edit framing carries current values for verbatim echo. Mirror the line-849 pattern, all fields/modes.

### H2 — "Stop" during a structured build does NOT stop it and locks the Creator UI for minutes
- Files: character_assistant_screen.dart `_stop()` :2271-2283; build flow :787-1068; creator_build.dart `runStructuredBuild` :77-116 (no cancellation token).
- Mechanism: `_stop()` clears `_generating` but NOT `_structuredBuilding`; the build has no cancellation, so it runs every remaining batch+re-request to the end (minutes). UI stays disabled (creatorSendBlocked) until the build's `finally` runs. `_abortInFlightStream` (:2295-2324) DOES clear `_structuredBuilding` — `_stop` was never given the same line (asymmetric by omission).
- Fix shape: have `_stop` clear `_structuredBuilding` + add a cancellation token to `runStructuredBuild` (bail between batches when cancelled).

### H3 — Structured build has NO keep-alive → Android can kill the app mid-build and lose the whole build
- Files: build flow :787-1068 (no `_keepAliveStart/Stop`); keep-alive wraps only the architect chat turn (:1457/1534) + vision.
- Mechanism: the SHORT architect turn holds the foreground keep-alive; the LONG build (the op whose own status says "can take a couple minutes, keep the app open") holds nothing. Backgrounding mid-build on a memory-pressured device can reap the process → build lost.
- Fix shape: wrap the structured build in `_keepAliveStart(heavy:true)` / `_keepAliveStop()`.

### H4 — Continuation seam mistakes a {…} fragment inside a resumed string for the whole object → loses the entire batch + injects garbage
- File: creator_build.dart:156-160 (seam guard `extractJsonObject(more)` is greedy-first-object over the whole continuation chunk).
- Mechanism: when a batch truncates mid-string and the model resumes correctly, if the resumed VALUE text contains a JSON-object-looking substring, `extractJsonObject(more)` returns that inner fragment and the real partial `raw` is discarded. Different from the already-fixed re-emit case. Empirically reproduced (fields lost + "Note: INJECTED GARBAGE" rendered into Description).
- Fix shape: only accept the standalone object if it shares >=1 requested batch key (or only when `more` starts with `{`).

### H5 — Cross-batch merge clobber: a later batch can silently blank an earlier batch's good field
- File: creator_build.dart:93 (`fields.addAll(parsed)` — unconditional).
- Mechanism: models over-emit keys; if a later batch echoes an earlier key as empty, the good value is destroyed. The FIX#2 re-merge at :107-110 already uses the correct empty-skip guard `if (_isEmpty(fields[k]) && !_isEmpty(value))` — line 93 lacks it. Non-required clobbered fields are lost silently. Empirically reproduced.
- Fix shape: apply the same empty-skip guard at line 93.

## MEDIUM / LOW
- M1 — Editing a user message that had an image drops the vision analysis; architect then replies blind (char_assistant :2430-2479 has no re-run-vision branch, unlike `_retry` :2526-2562).
- M2 — Scenario edit can wipe a `<Tag>`/`<World>` section: the scenario Description is re-rendered wholesale on edit; `mergeDescriptionSections` (creator_cascade.dart:203) exists but is NEVER called on the edit path.
- L1 — Can't clear a field via the AI editor: renderCard skips empty values, so "remove all tags" is silently ignored (creator_render.dart:74-90 + blank-guard).
- L2 — Smart-quote delimiter repair skipped if ANY straight `"` exists → a recoverable mixed-quote batch is dropped (creator_json.dart:78).
- Minor (not bugs): Save reachable mid-build can persist the pre-build canvas (:2727/:3805, no guard); edit-during-stream leaks the old SSE subscription (no cancel); a "pass N of M" over-count by one (cosmetic); `endsInsideUnterminatedString` is now dead code.

## Recommended fix order
H1 (worst — silent loss on the common edit) → H5 + H4 (pipeline data loss) → H2 + H3 (Stop/keep-alive, mobile). Then M/L. CEO verifies each against the real code before the fix.
