// Wave CY.18.69: phone-side LAN pairing flow.
//
// Two entry paths into the same `LanClient.pair()` call:
//
//   1. Scan QR (native mobile only — gated on Platform.isAndroid /
//      isIOS so desktop + web never instantiate the camera widget).
//      Decoded QR is a `pyre://pair?host=…&port=…&token=…` URL we
//      parse and hand to LanClient.
//   2. Manual form (every platform). User types host + port + token
//      copied from the desktop's "Pair new device" modal. Mandatory
//      path on web because browsers can't open the host camera, and
//      a fallback on mobile when the scan flow misbehaves.
//
// When paired, the screen shows the current connection summary, a
// "Force sync" button (stub — real sync engine ships in Wave 70), and
// a Disconnect button. Disconnect only clears the local bearer; the
// desktop registry retains the device until the user explicitly
// revokes from the desktop Network screen.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/lan_client.dart';
import '../services/sync_engine.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';

bool get _supportsCameraScan {
  if (kIsWeb) return false;
  // mobile_scanner has working impls on iOS + Android. macOS support
  // exists but is unusual for the desktop use case; we hide it there
  // and rely on the manual form (desktop users see this screen rarely
  // since the desktop IS the server in the canonical flow).
  return Platform.isAndroid || Platform.isIOS;
}

class LanConnectScreen extends StatefulWidget {
  const LanConnectScreen({super.key});

  @override
  State<LanConnectScreen> createState() => _LanConnectScreenState();
}

class _LanConnectScreenState extends State<LanConnectScreen> {
  @override
  void initState() {
    super.initState();
    LanClient.instance.load();
    LanClient.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    LanClient.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _openScanner() async {
    final url = await Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const _ScannerPage()),
    );
    if (url == null || url.isEmpty) return;
    await _pairFromUrl(url);
  }

  Future<void> _openManual() async {
    final result = await showDialog<_ManualEntryResult?>(
      context: context,
      builder: (ctx) => const _ManualEntryDialog(),
    );
    if (result == null) return;
    await _runPair(result.host, result.port, result.token);
  }

  Future<void> _pairFromUrl(String url) async {
    // Accept pyre://pair?host=…&port=…&token=…
    try {
      final uri = Uri.parse(url);
      if (uri.scheme != 'pyre' || uri.host != 'pair') {
        _snack('QR is not a Pyre pairing code.');
        return;
      }
      final host = uri.queryParameters['host'];
      final portStr = uri.queryParameters['port'];
      final token = uri.queryParameters['token'];
      final port = portStr == null ? null : int.tryParse(portStr);
      if (host == null || port == null || token == null) {
        _snack('QR missing host/port/token.');
        return;
      }
      await _runPair(host, port, token);
    } catch (e) {
      _snack('Could not read QR: $e');
    }
  }

  Future<void> _runPair(String host, int port, String token) async {
    _snack('Pairing…', short: true);
    final err = await LanClient.instance.pair(
      host: host,
      port: port,
      pairingToken: token,
    );
    if (!mounted) return;
    if (err != null) {
      _snack(err);
    } else {
      _snack('Paired with $host:$port');
    }
  }

  Future<void> _disconnect() async {
    final ok = await confirmDelete(
      context,
      title: 'Disconnect from PC?',
      message:
          'You can re-pair anytime by scanning a fresh QR from the PC. '
          'The PC will keep this device in its registry until you revoke '
          'it from the desktop Network screen.',
      confirmLabel: 'Disconnect',
    );
    if (!ok) return;
    await LanClient.instance.disconnect();
  }

  void _snack(String msg, {bool short = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration:
            Duration(seconds: short ? 1 : 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = LanClient.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to LAN')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (c.isPaired) ..._pairedSection(c) else ..._unpairedSection(),
          const SizedBox(height: 20),
          const Text(
            'How this works:\n'
            'Pyre LAN sync lets your phone + browser tabs read and write the '
            'same characters, chats, personas, and lorebooks as your PC. '
            'Everything stays on your Wi-Fi — no cloud, no relay. The PC '
            'must have the server turned on (More → Network → Run Pyre LAN '
            'server) before you pair.',
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _unpairedSection() {
    return [
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Not connected to a Pyre server.',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      if (_supportsCameraScan)
        Card(
          child: ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Scan QR from PC'),
            subtitle: const Text(
                'Open the desktop\'s Network → Pair new device → point your camera at the QR.'),
            onTap: _openScanner,
          ),
        ),
      const SizedBox(height: 8),
      Card(
        child: ListTile(
          leading: const Icon(Icons.keyboard_alt_outlined),
          title: const Text('Enter manually'),
          subtitle: const Text(
              'Type host / port / token shown below the QR on the PC.'),
          onTap: _openManual,
        ),
      ),
    ];
  }

  List<Widget> _pairedSection(LanClient c) {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.link, color: EmberColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c.serverName ?? 'Connected',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Base URL: ${c.baseUrl}',
                style: const TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              if (c.deviceId != null) ...[
                const SizedBox(height: 2),
                Text(
                  'Device ID: ${c.deviceId}',
                  style: const TextStyle(
                    color: EmberColors.textDim,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // Wave 70 will wire this to SyncEngine.forceTick(); for
              // now it's a visible stub so the screen is feature-
              // complete from the user's perspective and the cron tick
              // doesn't have to come back to add a button.
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Force sync now'),
                    onPressed: () async {
                      // Wave CY.18.70: trigger SyncEngine immediately
                      // bypassing the 30s timer. Same tick code path.
                      await SyncEngine.instance.forceTick();
                      if (!mounted) return;
                      final eng = SyncEngine.instance;
                      _snack(
                        eng.status == SyncStatus.success
                            ? 'Synced'
                            : (eng.lastError ?? 'Sync attempted'),
                        short: true,
                      );
                    },
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.link_off,
                        size: 16, color: Colors.redAccent),
                    label: const Text('Disconnect',
                        style: TextStyle(color: Colors.redAccent)),
                    onPressed: _disconnect,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }
}

/// Full-screen camera page. Lives as a separate route so its lifecycle
/// (camera open/close) is bound to push/pop, and we don't have to
/// micromanage the controller across rebuilds of the parent screen.
class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage>
    with WidgetsBindingObserver {
  // Wave CY.18.248: autoStart:false because we drive start/stop ourselves.
  // mobile_scanner's MobileScanner widget only auto-starts + restarts-on-
  // resume the controller it OWNS — when you hand it an external controller
  // (as we do), its didChangeAppLifecycleState bails out (`if
  // (widget.controller != null) return;`). On Android, the very first
  // start() pops the camera-permission dialog, which pauses→resumes the
  // activity; meanwhile start() latches a `permissionDenied` error that
  // only stop() clears. With the widget's resume-restart disabled, the
  // preview stays blank forever after the user taps "Allow". So we own the
  // lifecycle here and restart on resume.
  final MobileScannerController _ctl = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Wave CY.18.252: the INITIAL open is a plain start() — NO preceding
    // stop(). A stop() on a never-started CameraX controller can race the
    // first start() and make it error out (Wave 248 added that stop() and it
    // regressed the open to a hard error on a device where permission was
    // already granted). We only stop()+start() on RESUME / manual Retry,
    // where clearing a stale latched error actually matters.
    unawaited(_start(restart: false));
  }

  /// Start the camera. When [restart] is true (app-resume or the Retry
  /// button) a stop() runs first to clear any stale error mobile_scanner
  /// latched (e.g. a `permissionDenied` from a start() that ran before the
  /// user granted access — the library only resets it on stop()). On the
  /// initial open we skip the stop() to avoid a stop-before-start race.
  Future<void> _start({required bool restart}) async {
    if (_busy || _handled || !mounted) return;
    _busy = true;
    if (restart) {
      try {
        await _ctl.stop();
      } catch (_) {/* not running — fine */}
    }
    try {
      await _ctl.start();
    } catch (_) {
      // Failure surfaces via the controller error state → errorBuilder.
    }
    _busy = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_handled) {
      unawaited(_start(restart: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_handled) return;
    for (final b in cap.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      // Accept the first non-empty value and pop with it. The parent
      // validates that it's a pyre:// URL.
      _handled = true;
      Navigator.of(context).pop(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Pyre QR'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            tooltip: 'Torch',
            onPressed: () => _ctl.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _ctl,
            onDetect: _onDetect,
            // Wave CY.18.252: show the REAL error (code + native message) so
            // a failure is diagnosable from a screenshot, plus a Retry button
            // (stop()+start()) to recover from a transient / permission-cache
            // failure without leaving the screen.
            errorBuilder: (context, error, child) {
              final details = error.errorDetails?.message;
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Camera unavailable. If you just granted permission, '
                        'tap Retry. Otherwise go back and use "Enter manually".',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Error: ${error.errorCode.name}'
                        '${(details != null && details.isNotEmpty) ? '\n$details' : ''}',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () => _start(restart: true),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          // Translucent overlay framing the centre — visual hint where
          // to aim the camera. mobile_scanner accepts any decoded code
          // anywhere in frame, this is purely UX.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.8),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Open Pyre on your PC → More → Network → Pair new device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualEntryResult {
  final String host;
  final int port;
  final String token;
  _ManualEntryResult(this.host, this.port, this.token);
}

class _ManualEntryDialog extends StatefulWidget {
  const _ManualEntryDialog();
  @override
  State<_ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<_ManualEntryDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '6767');
  final _token = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final token = _token.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'Host required (e.g. 192.168.0.45)');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Port must be 1–65535');
      return;
    }
    if (token.isEmpty) {
      setState(() => _error = 'Token required');
      return;
    }
    Navigator.of(context).pop(_ManualEntryResult(host, port, token));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enter pairing details'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: '192.168.0.45',
              isDense: true,
            ),
            autofocus: true,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _port,
            decoration: const InputDecoration(
              labelText: 'Port',
              isDense: true,
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _token,
            decoration: const InputDecoration(
              labelText: 'Token',
              hintText: 'paste from PC',
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            maxLines: 2,
            minLines: 1,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Pair'),
        ),
      ],
    );
  }
}
