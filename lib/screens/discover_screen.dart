import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../models/models.dart';
import '../services/card_import.dart';
import '../services/gallery_import.dart';
import '../services/gallery_scrape.dart';
import '../services/http_errors.dart';
import '../services/lorebook_import.dart';
import '../services/attachment_store.dart';
import '../services/png_encoder.dart';
import '../services/png_parser.dart';
import '../services/resolvers.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/card_import_confirm.dart';
import '../widgets/desktop_botbooru_webview.dart';

bool get _supportsWebview {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

/// Wave CY.18.96: Windows desktop has its own embedded webview path
/// (Edge WebView2 via webview_windows). It uses a different widget
/// (DesktopBotbooruWebview) and a different controller — the
/// webview_flutter controller managed by this state class stays
/// null on Windows and is never touched. Linux/macOS desktop are
/// NOT in this set: webview_windows is Windows-only; those
/// platforms fall through to the external-launch fallback.
bool get _supportsWindowsWebview {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows;
}

// Wave CY.18.96: a `_supportsAnyEmbeddedWebview` helper was drafted
// here but the body's path selection ended up checking
// `_supportsWindowsWebview` and `_supportsWebview` independently
// (different widgets, different controllers), so the OR helper was
// never used. Kept this note instead of the dead getter so the next
// person doesn't waste time wiring it.

/// Hostnames we trust enough to fetch character cards from automatically.
/// Anything else has to go through the manual "Import by URL" dialog,
/// which surfaces the URL to the user for visual review.
const _trustedDownloadHosts = <String>{
  'botbooru.com',
  'www.botbooru.com',
  'cdn.botbooru.com',
  'chub.ai',
  'www.chub.ai',
  'avatars.chub.io',
  'avatars.charhub.io',
  'characterhub.org',
  // RisuRealm: the character page AND its download API are both this host,
  // so a resolved `/api/v1/download/png-v2/{id}` URL is fetched directly.
  'realm.risuai.net',
  'www.realm.risuai.net',
  // Common file-hosts people share bare chara_card PNG/JSON from. Pulled
  // from the shared resolver allowlist so a catbox/pixeldrain direct link
  // passes the trusted-host check the same way the community CDNs do.
  ...kCardFileHostAllowlist,
};

/// Returns true if [url] parses as an https URL whose host is in
/// [_trustedDownloadHosts]. Used to gate the JS channel and the WebView's
/// navigation delegate — a hostile page can't trick us into fetching from
/// `evil.com` because the host check happens BEFORE any http.get fires.
bool _isTrustedSource(String url) {
  Uri u;
  try {
    u = Uri.parse(url);
  } catch (_) {
    return false;
  }
  if (u.scheme != 'https') return false;
  if (u.host.isEmpty) return false;
  return _trustedDownloadHosts.contains(u.host.toLowerCase());
}

/// Hard cap on a downloaded chara-card PNG. A legitimate card is well
/// under this; anything bigger is a hostile/huge response we refuse
/// rather than buffer into memory (OOM guard). Mirrors the 50 MB
/// backup-import cap in backup_restore_screen.dart.
const int _kMaxCardBytes = 25 * 1024 * 1024; // 25 MB

/// GET [target] with auto-redirects DISABLED and the body capped at
/// [_kMaxCardBytes]. A 3xx would let an allowlisted host bounce us to
/// an arbitrary address (limited SSRF), so we surface it as an error
/// instead of following it. Returns an [http.Response] so callers can
/// reuse `statusCode` / `bodyBytes` exactly as with `http.get`.
Future<http.Response> _fetchCappedNoRedirect(Uri target) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', target)..followRedirects = false;
    final streamed = await client.send(request);
    if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
      throw "Couldn't import — the link redirected to another address.";
    }
    final declared = streamed.contentLength;
    if (declared != null && declared > _kMaxCardBytes) {
      throw "Couldn't import — file is too large.";
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > _kMaxCardBytes) {
        throw "Couldn't import — file is too large.";
      }
    }
    return http.Response.bytes(
      builder.takeBytes(),
      streamed.statusCode,
      headers: streamed.headers,
      reasonPhrase: streamed.reasonPhrase,
    );
  } finally {
    client.close();
  }
}

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  WebViewController? _controller;
  bool _busy = false;
  String? _status;
  /// Whether the embedded webview is currently shown. Starts false so the
  /// user sees the "how to import" landing screen first instead of being
  /// dropped straight into a third-party site they may not know is the
  /// default. Tap "Open botbooru.com" on the landing → flip to true →
  /// webview becomes visible. The webview kebab has a "Back to instructions"
  /// option so the user is never stuck inside the embedded browser.
  bool _showWebview = false;

  /// Wave CY.18.98: toggling the embedded webview also asks the
  /// parent shell to drop its content max-width cap so the embed
  /// fills the entire space minus the navigation rail. Centralising
  /// the flag flip here (instead of sprinkling it at every callsite
  /// that mutates _showWebview) keeps the cleanup invariant trivial:
  /// every state transition goes through this helper.
  void _setShowWebview(bool value) {
    if (!mounted) return;
    setState(() => _showWebview = value);
    try {
      context.read<AppStore>().setWantsFullWidthContent(value);
    } catch (_) {
      // Provider lookup can fail during teardown — best-effort.
    }
  }

  @override
  void initState() {
    super.initState();
    if (_supportsWebview) {
      _initController();
    }
  }

  void _initController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Channel that injected JS uses to ship the original API URL of a
      // download click back to Flutter (botbooru wraps downloads in blob:
      // URIs which WebView cannot navigate to).
      ..addJavaScriptChannel(
        'EmberDL',
        onMessageReceived: (msg) {
          // The JS channel is the easiest place for a hostile page to
          // smuggle data — any script in the WebView can call
          // EmberDL.postMessage(arbitraryUrl) and we used to feed that
          // straight into http.get. Drop messages whose URL isn't in our
          // trusted-host allowlist so a compromised page can't make us
          // fetch+import from an attacker-controlled origin.
          final url = msg.message.trim();
          if (url.isEmpty) return;
          if (!_isTrustedSource(url)) {
            debugPrint('EmberDL: rejected untrusted URL "$url"');
            return;
          }
          _importFromUrl(url);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _injectDownloadHook(),
          onNavigationRequest: (req) {
            final url = req.url;
            // Catch /download/png/{id} clicks that ARE plain navigations
            // (some browsers / mobile UA codepaths in botbooru do this).
            // Still validate the host — a redirect could land us on an
            // arbitrary origin's /download/png/N endpoint.
            if (url.contains('/download/png/') ||
                url.toLowerCase().endsWith('.png')) {
              if (_isTrustedSource(url)) {
                _importFromUrl(url);
              }
              return NavigationDecision.prevent;
            }
            // After our JS hook intercepts a blob download, the page may
            // still try to navigate the WebView to blob:/about:blank.
            // Block those so the current page stays visible.
            if (url.startsWith('blob:') ||
                url == 'about:blank' ||
                url.startsWith('javascript:')) {
              return NavigationDecision.prevent;
            }
            // Confine browsing to botbooru itself. Off-site links go to
            // the OS browser instead — that way our JS channel and the
            // user's login session don't follow the user onto pages we
            // can't trust.
            //
            // Wave CY: restrict the off-site launch to http(s). Without
            // this, a hostile page can navigate to `intent://`, `tel:`,
            // `sms:`, `mailto:`, `market:`, custom-app deep links, or
            // `file:` — Android hands those off to whatever resolves,
            // which lets the page open the user's banking app, prefill
            // an SMS, or trigger an in-app purchase flow.
            if (!_isTrustedSource(url)) {
              final parsed = Uri.tryParse(url);
              if (parsed != null &&
                  (parsed.scheme == 'http' || parsed.scheme == 'https')) {
                launchUrl(parsed, mode: LaunchMode.externalApplication)
                    .catchError((_) => false);
              }
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse('https://botbooru.com/'));

    // Android-only: enable native file chooser (for upload buttons) and the
    // download manager hook (for direct attachment downloads).
    if (defaultTargetPlatform == TargetPlatform.android &&
        controller.platform is AndroidWebViewController) {
      final android = controller.platform as AndroidWebViewController;
      android.setOnShowFileSelector(_onShowFileSelector);
      android.setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller;
  }

  /// Hook for the WebView's native file picker (e.g. botbooru's "Add image"
  /// button on a card edit page). Returns a list of `file://` URIs.
  ///
  /// Wave CU: we intercept the picker to show a Characters-library picker
  /// first — every Character in the app, sortable/searchable, with a tap
  /// generating a fresh chara_card_v2 PNG on the fly. The legacy
  /// PyreExports/ folder is no longer required: any character (created,
  /// imported, AI-edited, manual-edited) is uploadable as long as it has
  /// an avatar. The user can fall through to the regular OS picker via
  /// "Browse other files…" if they want anything else.
  ///
  /// Restricted to image extensions in the fall-through: the only
  /// legitimate use on botbooru is uploading PNG/JPG cards or scenario
  /// images. Without this, a hostile page could prompt the user to
  /// "upload your character" and then receive whatever file they pick
  /// from device storage — including JSON backups containing API keys
  /// and chat history (Wave CY.1 audit).
  Future<List<String>> _onShowFileSelector(
      FileSelectorParams params) async {
    final allowMultiple = params.mode == FileSelectorMode.openMultiple;
    // For non-image pickers (rare on botbooru), skip the Characters
    // sheet — chara_card_v2 PNGs aren't what the page is asking for.
    final wantsImage = params.acceptTypes.isEmpty ||
        params.acceptTypes.any((t) {
          final lt = t.toLowerCase();
          return lt.startsWith('image/') ||
              lt == '*/*' ||
              lt == '.png' ||
              lt == '.jpg' ||
              lt == '.jpeg' ||
              lt == '.webp';
        });

    if (!wantsImage) {
      return _systemFilePicker(allowMultiple: allowMultiple);
    }

    final store = context.read<AppStore>();
    // Snapshot the messenger BEFORE any await so we can surface
    // per-character encode errors without re-touching `context` after
    // the modal closes (Dart analyzer flags the cross-await pattern).
    final messenger = ScaffoldMessenger.of(context);
    // Newest-first feels right for an upload picker — the user almost
    // always wants the card they JUST finished editing.
    final characters = List<Character>.from(store.characters)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (!mounted) return const [];
    final picked = await showModalBottomSheet<_CharacterPickerPick>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _CharacterPickerSheet(
        characters: characters,
        multi: allowMultiple,
      ),
    );
    if (picked == null) return const [];
    if (picked.fallthrough) {
      return _systemFilePicker(allowMultiple: allowMultiple);
    }
    // Encode the picked Character(s) to chara_card_v2 PNG files in a temp
    // dir, then hand the file:// URIs back. We DO NOT silently skip
    // failures — if anything fails (no avatar, malformed bytes), the user
    // gets a SnackBar and an empty return so botbooru's form stays open
    // for them to retry.
    final List<String> uris = [];
    for (final c in picked.characters) {
      try {
        final path = await _encodeCharacterToTempPng(c);
        uris.add(Uri.file(path).toString());
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not export ${c.name}: $e')),
        );
      }
    }
    return uris;
  }

  Future<List<String>> _systemFilePicker({required bool allowMultiple}) async {
    // Wave CY.1: image-only. JSON used to be in the allowlist for
    // chara_card_v2-as-JSON uploads but it doubles as a backup format,
    // so a hostile page could social-engineer the user into uploading
    // a Pyre backup containing API keys.
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: allowMultiple,
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
    );
    if (result == null) return const [];
    return result.files
        .where((f) => f.path != null)
        .map((f) => Uri.file(f.path!).toString())
        .toList();
  }

  /// Wave CU: encode [c] to a fresh chara_card_v2 PNG and write it to
  /// the system temp directory. Returns the absolute path so the caller
  /// can hand a file:// URI to the WebView. Throws if the character has
  /// no avatar (chara_card_v2 requires an image) or the avatar is
  /// malformed.
  Future<String> _encodeCharacterToTempPng(Character c) async {
    // Wave CY.18.145: resolve via the shared helper so a migrated
    // `pyre://attachment/<hash>` avatar works — the old naive comma-split
    // decode threw "invalid avatar data" on those, so uploading a saved
    // card to botbooru (the Wave-CU picker) was broken for externalised
    // avatars.
    final avatarBytes = await resolveAvatarBytes(c.avatar);
    if (avatarBytes == null) {
      throw 'no avatar — set one in the editor first';
    }
    final pngBytes = encodeCharaCardPng(c, avatarBytes);
    final safeName = c.name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
        .trim()
        .replaceAll(' ', '_');
    final base = safeName.isEmpty ? 'card' : safeName;
    final tempDir = await getTemporaryDirectory();
    // Stamp the filename so successive picks don't collide. The temp
    // dir is OS-managed; we don't bother cleaning up — the next upload
    // overwrites with a new stamp and Android's normal cache wipes the
    // rest.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${tempDir.path}/${base}_$stamp.card.png');
    await file.writeAsBytes(pngBytes);
    return file.path;
  }

  /// Wave CY.18.251: Windows-desktop counterpart of [_onShowFileSelector].
  ///
  /// WebView2 has no file-chooser hook, so [DesktopBotbooruWebview] injects
  /// a JS hook that intercepts botbooru's `<input type=file>` and asks us
  /// (via this callback) to pick the card(s). We show the SAME card-library
  /// picker the Android path uses ([_CharacterPickerSheet], newest-first),
  /// encode the chosen Character(s) to chara_card_v2 PNG, base64 them, and
  /// hand back [PyreUploadFile]s — the widget injects them into the form via
  /// DataTransfer. Returns an empty list on cancel so the form is untouched.
  ///
  /// [multiple] mirrors the input's `multiple` attribute (single-tap pick vs
  /// multi-select), exactly like the Android selector.
  Future<List<PyreUploadFile>> _onPickCardsForUpload(bool multiple) async {
    final store = context.read<AppStore>();
    // Snapshot the messenger BEFORE any await — the modal closes between
    // here and the per-card encode, so we can't re-touch `context` for
    // SnackBars afterwards (Dart cross-await analyzer rule).
    final messenger = ScaffoldMessenger.of(context);
    // Newest-first — the user almost always wants the card they just
    // finished editing.
    final characters = List<Character>.from(store.characters)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (!mounted) return const [];
    final picked = await showModalBottomSheet<_CharacterPickerPick>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _CharacterPickerSheet(
        characters: characters,
        multi: multiple,
      ),
    );
    if (picked == null) return const []; // cancelled — leave the form as-is
    if (picked.fallthrough) {
      // "Browse other files…" → OS image picker. Read each picked file's
      // bytes and base64 them. Image-only (png/jpg/jpeg/webp) for the same
      // SSRF/exfil reason as [_systemFilePicker].
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: multiple,
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      );
      if (result == null) return const [];
      final List<PyreUploadFile> out = [];
      for (final f in result.files) {
        if (f.path == null) continue;
        try {
          final bytes = await File(f.path!).readAsBytes();
          out.add(PyreUploadFile(f.name, base64Encode(bytes)));
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text('Could not read ${f.name}: $e')),
          );
        }
      }
      return out;
    }
    // Encode each picked Character to a chara_card_v2 PNG in memory. We DO
    // NOT silently drop avatarless cards — the user gets a SnackBar and the
    // card is skipped (matching the Android path's loud-failure stance).
    final List<PyreUploadFile> out = [];
    for (final c in picked.characters) {
      try {
        final avatarBytes = await resolveAvatarBytes(c.avatar);
        if (avatarBytes == null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Skipped ${c.name} — no avatar (a card needs an image).',
              ),
            ),
          );
          continue;
        }
        final pngBytes = encodeCharaCardPng(c, avatarBytes);
        final safeName = c.name
            .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
            .trim()
            .replaceAll(' ', '_');
        final base = safeName.isEmpty ? 'card' : safeName;
        out.add(PyreUploadFile('$base.card.png', base64Encode(pngBytes)));
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not export ${c.name}: $e')),
        );
      }
    }
    return out;
  }

  /// Injects a small script that intercepts botbooru's "Download PNG"
  /// behaviour. Botbooru's button fetches the PNG and wraps the bytes in a
  /// blob: URL, which Android WebView refuses to navigate to. The hook
  /// catches the click on any <a> with a botbooru download endpoint and
  /// ships the original https URL back to Flutter via the EmberDL channel.
  void _injectDownloadHook() {
    _controller?.runJavaScript(r'''
      (function() {
        if (window.__emberDLHooked) return;
        window.__emberDLHooked = true;

        // 1) Capture clicks on anchors whose href / data-url matches a
        //    download endpoint, BEFORE the page's own JS runs.
        document.addEventListener('click', function(e) {
          var a = e.target && e.target.closest && e.target.closest('a, button');
          if (!a) return;
          var url = a.href || a.getAttribute('data-url') || '';
          var m = url.match(/\/download\/png\/(\d+)/);
          if (!m && a.dataset && a.dataset.id) {
            // Buttons that don't have an href yet — use the card id.
            var btnText = (a.textContent || '').toLowerCase();
            if (btnText.indexOf('download png') >= 0) {
              url = location.origin + '/download/png/' + a.dataset.id;
              m = url.match(/\/download\/png\/(\d+)/);
            }
          }
          if (m) {
            e.preventDefault();
            e.stopPropagation();
            EmberDL.postMessage(location.origin + '/download/png/' + m[1]);
          }
        }, true);

        // 2) Override URL.createObjectURL so any blob:-based download that
        //    slipped through is also redirected. We sniff the originating
        //    fetch URL by hooking fetch as well.
        var lastFetched = null;
        var origFetch = window.fetch;
        window.fetch = function(input, init) {
          try {
            var u = (typeof input === 'string') ? input : (input && input.url) || '';
            if (/\/download\/png\/\d+/.test(u)) lastFetched = u;
          } catch (_) {}
          return origFetch.apply(this, arguments);
        };
        var origCreate = URL.createObjectURL;
        URL.createObjectURL = function(obj) {
          var blobUrl = origCreate.apply(this, arguments);
          if (lastFetched) {
            var abs = lastFetched.startsWith('http')
              ? lastFetched : (location.origin + lastFetched);
            EmberDL.postMessage(abs);
            lastFetched = null;
            // Return a no-op URL: the page will still build the <a> and
            // .click() it, but navigation to javascript:void(0) does
            // nothing AND we belt-and-braces block it in the
            // NavigationDelegate above.
            return 'javascript:void(0)';
          }
          return blobUrl;
        };
      })();
    ''');
  }

  Future<void> _importFromUrl(
    String url, {
    List<String> galleryDomSrcs = const [],
  }) async {
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _status = 'Resolving…';
    });
    try {
      final resolved = await resolveCommunityUrl(url);
      // Wave CT: chub.ai already returns PNG bytes from the resolver's
      // POST — reuse them. Otherwise fall through to a GET on the
      // resolved URL with the trusted-host allowlist.
      final Uint8List pngBytes;
      if (resolved?.bytes != null) {
        pngBytes = resolved!.bytes!;
      } else {
        final target = resolved?.pngUrl ?? Uri.parse(url);
        if (target.scheme != 'https' ||
            !_trustedDownloadHosts.contains(target.host.toLowerCase())) {
          throw 'Refused to fetch from untrusted host: ${target.host}';
        }
        setState(() => _status = 'Downloading…');
        // Disable auto-redirect: a 3xx would let a trusted host bounce
        // us to an arbitrary (e.g. internal) address, defeating the
        // host-allowlist check above (limited SSRF). A redirect is
        // treated as a failed import. Also cap the body at ~25 MB to
        // avoid OOM from a hostile/huge response (cf. the 50 MB
        // backup-import cap in backup_restore_screen.dart).
        final resp = await _fetchCappedNoRedirect(target);
        if (resp.statusCode >= 400) {
          // Wave CY.3: friendly 429/Retry-After/etc. — botbooru's
          // download route is rate-limited and the bare `HTTP 429`
          // we used to throw looked like a hard bug to users.
          throw describeHttpFailure(resp, host: friendlyHostName(target));
        }
        pngBytes = resp.bodyBytes;
      }
      final card = parseCharaCardPng(pngBytes);
      final character = characterFromCharaCard(card);
      // Wave CY.18.141/142: BotBooru gallery is NOT fetched from their API
      // (owner's request: use our frontend, don't share our API). The Windows
      // webview reads the rendered `#post-mini-gallery img` srcs at import time
      // and passes them as `galleryDomSrcs`; here we resolve + host-gate them
      // into clean gallery image URLs. Other paths (mobile, paste-import) pass
      // no srcs, so no gallery is offered there.
      List<String> galleryUrls = const [];
      if (resolved?.source == 'botbooru' && galleryDomSrcs.isNotEmpty) {
        galleryUrls = resolveBotbooruGalleryDomUrls(
          galleryDomSrcs,
          allowedHosts: kBotbooruGalleryHosts,
        );
      }
      // Surface the card description before saving so the user can spot
      // adversarial prompt-injection text (cards CAN contain instructions
      // to the AI that hijack subsequent system prompts).
      if (!mounted) return;
      final choice = await confirmCardImport(
        context,
        character,
        galleryCount: galleryUrls.length,
      );
      if (!choice.import) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Import cancelled.')),
        );
        return;
      }
      if (choice.withGallery) {
        character.gallery = await downloadGalleryImages(galleryUrls);
      }
      // Wave CA: handle embedded character_book if present.
      if (!mounted) return;
      await handleEmbeddedBookForCharacter(
        context: context,
        store: store,
        character: character,
        charaCardData: card.card,
      );
      store.addCharacter(character);
      messenger.showSnackBar(
        SnackBar(content: Text('Imported ${character.name}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    final inMobileWebview =
        _supportsWebview && _controller != null && _showWebview;
    // Wave CY.18.96: Windows desktop embed is a separate widget tree
    // (its own WebviewController inside DesktopBotbooruWebview).
    // Showing the embed reuses the same _showWebview flip so the
    // landing → browse → import flow is identical to mobile.
    final inWindowsWebview = _supportsWindowsWebview && _showWebview;
    return PopScope(
      // Intercept the Android back button so it: (1) navigates inside the
      // WebView when there's history, (2) flips back to the landing screen
      // when at the top of the embedded site, (3) only THEN leaves the
      // Discover tab.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (inMobileWebview) {
          if (await _controller!.canGoBack()) {
            await _controller!.goBack();
            return;
          }
          // No more history → go back to the landing.
          if (mounted) _setShowWebview(false);
          return;
        }
        if (inWindowsWebview) {
          // Windows desktop: the DesktopBotbooruWebview manages its
          // own history internally via its toolbar. Bind the system
          // back to the landing flip so a stray Esc/back action still
          // takes the user out gracefully.
          if (mounted) _setShowWebview(false);
          return;
        }
      },
      child: Scaffold(
        // Wave CY.18.97: when the Windows embed is showing, drop the
        // AppBar entirely so the webview takes the full available
        // area — the embed's own toolbar provides the only nav. On
        // mobile and on the landing screen we keep the standard
        // Discover AppBar.
        appBar: inWindowsWebview
            ? null
            : AppBar(
                title: const Text('Discover'),
                actions: [
                  if (inMobileWebview) ...[
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new),
                      tooltip: 'Back',
                      onPressed: () async {
                        if (await _controller!.canGoBack()) {
                          await _controller!.goBack();
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh',
                      onPressed: () => _controller!.reload(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.more_vert),
                      tooltip: 'More',
                      onPressed: _showWebviewMenu,
                    ),
                  ],
                ],
              ),
        body: _buildBody(),
      ),
    );
  }

  /// Wave CY.18.96: route the body. Order matters — Windows desktop
  /// check comes before the web fallback because both fall outside
  /// `_supportsWebview` (which is Android+iOS only).
  Widget _buildBody() {
    if (_supportsWindowsWebview) {
      return _showWebview ? _buildWindowsWebview() : _buildLanding();
    }
    if (_supportsWebview) {
      return _showWebview ? _buildNativeWebView() : _buildLanding();
    }
    // Linux/macOS desktop + web all land here. Same external-launch
    // pattern: button opens the OS browser, URL bar for paste-import.
    return _buildWebFallback();
  }

  Widget _buildWindowsWebview() {
    return DesktopBotbooruWebview(
      initialUrl: 'https://botbooru.com/',
      onClose: () => _setShowWebview(false),
      // Wave CY.18.251: in-page upload picker (Android parity). When the
      // user clicks botbooru's file input, the webview's JS hook calls this
      // to show Pyre's card-library picker, then injects the chosen card.
      onPickCardsForUpload: _onPickCardsForUpload,
      onImportCurrentUrl: (url, galleryDomSrcs) {
        // Funnel through the existing import-by-URL flow so trusted
        // host validation, resolver chain, and confirm modal all
        // fire identically to the bookmarklet hand-off. The gallery
        // DOM srcs (read from the rendered page) ride along so a
        // BotBooru card can offer its mini-gallery on import.
        _importFromUrl(url, galleryDomSrcs: galleryDomSrcs);
      },
    );
  }

  /// Landing screen shown before the user opens the embedded webview.
  /// Explains what Discover does, how to import cards, and gives the
  /// user an explicit choice — instead of dropping them into a third-
  /// party site with no warning.
  Widget _buildLanding() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: EmberColors.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.explore_outlined,
                color: EmberColors.primary,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Discover characters',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Browse botbooru.com inside the app. When you find a card you like, tap "Download PNG" — Pyre intercepts it and offers a one-tap import.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'HOW TO IMPORT',
              style: TextStyle(
                color: EmberColors.primary,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            _step('1', 'Open botbooru below and find a character you want.'),
            _step('2', 'Open the character page.'),
            _step(
                '3',
                'Tap "Download PNG". Pyre will catch the click, show you the card description, and ask you to confirm before saving.'),
            _step(
                '4',
                'Use the app bar to refresh, navigate back, sign out, or return here.'),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text('Open botbooru.com'),
                ),
                onPressed: () => _setShowWebview(true),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'You can paste a card URL too — More menu inside the webview.',
                style: TextStyle(
                    color: EmberColors.textDim, fontSize: 11),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: EmberColors.bgElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: EmberColors.stroke),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: EmberColors.textMid),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pyre is not affiliated with botbooru. The webview is locked to a few trusted character-card hosts; off-site links open in your phone\'s browser instead.',
                      style: TextStyle(
                          color: EmberColors.textMid,
                          fontSize: 11,
                          height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(String n, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: EmberColors.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: Text(
                n,
                style: const TextStyle(
                  color: EmberColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              body,
              style: const TextStyle(
                color: EmberColors.textHigh,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showWebviewMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('Back to instructions'),
              onTap: () {
                Navigator.pop(sheet);
                _setShowWebview(false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Botbooru home'),
              onTap: () {
                Navigator.pop(sheet);
                _controller?.loadRequest(Uri.parse('https://botbooru.com/'));
              },
            ),
            ListTile(
              leading: const Icon(Icons.cookie_outlined,
                  color: EmberColors.danger),
              title: const Text('Sign out / clear cookies',
                  style: TextStyle(color: EmberColors.danger)),
              onTap: () async {
                Navigator.pop(sheet);
                await WebViewCookieManager().clearCookies();
                _controller?.loadRequest(Uri.parse('https://botbooru.com/'));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cookies cleared.')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNativeWebView() {
    return Stack(
      children: [
        WebViewWidget(controller: _controller!),
        if (_busy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                        color: EmberColors.primary),
                    const SizedBox(height: 12),
                    Text(_status ?? 'Working…',
                        style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWebFallback() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.public, color: EmberColors.primary),
                    SizedBox(width: 8),
                    Text(
                      'Botbooru',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'On Android and Windows, this tab embeds botbooru.com '
                  'directly so you can browse + import without leaving '
                  'Pyre.\n\n'
                  'On this platform, the embed isn\'t available — open '
                  'botbooru externally and use the bookmarklet hand-off, '
                  'or paste a card URL below.',
                  style:
                      TextStyle(color: EmberColors.textMid, height: 1.4),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Open Botbooru'),
                      onPressed: () => _openBotbooru(context),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('Import by URL'),
                      onPressed: () => _showUrlDialog(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Open botbooru.com. On web we use a `_blank` target so Chrome's
  /// popup blocker doesn't kill the navigation; on native we let the
  /// OS pick the default browser.
  Future<void> _openBotbooru(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.parse('https://botbooru.com/');
    try {
      final ok = await launchUrl(
        uri,
        mode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
      if (!ok) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Browser refused to open the link. Allow popups for this site.')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open: $e')));
    }
  }

  Future<void> _showUrlDialog(BuildContext context) async {
    final ctl = TextEditingController();
    String? err;
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: EmberColors.bgPanel,
          title: const Text('Import by URL'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste a botbooru / chub character page URL, or a direct PNG link.',
                style: TextStyle(color: EmberColors.textMid),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctl,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'https://…'),
              ),
              if (err != null) ...[
                const SizedBox(height: 8),
                Text(err!, style: const TextStyle(color: EmberColors.danger)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() {
                        busy = true;
                        err = null;
                      });
                      try {
                        await _importFromUrl(ctl.text.trim());
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setLocal(() {
                          err = e.toString();
                          busy = false;
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Wave CU: Characters-library picker — bottom sheet shown when the WebView
// triggers its file picker (e.g. botbooru's upload form). Lists every
// Character in the app (newest first), with a search field and a
// "Browse other files…" fallthrough. The picked Character(s) get encoded
// to chara_card_v2 PNG on the fly by the caller.

class _CharacterPickerPick {
  /// Characters the user chose. Empty if they hit [fallthrough].
  final List<Character> characters;
  /// True when the user picked "Browse other files…" — caller falls
  /// through to the regular OS file picker.
  final bool fallthrough;
  const _CharacterPickerPick({
    required this.characters,
    required this.fallthrough,
  });
}

class _CharacterPickerSheet extends StatefulWidget {
  final List<Character> characters;
  /// Whether the upload form accepts multiple files. When true, taps
  /// toggle selection and a "Use N" button appears; when false, tapping
  /// a row picks it instantly.
  final bool multi;
  const _CharacterPickerSheet({
    required this.characters,
    required this.multi,
  });

  @override
  State<_CharacterPickerSheet> createState() => _CharacterPickerSheetState();
}

class _CharacterPickerSheetState extends State<_CharacterPickerSheet> {
  final Set<String> _selected = <String>{};
  String _query = '';
  late final TextEditingController _searchCtl;

  @override
  void initState() {
    super.initState();
    _searchCtl = TextEditingController();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  List<Character> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.characters;
    return widget.characters.where((c) {
      if (c.name.toLowerCase().contains(q)) return true;
      final tag = c.tagline;
      if (tag != null && tag.toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final mediaHeight = MediaQuery.of(context).size.height;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mediaHeight * 0.85),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Grabber
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: EmberColors.stroke,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Pick a character to upload',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Any character in your library is uploadable as a '
                    'chara_card_v2 PNG. Tap to pick.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextField(
                  controller: _searchCtl,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon:
                        Icon(Icons.search, size: 18, color: EmberColors.textDim),
                    hintText: 'Search by name or tagline…',
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const Divider(color: EmberColors.stroke, height: 1),
              Flexible(
                child: widget.characters.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 24, vertical: 32),
                        child: Text(
                          "You don't have any characters yet. Create or "
                          'import one first, then come back here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: EmberColors.textDim, fontSize: 13),
                        ),
                      )
                    : filtered.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 24, vertical: 32),
                            child: Text(
                              'No characters match that search.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: EmberColors.textDim, fontSize: 13),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) => const Divider(
                                color: EmberColors.stroke,
                                height: 1,
                                indent: 80),
                            itemBuilder: (_, i) {
                              final c = filtered[i];
                              final selected = _selected.contains(c.id);
                              final hasAvatar =
                                  c.avatar != null && c.avatar!.isNotEmpty;
                              return _CharacterPickerRow(
                                character: c,
                                selected: selected,
                                showCheckbox: widget.multi,
                                disabled: !hasAvatar,
                                onTap: !hasAvatar
                                    ? () {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                                '${c.name} has no avatar. '
                                                'chara_card_v2 PNGs need an '
                                                'image — set one in the editor.'),
                                          ),
                                        );
                                      }
                                    : () {
                                        if (widget.multi) {
                                          setState(() {
                                            if (selected) {
                                              _selected.remove(c.id);
                                            } else {
                                              _selected.add(c.id);
                                            }
                                          });
                                        } else {
                                          Navigator.of(context).pop(
                                            _CharacterPickerPick(
                                              characters: [c],
                                              fallthrough: false,
                                            ),
                                          );
                                        }
                                      },
                              );
                            },
                          ),
              ),
              const Divider(color: EmberColors.stroke, height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  children: [
                    if (widget.multi && _selected.isNotEmpty)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.upload, size: 16),
                          label: Text('Use ${_selected.length} selected'),
                          onPressed: () {
                            final picks = widget.characters
                                .where((c) => _selected.contains(c.id))
                                .toList();
                            Navigator.of(context).pop(
                              _CharacterPickerPick(
                                characters: picks,
                                fallthrough: false,
                              ),
                            );
                          },
                        ),
                      ),
                    if (widget.multi && _selected.isNotEmpty)
                      const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open_outlined, size: 16),
                        label: const Text('Browse other files…'),
                        onPressed: () => Navigator.of(context).pop(
                          const _CharacterPickerPick(
                            characters: [],
                            fallthrough: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CharacterPickerRow extends StatelessWidget {
  final Character character;
  final bool selected;
  final bool showCheckbox;
  final bool disabled;
  final VoidCallback onTap;
  const _CharacterPickerRow({
    required this.character,
    required this.selected,
    required this.showCheckbox,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tagline = character.tagline;
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: disabled ? 0.5 : 1.0,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              AvatarBubble(
                dataUrl: character.avatar,
                fallback: character.name,
                radius: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      character.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (disabled)
                      const Text(
                        'No avatar — set one to upload',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: EmberColors.danger, fontSize: 11),
                      )
                    else if (tagline != null && tagline.isNotEmpty)
                      Text(
                        tagline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: EmberColors.textDim, fontSize: 11),
                      ),
                  ],
                ),
              ),
              if (showCheckbox && !disabled)
                Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                  activeColor: EmberColors.primary,
                )
              else if (!disabled)
                const Icon(Icons.chevron_right,
                    color: EmberColors.textDim, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
