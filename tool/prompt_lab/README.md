# Prompt Lab — prompt-pipeline observability

Prompt Lab lets you see the **exact** prompt Pyre assembles and sends to a model —
for a chat turn (with LTM checkpoint, Live Sheet, Script, lorebooks, group roster)
and for the Character/Persona/Scenario Creator (the structured-JSON build request
for the first field batch + the deterministic card render) plus the vision call.
It is **agent-first**: a headless, file-based harness meant to be
driven by an AI agent (Claude, Codex, …) or a contributor working in the repo —
no UI clicking, no live model required for the core flow.

It has three independent surfaces:

| Surface | Needs a key? | What it answers |
|---|---|---|
| **`inspect`** | No | "What prompt do we assemble?" — dumps every labeled segment + token counts to disk. |
| **`live`** | Yes (your own) | "What does a real model do with it?" — fires one scenario at your provider and appends the raw response + parse outcome. |
| **In-app diagnostics log** | Uses the app's configured key | "What actually went over the wire in a real session?" — opt-in JSONL capture at the single `chat_api` chokepoint. |

The harness reuses the **real** builders in `lib/services/chat_prompt_builder.dart`
(the same code the app runs), so what you see is what ships. Fixtures come from the
bundled example cards (Ren persona + the Vael world/scenario) with **fixed-length**
message arrays so `{{random:}}` and token counts are deterministic.

---

## 1. `inspect` — assemble prompts, no key

From the `flutter_app/` package root:

```
C:\Users\Gui\flutter\bin\flutter.bat test tool/prompt_lab/prompt_lab.dart
```

(POSIX: `flutter test tool/prompt_lab/prompt_lab.dart`.)

It writes, per scenario, to the gitignored `tool/prompt_lab/out/`:

- `<id>.md` — a human/agent-readable report: each segment labeled
  `## [<kind>] (~N tokens)` in assembly order, plus the full turn list.
- `<id>.request.json` — the raw request body (messages + sampling) exactly as it
  would be serialized for the provider.

Scenarios: `chat_single`, `chat_group`, `creator_character`, `creator_scenario`,
`creator_persona`, `creator_vision`. Each `creator_*` build scenario dumps the
first batch's structured JSON request (via `buildBatchTurns`) plus a trailing
`render` turn with the deterministic `renderCard` Description of a known field
map. A summary table (id → ~tokens, segment/turn count) prints at the end.

Nothing here calls a model. This is the fast loop for validating a prompt change.

## 2. Golden snapshots

`test/goldens/prompt_lab/*.txt` are committed, stable serializations of the
assembled prompts (no tokens/timestamps). The golden test asserts the current
assembly matches:

```
C:\Users\Gui\flutter\bin\flutter.bat test test/prompt_lab_golden_test.dart
```

When you **intentionally** change a prompt, regenerate the goldens (see the header
of `test/prompt_lab_golden_test.dart`) and commit them — the diff is the
prompt-engineering change, reviewable in the PR.

## 3. `live` — fire one scenario at a real provider

1. Copy the template and fill it in with **your own** provider:
   ```
   cp tool/prompt_lab/local.example.json tool/prompt_lab/local.json
   ```
   `local.json` is **gitignored** — it holds your API key and must never be
   committed. Fields are documented inline in `local.example.json`
   (`baseUrl`, `model`, `apiKey`, optional `extraParams`, optional `kind`).
   Local servers (LM Studio/Ollama) usually ignore `apiKey` — leave it blank and
   set `"kind": "localhost"`.

2. Run a scenario (defaults to `chat_single`):
   ```
   C:\Users\Gui\flutter\bin\flutter.bat test tool/prompt_lab/prompt_lab_live.dart --dart-define=scenario=chat_single
   ```

It appends the raw response, `finish_reason`, and a **per-feature parse outcome**
(chat → truncation flag; creator → JSON-object shape + the deterministic
`renderCard`/`missingRequired` verdict over a fixture field map; LTM →
recap-complete; Live Sheet → parsed delta; scene → classifier verdict) to the
report. The key is redacted in all output and is **never** written to any report.

If `local.json` is missing or still holds the placeholder key, live mode **skips
gracefully** (exit 0) so the harness stays safe to run unattended.

## 4. In-app diagnostics log (capture a real session)

To see the prompts from a real session on a device, the app has an opt-in logger
(Storage → Developer → "Log raw LLM calls"). When on, every LLM call
(chat / LTM / Live Sheet / creator-architect / creator-vision / scene) is written
to `{appDocs}/Pyre/logs/llm/<date>.jsonl` and can be exported/copied/cleared from
the same screen. It is **off by default**, contains your chat text, and **never**
contains your API key (the key rides the `Authorization` header, which is not
captured). Use it to hand a real transcript to an agent for analysis.

---

### Safety notes

- An agent must **never type an API key into a UI field**. Live mode reads a key
  you placed in the gitignored `local.json`; the in-app path uses the key already
  in the app's secure storage.
- `tool/prompt_lab/out/` and `tool/prompt_lab/local.json` are gitignored.
- The API key never appears in any report, golden, or diagnostics line — there is
  a unit test (`test/llm_debug_log_test.dart`) that pins a sentinel key's absence.
