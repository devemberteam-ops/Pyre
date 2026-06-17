# Spec v2 (SECURE): botbooru web embed via a SEPARATE-ORIGIN proxy

> v1 (same-origin `/bbx` iframe) was REJECTED by security review: the proxied
> botbooru JS ran same-origin with the Pyre web app → a stored-XSS/hostile card
> could read `localStorage['lan.bearerToken']` and own the library. This v2
> pivots to a SEPARATE-ORIGIN proxy so the iframe is cross-origin and cannot
> touch the Pyre app. Branch release/1.1.3. SECURITY-CRITICAL. Pivot the
> uncommitted v1 code in place.

## Architecture
- A SECOND HTTP server (the "bbx origin") on a DIFFERENT port than the main
  Pyre server. Same bind interface (BindMode). The iframe loads botbooru from
  THIS origin → cross-origin with the Pyre web app (`http://host:mainPort`) →
  botbooru's JS runs at `http://host:bbxPort`, a different origin → SOP blocks it
  from reading the Pyre app's window/localStorage. THE main origin no longer
  proxies botbooru at all (remove the `/bbx/` route from the MAIN router).
- The iframe reports its current URL to the parent via postMessage (cross-origin
  can't read contentWindow.location). The "Import this card" fetch is
  cross-origin → the bbx server returns CORS headers that allow ONLY the Pyre
  main origin to read the bytes.

## Server changes (pyre_server.dart)
1. SECOND server: in `start()`, after the main `shelf_io.serve`, bind a second
   server: try `port+1`; if taken, bind `0` (ephemeral) — store `_bbxPort` +
   `_bbxHttp`. Its handler = a Pipeline (NO auth middleware) over a tiny router
   `r.all('/<rest|.*>', _proxyBotbooruDedicated)`. `stop()` closes `_bbxHttp`
   too and nulls `_bbxPort`.
2. `_proxyBotbooru` (shared fetch core) gets:
   - **B2 fix:** `followRedirects = false`. On a 3xx, read `Location`, resolve
     against the target, re-check `bbxHostLocked`; follow manually only if the
     destination host is botbooru.com (bounded to ~5 hops); else stop with 502.
   - **CORS for the dedicated origin:** add a helper `bbxCorsOriginFor(reqOrigin,
     mainPort)` → returns reqOrigin IF its port == mainPort (so ONLY the Pyre
     app can read proxied bytes cross-origin), else null. Set
     `Access-Control-Allow-Origin` from it (+ handle `OPTIONS` preflight →
     200 with the CORS headers). Do NOT allow credentials; do NOT use `*`.
   - keep: host-lock, 25MB streaming cap, cookie pass-through (so the user's
     botbooru session renders), error scrub.
3. HTML rewrite for the DEDICATED origin (simpler — root-relative `/x` already
   resolves to this origin → botbooru, no prefixing needed): only rewrite
   ABSOLUTE `https://botbooru.com/` → `/` (relative), and inject the postMessage
   shim. (Keep `bbx_utils.rewriteBotbooruHtml` but add a dedicated-mode variant
   OR a param; the existing `/bbx/`-prefix rewrite is no longer used since the
   main `/bbx` route is removed.)
4. postMessage shim (injected into the proxied HTML):
   - On load AND on SPA nav (patch history.pushState/replaceState + a popstate
     listener), `window.parent.postMessage({type:'pyre-bbx-loc', href:
     location.href}, '*')`. (targetOrigin '*' for SEND is fine; the PARENT
     validates the sender origin. The href is a botbooru URL, not a secret.)
   - Listen for `{type:'pyre-bbx-back'}` from the parent → `history.back()`.
5. MAIN server: `GET /bbx-info` (PUBLIC, on the main router) → `{"port":
   <bbxPort or null>}`. The web reads it to learn the bbx origin.

## Web changes (botbooru_web_frame_web.dart)
- On init: fetch `/bbx-info` (same-origin) → `bbxPort`; compute
  `bbxOrigin = '${Uri.base.scheme}://${Uri.base.host}:$bbxPort'`. If unavailable
  (null/error → e.g. public web with no desktop), render the existing
  `_buildWebFallback` (Open externally + Import by URL) instead of the iframe.
- iframe `src = '$bbxOrigin/'` (cross-origin). sandbox MAY keep `allow-same-origin`
  now (the iframe is its OWN origin = bbxPort, different from the Pyre app → it
  can use botbooru's cookies/storage but CANNOT reach the parent). Keep
  `allow-scripts allow-forms allow-popups`.
- Track current URL via `web.window.onMessage`: accept ONLY messages where
  `event.origin == bbxOrigin` AND `data.type == 'pyre-bbx-loc'` → store latest
  href. "Import this card" uses the latest href (map `$bbxOrigin/<rest>` →
  `https://botbooru.com/<rest>` — add `bbxOriginUrlToBotbooru(href, bbxOrigin)`
  to bbx_utils) → onImport.
- Home: `iframe.src = '$bbxOrigin/'`. Back: postMessage `{type:'pyre-bbx-back'}`
  to `iframe.contentWindow` with targetOrigin `bbxOrigin`.

## Import changes (discover_screen `_handleBbxImport`)
- The botbooru URL now comes from the postMessage'd href (already mapped to
  `https://botbooru.com/...`). Resolve via `resolveCommunityUrl`, then fetch the
  download bytes from the BBX ORIGIN (cross-origin): map `https://botbooru.com/X`
  → `$bbxOrigin/X` and `fetchCappedNoRedirect` (the bbx server's CORS allows the
  Pyre origin to read it). Parse + confirm-dialog import as before. The widget
  passes `bbxOrigin` to the import callback (so discover knows where to fetch).

## Security invariants (re-verify ALL)
- The iframe origin (bbxPort) is DIFFERENT from the Pyre app origin (mainPort) →
  botbooru JS cannot read the Pyre app's localStorage/bearer or call its APIs.
- The MAIN origin has NO botbooru proxy route anymore (removed) → no same-origin
  botbooru HTML can ever be served on the Pyre app origin.
- bbx CORS allows reading ONLY by the Pyre main origin (port==mainPort), not `*`,
  no credentials.
- host-lock holds on the initial target AND on every redirect hop (B2).
- Errors scrubbed; 25MB cap; auth allowlist on the MAIN server unchanged;
  protected routes still bearer-gated. The bbx server has NO access to the
  AppStore / bearer / SecureKeys — it ONLY proxies botbooru.com.
- postMessage: parent accepts loc messages ONLY from bbxOrigin.

## TDD (pure)
- `bbxHostLocked` redirect cases; `bbxCorsOriginFor(origin, mainPort)`;
  the dedicated-mode rewrite (absolute→relative + shim + no `/bbx/` prefix);
  `bbxOriginUrlToBotbooru`. Keep existing bbx tests green (adjust the ones that
  asserted the `/bbx/` prefix rewrite if that mode is removed).
- Lead runs full suite + web/exe builds + independent security re-verify.

## Out of scope
- Hooking botbooru's own Download button (Pyre "Import this card" stays the v1).
- Phone unaffected (native webview).
