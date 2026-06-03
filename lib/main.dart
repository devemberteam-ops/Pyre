import 'dart:io' show Platform, exit;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'services/attachment_store.dart';
import 'services/card_import.dart';
import 'services/desktop_shortcuts.dart';
import 'services/error_log.dart';
import 'services/llm_debug_log.dart';
import 'services/focus_bus.dart';
import 'services/gallery_import.dart';
import 'services/http_errors.dart';
import 'services/lan_client.dart';
import 'services/lorebook_import.dart';
import 'services/png_parser.dart';
import 'services/pyre_server.dart';
import 'services/remote_backend.dart';
import 'services/resolvers.dart';
import 'services/single_instance.dart';
import 'services/sync_engine.dart';
import 'services/store_backend.dart';
import 'services/update_check.dart';
import 'models/models.dart' show UiPrefs;
import 'state/app_store.dart';
import 'theme.dart';
import 'screens/chats_screen.dart';
import 'screens/characters_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/more_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/web_pair_first_screen.dart';
import 'widgets/card_import_confirm.dart';
import 'widgets/command_palette.dart';

/// Global Navigator key — lets the bookmarklet hand-off path show a
/// confirmation dialog before committing an imported card, even though
/// it runs from outside the widget tree.
final GlobalKey<NavigatorState> _rootNavKey = GlobalKey<NavigatorState>();

/// Wave CY.18.46: true when the binary is a Windows / Linux / macOS
/// desktop build. Web is explicitly false (Platform isn't available
/// there anyway). Used to gate windowManager init and any other
/// desktop-only setup.
bool get _isDesktop {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Wave CY.18.46: visual breakpoint that controls "phone-in-window"
/// vs "wide responsive desktop". Below this width, even with the
/// `desktopWideLayout` setting on, we force phone mode (the wide
/// layout literally doesn't fit). Above, the user's preference wins.
const double _kWideLayoutThreshold = 900;

/// Wave CY.18.46: max content width in wide mode. Prevents chat /
/// character lists from stretching absurdly on a 4K monitor where
/// long reading lines become unreadable.
const double _kWideContentMaxWidth = 1100;

/// Wave CY.18.46: content width in phone-in-window mode. The OG
/// portrait-mobile feel scaled to desktop without redesigning a
/// single widget — chat, character list, more screen all look
/// identical to the Android build, just centered in a 480px column.
const double _kPhoneContentMaxWidth = 480;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Wave CY.18.77: single-instance check on desktop. The close-to-tray
  // behavior (Wave 55) means clicking X hides the window — but Windows
  // happily lets you launch pyre.exe again from the shortcut, spawning
  // a SECOND process unaware of the first. Zombies pile up, each
  // racing to write the same JSON state file. This guard bails out
  // secondary launches BEFORE any IO touches state. The primary
  // catches the ping and pops its window to the front.
  //
  // Mobile / web skip this — Android single-tasks by default, web tabs
  // are intentionally independent.
  if (_isDesktop) {
    final iAmPrimary = await SingleInstance.acquire(
      onWake: () async {
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (e) {
          // Window manager not yet initialised when the ping arrives
          // early in boot — onWake will re-fire if the user clicks
          // the launcher again later (after boot completes).
        }
      },
    );
    if (!iAmPrimary) {
      // A primary Pyre is already running; we sent it a wake ping.
      // Exit immediately so we don't double-init AppStore, double-
      // start the server, double-listen window events, etc.
      exit(0);
    }
  }

  // Wave CY.18.45: install global error handlers BEFORE anything else
  // can crash. Captures FlutterError + PlatformDispatcher.onError into
  // a local circular JSONL log the user can export via Storage screen.
  // 100% on-device — no telemetry, no network. The privacy policy's
  // "no crash reports" promise stays accurate because nothing leaves
  // the device unless the user manually exports it.
  ErrorLog.install();
  // Wave CY.18.64: warm the attachment-store dir cache so AvatarBubble
  // (and any other widget that calls AttachmentStore.fileForSync) can
  // resolve `pyre://attachment/...` URLs synchronously during build()
  // without re-awaiting the path each time. No-op on web.
  await AttachmentStore.warmUp();
  // Wave CY.18.69: hydrate the paired-server state (host/port from
  // SharedPreferences, bearer token from OS keystore) so the LAN
  // status indicator + sync engine know what to talk to from the
  // first frame. No-op when nothing is paired yet.
  await LanClient.instance.load();
  // Wave CY.18.214: load the opt-in LLM diagnostics-log flag from
  // SharedPreferences so the chat_api hook + the Storage toggle reflect
  // the persisted state from the first frame. Default OFF — until the
  // user flips it in Storage → Developer, every LLM call is a strict
  // no-op past the `enabled` guard (no record built, nothing written).
  await LlmDebugLog.instance.init();
  // Wave CY.18.71 + .81: web/PWA branching. Web has no useful local
  // persistence and no way to be its own LAN server. Two web paths:
  //   - Already paired (this browser has bearer in localStorage):
  //     boot the full app immediately, return.
  //   - Not paired: show the pair splash. On successful pair, the
  //     splash calls _bootWebApp() which calls runApp(PyreApp(...))
  //     and the splash is replaced in-place — no page reload, no
  //     "click to continue" intermediate step.
  if (kIsWeb) {
    if (!LanClient.instance.isPaired) {
      runApp(WebPairFirstApp(onPaired: _bootWebApp));
      return;
    }
    await _bootWebApp();
    return;
  }
  // Wave CY.18.46: desktop window init. Sets a sane initial size + min
  // size + window title so the user doesn't see a 200x200 tiny square
  // on first launch. No-op on Android / iOS / web (where windows are
  // managed by the OS / browser). The min size keeps the responsive
  // layout above the threshold where things would visually break.
  //
  // Wave CY.18.48: window state persist. Before showing the window we
  // load the AppStore (so we have access to UiPrefs.windowBounds from
  // last session), then size + position the window from the saved
  // bounds. Falls back to centered 1200x800 on first launch. A
  // WindowListener registered after .show() saves bounds on every
  // resize/move with debounce so the next launch picks up where the
  // user left off.
  // Native build always uses LocalBackend (the on-disk JSON store).
  // Web took the early-return branch above with RemoteBackend.
  final store = AppStore(storage: LocalBackend());
  await store.load();
  // Wave CY.18.70: install the sync loop after the store is loaded so
  // the engine sees real data when it kicks its first tick. Wires
  // AppLifecycleState observer + 30s poll timer (only while paired +
  // foreground). Listens to LanClient.changes so a fresh pair triggers
  // an immediate first tick. Desktop runs this too — if you ever pair
  // two desktops the second one syncs as a client. No behavioural
  // impact otherwise (LanClient.isPaired stays false until paired).
  SyncEngine.instance.install(store);
  if (_isDesktop) {
    await windowManager.ensureInitialized();
    final saved = store.uiPrefs.windowBounds;
    final initialSize = (saved != null && saved.length == 4)
        ? Size(saved[2], saved[3])
        : const Size(1200, 800);
    final initialPos = (saved != null && saved.length == 4)
        ? Offset(saved[0], saved[1])
        : null; // null → windowManager centers on screen
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: initialSize,
        minimumSize: const Size(720, 600),
        title: 'Pyre',
        titleBarStyle: TitleBarStyle.normal,
        center: initialPos == null, // center only when no saved pos
      ),
      () async {
        if (initialPos != null) {
          await windowManager.setPosition(initialPos);
        }
        await windowManager.show();
        await windowManager.focus();
      },
    );
    // Wire the save-on-change listener AFTER the window is visible
    // (avoids saving the initial-setup transients).
    windowManager.addListener(_WindowBoundsSaver(store));
    // Wave CY.18.55: system tray + close-to-tray. Intercept the
    // window close button so X minimises to tray instead of killing
    // the app (Discord / Steam / etc convention). The tray icon
    // gives Show / Quit. setPreventClose tells windowManager NOT to
    // shut down on close — the listener decides what to do instead.
    //
    // Wave CY.18.59: only install the close-to-tray behaviour if
    // tray init ACTUALLY succeeded. Pre-Wave 59 the order was
    //   setPreventClose(true) → install() → addListener
    // which meant a failed install (Linux session with no tray
    // daemon, locked-down Windows, etc.) left preventClose=true with
    // a listener that hides the window — but no tray icon to
    // restore it. User saw "X closes the window and it never comes
    // back." Now: install returns bool; on failure we leave the
    // default OS close-kills-app behaviour intact. Worst case the
    // user loses the close-to-tray nicety; best case nothing
    // changes. Either way, the window is always restorable.
    final trayOk = await _SystemTray.install();
    if (trayOk) {
      await windowManager.setPreventClose(true);
      windowManager.addListener(_SystemTray.instance);
    }
    // Wave CY.18.68: auto-start the LAN server when the user enabled
    // it last session. Fire-and-forget — a bind failure (port in use,
    // permission denied) gets swallowed; the user opens Network
    // settings and sees the toggle still ON but the status missing,
    // then they bounce it or change the port. This matches Discord /
    // Steam / etc. — services that the user opted in to come back up
    // on their own.
    if (store.uiPrefs.lanServerEnabled) {
      try {
        await PyreServer.instance.start(
          port: store.uiPrefs.lanServerPort,
          bind: store.uiPrefs.lanBindMode == 'localhost'
              ? BindMode.localhostOnly
              : BindMode.entireLan,
          store: store,
        );
      } catch (e) {
        // Server didn't come up; user will notice in the UI. No
        // popup — restarts that fail because the port is held by a
        // leftover process from the previous run shouldn't block the
        // first frame.
      }
    }
  }
  // Hand-off from the HTML prototype's bookmarklet: a `?import=<url>` query
  // parameter triggers an immediate background card import on web. Native
  // builds ignore this (they get downloads via the in-app Discover webview).
  if (kIsWeb) {
    _maybeHandleImportParam(store);
  }
  // Wave CY.18.45: scheduled non-blocking update probe. Fires once per
  // app start AFTER runApp so it never holds the first frame back. The
  // probe itself is silent on failure — if there's no network, no
  // repo, no latest.json, the user sees nothing. When a newer version
  // IS published, the user gets a one-line snackbar with a "View"
  // action that opens the release page in their browser.
  _scheduleUpdateCheck();
  runApp(PyreApp(store: store));
}

/// Wave CY.18.81: web-only boot path. Used by main() when the page
/// already has a paired LanClient (re-visit), AND by WebPairFirstApp
/// after a fresh pair completes (so the splash transitions directly
/// into the full UI without a page reload). Idempotent on the runApp
/// call — Flutter happily replaces the root widget when called twice.
Future<void> _bootWebApp() async {
  final store = AppStore(storage: RemoteBackend());
  await store.load();
  SyncEngine.instance.install(store);
  runApp(PyreApp(store: store));
}

Future<void> _scheduleUpdateCheck() async {
  // Small delay so we don't compete with the first frame's network
  // budget (chub bookmarklet handoff, vision provider model probe,
  // etc.). 4s is conservative — by then the UI is steady.
  await Future<void>.delayed(const Duration(seconds: 4));
  final info = await checkForUpdate();
  if (info == null) return;
  final ctx = await _waitForNavContext(
      timeout: const Duration(seconds: 8));
  if (ctx == null || !ctx.mounted) return;
  final messenger = ScaffoldMessenger.of(ctx);
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        'Pyre ${info.latestVersion} is out'
        '${info.notes.isNotEmpty ? " — ${info.notes}" : ""}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      duration: const Duration(seconds: 10),
      behavior: SnackBarBehavior.floating,
      action: info.url.isEmpty
          ? null
          : SnackBarAction(
              label: 'View',
              onPressed: () async {
                final uri = Uri.tryParse(info.url);
                if (uri == null) return;
                try {
                  await launchUrl(uri,
                      mode: LaunchMode.externalApplication);
                } catch (_) {/* best-effort */}
              },
            ),
    ),
  );
}

Future<void> _maybeHandleImportParam(AppStore store) async {
  try {
    final uri = Uri.base;
    final import = uri.queryParameters['import'];
    if (import == null || import.isEmpty) return;
    // Strip the query so a reload doesn't re-import.
    final clean = uri.replace(queryParameters: const {});
    // Best-effort history rewrite via the only safe path on Flutter Web
    // (using SystemNavigator would close the tab) — let the app itself
    // hold the cleaned URI for the next nav.
    _scheduleImport(store, import, clean);
  } catch (_) {/* ignore — handoff is best effort */}
}

/// Trusted hosts for the `?import=URL` web hand-off. Anyone with a link
/// to your tab can trigger this on page load — accepting arbitrary hosts
/// would let an attacker forge a link that makes Pyre fetch from
/// (and potentially leak into) any URL of their choice. Limit to the
/// community sites the bookmarklet was designed for.
const _trustedImportHosts = <String>{
  'botbooru.com',
  'www.botbooru.com',
  'cdn.botbooru.com',
  'chub.ai',
  'www.chub.ai',
  'avatars.chub.io',
  'avatars.charhub.io',
  'characterhub.org',
  // RisuRealm: page and download API share this host, so a resolved
  // `/api/v1/download/png-v2/{id}` URL passes the trusted-host check.
  'realm.risuai.net',
  'www.realm.risuai.net',
  // Common file-hosts for bare chara_card PNG/JSON (catbox, pixeldrain).
  // Shared with the resolver + Discover allowlist. The `?import=` query
  // hand-off is attacker-influenceable, so this stays strictly
  // allowlist-only — the typed "Import character" dialog is the path that
  // additionally allows arbitrary *public* hosts via isPublicHost().
  ...kCardFileHostAllowlist,
};

void _scheduleImport(AppStore store, String input, Uri cleanedHomeUri) {
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      // Host check on the URL the user (or attacker-crafted query string)
      // handed us — BEFORE any http.get fires.
      Uri parsed;
      try {
        parsed = Uri.parse(input);
      } catch (_) {
        return;
      }
      if (parsed.scheme != 'https' ||
          !_trustedImportHosts.contains(parsed.host.toLowerCase())) {
        return;
      }
      final resolved = await resolveCommunityUrl(input);
      // Wave CT: chub.ai's resolver fetches the PNG via POST and hands
      // the bytes back inline — reuse them rather than doing another GET
      // (which the chub endpoint refuses). For everything else, GET the
      // resolved URL under the allowlist as before.
      final Uint8List pngBytes;
      if (resolved?.bytes != null) {
        pngBytes = resolved!.bytes!;
      } else {
        final target = resolved?.pngUrl ?? parsed;
        if (target.scheme != 'https' ||
            !_trustedImportHosts.contains(target.host.toLowerCase())) {
          return;
        }
        // Disable redirects + cap the body: a 3xx from an allowlisted
        // host could bounce us to an internal address (limited SSRF),
        // and an unbounded body is an OOM vector. _fetchCardCapped
        // throws on either; the surrounding catch surfaces a SnackBar
        // / bails without importing.
        final resp = await _fetchCardCapped(target);
        if (resp.statusCode >= 400) {
          // Wave CY.3: previously bailed silently on any error. For
          // 429/503/etc. the user has no idea anything happened —
          // they tapped the bookmarklet, the app blinked, nothing
          // imported. Wait for the Navigator and surface a SnackBar
          // with a friendly explanation (rate-limit / not-found /
          // generic HTTP code).
          final msg = describeHttpFailure(resp,
              host: friendlyHostName(target));
          final ctx = await _waitForNavContext();
          if (ctx != null && ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(
                content: Text(msg),
                duration: const Duration(seconds: 5),
              ),
            );
          }
          return;
        }
        pngBytes = resp.bodyBytes;
      }
      final card = parseCharaCardPng(pngBytes);
      final character = characterFromCharaCard(card);
      // Wave CY.1: even the bookmarklet handoff now confirms before
      // committing. The Navigator key may not be ready on the very
      // first frame, so we wait up to ~3s for it. If we never get a
      // context we BAIL (don't silently add) — letting an attacker-
      // crafted ?import= URL paste a card without consent is exactly
      // the prompt-injection vector confirmCardImport exists to stop.
      // Wave CY.18.141: BotBooru gallery auto-import REMOVED. Per the site
      // owner's request ("don't go around sharing our API, use our frontend")
      // Pyre no longer calls BotBooru's backend. This bookmarklet / ?import=
      // path has no live frontend to read, so it offers no gallery. The
      // gallery is read from the rendered page only inside the Discover webview
      // (Wave 142) or added by hand in the gallery editor.
      const List<String> galleryUrls = [];
      final ctx = await _waitForNavContext();
      if (ctx == null || !ctx.mounted) return;
      final choice = await confirmCardImport(
        ctx,
        character,
        galleryCount: galleryUrls.length,
      );
      if (!choice.import) return;
      if (choice.withGallery) {
        character.gallery = await downloadGalleryImages(galleryUrls);
      }
      // Wave CA: auto-extract embedded character_book — silently
      // extracting it as a visible Lorebook the user can manage later
      // is better than dropping it.
      final book = extractCharacterBook(card.card);
      if (book != null &&
          (book['entries'] is List) &&
          (book['entries'] as List).isNotEmpty) {
        final lorebook = lorebookFromCharacterBook(
          book,
          hidden: false,
          nameFallback: '${character.name} world',
        );
        store.addLorebook(lorebook);
        character.lorebookIds.add(lorebook.id);
      }
      store.addCharacter(character);
      store.setActiveTab('characters');
    } catch (_) {/* swallow — UI still works */}
  });
}

/// Hard cap on a downloaded chara-card PNG (OOM guard). Mirrors the
/// 50 MB backup-import cap; a real card is far smaller.
const int _kMaxImportCardBytes = 25 * 1024 * 1024; // 25 MB

/// GET [target] with redirects DISABLED and the body capped at
/// [_kMaxImportCardBytes]. A 3xx would let an allowlisted host bounce
/// the request to an arbitrary address (limited SSRF), so we throw
/// instead of following it; an oversized body is also rejected.
/// Returns an [http.Response] so callers reuse `statusCode`/`bodyBytes`.
Future<http.Response> _fetchCardCapped(Uri target) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', target)..followRedirects = false;
    final streamed = await client.send(request);
    if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
      throw "Couldn't import — the link redirected to another address.";
    }
    final declared = streamed.contentLength;
    if (declared != null && declared > _kMaxImportCardBytes) {
      throw "Couldn't import — file is too large.";
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > _kMaxImportCardBytes) {
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

/// Poll the global Navigator key until a BuildContext is available, then
/// hand it back. Bookmarklet hand-off races the first frame, so we
/// can't assume the Navigator is mounted yet. Bail after ~3s rather than
/// pinning the future forever.
Future<BuildContext?> _waitForNavContext({
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final ctx = _rootNavKey.currentContext;
    if (ctx != null && ctx.mounted) return ctx;
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  return _rootNavKey.currentContext;
}

class PyreApp extends StatefulWidget {
  final AppStore store;
  const PyreApp({super.key, required this.store});

  @override
  State<PyreApp> createState() => _PyreAppState();
}

class _PyreAppState extends State<PyreApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    // Flush any pending debounced save before this binding tears down.
    widget.store.flushPersist();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS can kill the process at any moment after we leave the
    // foreground. Force the debounced persist to flush NOW so the last
    // few hundred ms of state aren't lost on a cold kill.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      widget.store.flushPersist();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppStore>.value(
      value: widget.store,
      child: MaterialApp(
        title: 'Pyre',
        debugShowCheckedModeBanner: false,
        theme: emberTheme(),
        navigatorKey: _rootNavKey,
        // Wave CY.18.94: native desktop apps let users drag-select
        // text anywhere — character descriptions, error messages,
        // help text, links, anything. Flutter's default Text widget
        // is non-selectable; SelectionArea fixes that for an entire
        // subtree at once. We only enable it on desktop because on
        // touch platforms the long-press-to-select gesture conflicts
        // with our existing long-press menus (message actions,
        // character list quick actions etc). SelectableText nodes
        // already inside the tree (chat bubbles from Wave Q) are
        // documented to coexist with SelectionArea — the inner widget
        // handles selection within its own bounds.
        builder: (context, child) {
          if (child == null) return const SizedBox.shrink();
          // Pyre 1.1 (F5): apply the global UI text-scale ABOVE the
          // whole navigation/screen tree so every screen inherits it,
          // and rebuild whenever the user moves the slider. _UiScaleWrap
          // reads `uiScale` reactively from the AppStore and composes it
          // with the ambient (OS accessibility) text scale.
          Widget content = _UiScaleWrap(child: child);
          if (_isDesktop) {
            content = SelectionArea(child: content);
          }
          return content;
        },
        home: const RootShell(),
      ),
    );
  }
}

/// Pyre 1.1 (F5): applies the global UI text-scale to the whole app.
///
/// Sits ABOVE the navigation/screen tree (inside MaterialApp.builder), so
/// every screen inherits the scaled MediaQuery. It watches `uiScale` from
/// the AppStore reactively, so moving the slider live-updates the entire
/// app. The user's choice is COMPOSED with — not allowed to discard — the
/// OS accessibility text scale: we take whatever `textScaler` the ambient
/// MediaQuery already provides (which already reflects the device's
/// font-size setting), multiply it by `uiScale`, and clamp the final
/// factor into the supported range. At `uiScale == 1.0` the factor is the
/// ambient scaler unchanged, so rendering is byte-identical to before this
/// feature existed.
class _UiScaleWrap extends StatelessWidget {
  final Widget child;
  const _UiScaleWrap({required this.child});

  @override
  Widget build(BuildContext context) {
    // Reactive read: a notifyListeners() from setUiScale rebuilds this and
    // re-applies the new factor across the whole subtree.
    final scale = context.select<AppStore, double>(
      (s) => s.uiPrefs.clampedUiScale,
    );
    final media = MediaQuery.of(context);
    // At 1.0 we touch nothing — the ambient textScaler (already reflecting
    // the OS font-size setting) passes through unchanged, so the default
    // renders exactly as it did before F5. When the user moves the slider,
    // multiply on top of the OS scaler and clamp the resulting factor.
    if (scale == 1.0) return child;
    final scaled = _MultipliedTextScaler(media.textScaler, scale).clamp(
      minScaleFactor: UiPrefs.kUiScaleMin,
      maxScaleFactor: UiPrefs.kUiScaleMax,
    );
    return MediaQuery(
      data: media.copyWith(textScaler: scaled),
      child: child,
    );
  }
}

/// Wraps an existing [TextScaler] and multiplies its result by [factor].
/// Used to COMPOSE the user's UI-scale slider with the OS accessibility
/// text scale instead of overwriting it (an OS large-text user keeps their
/// bump and gets the app slider on top).
class _MultipliedTextScaler extends TextScaler {
  final TextScaler _base;
  final double _factor;
  const _MultipliedTextScaler(this._base, this._factor);

  @override
  double scale(double fontSize) => _base.scale(fontSize) * _factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => _base.textScaleFactor * _factor;
}

/// Wave CY.18.159: F11 fullscreen toggle (desktop). Best-effort — swallows
/// errors if the window manager isn't ready yet (very early boot).
Future<void> _toggleFullScreen() async {
  try {
    final isFull = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFull);
  } catch (_) {}
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  static const _tabOrder = ['chats', 'characters', 'discover', 'more'];

  // Wave CY.18.150: stable identity for the 4-tab IndexedStack. When the
  // Discover webview flips `wantsFullWidthContent`, the shell rebuilds the
  // content area with a DIFFERENT wrapper (bare stack vs Center>ConstrainedBox,
  // or Row+Spacer vs bare) — a structural change that would otherwise discard
  // the IndexedStack's ENTIRE State subtree, resetting DiscoverScreen's
  // `_showWebview` back to false. That was the "have to press Open BotBooru
  // twice" bug: tap 1 set _showWebview=true but the same-frame
  // setWantsFullWidthContent(true) reparented the stack and wiped it; tap 2
  // stuck only because wantsFull no longer changed. A GlobalKey moves the same
  // element/State to the new position instead of rebuilding it, so the webview
  // opens on the FIRST tap. (Bonus: window-resize across the rail threshold no
  // longer resets in-tab state either.) Only one layout branch renders per
  // build, so this single key is never duplicated in the tree.
  final GlobalKey _contentStackKey = GlobalKey();

  int _indexFromPref(String pref) {
    final i = _tabOrder.indexOf(pref);
    return i < 0 ? 1 : i;
  }

  @override
  void initState() {
    super.initState();
    // First-run guard. Schedule onboarding for the first frame after build
    // when there's nothing configured yet — a true cold-start state. We
    // can't push during initState because there's no Navigator yet.
    //
    // Wave CY.18.39: gate on `seenOnboarding` instead of just
    // `providers.isEmpty`. Pre-Wave a user who tapped Skip without
    // configuring saw onboarding on every cold start — annoying. Now
    // the welcome screen shows once; subsequent launches drop straight
    // into the app (chat screen's own empty-state CTA points users to
    // More → API Connections if they still haven't added a provider).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<AppStore>();
      if (!store.seenOnboarding && store.providers.isEmpty) {
        Navigator.of(context).push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const OnboardingScreen(),
        ));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final index = _indexFromPref(store.uiPrefs.activeTab);

    // Wave CY.18.53: global desktop shortcuts. `Ctrl+,` (or `Cmd+,`
    // on macOS — Flutter's SingleActivator handles the platform
    // remap automatically when `meta` is requested) jumps to the
    // More tab, matching the universal "Preferences" convention.
    // Wraps the rest of the shell in CallbackShortcuts on desktop;
    // on mobile this is an empty pass-through (touch users don't
    // expect / can't trigger keyboard shortcuts).
    //
    // Wave CY.18.57:
    //   Ctrl+N → jump to Characters tab (the entry point for starting
    //     a new chat — pick a character → tap → fresh chat).
    //   Ctrl+K → open a "command palette" modal that lists every
    //     desktop shortcut and lets the user execute any of them by
    //     click as well as by key. Doubles as discovery (the user
    //     never has to wonder "what shortcuts does Pyre have"). The
    //     palette itself is dismissable with Esc (Flutter's default
    //     Navigator behavior on desktop), so no separate Esc binding
    //     needed.
    // Wave CY.18.90: shortcuts are now user-remappable. Build the
    // activator → callback map from the live UiPrefs at every render
    // so a remap from the Desktop Shortcuts screen takes effect
    // without a restart. Each callback below is keyed by a stable
    // action id (declared in desktop_shortcuts.dart); the binding
    // resolved by effectiveBinding() is either the user's override
    // or the factory default. Skipped silently when the persisted
    // keyId fails to resolve — guards against schema drift.
    final Map<String, VoidCallback> actionCallbacks = {
      ShortcutAction.openSettings: () => store.setActiveTab('more'),
      ShortcutAction.newChat: () => store.setActiveTab('characters'),
      ShortcutAction.commandPalette: () {
        final nav = _rootNavKey.currentState;
        if (nav == null) return;
        showCommandPalette(nav.context, store);
      },
      // Wave CY.18.61: Ctrl+F → Characters tab + focus its search
      // field. If pressed while already on Characters the tab-switch
      // is a no-op and we go straight to the focus call. The
      // post-frame callback is necessary on the cross-tab case so
      // the Characters screen has time to (re)build its TextField
      // and register its FocusNode into the bus.
      ShortcutAction.searchCharacters: () {
        store.setActiveTab('characters');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          FocusBus.focusCharactersSearch();
        });
      },
    };

    final Map<ShortcutActivator, VoidCallback> globalShortcuts = _isDesktop
        ? () {
            final out = <ShortcutActivator, VoidCallback>{};
            for (final actionId in ShortcutAction.all) {
              final binding = effectiveBinding(actionId, store.uiPrefs);
              final activator = binding.toActivator();
              final cb = actionCallbacks[actionId];
              if (activator != null && cb != null) {
                out[activator] = cb;
              }
            }
            // Wave CY.18.159: F11 toggles fullscreen on desktop — a fixed,
            // conventional binding (not part of the remappable ShortcutAction
            // set), so it's added directly here.
            out[const SingleActivator(LogicalKeyboardKey.f11)] =
                _toggleFullScreen;
            return out;
          }()
        : const <ShortcutActivator, VoidCallback>{};

    const screens = <Widget>[
      ChatsScreen(),
      CharactersScreen(),
      DiscoverScreen(),
      MoreScreen(),
    ];
    const labels = ['Chats', 'Characters', 'Discover', 'More'];
    const icons = [
      Icons.chat_bubble_outline,
      Icons.people_outline,
      Icons.explore_outlined,
      Icons.more_horiz,
    ];

    // Wave CY.18.46: layout decision.
    //   1. Mobile (Android/iOS) → always bottom nav at full width. The
    //      "wide" mode setting only applies to desktop.
    //   2. Desktop with `desktopWideLayout=false` (default) → "phone-
    //      in-a-window": same bottom nav, content constrained to
    //      ~480px, centered. Identical to Android visually.
    //   3. Desktop with `desktopWideLayout=true` AND window wide
    //      enough → NavigationRail on the left, content stretches
    //      to 1100px max.
    //   4. Desktop with the toggle on but a narrow window (user
    //      dragged the window small) → falls back to bottom nav so
    //      the rail doesn't crowd out content. The toggle is
    //      preserved; expanding the window restores wide mode.
    final width = MediaQuery.of(context).size.width;
    final useWideRail = _isDesktop &&
        store.uiPrefs.desktopWideLayout &&
        width >= _kWideLayoutThreshold;

    if (useWideRail) {
      return CallbackShortcuts(
        bindings: globalShortcuts,
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) =>
                      store.setActiveTab(_tabOrder[i]),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationRailDestination(
                        icon: Icon(icons[i]),
                        label: Text(labels[i]),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                // Wave CY.18.98: bypass the 1100px content cap when
                // the active tab has signalled "I need the full
                // width". Currently used by the Discover Windows
                // webview embed; any future surface that needs the
                // whole canvas (a chat tree fullscreen, a big diff
                // viewer) flips the same flag.
                Expanded(
                  child: () {
                    final wantsFull = store.wantsFullWidthContent &&
                        store.uiPrefs.activeTab == 'discover';
                    final stack = IndexedStack(
                        key: _contentStackKey,
                        index: index,
                        children: screens);
                    if (wantsFull) return stack;
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            maxWidth: _kWideContentMaxWidth),
                        child: stack,
                      ),
                    );
                  }(),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Phone layout: bottom nav, content centered + capped on desktop
    // (Android / iOS / narrow desktop window all share this branch).
    //
    // Wave CY.18.46: desktop uses `Row` with `Spacer`s to constrain ONLY
    // the horizontal axis — previous `Center` wrapper was constraining
    // BOTH axes, which made the IndexedStack vertically-center its
    // empty-state content AND pushed the bottom nav out of position.
    // `Row` with `Spacer` keeps the column full-height; the inner
    // `SizedBox(width: …)` caps width without touching height.
    final navBar = NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (i) => store.setActiveTab(_tabOrder[i]),
      destinations: [
        for (var i = 0; i < labels.length; i++)
          NavigationDestination(icon: Icon(icons[i]), label: labels[i]),
      ],
    );
    final indexedScreens = IndexedStack(
        key: _contentStackKey, index: index, children: screens);
    // Wave CY.18.98: same full-width override for the phone-in-window
    // desktop layout. Without this branch, a Windows user with
    // desktopWideLayout=false would still see the embed pinned to
    // 480px in the centre with empty bands either side.
    final wantsFull = store.wantsFullWidthContent &&
        store.uiPrefs.activeTab == 'discover';
    final scaffold = Scaffold(
      body: _isDesktop
          ? (wantsFull
              ? indexedScreens
              : Row(
                  children: [
                    const Spacer(),
                    SizedBox(
                        width: _kPhoneContentMaxWidth,
                        child: indexedScreens),
                    const Spacer(),
                  ],
                ))
          : indexedScreens,
      bottomNavigationBar: _isDesktop
          ? Row(
              children: [
                const Spacer(),
                SizedBox(
                    width: _kPhoneContentMaxWidth, child: navBar),
                const Spacer(),
              ],
            )
          : navBar,
    );
    // Wave CY.18.53: install desktop shortcuts at the shell. Empty
    // map on mobile so this is a zero-cost pass-through.
    return CallbackShortcuts(
      bindings: globalShortcuts,
      child: Focus(autofocus: true, child: scaffold),
    );
  }
}

/// Wave CY.18.48: window-manager listener that saves window bounds
/// (x, y, width, height) to AppStore.uiPrefs whenever the user
/// resizes or moves the window. The save itself is debounced via
/// AppStore.persistOnly so we don't thrash disk on every pixel of a
/// drag; the listener fires hundreds of times during a resize and
/// they all collapse into a single write at the tail.
///
/// Doesn't fire notifyListeners — window-bounds changes have no UI
/// consequence (the OS already redrew). Only the next-launch path
/// reads these.
class _WindowBoundsSaver extends WindowListener {
  final AppStore store;
  _WindowBoundsSaver(this.store);

  Future<void> _capture() async {
    try {
      final bounds = await windowManager.getBounds();
      store.setWindowBounds([
        bounds.left,
        bounds.top,
        bounds.width,
        bounds.height,
      ]);
    } catch (_) {
      // windowManager throws on some platforms / states (e.g. window
      // not yet ready, plugin still initializing). Persistence is
      // best-effort — the next move/resize will retry.
    }
  }

  @override
  void onWindowResize() => _capture();

  @override
  void onWindowMove() => _capture();
}

/// Wave CY.18.55: system tray + close-to-tray controller. Singleton so
/// the WindowListener (close intercept) and TrayListener (menu clicks)
/// share state. On the first close attempt the window hides into the
/// tray rather than killing the process; user reopens via tray icon
/// click or Show menu item. "Quit" is the only path that actually
/// shuts down — explicit user intent required, matches Discord/Steam.
class _SystemTray extends WindowListener with tray.TrayListener {
  _SystemTray._();
  static final _SystemTray instance = _SystemTray._();

  /// Wave CY.18.59: returns true on success, false if anything in the
  /// install sequence threw. Caller gates the close-to-tray
  /// behaviour on this — if tray init failed, the OS close button
  /// stays as kill-the-app instead of hiding-with-no-restore-path.
  static Future<bool> install() async {
    // Tray icon = same .ico used by the .exe (rebrand wave 47 wired
    // it through flutter_launcher_icons). We point at the runtime
    // copy under the build folder; tray_manager accepts either an
    // asset path or a file path resolved relative to the exe.
    try {
      // Wave CY.18.208: the tray icon must be a real .ico on Windows —
      // tray_manager renders a PNG as a BLANK tray icon there. We bundle
      // the same Pyre-brand .ico the taskbar/.exe use (copied to
      // assets/icon/app_icon.ico). macOS/Linux tray backends accept PNG,
      // so they keep the existing assets/icon/icon.png.
      final iconAsset = Platform.isWindows
          ? 'assets/icon/app_icon.ico'
          : 'assets/icon/icon.png';
      await tray.trayManager.setIcon(iconAsset, isTemplate: false);
      await tray.trayManager.setToolTip('Pyre');
      await tray.trayManager.setContextMenu(tray.Menu(items: [
        tray.MenuItem(key: 'show', label: 'Show Pyre'),
        tray.MenuItem.separator(),
        tray.MenuItem(key: 'quit', label: 'Quit'),
      ]));
      tray.trayManager.addListener(instance);
      return true;
    } catch (e) {
      // Tray init can fail on Linux without a system tray daemon
      // (e.g. minimal Wayland sessions). Caller will skip
      // setPreventClose so the user can still close the window
      // normally. Better than a silently-uncloseable app.
      debugPrint('[_SystemTray] install failed: $e');
      return false;
    }
  }

  @override
  void onWindowClose() async {
    // Close button → hide window, keep process alive. The tray icon
    // is the only way back; if the user closed the app entirely
    // (Quit menu / Alt+F4 with Shift?), `onTrayMenuItemClick('quit')`
    // is the explicit path that calls `destroy`.
    await windowManager.hide();
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() {
    // Single click on tray icon = restore. Standard Windows tray UX.
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    tray.trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(tray.MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await _showWindow();
        break;
      case 'quit':
        // Explicit quit — actually shut down. windowManager.destroy()
        // bypasses the preventClose hook.
        await tray.trayManager.destroy();
        await windowManager.destroy();
        break;
    }
  }
}

// Wave CY.18.58: _CommandPaletteDialog moved to widgets/command_palette.dart
// so the More screen can also open it without dragging a `_private` class
// out of main.dart.
