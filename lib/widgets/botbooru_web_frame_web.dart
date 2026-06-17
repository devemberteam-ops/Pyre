// Pyre — Web-only BotBooru iframe widget (v2 SECURE).
//
// v2 architecture: the botbooru embed now runs on a SEPARATE origin served by
// the bbx dedicated server (bbxPort ≠ mainPort). The iframe at bbxPort is
// cross-origin with the Pyre web app — botbooru JS cannot read the Pyre app's
// localStorage/bearer (SOP blocks it).
//
// Flow:
//   1. On init: fetch /bbx-info (same-origin) → bbxPort → bbxOrigin.
//   2. If bbxPort is null (public web, no desktop), render _buildWebFallback.
//   3. iframe src = '$bbxOrigin/' (cross-origin). sandbox keeps allow-same-origin
//      because the iframe is its OWN origin (bbxPort) — it can use botbooru's
//      cookies/storage but CANNOT reach the parent's window/localStorage.
//   4. Track current URL via window.onMessage (cross-origin postMessage from the
//      shim injected by rewriteBotbooruHtmlDedicated). Accept ONLY messages where
//      event.origin == bbxOrigin AND type == 'pyre-bbx-loc'.
//   5. "Import this card": map latest href (bbxOriginUrlToBotbooru) → botbooruUrl
//      → hand to onImport. The caller fetches via the bbx CORS endpoint.
//   6. "Home": set iframe.src = '$bbxOrigin/'.
//   7. "Back": postMessage {type:'pyre-bbx-back'} to iframe.contentWindow with
//      targetOrigin = bbxOrigin.
//
// Security:
//   - iframe origin (bbxPort) ≠ Pyre app origin (mainPort): SOP blocks all
//     cross-origin JS access.
//   - We only accept postMessages where event.origin == bbxOrigin (exact match).
//   - The home/back src/postMessage targets are always bbxOrigin, never
//     a user-supplied URL.
//   - "Import this card" hands the URL to the caller; the caller still runs
//     resolveCommunityUrl + confirm-dialog + trusted-host chain.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../services/bbx_utils.dart';
import '../theme.dart';

/// Unique factory name for the platform view registry.
const _kViewType = 'pyre-bbx-frame';

/// Whether the iframe platform view has been registered for this run.
bool _registered = false;

/// The live iframe element — kept so the toolbar can navigate it.
web.HTMLIFrameElement? _iframe;

/// The latest href reported by the bbx iframe via postMessage 'pyre-bbx-loc'.
String? _latestBbxHref;

/// The message listener subscription — cancelled on dispose.
StreamSubscription<web.MessageEvent>? _msgSub;

void _ensureRegistered(String bbxOrigin) {
  if (_registered) return;
  _registered = true;
  _iframe = web.HTMLIFrameElement()
    ..src = '$bbxOrigin/'
    ..style.border = 'none'
    ..style.width = '100%'
    ..style.height = '100%'
    // allow-same-origin: the iframe is on bbxPort (its OWN origin), so
    // it can use botbooru's cookies/storage but still can't reach the
    // parent's window or localStorage (different port = different origin).
    ..setAttribute('sandbox',
        'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox');
  ui_web.platformViewRegistry.registerViewFactory(
    _kViewType,
    (int id) => _iframe!,
  );
}

/// Toggle whether the bbx iframe captures pointer events. Flutter web renders
/// the iframe as a real DOM element that sits ABOVE the Flutter canvas for hit
/// testing, so a Flutter dialog/overlay shown over the iframe LOOKS on top but
/// its buttons never receive clicks (the iframe eats them). Call
/// `setBotbooruFrameInteractive(false)` while a dialog is open so the clicks
/// reach the Flutter overlay, then `(true)` to restore botbooru interaction.
void setBotbooruFrameInteractive(bool interactive) {
  try {
    _iframe?.style.pointerEvents = interactive ? 'auto' : 'none';
  } catch (_) {}
}

/// Fetch /bbx-info from the same-origin main server.
/// Returns the bbxPort as an int, or null on any error.
Future<int?> _fetchBbxPort() async {
  try {
    final resp = await web.window.fetch('/bbx-info'.toJS).toDart;
    // web.Response.text() returns JSPromise<JSString>; .toDart → Future<JSString>.
    // JSString.toDart gives the Dart String.
    final jsText = await resp.text().toDart;
    final text = jsText.toDart;
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    final port = decoded['port'];
    if (port is int) return port;
    if (port is double) return port.toInt();
    return null;
  } catch (_) {
    return null;
  }
}

/// Web implementation of the BotBooru embed: an HTMLIFrameElement pointing at
/// the bbx dedicated origin plus a compact toolbar.
class BotbooruWebFrame extends StatefulWidget {
  /// Called when the user taps "Import this card". Receives the canonical
  /// `https://botbooru.com/...` URL and the [bbxOrigin] string (the cross-
  /// origin endpoint where the caller should fetch the download bytes with
  /// the bbx CORS headers). Will be called with a null botbooruUrl if the
  /// current page is not a recognisable card URL.
  final void Function(String botbooruUrl, String bbxOrigin)? onImport;

  const BotbooruWebFrame({super.key, this.onImport});

  @override
  State<BotbooruWebFrame> createState() => _BotbooruWebFrameState();
}

class _BotbooruWebFrameState extends State<BotbooruWebFrame> {
  bool _loading = true; // true while fetching /bbx-info
  String? _bbxOriginLocal; // null = bbx unavailable → show fallback

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final port = await _fetchBbxPort();
    if (!mounted) return;
    if (port == null) {
      setState(() => _loading = false);
      return;
    }
    final origin = '${Uri.base.scheme}://${Uri.base.host}:$port';
    _bbxOriginLocal = origin;

    // Register the iframe (idempotent).
    _ensureRegistered(origin);

    // If the iframe was already created with the right src, nothing to do.
    // If the widget is rebuilt after a hot-restart (same _registered=true),
    // update the src to the current bbxOrigin.
    final el = _iframe;
    if (el != null && !el.src.startsWith(origin)) {
      el.src = '$origin/';
    }

    // Listen for postMessages from the bbx iframe.
    _msgSub?.cancel();
    _msgSub = web.window.onMessage.listen(_onMessage);

    setState(() => _loading = false);
  }

  void _onMessage(web.MessageEvent event) {
    // Security: only accept messages from the bbx origin.
    final expectedOrigin = _bbxOriginLocal;
    if (expectedOrigin == null) return;
    if (event.origin != expectedOrigin) return;

    // The shim sends JSON strings (JSON.stringify). Convert the JS value to a
    // Dart string via dartify() / toString, then parse as JSON.
    try {
      final raw = event.data.dartify();
      if (raw == null) return;
      final jsonStr = raw is String ? raw : raw.toString();
      final data = jsonDecode(jsonStr) as Map<String, dynamic>?;
      if (data == null) return;
      if (data['type'] != 'pyre-bbx-loc') return;
      final href = data['href'];
      if (href is String && href.isNotEmpty) {
        _latestBbxHref = href;
      }
    } catch (_) {
      // Ignore malformed messages.
    }
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _msgSub = null;
    super.dispose();
  }

  void _goHome() {
    try {
      final el = _iframe;
      final origin = _bbxOriginLocal;
      if (el == null || origin == null) return;
      el.src = '$origin/';
    } catch (_) {}
  }

  void _goBack() {
    try {
      final el = _iframe;
      final origin = _bbxOriginLocal;
      if (el == null || origin == null) return;
      // Send JSON string {type:'pyre-bbx-back'} to the iframe.
      // targetOrigin = bbxOrigin so only the bbx iframe receives it.
      const msg = '{"type":"pyre-bbx-back"}';
      el.contentWindow?.postMessage(
        msg.toJS,
        origin.toJS,
      );
    } catch (_) {}
  }

  void _handleImport() {
    final href = _latestBbxHref;
    final origin = _bbxOriginLocal;
    if (href == null || origin == null) {
      _showHint('Navigate to a character or lorebook page on BotBooru first.');
      return;
    }
    final botbooruUrl = bbxOriginUrlToBotbooru(href, origin);
    if (botbooruUrl == null) {
      _showHint('Open a character or lorebook page on BotBooru first.');
      return;
    }
    widget.onImport?.call(botbooruUrl, origin);
  }

  void _showHint(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_bbxOriginLocal == null) {
      // bbx server unavailable (public web / no desktop) → show fallback.
      return _buildWebFallback(context);
    }
    return Column(
      children: [
        _Toolbar(
          onHome: _goHome,
          onBack: _goBack,
          onImport: widget.onImport != null ? _handleImport : null,
        ),
        const Expanded(
          child: HtmlElementView(viewType: _kViewType),
        ),
      ],
    );
  }

  /// Fallback UI for when the bbx server is unavailable (public web hosting,
  /// no Pyre desktop server). Mirrors the existing _buildWebFallback style.
  Widget _buildWebFallback(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.open_in_new,
              size: 48, color: EmberColors.textMid.withAlpha(128)),
          const SizedBox(height: 16),
          Text(
            'BotBooru embed requires the Pyre desktop app.',
            style: TextStyle(color: EmberColors.textMid),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Open BotBooru externally'),
            onPressed: () {
              try {
                web.window.open('https://botbooru.com/', '_blank');
              } catch (_) {}
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: EmberColors.textMid,
              side: BorderSide(color: EmberColors.stroke),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final VoidCallback onHome;
  final VoidCallback onBack;
  final VoidCallback? onImport;

  const _Toolbar({
    required this.onHome,
    required this.onBack,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        border: Border(
          bottom: BorderSide(color: EmberColors.stroke, width: 1),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.home_outlined, size: 18),
            tooltip: 'Home',
            color: EmberColors.textMid,
            visualDensity: VisualDensity.compact,
            onPressed: onHome,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 18),
            tooltip: 'Back',
            color: EmberColors.textMid,
            visualDensity: VisualDensity.compact,
            onPressed: onBack,
          ),
          const Spacer(),
          OutlinedButton.icon(
            icon: const Icon(Icons.download, size: 14),
            label: const Text('Import this card'),
            onPressed: onImport,
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
              foregroundColor: EmberColors.textMid,
              side: BorderSide(color: EmberColors.stroke),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Open externally'),
            onPressed: () {
              try {
                web.window.open('https://botbooru.com/', '_blank');
              } catch (_) {}
            },
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
              foregroundColor: EmberColors.textMid,
              side: BorderSide(color: EmberColors.stroke),
            ),
          ),
        ],
      ),
    );
  }
}
