# Changelog

All notable changes to Pyre are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Pyre follows a leading-digit `MAJOR.MINOR.PATCH` version.

## [1.1.0] - 2026-06-06

> Draft date — final date set at release.

Pyre 1.1 is the first feature release after the 1.0 launch. It focuses on the
"power user" requests from the community: deeper control over how prompts are
built, importing your existing SillyTavern setup wholesale, customizing how
chats look, and a round of stability and data-integrity fixes that make backups
and long sessions more trustworthy.

### Added

- **Composable presets (Prompt Manager).** Presets can now hold a list of named
  prompt blocks, each with its own on/off switch. Import a modular preset and
  toggle which modules are active without editing any text. Reorder, rename, edit
  and add blocks in the preset editor. Flat (single-prompt) presets are
  unchanged and keep their simple editor.
- **Bulk SillyTavern import.** Select many files at once and Pyre sniffs each one
  and routes it to the right place — character cards, lorebooks, regex rules and
  presets all in a single pass, with a summary of what came in and what didn't.
- **One-tap BotBooru lorebook import.** On a lorebook page in the in-app Discover
  browser, "Download JSON" now imports the lorebook straight into Pyre — the same
  one-tap flow as character cards, with a confirmation showing the name and entry
  count. (Mobile and desktop; see Platforms for Web.)
- **Regex find/replace rules.** A global list of find/replace rules that can
  clean up model output, your own input, or just what's shown on screen. Rules
  can apply to the saved message, only to what the model sees, or only to what's
  rendered — mirroring SillyTavern's behavior. Includes a test field, an
  invalid-pattern guard so a bad rule can never break a chat, and import of
  SillyTavern regex `.json` files. Ships with one safe default rule —
  *"Unwrap italics around dialogue"* — that strips the italic asterisks models
  often wrap spoken lines in (`*"Hello."*`), so dialogue renders as dialogue
  instead of faint narration; it's display-only and you can toggle or delete it
  any time.
- **Chat bubble customization.** Separate colors for your bubbles and the
  character's, plus adjustable corner radius, border, padding, text size, and a
  backdrop blur so text stays readable over busy chat backgrounds.
- **Lorebook keyword options.** Entries now support secondary keys with
  AND/NOT logic, per-entry case sensitivity, whole-word matching, and a trigger
  probability. SillyTavern World Info imports carry these fields over.
- **`{{summary}}` macro.** Drop `{{summary}}` into a preset to place the
  long-term-memory recap exactly where you want it instead of relying on the
  default injection point.
- **Quick preset switch from inside a chat.** Change the active preset (and tweak
  the main prompt) from the chat itself, without going back to Settings.
- **Global UI scale.** A slider to shrink or enlarge the whole interface — useful
  on small or high-density phones.
- **Per-provider prompt post-processing.** Optional SillyTavern-style reshaping
  of the outgoing message list (merge consecutive turns, single system message,
  strict user/assistant alternation, or collapse to one user message) for models
  and routes that are strict about message shape. Off by default; existing
  requests are unchanged.
- **Duplicate a character or persona** from its menu, to fork a card without
  re-importing or rebuilding it.
- **Avatar thumbnails frame the face.** Portrait card art is now auto-cropped
  toward the face in the circular thumbnail instead of being squished whole into
  the circle — no manual cropping needed.
- **Non-destructive recrop.** Re-framing an avatar keeps the full original: the
  thumbnail shows the crop, but tapping it (and the chat backdrop) shows the
  whole picture. Works for characters, personas and your BotBooru profile, and
  the original travels with sync so it isn't broken on a second device.
- **More import sources.** Import character cards from a direct `.png`/`.json`
  link, from catbox.moe / pixeldrain, and from RisuRealm
  (`realm.risuai.net`) — on top of BotBooru, chub.ai and the existing flows.
- **Your BotBooru profile syncs.** Username, avatar, bio, title, pronouns and
  featured character now travel between your paired devices, as their own
  last-writer-wins unit so an unrelated settings sync can never blank them.
- **"Check sync" + a sync status indicator.** Confirm both devices hold the same
  library via a per-collection fingerprint, and see what the last sync moved
  (pulled / pushed) and when, right on the LAN screen.
- **Local model server quality-of-life.** Optionally preload your local model on
  launch and use longer connect/stall timeouts so the first request survives a
  cold load (LM Studio / Ollama), plus clearer localhost-provider hints.
- **Desktop Enter-to-send in the Character Creator** (Shift+Enter inserts a
  newline; on Android, Enter stays a newline and the send button commits).
- **Import a whole SillyTavern backup.** Point Pyre at ST's "Download Backup"
  `.zip` and it pulls in your cards, world info, presets, regex scripts and chat
  logs in one pass — and hard-skips `secrets.json`, so your ST API keys are never
  read.
- **SillyTavern chat-log import.** Chat `.jsonl` files import with their swipes
  preserved as message variants, bound to the matching character.
- **"Guide my message."** A distinct action from "Impersonate me": instead of
  writing the whole next turn as your persona, it steers the upcoming reply from
  an outline / perspective you provide.
- **Rename a chat** from its menu.
- **Better reasoning-model support.** A model's "thinking" channel is handled and
  kept out of the visible reply (and out of Checkpoints summaries).

### Changed

- **Long-Term Memory is now called "Checkpoints"** throughout the app — clearer
  language for the same continuous-recap feature.
- **Backups now include your images.** Avatars and gallery images are packed into
  the backup file, so restoring on a fresh install or a second device brings the
  pictures with it instead of leaving placeholders.
- **Sync got safer.** Conflicting edits to the same chat across two devices are
  now detected and surfaced (instead of one side silently winning), and folders
  and your forked Creator/architect prompts now sync between devices.
- **Imported avatars no longer bloat your data file.** Card and image imports now
  store the picture as a content-addressed file like everything else, instead of
  inlining it into the main JSON store on every save.
- **Real "Save to device" on Android.** Exporting a card now goes through the
  system file picker / share sheet instead of vanishing into app-private storage.
- **Your settings sync too.** Model, chat, memory, Live Sheet, script and guide
  settings — plus your active / Creator / vision provider choices — now sync
  between devices. Your custom chat background stays per-device on purpose.
- **Volume-safe image sync.** Sync now uploads only the image bytes the other
  device is missing (content-addressed negotiation), so syncing a big library
  never re-sends gigabytes of pictures the other side already has.
- **The Character Creator opens on the chat** (not an empty sheet) and no longer
  shows internal "block" wording anywhere in its chat, status text or help.

### Fixed

- Fixed a Windows crash that could hit anyone during normal use (a null-dereference
  in the desktop window layer's accessibility bridge), plus a big performance pass
  so large libraries no longer slow down or crash as you add lots of cards.
- Fixed a desktop UI-thread hang that could occur when changing the text scale or
  resizing the window.
- The Creator no longer silently discards a card if you send a chat message while
  a build is in progress.
- The Live Sheet now actually tracks state on a new chat when it's enabled,
  rather than staying inert until manually toggled off and on.
- Persona `{{user}}`/`{{char}}` placeholders are now resolved when generating an
  opening message, instead of leaking through literally.
- SillyTavern-imported modular presets now include the character, persona and
  lorebook in the prompt (previously they could ship only the jailbreak text).
- The provider editor no longer leaks text fields (and your API key) in memory
  each time it's opened; the same leak was fixed across the character editor,
  persona editor, preset/lorebook editors and many smaller dialogs.
- Provider Browse / Test / warm-up requests now have the same private-network
  safety guard as imports.
- Lorebook injection order is now stable and deterministic from build to build
  (better prompt-cache hits, reproducible regenerations).
- The in-chat preset quick-edit no longer pretends to save changes on modular
  presets where they wouldn't apply.
- Soft-deleted personas no longer appear in the persona picker.
- Out-of-range slider values from older builds, sync or backups no longer crash
  or render oddly on the Presets screen.
- Card-fetch helpers now have timeouts, so a stalled host can't hang an import
  forever; the desktop sync server now caps incoming push bodies.
- Failed saves are now surfaced instead of silently swallowed.
- Vision (image-reference) profiles get a more generous output budget and a soft
  "may be truncated" note, reducing silently cut-off appearance profiles.
- Various list-virtualization and caching improvements to keep long sessions and
  large libraries responsive.
- BotBooru "Download PNG" (and pulling in the image gallery) broke after a site
  change — fixed by following the card id from the page URL.
- "Impersonate me" is back as its own action — write the next message *as* your
  persona — separate from "Guide my message" (which only outlines/steers).
- An "Exported" notice that could stay on screen forever now always dismisses.
- Re-pairing — or pointing at a reset PC — could leave only some cards / chats /
  presets synced; sync now detects the new device and does a full reconcile.
- Fixed a crash and a leftover background process when quitting from the tray.
- The Checkpoints summary prompt now updates itself on upgrade instead of keeping
  the old one.
- API-key sync hardened in both directions — re-stamps providers when you enable
  it and resets cleanly on re-pair — so keys reliably reach a newly opted-in
  device.
- LAN hardening: a generous per-device rate limit on the model proxy, same-origin
  CORS, and redirect-free + size-capped card fetches.
- Image-reference (vision) profiles strip any leaked model "reasoning" preamble
  and run in a closed circuit — no roleplay prompt or sampling settings bleed in.
- **Broad provider compatibility.** A request a strict provider rejects for shape
  reasons now auto-retries once with a minimal safe body, and known-strict
  providers (OpenAI reasoning models, Mistral) proactively drop the fields they
  reject (`max_completion_tokens` vs `max_tokens`, the extended samplers).
  Permissive providers (OpenRouter, Venice, local, …) are unaffected.
- **Windows "Stability mode."** Machines that crashed through the GPU-overlay +
  accessibility path (e.g. the NVIDIA GeForce overlay hooking the present chain)
  can switch on a per-machine stability mode that steers the engine onto
  lower-risk graphics / accessibility paths at the next launch.

### Platforms

Pyre 1.1 ships for **Android, Windows, Linux and Web**.

- **Android, Windows and Linux** are full native apps — your characters, chats,
  presets and keys live on the device.
- **Web / PWA is a companion client, not a standalone app.** Open Pyre in a
  browser — including **iOS Safari → "Add to Home Screen"** for an app-like icon,
  which is how you use Pyre on iPhone/iPad (there is no native iOS app) — and
  **pair it with your desktop Pyre over your local network**. It mirrors your
  desktop's library and runs models *through* your desktop, so it needs your
  desktop Pyre running and reachable; there is no offline/standalone web mode.
  On Web, in-app Discover browsing and one-tap card/lorebook import aren't
  available (browsers can't embed the source site) — open links externally or
  paste a URL — and chats use your global model settings.

---

## [1.0.8] - 2026-06-03

- Fixed the Character Creator app bar overflowing on narrow screens.

## [1.0.7] - 2026-06-03

- Added standalone SillyTavern lorebook import.

## [1.0.6] - 2026-06-03

- Creator and Fill-In fixes.

## [1.0.5] - 2026-06-02

- The long-term-memory summariser now retries once after a transient provider
  blip.

## [1.0.4] - 2026-06-02

- Key sync now backfills a missing key onto an existing provider.

## [1.0.3] - 2026-06-02

- Phone-side provider-key sync toggle, full re-pull, and provider delete.

## [1.0.2] - 2026-06-02

- Fixed API key / provider sync doing nothing (providers were stuck at
  `mtime=0`).

## [1.0.1] - 2026-06-02

- Fixed chat backgrounds appearing blank for avatar / `pyre://` image sources.

## [1.0.0] - 2026-06-02

- First public release of Pyre — a private, local-first, bring-your-own-API-key
  roleplay chat client. Includes streaming chat with variants and branching, the
  AI Character/Scenario Creator, personas, lorebooks/world info, presets and
  sampling, Checkpoints (long-term memory), card import/export (chara_card_v2
  PNG/JSON, by URL, and from community sources), smart provider fallback,
  LAN sync between your own devices, bundled example cards, and desktop features
  (tray, shortcuts, command palette, completion toasts).
