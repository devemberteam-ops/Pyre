// Wave CY.18.96 + 97: in-app browsing of botbooru.com on Windows
// desktop via Edge WebView2 (webview_windows package).
//
// Wave 97 reshaped the chrome:
//   - Full-bleed: the parent removes its AppBar when the embed is
//     visible, so this widget owns the entire window vertically.
//   - URL bar gone. The user said "sem a opção de trocar o link" —
//     the editable / copy chip wasn't earning its keep and looked
//     too much like "type a URL here".
//   - Prominent "Back" on the left, flanked by tiny browser
//     back/forward/reload glyphs. The ✕ on the right is gone — one
//     clear way to leave the embed.
//   - Same JS hook from the mobile webview is now injected here, so
//     clicking "Download PNG" inside botbooru posts the URL via
//     `window.chrome.webview.postMessage(...)`, which we forward to
//     [onImportCurrentUrl]. "Use for import" still exists as a
//     belt-and-braces manual path for pages where the hook misses
//     (rare but cheap to keep).
//
// Why JS injection here and not navigation control? webview_windows
// doesn't expose a per-request navigation delegate. We compensate
// by (a) injecting the click+blob hook so downloads are caught
// before the page tries to navigate, and (b) the import callback
// runs through Discover's `_importFromUrl`, which already validates
// the URL is on the trusted-host allowlist before fetching.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/attachment_store.dart';
import '../services/png_encoder.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'export_snack.dart';

/// Wave CY.18.251: one file to inject into the page's `<input type=file>`.
///
/// [name] is the filename (including the `.png` extension); [b64] is the
/// base64-encoded PNG bytes. After the user picks, [_setFilesIife] (a
/// one-shot injected IIFE — Wave CY.18.255 / audit FIX 3) decodes the
/// base64 into a `File` and assigns it to the intercepted input via a
/// `DataTransfer`.
class PyreUploadFile {
  final String name;
  final String b64;
  const PyreUploadFile(this.name, this.b64);
}

/// Wave CY.18.260: hard cap on the decoded card PNG bytes posted by the
/// in-webview download hook ({cardB64}). A real chara_card PNG is far smaller;
/// this rejects an absurdly large base64 blob before it reaches the importer
/// (mirrors the 25 MB `fetchCappedNoRedirect` cap the native re-fetch enforced).
const int _kCardBytesMaxLen = 25 * 1024 * 1024; // 25 MB

class DesktopBotbooruWebview extends StatefulWidget {
  final String initialUrl;

  /// Called with a download URL when the JS hook traps a PNG export
  /// click, OR when the user taps "Use for import" on a card page.
  /// The parent's handler validates the host before fetching.
  ///
  /// Wave CY.18.142: also carries the raw `img.src` values read from
  /// the page's rendered `#post-mini-gallery` DOM at import time, so
  /// the parent can resolve + host-gate them into gallery image URLs
  /// (an empty list when the page has no gallery).
  final void Function(String url, List<String> galleryDomSrcs)
      onImportCurrentUrl;

  /// Wave CY.18.260: FRONTEND-ONLY CHARACTER import from BYTES. The download
  /// hook now fetches the card PNG INSIDE the authenticated webview
  /// (`credentials:'include'`) and posts the bytes (base64) — so the parent
  /// imports from the decoded bytes and makes NO HTTP request (BotBooru
  /// bot-gates `/download/png`, breaking a cookie-less native re-fetch).
  /// [galleryDomSrcs] are the scraped `#post-mini-gallery img` srcs.
  final void Function(Uint8List bytes, List<String> galleryDomSrcs)
      onImportCardBytes;

  /// Wave CY.18.260: the in-webview card fetch failed (network / auth / HTTP).
  /// The parent shows a friendly snackbar. [message] is the JS error text.
  final void Function(String message) onCardError;

  /// FRONTEND-ONLY LOREBOOK import. Called with the raw lorebook JSON TEXT that
  /// the download hook fetched INSIDE the logged-in webview session (the app
  /// must never call BotBooru's API). The parent parses the text directly — no
  /// HTTP request is issued for it. [nameHint] is the page's lorebook title
  /// (BotBooru's download JSON has an empty top-level `name`); the parent uses
  /// it only when the JSON's own name is blank.
  final void Function(String jsonText, {String? nameHint}) onImportLorebookJson;

  /// Called when the in-webview lorebook fetch failed (network/auth/HTTP). The
  /// parent shows a friendly snackbar. [message] is the JS error text.
  final void Function(String message) onLorebookError;

  /// Required: a back-to-landing handler. The toolbar's Back button
  /// calls this — there's no other way out of the embed (the parent's
  /// AppBar is hidden in this mode).
  final VoidCallback onClose;

  /// Wave CY.18.251: in-page upload-picker parity with Android.
  ///
  /// WebView2 has no file-chooser hook (unlike Android's
  /// `setOnShowFileSelector`), so we INJECT a JS hook
  /// ([_uploadHookScript]) that intercepts clicks on the page's
  /// `<input type=file>` and posts a `pickCard` message. We then call
  /// this callback to show Pyre's card-library picker, encode the
  /// chosen card(s) to chara_card_v2 PNG, and inject them back into the
  /// form via DataTransfer. [multiple] mirrors the input's `multiple`
  /// attribute. Returns an empty list when the user cancels (the form
  /// is left untouched). When null, the hook still fires but no picker
  /// shows — falls back to the "My cards" folder export.
  final Future<List<PyreUploadFile>> Function(bool multiple)?
      onPickCardsForUpload;

  const DesktopBotbooruWebview({
    super.key,
    required this.initialUrl,
    required this.onImportCurrentUrl,
    required this.onImportCardBytes,
    required this.onCardError,
    required this.onImportLorebookJson,
    required this.onLorebookError,
    required this.onClose,
    this.onPickCardsForUpload,
  });

  @override
  State<DesktopBotbooruWebview> createState() =>
      _DesktopBotbooruWebviewState();
}

class _DesktopBotbooruWebviewState extends State<DesktopBotbooruWebview> {
  final WebviewController _controller = WebviewController();

  /// Wave CY.18.255 (audit FIX 6): hold the controller-stream
  /// subscriptions so dispose() can cancel them before disposing the
  /// controller (they were previously fire-and-forget, so a dispose
  /// mid-navigation could fire a callback against a torn-down widget).
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Init outcome: null = still loading, true = ready, false = failed
  /// (almost always "WebView2 runtime not installed").
  bool? _ready;
  String? _initError;

  /// Current URL — kept only to pass to the import-by-current-URL
  /// fallback button. NOT rendered in the chrome.
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    _initialise();
  }

  Future<void> _initialise() async {
    try {
      await _controller.initialize();
      await _controller.setBackgroundColor(Colors.transparent);
      await _controller
          .setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

      // URL tracking — for the "Use for import" button only. Not
      // surfaced in any UI.
      _subs.add(_controller.url.listen((u) {
        if (!mounted) return;
        setState(() => _currentUrl = u);
      }));

      // JS hook: re-inject every time a navigation completes (page
      // reload, in-app SPA route changes, etc). webview_windows fires
      // `loadingState == navigationCompleted` for each. The script
      // itself is idempotent (window.__pyreDLHooked guard) so
      // duplicate injections during sub-frame loads are harmless.
      _subs.add(_controller.loadingState.listen((state) {
        if (state == LoadingState.navigationCompleted) {
          _controller.executeScript(_downloadHookScript);
          // Wave CY.18.146: native <select> dropdown popups don't render in
          // the offscreen-composited WebView2 (so Origin / Content Rating on
          // botbooru's upload form couldn't be opened). Expand selects INLINE
          // (DOM listbox via the `size` attr) instead.
          _controller.executeScript(_selectFixScript);
          // Wave CY.18.251: intercept the page's file-input clicks so we can
          // show Pyre's card-library picker (Android parity) and inject the
          // chosen card PNG back into the form. Idempotent (guarded).
          _controller.executeScript(_uploadHookScript);
        }
      }));

      // Messages from the JS hook arrive here. Validate it looks like
      // a botbooru download URL before forwarding — the host allow-
      // list check happens downstream in _importFromUrl, but we
      // pre-filter obvious junk so we don't bother the import flow
      // with random page chatter.
      _subs.add(_controller.webMessage.listen((msg) async {
        try {
          final raw = (msg is String) ? msg : msg.toString();
          final t = raw.trim();
          if (t.isEmpty) return;
          // Wave CY.18.251: the upload hook posts {pyreType:'pickCard',
          // multiple:bool} when the user clicks the page's file input. Handle
          // it FIRST (and return) so it never falls through to the URL-import
          // path — it carries no `url`.
          if (t.startsWith('{')) {
            final probe = jsonDecode(t);
            if (probe is Map && probe['pyreType'] == 'pickCard') {
              final multiple = probe['multiple'] == true;
              final cb = widget.onPickCardsForUpload;
              if (cb == null) return;
              final items = await cb(multiple);
              if (items.isEmpty) return; // user cancelled — leave the form
              final payload = jsonEncode(
                items
                    .map((e) => {'name': e.name, 'b64': e.b64})
                    .toList(),
              );
              // Wave CY.18.255 (audit FIX 3): inject the files via a
              // SELF-CONTAINED IIFE rather than calling a persistent
              // `window.__pyreSetFiles`. The old approach left a reusable
              // function on `window` that any page script could call to
              // inject attacker-chosen files into the form. This IIFE does
              // the DataTransfer assignment inline on `window.__pyrePendingInput`
              // and leaves nothing reusable behind. The payload is a JSON
              // literal embedded directly in the script body.
              await _controller.executeScript(_setFilesIife(payload));
              return;
            }
          }
          // FRONTEND-ONLY LOREBOOK: the download hook fetches the lorebook
          // JSON inside the logged-in session and posts {lorebookJson: text}
          // (or {lorebookError: msg} on failure). Route these BEFORE the URL
          // path — they carry JSON/an error, not a URL, and the parent must
          // NOT make any HTTP request for them.
          if (t.startsWith('{')) {
            final probe = jsonDecode(t);
            if (probe is Map && probe['lorebookJson'] is String) {
              final hint = probe['lorebookName'];
              widget.onImportLorebookJson(
                probe['lorebookJson'] as String,
                nameHint: hint is String ? hint : null,
              );
              return;
            }
            if (probe is Map && probe['lorebookError'] is String) {
              widget.onLorebookError(probe['lorebookError'] as String);
              return;
            }
            // Wave CY.18.260: FRONTEND-ONLY CHARACTER — the hook fetched the
            // card PNG inside the logged-in session and posts {cardB64, gallery}
            // (or {cardError} on failure). Route these BEFORE the URL path —
            // they carry bytes/an error, not a URL, and the parent must NOT make
            // any HTTP request for them. Decode + size-cap the base64 here so a
            // hostile / huge blob can't reach the importer.
            if (probe is Map && probe['cardB64'] is String) {
              final b64 = probe['cardB64'] as String;
              Uint8List bytes;
              try {
                bytes = base64Decode(b64);
              } catch (_) {
                widget.onCardError('Could not read the downloaded card.');
                return;
              }
              if (bytes.isEmpty || bytes.length > _kCardBytesMaxLen) {
                widget.onCardError('Could not read the downloaded card.');
                return;
              }
              final g = probe['gallery'];
              final gallery =
                  g is List ? g.whereType<String>().toList() : <String>[];
              widget.onImportCardBytes(bytes, gallery);
              return;
            }
            if (probe is Map && probe['cardError'] is String) {
              widget.onCardError(probe['cardError'] as String);
              return;
            }
          }
          // Wave CY.18.148: the download hook posts a JSON envelope
          // {url, gallery:[...]} — the gallery DOM srcs are read in-page and
          // ride THIS proven postMessage channel (the Wave-142 executeScript
          // return read came back empty in offscreen WebView2). Tolerate a
          // bare URL string too (defensive / older messages).
          String url;
          List<String> gallery = const [];
          if (t.startsWith('{')) {
            final decoded = jsonDecode(t);
            if (decoded is Map && decoded['url'] is String) {
              url = (decoded['url'] as String).trim();
              final g = decoded['gallery'];
              if (g is List) gallery = g.whereType<String>().toList();
            } else {
              return;
            }
          } else {
            url = t;
          }
          if (!url.startsWith('http')) return;
          widget.onImportCurrentUrl(url, gallery);
        } catch (_) {
          // Best-effort — never let a malformed message crash the embed.
        }
      }));

      await _controller.loadUrl(widget.initialUrl);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _currentUrl = widget.initialUrl;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ready = false;
        _initError = e.toString();
      });
    }
  }

  /// Wave CY.18.142: read the raw `img.src` values out of the page's
  /// rendered mini-gallery DOM (`#post-mini-gallery img`). BotBooru's
  /// own frontend JS populates this; we read it at IMPORT time (the
  /// page is fully rendered by the time the user clicks Download PNG,
  /// so there's no render-timing race). The parent resolves +
  /// host-gates these into gallery image URLs. Best-effort — returns
  /// an empty list on any failure or when there's no gallery.
  Future<List<String>> _readGalleryDomSrcs() async {
    try {
      // Return the array directly (NOT JSON.stringify) — webview_windows
      // jsonDecodes WebView2's result, so we get a List back. Handle both a
      // List and a JSON String defensively.
      final res = await _controller.executeScript(
        'Array.prototype.slice.call('
        'document.querySelectorAll("#post-mini-gallery img"))'
        '.map(function(i){return i.getAttribute("src")||"";})'
        '.filter(function(s){return s.length>0;})',
      );
      if (res is List) return res.whereType<String>().toList();
      if (res is String) {
        final d = jsonDecode(res);
        if (d is List) return d.whereType<String>().toList();
      }
    } catch (_) {/* best-effort — no gallery on failure */}
    return const [];
  }

  /// Export every saved character that has an avatar to a dedicated
  /// folder as a chara_card_v2 PNG, then open that folder in Explorer.
  ///
  /// Wave CY.18.251: this is now the FALLBACK path. The primary path is
  /// the in-page picker ([_uploadHookScript] → [onPickCardsForUpload]),
  /// which intercepts botbooru's file input and injects the chosen card
  /// directly — matching Android. This folder dump still earns its keep
  /// for pages that use a fully-custom drop-zone with no real
  /// `<input type=file>` (the interception can't catch those): dump every
  /// card into `<docs>/PyreExports/UploadCards/` and open the folder so
  /// the user picks one in botbooru's OS file dialog.
  ///
  /// Best-effort per character — one card's failure never aborts the
  /// rest. Cards without an avatar are skipped (a chara_card_v2 PNG
  /// needs an image to embed the metadata into).
  Future<void> _exportCardsAndOpenFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    final store = context.read<AppStore>();
    final characters = store.characters;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final outDir =
          Directory('${docs.path}/PyreExports/UploadCards');
      if (!await outDir.exists()) await outDir.create(recursive: true);

      // Track filenames already used in this run so two characters with
      // the same (sanitised) name don't clobber each other.
      final usedNames = <String>{};
      var exported = 0;
      var skippedNoAvatar = 0;

      for (final c in characters) {
        try {
          final avatarBytes = await resolveAvatarBytes(c.avatar);
          if (avatarBytes == null) {
            skippedNoAvatar++;
            continue;
          }
          final pngBytes = encodeCharaCardPng(c, avatarBytes);
          final filename = _uniqueFilename(c.name, usedNames);
          final file = File('${outDir.path}/$filename');
          await file.writeAsBytes(pngBytes);
          exported++;
        } catch (_) {
          // Best-effort — skip this card, keep going.
        }
      }

      // Open the folder in Explorer (Windows only — this widget is
      // Windows-only, but guard for safety).
      //
      // Wave CY.18.150: explorer.exe is finicky about path separators. The
      // dir path is `${docs.path}/PyreExports/UploadCards` — `docs.path`
      // comes back with BACKslashes on Windows but we appended FORWARD
      // slashes, so the argument is mixed (`C:\…\Documents/PyreExports/…`).
      // explorer can't navigate that and silently falls back to opening the
      // Documents root (exactly what Gui saw — "me levou para Documentos, tive
      // que procurar a pasta"). Normalise to all-backslashes so it opens the
      // UploadCards folder DIRECTLY.
      if (Platform.isWindows) {
        try {
          final winPath = outDir.path.replaceAll('/', r'\');
          await Process.start('explorer.exe', [winPath]);
        } catch (_) {/* best-effort — folder still exists for them */}
      }

      if (!mounted) return;
      final String msg;
      if (exported > 0) {
        msg = 'Exported $exported '
            '${exported == 1 ? 'card' : 'cards'} → opened the folder. '
            "Pick one in botbooru's upload dialog.";
      } else if (skippedNoAvatar > 0) {
        msg = 'No cards have an avatar yet — a card needs an image to '
            'export. Set avatars in the editor, then try again. '
            'Opened the (empty) folder anyway.';
      } else {
        msg = 'No saved cards to export yet. Opened the folder anyway.';
      }
      // Guaranteed-dismiss notice: explorer.exe was launched just above and
      // steals window focus, which can freeze this SnackBar's entrance
      // animation so Flutter never arms the built-in auto-dismiss timer. The
      // helper arms a frame-independent close so it can't hang forever.
      // No Share action here (the user picks the file in botbooru's dialog).
      showExportSnack(messenger, msg, null, visible: const Duration(seconds: 6));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export cards: $e')),
      );
    }
  }

  /// Build a filesystem-safe `<name>.card.png` filename, disambiguating
  /// collisions against [used] with an index suffix.
  String _uniqueFilename(String name, Set<String> used) {
    final safe = name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
        .trim()
        .replaceAll(' ', '_');
    final base = safe.isEmpty ? 'card' : safe;
    var candidate = '$base.card.png';
    var i = 2;
    while (used.contains(candidate.toLowerCase())) {
      candidate = '${base}_$i.card.png';
      i++;
    }
    used.add(candidate.toLowerCase());
    return candidate;
  }

  @override
  void dispose() {
    // Wave CY.18.255 (audit FIX 6): cancel the controller-stream
    // subscriptions BEFORE disposing the controller so no late callback
    // fires against the torn-down widget.
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _toolbar(),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _toolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        color: EmberColors.bgPanel,
        border: Border(
          bottom: BorderSide(color: EmberColors.stroke, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Prominent back-to-landing. Left-most, labelled, primary
          // colour — the one obvious way out of the embed.
          TextButton.icon(
            onPressed: widget.onClose,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Back'),
            style: TextButton.styleFrom(
              foregroundColor: EmberColors.primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
          ),
          const SizedBox(width: 4),
          Container(
              width: 1, height: 22, color: EmberColors.stroke),
          const SizedBox(width: 4),
          // Browser nav cluster — small icon-only buttons. No labels
          // because the icons are universally understood and we want
          // the chrome compact.
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            tooltip: 'Browser back',
            color: EmberColors.textMid,
            visualDensity: VisualDensity.compact,
            onPressed: _ready == true ? () => _controller.goBack() : null,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            tooltip: 'Browser forward',
            color: EmberColors.textMid,
            visualDensity: VisualDensity.compact,
            onPressed:
                _ready == true ? () => _controller.goForward() : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Reload',
            color: EmberColors.textMid,
            visualDensity: VisualDensity.compact,
            onPressed: _ready == true ? () => _controller.reload() : null,
          ),
          const Spacer(),
          // "My cards" — export every saved card with an avatar to a
          // dedicated folder and open it in Explorer. WebView2 can't
          // hook botbooru's upload picker (unlike Android), so the
          // practical path is: land the user in a folder full of their
          // cards, then they pick one in botbooru's OS file dialog.
          OutlinedButton.icon(
            onPressed: _exportCardsAndOpenFolder,
            icon: const Icon(Icons.drive_folder_upload, size: 14),
            label: const Text('My cards'),
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
              foregroundColor: EmberColors.textMid,
              side: const BorderSide(color: EmberColors.stroke),
            ),
          ),
          const SizedBox(width: 8),
          // "Use for import" stays as a fallback path — the JS hook
          // covers the common case but botbooru's UI might add new
          // download patterns the hook doesn't catch.
          OutlinedButton.icon(
            onPressed: _currentUrl.isEmpty
                ? null
                : () async {
                    final srcs = await _readGalleryDomSrcs();
                    widget.onImportCurrentUrl(_currentUrl, srcs);
                  },
            icon: const Icon(Icons.download, size: 14),
            label: const Text('Use this page for import'),
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
              foregroundColor: EmberColors.textMid,
              side: const BorderSide(color: EmberColors.stroke),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_ready == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 12),
            Text(
              'Starting embedded browser…',
              style:
                  TextStyle(color: EmberColors.textDim, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (_ready == false) {
      return _errorCard();
    }
    return Webview(_controller);
  }

  Widget _errorCard() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: EmberColors.primary, size: 20),
                    SizedBox(width: 10),
                    Text(
                      'Embedded browser unavailable',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Pyre uses Microsoft Edge WebView2 to embed '
                  'botbooru.com inside the app. The runtime isn\'t '
                  'installed on this machine.',
                  style: TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Install the free Evergreen runtime from Microsoft, '
                  'then relaunch Pyre:',
                  style: TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  'https://developer.microsoft.com/microsoft-edge/webview2/',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: EmberColors.primary,
                  ),
                ),
                if (_initError != null) ...[
                  const SizedBox(height: 12),
                  const Divider(color: EmberColors.stroke, height: 1),
                  const SizedBox(height: 8),
                  Text(
                    'Error: $_initError',
                    style: const TextStyle(
                      color: EmberColors.textDim,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// JS hook injected after every navigation. Mirrors the mobile
/// version in discover_screen.dart, but uses
/// `window.chrome.webview.postMessage` (the WebView2 bridge) instead
/// of an `EmberDL` channel object.
///
/// Two interception strategies layered together:
///   1. Click handler captures anchors/buttons whose URL or label
///      matches a download-PNG pattern. Prevents the page's own
///      handler from running and posts the canonical
///      `/download/png/<id>` URL.
///   2. fetch + URL.createObjectURL overrides catch the blob-URL
///      path some botbooru variants use. The fetch hook records the
///      last download URL it saw; when createObjectURL fires, we
///      assume the blob came from that URL and post it. The
///      original blob URL is replaced with `javascript:void(0)` so
///      the page's auto-click of an <a download> goes nowhere.
/// Wave CY.18.146 / reworked CY.18.147: make native HTML `<select>` dropdowns
/// usable inside the Windows WebView2. WebView2 is hosted offscreen-composited
/// (rendered to a Flutter texture); in that mode it neither renders the native
/// `<select>` popup NOR lets you scroll/click the native inline-expanded
/// (`size`) list (the CY.18.146 first attempt expanded but couldn't be
/// scrolled or clicked). So we replace the dropdown entirely with a CUSTOM
/// overlay built from plain `<div>`s — those scroll + click normally in the
/// webview. Clicking an item sets the underlying `select.value` and dispatches
/// `input`+`change` so botbooru's form logic still fires. Idempotent
/// (`window.__pyreSelectFixed` guard); touches ONLY `<select>` (skips
/// `multiple` + single-option).
const String _selectFixScript = r'''
(function() {
  if (window.__pyreSelectFixed) return;
  window.__pyreSelectFixed = true;
  var menu = null;
  function close() { if (menu) { menu.remove(); menu = null; } }
  document.addEventListener('mousedown', function(e) {
    if (menu && menu.contains(e.target)) return;
    var s = e.target && e.target.closest && e.target.closest('select');
    if (!s) { close(); return; }
    if (s.multiple || (s.options ? s.options.length : 0) <= 1) return;
    e.preventDefault();
    e.stopPropagation();
    close();
    var rect = s.getBoundingClientRect();
    var m = document.createElement('div');
    m.style.cssText = 'position:fixed;z-index:2147483647;background:#1c1c1e;color:#fff;border:1px solid #5a5a5e;border-radius:6px;overflow-y:auto;box-shadow:0 8px 28px rgba(0,0,0,.55);font:14px system-ui,sans-serif;';
    m.style.left = rect.left + 'px';
    m.style.width = rect.width + 'px';
    var below = window.innerHeight - rect.bottom;
    var above = rect.top;
    if (below < 200 && above > below) {
      m.style.maxHeight = Math.max(80, Math.min(300, above - 8)) + 'px';
      m.style.bottom = (window.innerHeight - rect.top + 2) + 'px';
    } else {
      m.style.maxHeight = Math.max(80, Math.min(300, below - 8)) + 'px';
      m.style.top = (rect.bottom + 2) + 'px';
    }
    for (var i = 0; i < s.options.length; i++) {
      (function(opt) {
        var it = document.createElement('div');
        it.textContent = opt.textContent;
        it.style.cssText = 'padding:9px 12px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
        var sel = 'rgba(255,140,90,.25)';
        if (opt.selected) it.style.background = sel;
        it.onmouseenter = function() { it.style.background = 'rgba(255,255,255,.18)'; };
        it.onmouseleave = function() { it.style.background = opt.selected ? sel : ''; };
        it.addEventListener('mousedown', function(ev) {
          ev.preventDefault();
          ev.stopPropagation();
          if (s.value !== opt.value) {
            s.value = opt.value;
            s.dispatchEvent(new Event('input', { bubbles: true }));
            s.dispatchEvent(new Event('change', { bubbles: true }));
          }
          close();
        });
        m.appendChild(it);
      })(s.options[i]);
    }
    document.body.appendChild(m);
    menu = m;
  }, true);
  window.addEventListener('scroll', function(e) {
    if (menu && menu.contains(e.target)) return;
    close();
  }, true);
  window.addEventListener('resize', close, true);
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') close();
  }, true);
})();
''';

const String _downloadHookScript = r'''
(function() {
  if (window.__pyreDLHooked) return;
  window.__pyreDLHooked = true;

  function readGallery() {
    try {
      return Array.prototype.slice.call(
        document.querySelectorAll('#post-mini-gallery img'))
        .map(function(i) { return i.getAttribute('src') || ''; })
        .filter(function(s) { return s.indexOf('mini-gallery') >= 0; });
    } catch (e) { return []; }
  }

  document.addEventListener('click', function(e) {
    var a = e.target && e.target.closest && e.target.closest('a, button');
    if (!a) return;
    var url = a.href || a.getAttribute('data-url') || '';

    // LOREBOOK "Download JSON" — the real control is an anchor
    // `<a href="/api/lorebooks/{id}/download.json" download>` (plus a
    // `#download-json-btn` button nearby). Match either.
    //
    // FRONTEND-ONLY: the app must NEVER call BotBooru's API. That endpoint is
    // bot-gated (403 to a cookie-less client) and only returns 200 inside a
    // logged-in browser session. So instead of posting the URL for native to
    // fetch, we fetch it HERE — inside the webview — with
    // `credentials:'include'` (the user's session cookies) and post the JSON
    // TEXT back over the SAME postMessage channel as a {lorebookJson:...}
    // envelope (or {lorebookError:...} on failure). Native parses the text
    // directly; it issues no HTTP request of its own.
    var lb = url.match(/\/api\/lorebooks\/(\d+)\/download\.json/);
    if (!lb && a.id === 'download-json-btn') {
      var anchor = document.querySelector(
        'a[href*="/api/lorebooks/"][href*="download.json"]');
      var lbHref = anchor ? (anchor.href || '') : '';
      if (lbHref) { lb = lbHref.match(/\/api\/lorebooks\/(\d+)\/download\.json/); url = lbHref; }
    }
    if (lb) {
      e.preventDefault();
      e.stopPropagation();
      var abs = url.indexOf('http') === 0
        ? url
        : (location.origin + '/api/lorebooks/' + lb[1] + '/download.json');
      // BotBooru's download JSON has an EMPTY top-level `name`; the real title
      // only lives in the page. Capture it as a name hint: prefer a visible
      // heading, else strip the ' — Botbooru' suffix off the tab title. The
      // parent uses it ONLY when the JSON's own name is blank.
      var lbName = '';
      try {
        var t1 = (document.title || '').split(/[—|]/)[0].trim();
        if (t1 && t1.toLowerCase() !== 'botbooru') lbName = t1;
      } catch (_) {}
      if (!lbName) { try {
        var og = document.querySelector('meta[property="og:title"]');
        var oc = og && (og.getAttribute('content') || '');
        if (oc) { var o = oc.split(/[—|]/)[0].trim();
          if (o && o.toLowerCase() !== 'botbooru') lbName = o; }
      } catch (_) {} }
      if (!lbName) { try {
        var hs = document.querySelectorAll('h1, h2, h3');
        for (var hi = 0; hi < hs.length; hi++) {
          var x = (hs[hi].textContent || '').trim();
          if (x && x.length < 80) { lbName = x; break; }
        }
      } catch (_) {} }
      fetch(abs, { credentials: 'include', headers: { 'Accept': 'application/json' } })
        .then(function(r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.text();
        })
        .then(function(t) {
          try { window.chrome.webview.postMessage(JSON.stringify({ lorebookJson: t, lorebookName: lbName })); } catch (_) {}
        })
        .catch(function(err) {
          try {
            window.chrome.webview.postMessage(JSON.stringify({
              lorebookError: (err && err.message) || 'download failed'
            }));
          } catch (_) {}
        });
      return;
    }

    // CHARACTER "Download PNG". Wave CY.18.260: find the numeric card id from
    // WHATEVER the (possibly-updated) markup exposes (see findCardId), then
    // fetch the PNG INSIDE the authenticated webview and post the BYTES
    // (base64) — BotBooru bot-gates /download/png so a native re-fetch stalls
    // + trips the site's own "Failed to download PNG" alert. The legacy
    // fetch + URL.createObjectURL overrides (which returned javascript:void(0)
    // and broke the site's updated handler) are GONE — we own the fetch now.
    var id = findCardId(a);
    if (id) {
      e.preventDefault();
      e.stopPropagation();
      var dl = location.origin + '/download/png/' + id;
      fetch(dl, { credentials: 'include' })
        .then(function(r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.blob();
        })
        .then(function(blob) {
          return new Promise(function(resolve, reject) {
            var fr = new FileReader();
            fr.onloadend = function() {
              var s = String(fr.result || '');
              var c = s.indexOf(',');
              resolve(c >= 0 ? s.slice(c + 1) : s);
            };
            fr.onerror = function() { reject(new Error('read failed')); };
            fr.readAsDataURL(blob);
          });
        })
        .then(function(b64) {
          try {
            window.chrome.webview.postMessage(JSON.stringify({
              cardB64: b64, gallery: readGallery()
            }));
          } catch (_) {}
        })
        .catch(function(err) {
          try {
            window.chrome.webview.postMessage(JSON.stringify({
              cardError: (err && err.message) || 'download failed'
            }));
          } catch (_) {}
        });
      return;
    }
  }, true);

  // Wave CY.18.260: locate a BotBooru card id from a clicked element or any
  // ancestor (mirrors the mobile __pyreFindCardId). Tries an href/data-url/
  // data-src containing `/download/png/<id>`, then a numeric data-post-id /
  // data-character-id / data-id, and finally — only for a control whose
  // label/aria/title/text mentions "download png"/"png" — a bare numeric id.
  // Best-effort: the exact new markup couldn't be inspected statically.
  function findCardId(start) {
    var node = start, depth = 0, sawPng = false;
    while (node && node.nodeType === 1 && depth < 6) {
      try {
        var href = (node.getAttribute && (node.getAttribute('href') ||
          node.getAttribute('data-url') ||
          node.getAttribute('data-src'))) || node.href || '';
        var hm = String(href).match(/\/download\/png\/(\d+)/);
        if (hm) return hm[1];
        var label = ((node.getAttribute &&
          (node.getAttribute('aria-label') ||
           node.getAttribute('title'))) || '') + ' ' +
          (node.textContent || '');
        label = label.toLowerCase();
        // Confirmed live (2026-06): <button id="download-png-btn"
        // aria-label="Download character card as PNG"> — no href, no data id.
        var isPng = node.id === 'download-png-btn' ||
          label.indexOf('download png') >= 0 ||
          label.indexOf('download character card') >= 0;
        if (isPng) sawPng = true;
        var pid = node.getAttribute && (
          node.getAttribute('data-post-id') ||
          node.getAttribute('data-character-id') ||
          node.getAttribute('data-id'));
        if (pid && /^\d+$/.test(pid) &&
            (isPng || label.indexOf('png') >= 0)) {
          return pid;
        }
      } catch (_) {}
      node = node.parentElement;
      depth++;
    }
    // The id now lives ONLY in the page URL (/character/<id>, older /post/<id>);
    // the button carries none. Endpoint /download/png/<id> is unchanged.
    if (sawPng) {
      var pm = String(location.pathname).match(/\/(?:character|post)\/(\d+)/);
      if (pm) return pm[1];
    }
    return '';
  }
})();
''';

/// Wave CY.18.251: intercept the page's `<input type=file>` so we can show
/// Pyre's card-library picker (Android parity) instead of the OS file dialog.
///
/// WebView2 exposes no file-chooser hook, so we do it in-page:
///   - A capture-phase click listener walks up from the click target to find
///     a file input — directly, via `label[for]`, or a label-wrapped input.
///     When found, it cancels the page's own handler, stashes the input as
///     `__pyrePendingInput`, and posts `{pyreType:'pickCard', multiple}`.
///   - The actual file injection is done by [_setFilesIife] (a one-shot IIFE
///     injected from Dart after the user picks), NOT by a persistent
///     `window.*` function — see Wave CY.18.255 / audit FIX 3.
/// Idempotent (`window.__pyreUploadHooked` guard).
const String _uploadHookScript = r'''
(function(){
  if (window.__pyreUploadHooked) return;
  window.__pyreUploadHooked = true;
  window.__pyrePendingInput = null;
  document.addEventListener('click', function(e){
    var input = null, node = e.target;
    while (node && node !== document) {
      if (node.tagName === 'INPUT' && (node.type||'').toLowerCase() === 'file') { input = node; break; }
      if (node.tagName === 'LABEL') {
        var f = node.htmlFor ? document.getElementById(node.htmlFor) : node.querySelector('input[type=file]');
        if (f && f.tagName === 'INPUT' && (f.type||'').toLowerCase() === 'file') { input = f; break; }
      }
      node = node.parentElement;
    }
    if (!input) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    window.__pyrePendingInput = input;
    try { window.chrome.webview.postMessage(JSON.stringify({ pyreType: 'pickCard', multiple: !!input.multiple })); } catch (_) {}
  }, true);
})();
''';

/// Wave CY.18.255 (audit FIX 3): build the one-shot file-injection script.
///
/// [itemsJson] is a JSON array literal of `{name, b64}` objects (already
/// encoded by the caller). It's embedded directly into the IIFE body, so
/// the injection runs once with these exact files and leaves NOTHING
/// reusable on `window` — unlike the old persistent `window.__pyreSetFiles`,
/// which any hostile page script could call to inject files of its own
/// choosing into the form input.
///
/// The IIFE decodes each base64 PNG into a `File`, assigns them to the
/// pending input (`window.__pyrePendingInput`, set by [_uploadHookScript])
/// via a `DataTransfer` (WebView2 is Chromium, so `input.files = dt.files`
/// works), dispatches input+change so botbooru's form logic fires, then
/// clears the pending-input handle.
String _setFilesIife(String itemsJson) => '''
(function(){
  try {
    var items = $itemsJson;
    var input = window.__pyrePendingInput;
    if (!input || !items || !items.length) return false;
    var dt = new DataTransfer();
    for (var i=0;i<items.length;i++){
      var bin = atob(items[i].b64), n = bin.length, arr = new Uint8Array(n);
      for (var j=0;j<n;j++) arr[j] = bin.charCodeAt(j);
      dt.items.add(new File([arr], items[i].name, {type:'image/png'}));
    }
    input.files = dt.files;
    input.dispatchEvent(new Event('input', {bubbles:true}));
    input.dispatchEvent(new Event('change', {bubbles:true}));
    window.__pyrePendingInput = null;
    return true;
  } catch (e) { return false; }
})();
''';
