import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../models/models.dart';
import '../services/capped_fetch.dart';
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

/// FRONTEND-ONLY LOREBOOK import message prefixes for the EmberDL channel.
///
/// The Discover webview's "Download JSON" hook fetches the lorebook bytes
/// INSIDE the logged-in session (the app must never call BotBooru's API), then
/// posts the result back over EmberDL: the raw JSON TEXT prefixed with
/// [_kLorebookTextPrefix], or an error message prefixed with
/// [_kLorebookErrPrefix]. The trailing `` (a control char that can't
/// appear unescaped in JSON) delimits the prefix so it can never collide with
/// real JSON content. Native strips the prefix and parses the text directly via
/// [parseLorebookImportText] — it issues no HTTP request of its own.
const String _kLorebookTextPrefix = 'PYRELB';
const String _kLorebookErrPrefix = 'PYRELBERR';

/// FRONTEND-ONLY CHARACTER import message prefixes for the EmberDL channel.
///
/// Wave CY.18.260: BotBooru bot-gates / rate-limits the `/download/png/{id}`
/// endpoint (403 to a cookie-less non-browser client), so the OLD flow — the
/// hook posts the URL and native RE-FETCHES it with `fetchCappedNoRedirect`
/// (no cookies) — broke: a ~3-minute stall hitting the gate, plus the site's
/// own "Failed to download PNG" alert (worsened because Pyre's
/// `URL.createObjectURL` override returned `'javascript:void(0)'` and tripped
/// the site's updated handler). The FIX mirrors the proven lorebook pattern:
/// the hook fetches the PNG INSIDE the authenticated webview
/// (`credentials:'include'`, the user's cookies) and posts the BYTES back as
/// base64 — native imports from the decoded bytes and issues NO HTTP request.
/// The payload after the prefix is `b64[<SOH>galleryJson]` (SOH = the U+0001
/// control char, which can't appear unescaped in base64 or JSON, so it can
/// never collide with the payload). [_kCardErrPrefix] carries a fetch error.
const String _kCardBytesPrefix = 'PYRECARD';
const String _kCardErrPrefix = 'PYRECARDERR';

/// Hard cap on the decoded PYRECARD PNG bytes. A real chara_card PNG is far
/// smaller; this rejects an absurdly large base64 blob a hostile page could
/// post over the channel before we hand it to the parser (mirrors the 25 MB
/// `fetchCappedNoRedirect` body cap the native re-fetch used to enforce).
const int _kCardBytesMaxLen = 25 * 1024 * 1024; // 25 MB

/// Parsed [_kCardBytesPrefix] payload: the decoded PNG [bytes] plus the raw
/// gallery DOM `img.src` strings the hook scraped from `#post-mini-gallery`.
class PyreCardPayload {
  final Uint8List bytes;
  final List<String> galleryDomSrcs;
  const PyreCardPayload(this.bytes, this.galleryDomSrcs);
}

/// Split a [_kCardBytesPrefix] EmberDL message body into its PNG bytes +
/// gallery srcs. The body (AFTER the prefix is stripped by the caller) is
/// `b64[<SOH>galleryJson]`: the base64 PNG, optionally followed by a SOH
/// (U+0001) and a JSON array of gallery `img.src` strings. Pure +
/// null-tolerant so the split/decode/cap rules are unit-testable (the webview
/// + native import are integration, not unit-testable).
///
/// Returns null when the base64 is empty / not decodable, or when the decoded
/// bytes are empty or exceed [_kCardBytesMaxLen] (the caller surfaces an
/// import-failed snackbar). A malformed / absent gallery JSON degrades to an
/// empty list (never throws) — the card still imports without a gallery.
PyreCardPayload? parseCardBytesPayload(String body) {
  final sep = body.indexOf('');
  final String b64;
  List<String> gallery = const [];
  if (sep >= 0) {
    b64 = body.substring(0, sep);
    final galleryJson = body.substring(sep + 1);
    if (galleryJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(galleryJson);
        if (decoded is List) {
          gallery = decoded.whereType<String>().toList();
        }
      } catch (_) {
        // Malformed gallery JSON → import the card without a gallery.
      }
    }
  } else {
    b64 = body;
  }
  if (b64.isEmpty) return null;
  final Uint8List bytes;
  try {
    bytes = base64Decode(b64);
  } catch (_) {
    return null;
  }
  if (bytes.isEmpty || bytes.length > _kCardBytesMaxLen) return null;
  return PyreCardPayload(bytes, gallery);
}

/// M-1: re-entrancy gate for the Discover import flow. Returns true iff a NEW
/// import may start — i.e. one is NOT already in flight. Extracted as a pure
/// function so the "second concurrent call is a no-op" guard is unit-testable
/// (the import handler itself drives a webview that can't be widget-tested).
bool canStartDiscoverImport(bool alreadyBusy) => !alreadyBusy;

/// Max length for a captured lorebook page-title hint. A real title is short;
/// this caps a runaway / hostile heading so it can't bloat the book name.
const int _kLorebookNameHintMaxChars = 120;

/// Sanitize a page-title name hint captured by the Discover webview hook:
/// trim, return null if blank, and cap the length. The result is passed as the
/// `nameFallback` to [parseLorebookImportText] (used only when the JSON's own
/// name is blank). Pure so the trim/cap/blank rules are unit-testable.
String? _sanitizeLorebookNameHint(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  return trimmed.length > _kLorebookNameHintMaxChars
      ? trimmed.substring(0, _kLorebookNameHintMaxChars).trim()
      : trimmed;
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

// Mega-audit 2026-06-05 (M-2): the local `_fetchCappedNoRedirect` here was a
// duplicate of `fetchCappedNoRedirect` in services/capped_fetch.dart. It has
// been replaced by a call to the shared helper, which now also enforces a
// connect + overall timeout so a stalled host fails fast instead of hanging
// the import spinner forever.

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
          final raw = msg.message;
          // FRONTEND-ONLY LOREBOOK: the hook fetches the lorebook JSON inside
          // the webview's authenticated session and posts the JSON TEXT here,
          // prefixed so we can tell it apart from a download URL. Handle these
          // BEFORE the URL path — they carry JSON, not a URL, and native must
          // NOT make any HTTP request for them.
          if (raw.startsWith(_kLorebookTextPrefix)) {
            // Payload after the prefix is `name<SOH>json` (the hook captures
            // the page's lorebook title as a name hint because BotBooru's
            // download JSON ships an empty top-level `name`). Split on the
            // FIRST SOH. Be tolerant: an older/no-name message has no second
            // SOH → treat the whole thing as the JSON text with no hint.
            final payload = raw.substring(_kLorebookTextPrefix.length);
            final sep = payload.indexOf('');
            final String nameHint;
            final String jsonText;
            if (sep >= 0) {
              nameHint = payload.substring(0, sep);
              jsonText = payload.substring(sep + 1);
            } else {
              nameHint = '';
              jsonText = payload;
            }
            _importLorebookFromJsonText(jsonText, nameHint: nameHint);
            return;
          }
          if (raw.startsWith(_kLorebookErrPrefix)) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "Couldn't download the lorebook — try again, or make "
                  "sure you're signed in to BotBooru.",
                ),
              ),
            );
            return;
          }
          // FRONTEND-ONLY CHARACTER: the hook fetched the PNG inside the
          // authenticated webview and posts the BYTES (base64) here. Native
          // imports from the decoded bytes — NO HTTP request of its own (this
          // is what avoids BotBooru's bot-gated /download/png re-fetch + the
          // site's own "Failed to download PNG" alert). Check the ERROR prefix
          // FIRST: `PYRECARDERR` starts with `PYRECARD`, so the bytes-prefix
          // test would otherwise swallow an error message.
          if (raw.startsWith(_kCardErrPrefix)) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "Couldn't download the card — try again, or make sure "
                  "you're signed in to BotBooru.",
                ),
              ),
            );
            return;
          }
          if (raw.startsWith(_kCardBytesPrefix)) {
            final payload = parseCardBytesPayload(
              raw.substring(_kCardBytesPrefix.length),
            );
            if (payload == null) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Couldn't read the downloaded card."),
                ),
              );
              return;
            }
            _importBytesAsCharacter(
              payload.bytes,
              galleryDomSrcs: payload.galleryDomSrcs,
            );
            return;
          }
          // The JS channel is the easiest place for a hostile page to
          // smuggle data — any script in the WebView can call
          // EmberDL.postMessage(arbitraryUrl) and we used to feed that
          // straight into http.get. Drop messages whose URL isn't in our
          // trusted-host allowlist so a compromised page can't make us
          // fetch+import from an attacker-controlled origin.
          final url = raw.trim();
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
            // FRONTEND-ONLY LOREBOOK: the lorebook "Download JSON" anchor used
            // to be intercepted here and fetched by native via _importFromUrl.
            // That made the app call BotBooru's bot-gated `/api/` endpoint
            // (403 to the cookie-less client) — REMOVED. The JS hook now
            // fetches the JSON inside the logged-in webview session and posts
            // the text back over EmberDL (PYRELB…). To keep native from
            // EVER fetching that URL, just BLOCK the navigation here and let
            // the hook handle it; we never call _importFromUrl for it.
            if (url.contains('/api/lorebooks/') &&
                url.toLowerCase().contains('download.json')) {
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

  /// Injects a small script that intercepts botbooru's "Download PNG" + lorebook
  /// "Download JSON" behaviour.
  ///
  /// Wave CY.18.260: the character path used to ship the `/download/png/{id}`
  /// URL back so native re-fetched it — but BotBooru now bot-gates that endpoint
  /// (403 to a cookie-less client), causing a stall + the site's own "Failed to
  /// download PNG" alert. The hook now FETCHES the PNG inside the authenticated
  /// webview (`credentials:'include'`) and posts the BYTES (base64) over EmberDL
  /// with a `PYRECARD` prefix — native imports from the decoded bytes and makes
  /// no HTTP request. The legacy `URL.createObjectURL` + `window.fetch`
  /// overrides (which returned `javascript:void(0)` and tripped the site's
  /// updated handler) are GONE — we own the fetch, so they're no longer needed.
  /// The lorebook path is unchanged (it already fetched-in-page → `PYRELB`).
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

          // 1a) LOREBOOK "Download JSON". The real control is an anchor
          //     `<a href="/api/lorebooks/{id}/download.json" download>` (and a
          //     `#download-json-btn` button nearby). Match either.
          //
          //     FRONTEND-ONLY: the app must NEVER call BotBooru's API. The
          //     `/api/lorebooks/.../download.json` endpoint is bot-gated (403
          //     to the app's cookie-less client) and only returns 200 inside a
          //     logged-in browser session. So instead of shipping the URL back
          //     for native to fetch, we fetch it HERE — inside the webview —
          //     with `credentials:'include'` (carrying the user's session
          //     cookies), then post the resulting JSON TEXT back over EmberDL
          //     with a `PYRELB` prefix. Native parses the text directly; it
          //     issues no HTTP request of its own. A control char ()
          //     delimits the prefix so it can never collide with JSON content.
          var lb = url.match(/\/api\/lorebooks\/(\d+)\/download\.json/);
          if (!lb && a.id === 'download-json-btn') {
            var lbHref = '';
            // The button sits next to the real anchor — find it.
            var anchor = document.querySelector(
              'a[href*="/api/lorebooks/"][href*="download.json"]');
            if (anchor) lbHref = anchor.href || '';
            if (lbHref) lb = lbHref.match(
              /\/api\/lorebooks\/(\d+)\/download\.json/);
            if (lb) url = lbHref;
          }
          if (lb) {
            e.preventDefault();
            e.stopPropagation();
            // a.href is already absolute; for the button branch `url` holds
            // the anchor's absolute href. Fall back to building it from origin.
            var abs = url.indexOf('http') === 0
              ? url
              : (location.origin + '/api/lorebooks/' + lb[1] + '/download.json');
            // BotBooru's download JSON has an EMPTY top-level `name`; the
            // real title only lives in the page. Capture it as a name hint:
            // prefer a visible heading, else strip the ' — Botbooru'
            // suffix off the tab title. Native uses it ONLY when the JSON's
            // own name is blank.
            // BotBooru's download JSON has an EMPTY `name`; the title only
            // lives on the page. Capture it robustly (tab title -> og:title ->
            // first real heading). Native uses it ONLY when the JSON name is
            // blank.
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
            fetch(abs, {
              credentials: 'include',
              headers: { 'Accept': 'application/json' }
            })
              .then(function(r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.text();
              })
              .then(function(t) {
                EmberDL.postMessage('PYRELB' + lbName + '' + t);
              })
              .catch(function(err) {
                EmberDL.postMessage(
                  'PYRELBERR' + ((err && err.message) || 'download failed'));
              });
            return;
          }

          // 1b) CHARACTER "Download PNG". Wave CY.18.260: find the numeric
          //     card id from WHATEVER the (possibly-updated) markup exposes —
          //     an href/data-url with `/download/png/<id>`, OR a
          //     data-post-id/data-id/data-character-id, OR (last resort) a
          //     "download png"/"png"-labelled control with a nearby id.
          //     Broadened because the exact new BotBooru markup couldn't be
          //     inspected statically — see __pyreFindCardId.
          var id = __pyreFindCardId(a);
          if (id) {
            e.preventDefault();
            e.stopPropagation();
            // FRONTEND-ONLY: do NOT post the URL for native to re-fetch.
            // BotBooru bot-gates `/download/png/{id}` (403 to a cookie-less
            // client), so a native re-fetch stalls + fails. Fetch the PNG HERE
            // — inside the logged-in webview, with `credentials:'include'` —
            // and post the BYTES (base64) so native imports them directly. A
            // SOH () delimits the base64 from the optional gallery JSON.
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
                    // result is `data:<mime>;base64,<b64>` — keep the b64 tail.
                    var s = String(fr.result || '');
                    var c = s.indexOf(',');
                    resolve(c >= 0 ? s.slice(c + 1) : s);
                  };
                  fr.onerror = function() { reject(new Error('read failed')); };
                  fr.readAsDataURL(blob);
                });
              })
              .then(function(b64) {
                // Scrape the rendered mini-gallery DOM (mobile parity with the
                // desktop readGallery()): the page is fully rendered by the
                // time the user taps Download PNG, so there's no render race.
                var gallery = [];
                try {
                  gallery = Array.prototype.slice.call(
                    document.querySelectorAll('#post-mini-gallery img'))
                    .map(function(i){ return i.getAttribute('src') || ''; })
                    .filter(function(s){ return s.length > 0; });
                } catch (_) {}
                EmberDL.postMessage(
                  'PYRECARD' + b64 + '' + JSON.stringify(gallery));
              })
              .catch(function(err) {
                EmberDL.postMessage(
                  'PYRECARDERR' + ((err && err.message) || 'download failed'));
              });
            return;
          }
        }, true);

        // Wave CY.18.260: locate a BotBooru card id from a clicked element or
        // any ancestor. Tries, in order: a `/download/png/<id>` substring on
        // href/data-url/data-src; a `data-post-id`/`data-id`/`data-character-id`
        // attribute; and finally, only for a control whose label/aria/title/text
        // mentions "download png" or "png", a numeric `data-id`/`data-post-id`
        // on the element or a `[data-post-id]` ancestor. Returns the id string
        // or '' if none found. Best-effort — the exact new markup couldn't be
        // inspected statically, so this casts a wide (but id-anchored) net.
        function __pyreFindCardId(start) {
          var node = start;
          var depth = 0;
          var sawPng = false;
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
              // Confirmed live (2026-06): the button is <button id=
              // "download-png-btn" aria-label="Download character card as PNG">
              // with NO href and NO data id.
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
          // The updated BotBooru markup puts NO id on #download-png-btn — the
          // card id lives ONLY in the page URL (/character/<id>, older /post/<id>).
          // So if the click was on a PNG-download control, take the id from the
          // URL. (Endpoint /download/png/<id> itself is unchanged — confirmed
          // live: click → POST /posts/<id>/track-download + GET /download/png/<id>.)
          if (sawPng) {
            var pm = String(location.pathname)
              .match(/\/(?:character|post)\/(\d+)/);
            if (pm) return pm[1];
          }
          return '';
        }
      })();
    ''');
  }

  Future<void> _importFromUrl(
    String url, {
    List<String> galleryDomSrcs = const [],
  }) async {
    // M-1: re-entrancy guard. `_busy` was SET but never CHECKED, so a
    // double-tap, or a click-hook firing alongside the blob-hook, could stack
    // two concurrent imports of the same card → a DUPLICATE character. Bail if
    // an import is already running; the in-flight one resets `_busy` in its
    // `finally`, so the next user-initiated import works normally.
    if (!canStartDiscoverImport(_busy)) return;
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    // FRONTEND-ONLY LOREBOOK: a pasted BotBooru lorebook page / API URL must
    // NOT be fetched by the app — that endpoint is bot-gated and calling it
    // would violate the "never call BotBooru's API" rule. Detect it and point
    // the user at the in-webview "Download JSON" flow instead of silently
    // failing or hitting the API. (Checked before the busy flag flips so the
    // hint shows immediately.)
    if (isBotbooruLorebookUrl(url)) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Open the lorebook in Discover and tap "Download JSON" to '
            'import it.',
          ),
        ),
      );
      return;
    }
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
        final resp = await fetchCappedNoRedirect(target);
        if (resp.statusCode >= 400) {
          // Wave CY.3: friendly 429/Retry-After/etc. — botbooru's
          // download route is rate-limited and the bare `HTTP 429`
          // we used to throw looked like a hard bug to users.
          throw describeHttpFailure(resp, host: friendlyHostName(target));
        }
        pngBytes = resp.bodyBytes;
      }
      // Wave CY.18.141/142: BotBooru gallery is NOT fetched from their API
      // (owner's request: use our frontend, don't share our API). The Windows
      // webview reads the rendered `#post-mini-gallery img` srcs at import time
      // and passes them as `galleryDomSrcs`; here the shared import core
      // resolves + host-gates them into clean gallery image URLs — but only
      // when the bytes came from BotBooru. Other paths (paste-import, chub,
      // RisuRealm) pass `allowGallery: false`, so no gallery is offered there.
      await _doImportCharacterBytes(
        pngBytes,
        store: store,
        messenger: messenger,
        galleryDomSrcs: galleryDomSrcs,
        allowGallery: resolved?.source == 'botbooru',
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

  /// FRONTEND-ONLY CHARACTER import from BYTES already in hand.
  ///
  /// Wave CY.18.260: the Discover "Download PNG" hook now fetches the card PNG
  /// INSIDE the authenticated webview (carrying the user's cookies) and posts
  /// the raw bytes to native (base64). This is the native entry point for that
  /// flow — it does NO HTTP request of its own (so it can't trip BotBooru's
  /// bot-gated `/download/png` re-fetch / rate-limit, and there is no
  /// cookie-less double-download). [bytes] is the decoded PNG;
  /// [galleryDomSrcs] are the `#post-mini-gallery img` srcs the hook scraped
  /// (always BotBooru-sourced here, so the gallery is offered).
  ///
  /// Owns the `_busy` re-entrancy guard (shared with [_importFromUrl] /
  /// [_importLorebookFromJsonText]) so a stray double-fire can't stack two
  /// imports, then delegates the parse → confirm → save to [_doImportCharacterBytes].
  Future<void> _importBytesAsCharacter(
    Uint8List bytes, {
    List<String> galleryDomSrcs = const [],
  }) async {
    if (!canStartDiscoverImport(_busy)) return;
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _status = 'Importing…';
    });
    try {
      await _doImportCharacterBytes(
        bytes,
        store: store,
        messenger: messenger,
        galleryDomSrcs: galleryDomSrcs,
        // The bytes came straight from the BotBooru webview, so the
        // scraped mini-gallery srcs are trusted-host content — offer them.
        allowGallery: true,
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

  /// Shared import CORE: parse chara-card [bytes] → resolve the BotBooru
  /// mini-gallery (when [allowGallery]) → confirm dialog → handle the embedded
  /// character_book → externalise inline images → add to the library.
  ///
  /// Extracted so BOTH the typed-URL fetch path ([_importFromUrl]) and the
  /// in-webview bytes path ([_importBytesAsCharacter]) run an identical import
  /// once the bytes are in hand. Does NOT manage `_busy` — each caller owns its
  /// own busy guard + try/finally; this method just throws on failure so the
  /// caller's catch surfaces the snackbar.
  Future<void> _doImportCharacterBytes(
    Uint8List bytes, {
    required AppStore store,
    required ScaffoldMessengerState messenger,
    required List<String> galleryDomSrcs,
    required bool allowGallery,
  }) async {
    // Audit 2026-06-04 [import-1-01]: sniff PNG-vs-JSON instead of
    // hard-assuming PNG. A valid `.json` card from an allowlisted file host
    // (catbox / pixeldrain) or a RisuRealm `json-v2` link used to throw
    // "Not a PNG"; `parseCharaCard` routes JSON bytes to the JSON parser.
    final card = parseCharaCard(bytes);
    final character = characterFromCharaCard(card);
    List<String> galleryUrls = const [];
    if (allowGallery && galleryDomSrcs.isNotEmpty) {
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
    // B-2 / H-6: externalise the inline avatar so it persists as a pyre://
    // ref, not inline base64.
    await externalizeCharacterImages(character);
    store.addCharacter(character);
    messenger.showSnackBar(
      SnackBar(content: Text('Imported ${character.name}')),
    );
  }

  /// FRONTEND-ONLY LOREBOOK import. [jsonText] is the raw JSON captured by the
  /// Discover webview's "Download JSON" hook INSIDE the user's authenticated
  /// session (the app must never call BotBooru's API). This method makes NO
  /// HTTP request: it parses the text directly via [parseLorebookImportText]
  /// (which enforces the size cap + rejects non-lorebook shapes), shows the
  /// confirm dialog (lorebook entries are an injection surface), then adds the
  /// book to the library.
  ///
  /// Shares the `_busy` re-entrancy guard with [_importFromUrl] so a stray
  /// double-fire can't stack two imports.
  ///
  /// [nameHint] is the page's lorebook title captured by the webview hook
  /// (BotBooru's download JSON ships an empty top-level `name`). It is threaded
  /// through as the `nameFallback` and used ONLY when the JSON's own name is
  /// blank — a non-empty JSON name always wins.
  Future<void> _importLorebookFromJsonText(
    String jsonText, {
    String? nameHint,
  }) async {
    if (!canStartDiscoverImport(_busy)) return;
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _status = 'Importing lorebook…';
    });
    try {
      final book = parseLorebookImportText(
        jsonText,
        nameFallback: _sanitizeLorebookNameHint(nameHint),
      );
      if (book == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Not a valid lorebook')),
        );
        return;
      }
      if (!mounted) return;
      final ok = await confirmLorebookImport(
        context: context,
        bookName: book.name,
        entryCount: book.entries.length,
      );
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Import cancelled.')),
        );
        return;
      }
      store.addLorebook(book);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            "Imported '${book.name}' — ${book.entries.length} "
            '${book.entries.length == 1 ? "entry" : "entries"}',
          ),
        ),
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
    // M-1: render the busy overlay on the Windows embed too — the import
    // confirm modal + spinner used to be invisible here, so a long
    // download/resolve looked frozen. Mirrors `_buildNativeWebView`.
    return Stack(
      children: [
        DesktopBotbooruWebview(
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
            // BotBooru card can offer its mini-gallery on import. NOTE: this
            // is now the MANUAL "Use this page for import" fallback only —
            // the "Download PNG" button click goes through onImportCardBytes.
            _importFromUrl(url, galleryDomSrcs: galleryDomSrcs);
          },
          // FRONTEND-ONLY CHARACTER: the PNG was fetched inside the webview's
          // logged-in session (cookies) — import from the decoded bytes, no app
          // HTTP request (avoids BotBooru's bot-gated /download/png re-fetch).
          onImportCardBytes: (bytes, galleryDomSrcs) {
            _importBytesAsCharacter(bytes, galleryDomSrcs: galleryDomSrcs);
          },
          onCardError: (_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "Couldn't download the card — try again, or make sure "
                  "you're signed in to BotBooru.",
                ),
              ),
            );
          },
          // FRONTEND-ONLY LOREBOOK: the JSON was fetched inside the webview's
          // logged-in session — parse the TEXT directly, no app HTTP request.
          onImportLorebookJson: _importLorebookFromJsonText,
          onLorebookError: (_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "Couldn't download the lorebook — try again, or make "
                  "sure you're signed in to BotBooru.",
                ),
              ),
            );
          },
        ),
        if (_busy) _busyOverlay(),
      ],
    );
  }

  /// Shared full-screen "working…" overlay shown during an import. Used by both
  /// the mobile native webview and the Windows desktop embed.
  Widget _busyOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: EmberColors.primary),
              const SizedBox(height: 12),
              Text(_status ?? 'Working…',
                  style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
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
        if (_busy) _busyOverlay(),
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
    ctl.dispose(); // H-3: dispose the URL-import controller on dialog close.
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
