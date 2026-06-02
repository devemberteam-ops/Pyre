// Wave CY.18.71: web/PWA pair-first splash.
//
// Shown ONLY on web before any AppStore exists. The web build is a
// hard thin client — it has no useful local persistence beyond a
// tiny prefs cache — so until the user pairs to a desktop running
// Pyre LAN server, there's literally nothing to show. This screen
// blocks app boot, walks them through manual host/port/token entry
// (browsers can't scan QR codes), and reloads the page on success
// so the regular entrypoint can boot in normal mode.
//
// Why no QR scan on web? `mobile_scanner` works on native iOS /
// Android via the platform camera APIs; on web the equivalent would
// require getUserMedia + a WASM QR decoder, which the package
// doesn't ship today. A 6-field form is fine — pairing is a one-
// off setup step, the QR was always a convenience for native users.

import 'package:flutter/material.dart';

import '../services/lan_client.dart';
import '../theme.dart';

/// Wave CY.18.81: caller (main.dart) passes [onPaired] — the same
/// boot sequence main() uses when the app launches already-paired.
/// On a successful pair, we call this callback which replaces the
/// splash with the real PyreApp by calling `runApp` again with the
/// full widget tree. No page reload, no manual refresh.
class WebPairFirstApp extends StatelessWidget {
  final Future<void> Function() onPaired;
  const WebPairFirstApp({super.key, required this.onPaired});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pyre',
      theme: emberTheme(),
      darkTheme: emberTheme(),
      themeMode: ThemeMode.dark,
      home: _WebPairFirstScreen(onPaired: onPaired),
      debugShowCheckedModeBanner: false,
    );
  }
}

class _WebPairFirstScreen extends StatefulWidget {
  final Future<void> Function() onPaired;
  const _WebPairFirstScreen({required this.onPaired});

  @override
  State<_WebPairFirstScreen> createState() => _WebPairFirstScreenState();
}

class _WebPairFirstScreenState extends State<_WebPairFirstScreen> {
  // Wave CY.18.79: read host + port from the current document URL.
  // Wave CY.18.81: the splash no longer shows them as editable fields —
  // they're inferred from the URL the browser is already on, and an
  // override field has zero value. We keep the values as plain
  // String fields (no TextEditingController, no UI) and surface them
  // as a small "Connecting to: <host>:<port>" caption above the
  // token field so the user knows what they're pairing TO.
  String _host = '';
  int _port = 6767;
  final _token = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    try {
      final loc = Uri.base;
      if (loc.host.isNotEmpty) _host = loc.host;
      if (loc.hasPort) {
        _port = loc.port;
      } else if (loc.scheme == 'https') {
        _port = 443;
      } else if (loc.scheme == 'http') {
        _port = 80;
      }
    } catch (_) {
      // Uri.base may not resolve in odd embedding contexts; the
      // pair call below will error cleanly if _host stays empty.
    }
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    final token = _token.text.trim();
    if (_host.isEmpty) {
      setState(() {
        _error = 'Could not detect host from URL. Reload from a '
            'http://<host>:<port>/ URL.';
        _busy = false;
      });
      return;
    }
    if (token.isEmpty) {
      setState(() {
        _error = 'Token required';
        _busy = false;
      });
      return;
    }
    final err = await LanClient.instance.pair(
      host: _host,
      port: _port,
      pairingToken: token,
      deviceName: 'Web tab',
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err;
        _busy = false;
      });
      return;
    }
    // Wave CY.18.81: pair succeeded → boot the real app directly via
    // the callback main() provided. This calls runApp(PyreApp(...)) on
    // a fresh AppStore with RemoteBackend, replacing the splash with
    // the full UI. No page reload, no "click here to continue" step.
    try {
      await widget.onPaired();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Paired, but app boot failed: $e. Refresh the page.';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Pyre',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Connect this browser to your PC',
                  style: TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  decoration: BoxDecoration(
                    color: EmberColors.bgPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: EmberColors.stroke),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '1. On your PC, open Pyre',
                        style: TextStyle(fontSize: 13),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '2. More → Network → turn the server ON, then '
                        'tap "Pair new"',
                        style: TextStyle(fontSize: 13),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '3. Copy the Token shown in the modal and paste '
                        'it below',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // Wave CY.18.81: tiny caption so the user knows what
                // they're pairing TO. The host/port came from the URL
                // they're already on; surfacing them as text (not as
                // editable fields) is the right balance between
                // transparency and not being noise.
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 6),
                  child: Text(
                    'Connecting to: $_host:$_port',
                    style: const TextStyle(
                      color: EmberColors.textDim,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                TextField(
                  controller: _token,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Token (from PC)',
                    hintText: 'paste the long random string',
                  ),
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12),
                  maxLines: 2,
                  minLines: 1,
                  onSubmitted: (_) => _busy ? null : _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Connect'),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Pyre runs on your own LAN. Your data never goes to a '
                  'cloud — your PC and this browser tab talk directly.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: EmberColors.textDim,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}
