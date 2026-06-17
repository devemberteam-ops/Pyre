// Pyre — BotBooru proxy helpers (pure / testable).
//
// Extracted so the host-lock check, HTML rewriter, and URL mapping are
// unit-testable without spinning up PyreServer or a web build.
//
// Used by:
//   - pyre_server.dart  (_proxyBotbooruDedicated uses bbxHostLocked,
//                        kBbxMaxResponseBytes, rewriteBotbooruHtmlDedicated,
//                        bbxCorsOriginFor; GET /bbx-info exposes _bbxPort)
//   - botbooru_web_frame_web.dart  (bbxOriginUrlToBotbooru for the Import button)
//
// v2 (SECURE): the bbx embed runs on a SEPARATE origin (bbxPort ≠ mainPort).
// The old /bbx/ same-origin route is GONE from the main server. The old
// same-origin helpers (bbxIframeUrlToBotbooru, botbooruUrlToBbxPath) are
// RETAINED for the test suite but are no longer called in production — the
// new cross-origin helpers (bbxOriginUrlToBotbooru) replace them.

/// Hard cap on a single proxied response: 25 MB. Mirrors the card-download cap
/// elsewhere in the app; a huge / hostile upstream response can't OOM the desktop.
const int kBbxMaxResponseBytes = 25 * 1024 * 1024;

/// Returns true iff [target] is safe to proxy — i.e. its host is EXACTLY
/// `botbooru.com` (the one hardcoded upstream we serve). Rejects empty, non-https,
/// and any host that isn't botbooru.com so a crafted `rest` path or query string
/// can't redirect the proxy to an arbitrary host (open-relay guard).
///
/// Called on EVERY redirect hop (B2 fix) so a redirect chain can never escape
/// botbooru.com even if the first hop passes.
///
/// Examples that pass:  `https://botbooru.com/character/123`
/// Examples that fail:  `https://evil.com/bbx`, `http://botbooru.com/`, ``
bool bbxHostLocked(Uri target) {
  if (target.scheme != 'https') return false;
  return target.host == 'botbooru.com';
}

// ---------------------------------------------------------------------------
// v2: dedicated-origin CORS helper
// ---------------------------------------------------------------------------

/// Decides the `Access-Control-Allow-Origin` value for the bbx dedicated
/// server. Returns [reqOrigin] (reflect it back) ONLY when the requesting
/// origin's port equals [mainPort] — i.e. the request is coming from the
/// Pyre web app at its own origin. Returns null in every other case.
///
/// Security invariants:
///   - Never returns `*` (credentials-capable cross-origin reads are blocked).
///   - Only the Pyre main origin (same host, port == mainPort) can read
///     proxied botbooru bytes cross-origin.
///   - An empty, un-parseable, or wrong-port origin → null → no ACAO header.
///
/// Pure — no I/O, no state.
String? bbxCorsOriginFor(String reqOrigin, int mainPort) {
  if (reqOrigin.isEmpty) return null;
  Uri parsed;
  try {
    parsed = Uri.parse(reqOrigin);
  } catch (_) {
    return null;
  }
  // Reject origins that have no explicit port in the string.
  // Dart's Uri.port returns the default port (80/443) when no port is written,
  // so we must check the authority string directly.
  // A URL with an explicit port has a colon in its host:port authority segment.
  // We look for ':<port>' in the authority (e.g. ":4848") to confirm the port
  // is actually written in the origin string.
  final authority = parsed.authority; // e.g. "192.168.1.10:4848"
  if (!authority.contains(':')) {
    // No colon → no explicit port → reject.
    return null;
  }
  final port = parsed.port;
  if (port != mainPort) return null;
  return reqOrigin;
}

// ---------------------------------------------------------------------------
// v2: dedicated-origin URL helper
// ---------------------------------------------------------------------------

/// Maps an iframe URL served by the bbx dedicated origin back to the canonical
/// `https://botbooru.com/…` URL.
///
/// [iframeHref] is the `href` field from the postMessage'd `pyre-bbx-loc` event —
/// for example `http://192.168.1.10:4849/character/12345`.
/// [bbxOrigin] is the bbx origin string — for example
/// `http://192.168.1.10:4849` (no trailing slash).
///
/// Returns null when:
///   - [iframeHref] does not start with `<bbxOrigin>/` (not served by bbx),
///   - the path after the origin is empty (the root landing page — not a card).
///
/// Security: pure mapping only. The caller runs the result through
/// `resolveCommunityUrl` and the existing host-allowlist before fetching.
String? bbxOriginUrlToBotbooru(String iframeHref, String bbxOrigin) {
  final base =
      bbxOrigin.endsWith('/') ? bbxOrigin.substring(0, bbxOrigin.length - 1) : bbxOrigin;
  final prefix = '$base/';
  if (!iframeHref.startsWith(prefix)) return null;
  final rest = iframeHref.substring(prefix.length);
  if (rest.isEmpty) return null;
  return 'https://botbooru.com/$rest';
}

// ---------------------------------------------------------------------------
// v2: dedicated-origin HTML rewrite
// ---------------------------------------------------------------------------

/// Rewrite botbooru HTML for the DEDICATED-ORIGIN proxy.
///
/// In dedicated-origin mode the iframe IS the bbx origin, so root-relative
/// URLs (e.g. `/character/1`) already resolve correctly to the bbx server —
/// NO `/bbx/` prefix is needed. Only two things need changing:
///
///   1. Absolute `https://botbooru.com/` → `/` so any absolute reference in
///      the HTML resolves to the bbx origin instead of botbooru.com directly
///      (which would bypass the proxy for subsequent navigations).
///   2. Inject the postMessage shim so the parent Pyre app can track the
///      current URL and send back-navigation commands cross-origin.
///
/// The shim:
///   - On page-load + SPA nav (patches history.pushState / history.replaceState
///     + a popstate listener), sends
///     `{type:'pyre-bbx-loc', href: location.href}` to `window.parent` with
///     targetOrigin `'*'` (the href is a bbx URL, not a secret; the PARENT
///     validates the sender origin — spec §4).
///   - Listens for `{type:'pyre-bbx-back'}` from the parent → `history.back()`.
///
/// Pure string transform — no I/O, no state.
String rewriteBotbooruHtmlDedicated(String html) {
  // 1. Rewrite absolute botbooru.com URLs to root-relative so they resolve
  //    on the bbx origin. Only the exact prefix is replaced; path/query/fragment
  //    are preserved. Both attribute and inline-script occurrences.
  html = html.replaceAll('https://botbooru.com/', '/');

  // 2. Inject the postMessage shim.
  // Messages are sent as JSON strings (JSON.stringify) so the Dart receiver
  // can parse them with plain jsonDecode(event.data.toString()) without any
  // JS-interop object conversion.
  const shim = r'''
<script>
(function(){
  function sendLoc(){
    try{
      var msg=JSON.stringify({type:'pyre-bbx-loc',href:location.href});
      window.parent.postMessage(msg,'*');
    }catch(e){}
  }
  // Patch SPA history methods.
  var _ps=history.pushState.bind(history);
  history.pushState=function(){ _ps.apply(history,arguments); sendLoc(); };
  var _rs=history.replaceState.bind(history);
  history.replaceState=function(){ _rs.apply(history,arguments); sendLoc(); };
  window.addEventListener('popstate',sendLoc);
  // Report on load.
  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',sendLoc);
  } else {
    sendLoc();
  }
  // Listen for back-nav commands from the parent.
  // The parent sends JSON strings; support both string and object for robustness.
  window.addEventListener('message',function(e){
    try{
      var d=e.data;
      if(typeof d==='string'){d=JSON.parse(d);}
      if(d&&d.type==='pyre-bbx-back'){history.back();}
    }catch(ex){}
  });
})();
</script>
''';
  if (html.contains('<head>')) {
    html = html.replaceFirst('<head>', '<head>$shim');
  } else {
    html = shim + html;
  }
  return html;
}

// ---------------------------------------------------------------------------
// Legacy v1 helpers — retained so existing tests stay green.
// NOT called from production code in v2.
// ---------------------------------------------------------------------------

/// [LEGACY v1 — not used in v2] Rewrite botbooru HTML for the same-origin
/// `/bbx/` proxy. Prefixes all root-relative static attribute URLs with
/// `/bbx/` and injects a runtime shim for dynamic fetch/XHR/setAttribute.
///
/// In v2 the main server no longer has a `/bbx/` route and this function is
/// not called. It is retained here so the existing unit tests continue to
/// pass and serve as a regression guard.
String rewriteBotbooruHtml(String html) {
  // 1) Root-relative URLs in static attributes.
  html = html
      .replaceAll('href="/', 'href="/bbx/')
      .replaceAll('src="/', 'src="/bbx/')
      .replaceAll("href='/", "href='/bbx/")
      .replaceAll("src='/", "src='/bbx/");
  // 2) Runtime shim — patch fetch / XHR / setAttribute / .src / .href so the
  //    SPA's dynamic calls also route through the proxy.
  const shim = '''
<script>
(function(){
  var P='/bbx/';
  function rw(u){
    try{
      if(typeof u!=='string'||!u) return u;
      if(u.indexOf('https://botbooru.com/')===0) return P+u.slice(21);
      if(u.charAt(0)==='/' && u.indexOf('//')!==0 && u.indexOf(P)!==0) return P+u.slice(1);
      return u;
    }catch(e){return u;}
  }
  var of=window.fetch;
  window.fetch=function(i,init){ try{ if(typeof i==='string'){i=rw(i);} else if(i&&i.url){i=new Request(rw(i.url),i);} }catch(e){} return of.call(this,i,init); };
  var oo=XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open=function(){ try{arguments[1]=rw(arguments[1]);}catch(e){} return oo.apply(this,arguments); };
  var osa=Element.prototype.setAttribute;
  Element.prototype.setAttribute=function(n,v){ try{ if(n==='src'||n==='href'){v=rw(v);} }catch(e){} return osa.call(this,n,v); };
  function pp(c,p){ try{ var pr=window[c]&&window[c].prototype; if(!pr) return; var d=Object.getOwnPropertyDescriptor(pr,p); if(!d||!d.set) return; Object.defineProperty(pr,p,{configurable:true,enumerable:d.enumerable,get:function(){return d.get.call(this);},set:function(v){d.set.call(this,rw(v));}}); }catch(e){} }
  pp('HTMLImageElement','src'); pp('HTMLScriptElement','src'); pp('HTMLSourceElement','src'); pp('HTMLMediaElement','src'); pp('HTMLLinkElement','href'); pp('HTMLAnchorElement','href');
  function fix(el){ try{ if(el.nodeType!==1) return; var s; if(el.hasAttribute('src')){s=el.getAttribute('src'); if(rw(s)!==s)el.setAttribute('src',s);} if(el.hasAttribute('href')){s=el.getAttribute('href'); if(rw(s)!==s)el.setAttribute('href',s);} if(el.querySelectorAll){var k=el.querySelectorAll('[src],[href]'); for(var j=0;j<k.length;j++)fix(k[j]);} }catch(e){} }
  try{ new MutationObserver(function(ms){ for(var a=0;a<ms.length;a++){var nn=ms[a].addedNodes; if(nn)for(var b=0;b<nn.length;b++)fix(nn[b]);} }).observe(document.documentElement,{childList:true,subtree:true}); }catch(e){}
})();
</script>
''';
  if (html.contains('<head>')) {
    html = html.replaceFirst('<head>', '<head>$shim');
  } else {
    html = shim + html;
  }
  return html;
}

/// [LEGACY v1 — not used in v2] Maps an iframe URL (served by the Pyre desktop
/// through `/bbx/`) back to the canonical `https://botbooru.com/…` URL.
///
/// [iframeHref] is the value of `contentWindow.location.href` — for example
/// `http://192.168.1.10:4848/bbx/character/12345`.
/// [origin] is the Pyre web-app origin — for example `http://192.168.1.10:4848`.
///
/// Returns null when:
///   - [iframeHref] does not start with `<origin>/bbx/`,
///   - the path after `/bbx/` is empty.
String? bbxIframeUrlToBotbooru(String iframeHref, String origin) {
  final base = origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
  final prefix = '$base/bbx/';
  if (!iframeHref.startsWith(prefix)) return null;
  final rest = iframeHref.substring(prefix.length);
  if (rest.isEmpty) return null;
  return 'https://botbooru.com/$rest';
}

/// [LEGACY v1 — not used in v2] Maps a resolved botbooru download URL
/// (`https://botbooru.com/<path>`) to a same-origin `/bbx/<path>` URL.
///
/// [botbooruUrl] must start with `https://botbooru.com/`; returns null otherwise.
/// [origin] must not end with `/`.
String? botbooruUrlToBbxPath(String botbooruUrl, String origin) {
  const prefix = 'https://botbooru.com/';
  if (!botbooruUrl.startsWith(prefix)) return null;
  final path = botbooruUrl.substring(prefix.length);
  final base = origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
  return '$base/bbx/$path';
}
