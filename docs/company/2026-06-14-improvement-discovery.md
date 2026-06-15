# Pyre — Improvement Discovery (2026-06-14)

> Run by the Chefe directly (the serialized HQ was busy with build + bug waves).
> 3 independent grounded passes: ember-framer + Explore(very thorough) + ember-challenger.
> Reasoned from REAL code (lib/screens, lib/widgets, lib/services). NOT run on the GUI —
> "feel" items flagged [HANDS-ON] need a human to actually use the app to confirm.
> Branch release/1.1.3 @ 4d6cf42.

## The headline (all three converged)
The gap is NOT more features or more knobs — the app already has deep settings and per-chat
bubble customization. The gap is the **FELT layer**: the app does not *respond* to the human
using it. This is squarely the house thesis (warmth / heart over grit, Toriyama–Ghibli–JRPG).

## Tier 1 — cheap, high-heart, low-risk (the "felt layer" + two quick wins)

1. **Haptics — there are ZERO in the entire app.** (S) Verified repo-wide: not one
   `HapticFeedback`/`SystemSound` call in `lib/` (the only vibration hit is an unrelated
   keepalive). For a *mobile-first* product this is the single biggest cheap miss. Light tick
   on send, selectionClick on swiping reply variants, soft tick on checkpoint save. Callbacks
   already exist (`chat_screen.dart` onSend/onSelectVariant/onRegenerate/onLongPress).
   [HANDS-ON to calibrate which actions deserve a buzz.]

2. **The "Generating…" moment is dead static text.** (S→M) `chat_screen.dart:4483` shows a
   frozen italic string while the character composes — the most-watched moment in the whole
   app, every single turn, and it is the deadest. No typing animation anywhere (verified: no
   shimmer/pulse). Animated "[character] is thinking…" indicator, tinted with the character's
   accent. The streaming flag (`isStreaming`/`_streamMessageId`) already exists to drive it.
   [HANDS-ON to tune feel.]

3. **Empty states / microcopy are help-desk voice, not Ember voice.** (S) `empty_state.dart`
   is a clean shared widget; `chats_screen.dart:40` fills it with "No chats yet — Start a chat
   from the Characters tab." The empty Chats screen is a blank page waiting for a story — free
   real estate for warmth. The widget already supports an optional CTA (`onCta`/`ctaLabel`)
   that several call-sites don't use → wiring the canonical action in is on-pattern + low-effort.

4. **First-run dead end (novice make-or-break).** (S) After onboarding the user has no provider;
   first Send fails with a friendly SnackBar — but it has a Retry button and NO button that
   takes them to API Connections (`chat_screen.dart:1661`). A non-technical user reads
   "Open More → API Connections" and is stuck. Add a "Set up" action that pushes
   `ApiConnectionsScreen`. (Irreducible-for-Kuru: should onboarding itself END on the provider
   screen? It was deliberately removed once for feeling "forced" — taste pivot.)

5. **In-app raw-output / log viewer (power-user win, data already exists).** (S–M)
   `llm_debug_log.dart` already writes every request/response/sampling/timing/finish_reason as
   daily JSONL (key-stripped by construction) and exposes `logFiles()`/`readAll()`/
   `recentTraces`/typed `LlmCallRecord`. It is **export-only — no in-app viewer exists.** A
   viewer is mostly a ListView + feature-filter + expandable detail over existing data. Lives
   naturally in Storage → Developer where the toggle already is.

## Tier 2 — bigger bets, need Kuru's taste/scope call BEFORE any code

6. **Theming — the trap.** (Reflex pick. Reframe, do not build the obvious version.)
   Per-chat *bubble* color/blur/radius/background ALREADY ships (`chat_appearance_screen.dart`,
   10-swatch palette + scene-aware backdrop). The "Theme" row was *deliberately removed*
   (`more_screen.dart:63`) because there was nothing to pick. A global app-chrome color picker
   would sand the ember identity into a generic skinnable wrapper. Soulful version = 2–3
   hand-authored named **moods** with character (Ember default / cool "Moonlit" / warm
   "Hearth"), not infinite RGB. COST WARNING: true app-wide theming = migrating **1272
   hardcoded `EmberColors.*` refs across 60 files** off compile-time constants → L/invasive.
   Recommend: start with selectable **accent color** (a few `EmberColors.primary` swaps drive
   most visible identity) + maybe 2–3 curated dark moods. Light mode = separate large project.

7. **Character expressions / Visual-Novel feel — the big delight bet.** (L, needs product
   vision.) No expression/sprite/VN/TTS/sound infra exists at all. Web research: expressions +
   VN mode are what the roleplay community values most for immersion. Cards already carry
   galleries (`gallery_editor_section.dart`), so a lightweight first step (a large character
   portrait beside/behind the chat, swapping among gallery images) is feasible without an
   emotion classifier. Full emotion-driven sprite-swapping is a real project. → A "do we want
   to be a visual novel?" question for Kuru, not a task to schedule.

8. **Settings-sprawl audit (hide the nerd knobs).** (M) Onboarding promises "you don't need to
   fiddle with nerd settings," but Chat Settings is a 9-row hub of sub-screens and More is long.
   Honest improvement = the OPPOSITE of more toggles: push advanced knobs behind "Advanced" so
   a novice never trips over them. Progressive disclosure, which the app already believes in.

9. **Roster reads like a contact list, not a cast.** (M) Characters/chats are competent rows;
   nothing radiates while browsing. JRPG party-screen energy: show last line / a one-line
   tagline under the name so the roster reads like *people you know*. [Taste call.]

## Explicitly DEMOTED / KILLED by the Challenger
- "More toggles / more knobs" → KILL (negative heart value now; settings already sprawl).
- Folders for chats → KILL (generic-wrapper default; chats already group BY CHARACTER, the
  right characterful organizing principle). Chat **search** = the one keep at scale.
- Export → already exists.

## Operational reality (be honest with Kuru)
- The HQ engine serializes on a single active-company lock: Company 0 (build) + Company 1
  (bug wave) are queued; a 3rd discovery couldn't start, so this brainstorm was run directly.
- The **Codex seat hit its usage limit** ("try again at 9:24 PM") — it was the workhorse dev.
- Tier-1 items are small/low-risk enough to dispatch via ember-implementers in worktrees
  WITHOUT waiting on the serialized HQ, once Kuru greenlights.
- The "feel" items ([HANDS-ON]) need the Chefe's computer-use pass on the real app (Kuru's
  access approval) — that is the authentic "see/use the app" source the headless seats can't be.
