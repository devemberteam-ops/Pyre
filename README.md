<div align="center">

# 🔥 Pyre

### The roleplay frontend that respects you — your device, your models, your characters.

**Bring your own AI. Pyre is the interface that gets out of the way.**

*Mobile-first · cross-platform · local-first · open source · BYOK*

[Features](#what-pyre-does) · [Download](#get-started-beta) · [Privacy](#privacy-by-design) · [Build from source](#build-from-source) · [Why we built this](#why-pyre-exists)

</div>

---

> **Pyre is in public beta.** It's stable enough that we run it every day, but you'll find rough edges — that's what the beta is for. Tell us what breaks.

Pyre is a chat client for AI roleplay. You point it at whatever model provider you want — OpenRouter, Venice, NanoGPT, a local server, anything OpenAI-compatible — and Pyre handles the rest: characters, group chats, branching, long-term memory, an AI-powered card creator, lorebooks, prompt presets, and a built-in window into the [BotBooru](https://botbooru.com) card community. No account. No middle-man server. Your data lives on your machine.

It runs on **Android, Windows, Linux, and the web**, and the same library can **sync between your phone and your desktop** over your own network.

---

## Why Pyre exists

We're roleplayers. For years the serious tooling meant one of two things: a powerful-but-punishing desktop app that was never designed for the phone — where most of us actually read and write — or a polished hosted site that owns your chats, owns your cards, and can change the rules whenever it wants.

Then the rules changed. Recent policy shifts at some of the big platforms started sanding the edges off the thing we were there for. And the "just use a frontend" answer came with its own tax: your cards trapped in one app, no shared library, and the immersion-killing ritual of *find a card → download it → figure out how to import it → repeat.*

So we built the frontend we wanted:

- **Mobile-first, not mobile-afterthought.** The whole UI is designed for a thumb, then scaled up to the desktop — not the reverse.
- **Nothing is hosted but by you.** Your characters and your chats are your business. They sit on your device, full stop. You bring the model; we never see a single message.
- **The marketplace comes to you.** Pyre integrates directly with **BotBooru**, the community card hub — browse and one-tap-import without ever leaving the app or breaking the scene.
- **No sanitizing.** Pyre doesn't host, generate, or moderate content. What you write and what your model says is between the two of you.
- **Clean for newcomers, deep for power users.** A calm default experience, with every knob underneath for people who live in this stuff.

We're **Ember Team** — a small, independent group. We've put months into Pyre, and we're keeping our names off it for now: judge the software, not us.

---

## What Pyre does

### 💬 Chat & roleplay
- **Live token streaming** with reasoning-model support (hides `<think>` scratchpads automatically).
- **Branching that doesn't destroy history.** Reroll any reply; rewrite any of your own messages — and swiping back to an old variant brings its *entire* downstream timeline back with it. A full **chat tree** view lets you navigate the branches visually.
- **Group chats** — multiple characters in one scene, with a responder chip-row to choose who speaks next.
- **In-character tools** — Impersonate-me drafts your next turn in your persona's voice; OOC asides, scene direction, and slash commands (`/ooc`, `/scene`, `/sys`, …).

### 🤖 AI Character & Scenario Creator
- Describe a vibe; Pyre's **architect** builds a complete, richly-detailed `chara_card_v2` card with you — appearance, psychology, lore, scenario, opening message, dialogue examples, tags.
- **Self-healing generation**: a convergent engine keeps working until the card is genuinely complete, recovers from truncation on its own, and runs a **final QA review pass** over the finished card.
- **Scenario mode** builds whole *settings* — an omniscient narrator, world rules, and a real recurring cast of NPCs (each a person, not a name).
- **Vision**: attach a reference image and a vision model profiles it as authoritative context.
- **Fork the brain**: the architect's prompts ship as an editable preset — keep the tuned default, or copy it and make the creator yours.

### 🃏 Characters, personas & cards
- Full **chara_card_v2** support — import/export PNG & JSON, round-tripping fields other apps drop.
- **Personas** for *you*, with a per-chat switcher.
- **Per-chat character snapshots**: editing a card never silently rewrites your old conversations.
- Organize with folders, tags, favorites, and search.

### 📖 Lorebooks, presets & memory
- **Lorebooks / World Info** with keyword triggering, bound to characters, personas, or individual chats (with per-chat overrides).
- **Prompt presets** with optional per-field sampling overrides (SillyTavern-style) and template tokens — plus a tuned, NSFW-friendly default.
- **Long-term memory**: a branch-aware auto-summarizer keeps a continuous narrative recap in context, so the model never forgets chapter one by chapter ten.

### 🔌 Providers & reliability
- **BYOK** — any OpenAI-compatible provider; auto-detect models and context-window size.
- **Smart fallback**: if a provider fails *or* refuses, Pyre offers (never silently) to retry on your next configured provider — and learns which models refuse what.
- Leaked API keys in provider error messages are scrubbed before they ever hit your screen.

### 🌐 BotBooru / Discover
- A built-in, allowlisted window into **BotBooru** (and other trusted card hubs) with **one-tap PNG import** — the host is verified before anything downloads.

### 🔄 Sync & desktop
- **Cross-device sync** — run the desktop app as a hub, pair your phone with a QR code, and your library follows you. The web build can even run *through* your desktop so your API key never leaves it.
- **Desktop niceties** — system tray & close-to-tray, single-instance, window-state memory, remappable keyboard shortcuts + a command palette, and native "card's ready" toasts.

### 💾 Backup & import
- Full **Backup & Restore** (keys stripped by default), **SillyTavern preset import**, and lorebook import/export.

---

## Platforms

| | Android | Windows | Linux | Web |
|---|:---:|:---:|:---:|:---:|
| Chat, characters, creator, lorebooks, memory | ✅ | ✅ | ✅ | ✅ |
| BotBooru in-app browser | ✅ | ✅ | — | — |
| Acts as a sync **hub** | — | ✅ | ✅ | — |
| Syncs **to** a hub | ✅ | ✅ | — | ✅ (via desktop) |
| Tray / shortcuts / window state | — | ✅ | ✅ | — |

---

## Get started (beta)

> Pyre is **bring-your-own-key**: it does nothing until you add a provider. You'll need an API key from an OpenAI-compatible provider (OpenRouter, Venice, NanoGPT, a local server, etc.).

**Android**
1. Download `app-release.apk` from the [latest release](../../releases).
2. Allow installs from your browser/files app, tap the APK.
3. Open Pyre → **More → API Connections** → add your provider + key.

**Windows**
1. Download the `pyre-windows-x64.zip` from the [latest release](../../releases) and unzip it (keep the whole folder together — the `.exe` needs its sibling DLLs and `data/`).
2. Run `pyre.exe`. Windows SmartScreen may warn on an unsigned app — **More info → Run anyway** (we don't yet pay for code-signing; the source is right here).
3. **More → API Connections** → add your provider + key.

**Linux / Web** — build from source for now (see below); prebuilt Linux binaries land via CI shortly.

**First-run tip:** for the AI Creator, a DeepSeek-family or other uncensored model gives the best results — the model matters more than the prompt. Recommendations live in-app under **More → Character Creator**.

---

## Privacy by design

Pyre is **local-first and BYOK**. Your messages travel exactly one place: from your device to the provider *you* chose, over HTTPS.

| Data | Where it lives |
|------|----------------|
| Characters, chats, lorebooks, presets, personas, settings | App-private storage on your device |
| API keys | Your OS secure store (Android Keystore / Windows credential store) |
| Sync traffic (if you enable it) | Directly between your own devices on your own network |

- **No analytics, no telemetry, no crash reporting.** Pyre collects nothing and phones home for nothing — no usage stats, no event counts, no device ID. Nothing about how you use Pyre ever leaves your device. (If something breaks, a local error log stays on your disk for *you* to export — it's never sent anywhere.)
- **Backups strip your API keys** unless you explicitly opt in (behind a confirmation).
- **No cloud account. No content hosting. No moderation layer.**

Full text: [Privacy Policy](docs/privacy-policy.md) · [Terms of Service](docs/terms-of-service.md)

---

## Build from source

Prereqs: Flutter ≥ 3.12, and the toolchain for your target (Android SDK + Java 17 for APK; Visual Studio C++ for Windows; standard build-essential for Linux).

```bash
flutter pub get
flutter run                     # debug, on any connected device
flutter test                    # unit tests
flutter build apk --release     # Android
flutter build windows --release # Windows
flutter build linux --release   # Linux
```

Release signing & packaging: [docs/RELEASE.md](docs/RELEASE.md).

---

## Status & roadmap

Public **beta**. Core experience is solid; we're hardening edges and listening. On the near horizon: prebuilt Linux/web artifacts via CI, hardening the LAN sync security model before we promote it, and continued Creator tuning.

Found a bug or have an idea? **Open an issue** — that's the fastest way to shape the beta.

---

## License

Pyre is intended to be released as **open source** (we're finalizing on **AGPL-3.0** — copyleft, so any hosted fork stays open). A `LICENSE` file lands with the first tagged release.

---

<div align="center">

**Built by Ember Team.** · Integrates with [BotBooru](https://botbooru.com). · Not affiliated with any model provider — Pyre hosts no models and no content.

</div>
