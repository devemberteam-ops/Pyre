# Spec: finish the botbooru web embed (wire the /bbx proxy)

> The hard part EXISTS: `_proxyBotbooru` (pyre_server.dart ~1276) is a PoC
> reverse-proxy that fetches botbooru.com, strips X-Frame-Options/CSP
> frame-ancestors, and rewrites HTML + injects a runtime shim so botbooru loads
> in a same-origin iframe through the desktop. It is NOT wired into the web UI
> and has rough security edges. Finish it. Branch release/1.1.3. SECURITY-SENSITIVE
> (unauth proxy to a third party). Front-end proxy is OK per Gui; the API stays
> off-limits (Izanagi). The native exe/apk already load botbooru's full front-end
> in a webview — this is the web equivalent.

## Key insight
The Flutter web app is served BY the desktop at `http://<desktop>:<port>/`, and
`/bbx/` is on that SAME origin. So:
- The iframe src is a RELATIVE `/bbx/` — same-origin, no pairing needed, and the
  Flutter parent CAN read the iframe's current URL (SOP allows same-origin).
- Import fetches go through `/bbx/` (relative) → CORS-safe.
This only applies when the web was served by a Pyre desktop (LAN web). On the
public web (pyrechat.app) `/bbx` doesn't exist → keep the existing fallback.

## Slice 1 — Harden `/bbx` (pyre_server.dart `_proxyBotbooru`)
- SCRUB the error leak: `Response.internalServerError(body: 'botbooru proxy
  error: $e')` returns the raw exception (audit LOW). Return a generic message;
  debugPrint the detail only.
- CAP the proxied response size (e.g. 25 MB) — abort if upstream exceeds it, so a
  huge/hostile response can't OOM the desktop.
- Keep it HARDCODED to `https://botbooru.com/` (it already is) — confirm `rest`
  can't escape the host (no `//evil`, no scheme injection via `rest`/query).
  `Uri.parse('https://botbooru.com/$rest?...')` with a path-y rest is host-locked;
  add a guard that the resolved target.host == 'botbooru.com' before sending.
- Do NOT forward upstream `set-cookie` to... actually cookies ARE needed for the
  user's botbooru login session in the iframe; KEEP cookie pass-through both ways
  (it's the user's own session, same as the native webview). Just don't log them.
- TDD (pure): the HTML-rewrite helper (already pure: `_rewriteBotbooruHtml` —
  add tests it rewrites href/src + injects the shim) and a host-lock check
  helper (resolved target must be botbooru.com).

## Slice 2 — Web Discover iframe (discover_screen.dart + a web-only widget)
- New conditional-import widget `botbooru_web_frame.dart` (stub on native; web
  impl via `package:web` + `dart:ui_web` platformViewRegistry):
  `registerViewFactory('pyre-bbx-frame', (id) => web.HTMLIFrameElement()
     ..src='/bbx/' ..style.border='none' ..width/height='100%')` then render via
  `HtmlElementView(viewType:'pyre-bbx-frame')`. Keep a ref to the IFrameElement
  so the toolbar can read `contentWindow.location.href`, go Home (`src='/bbx/'`),
  and Back (`contentWindow.history.back()`).
- On web, when the app is served by a Pyre desktop (heuristic: it always is for
  the LAN web — `Uri.base` host is the desktop; OR just always attempt and offer
  the external fallback as a secondary button below), show the iframe + a Pyre
  toolbar: [Home] [Back] [Import this card] [Open externally]. The existing
  `_buildWebFallback` stays as the fallback path (e.g. public web).
- Mirror the existing web-only conditional-import pattern used by
  `lib/services/web_download.dart` (web_download_web.dart / _stub.dart) so the
  native build doesn't see `package:web`/`dart:ui_web`.

## Slice 3 — "Import this card" (web)
- Read the iframe's current URL (same-origin contentWindow.location.href), e.g.
  `http://<desktop>:<port>/bbx/character/12345`.
- Map it back: strip the `<origin>/bbx/` prefix → `https://botbooru.com/character/12345`.
- Run the EXISTING resolver (`resolveCommunityUrl` in resolvers.dart) to get the
  download URL, then FETCH THE BYTES THROUGH `/bbx/`: rewrite the resolved
  `https://botbooru.com/<X>` → `<origin>/bbx/<X>` and GET that (same-origin,
  CORS-safe). Parse the chara_card_v2 PNG (parseCharaCardPng) and import via the
  same confirm-dialog path the "Import by URL" dialog uses (reuse
  `_importFromUrl`/the existing import handler — DO NOT duplicate the import/SSRF
  logic; route its botbooru fetch through the proxy on web).
- If the current iframe URL isn't a recognizable card page, show a hint ("open a
  character page first").
- Lorebooks: same path (the resolver already discriminates lorebook URLs).

## Security invariants (verifier checks)
- /bbx stays hardcoded to botbooru.com; `rest`/query can't redirect to another
  host (host-lock check). It's a LIMITED proxy, not an open relay.
- Errors scrubbed (no raw exception/header/cookie in the HTTP response or logs).
- Response size capped.
- No change to the auth allowlist; protected routes still bearer-gated. /bbx
  stays public (an iframe can't send a bearer) BUT only reaches botbooru.com.
- The import path reuses the existing resolver + the same host allowlist /
  confirm dialog — no new SSRF surface beyond botbooru via the proxy.

## Green gate + verify
- flutter analyze clean + full suite (run from flutter_app; never >1 flutter
  analyze/test at once). TDD the pure helpers (rewrite, host-lock, the /bbx URL
  mapping). The iframe/JS-interop is web-only (not unit-testable) — keep it thin.
- Then: rebuild web (`flutter build web --dart-define=PYRE_DEV=true`), copy
  build/web → build/windows/x64/runner/Release/web, rebuild the exe, relaunch.

## Out of scope / follow-up
- Hooking botbooru's OWN "Download" button inside the iframe (exact native
  parity) via postMessage — deferred; the Pyre "Import this card" button is the
  robust v1. Note it.
- Phone never uses /bbx (it has a real native webview).
