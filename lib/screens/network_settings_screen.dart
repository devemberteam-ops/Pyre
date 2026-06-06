// Wave CY.18.68: Network settings — the only place where the user can
// turn on Pyre's LAN server, see its status, generate pairing QR codes,
// and revoke previously-paired devices.
//
// Lives at More → Network. Desktop-only (the More-screen row that
// links here is gated on Platform.isWindows||Linux||macOS); mobile
// builds never reach this code path.
//
// Server lifecycle:
//   - On screen open: nothing changes (the server may or may not be
//     running depending on the persisted lanServerEnabled pref).
//   - Toggle ON → start the server with the current port + bind mode.
//   - Toggle OFF → stop the server.
//   - Port / bind change while running → bounce (stop + restart) so
//     the new value takes effect.
//
// The "Pair new device" modal issues a one-shot pairing token, builds
// the `pyre://pair?host=…&port=…&token=…` URL, renders it as a QR
// for camera scanning AND as text fallback for browser pairing
// (web/PWA users can't scan with a desktop browser).

import 'dart:async';
import 'dart:io' show NetworkInterface, InternetAddressType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/device_registry.dart';
import '../services/pyre_server.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';

class NetworkSettingsScreen extends StatefulWidget {
  const NetworkSettingsScreen({super.key});

  @override
  State<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends State<NetworkSettingsScreen> {
  late final TextEditingController _portCtl;
  String _lanIp = 'detecting…';
  StreamSubscription<void>? _registrySub;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _portCtl = TextEditingController(
        text: store.uiPrefs.lanServerPort.toString());
    _detectLanIp();
    DeviceRegistry.instance.load();
    _registrySub = DeviceRegistry.instance.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _portCtl.dispose();
    _registrySub?.cancel();
    super.dispose();
  }

  /// Find the first non-loopback IPv4 address the machine advertises.
  /// Used to build the QR / manual URL the mobile clients connect to.
  Future<void> _detectLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      String? best;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            // Prefer 192.168.* / 10.* / 172.16-31.* style addresses;
            // they're the actual home LAN. Skip 169.254.* link-local
            // which APIPA assigns when DHCP fails.
            final a = addr.address;
            if (a.startsWith('169.254.')) continue;
            best ??= a;
            if (a.startsWith('192.168.') ||
                a.startsWith('10.') ||
                a.startsWith('172.')) {
              best = a;
              break;
            }
          }
        }
        if (best != null && best.startsWith('192.168.')) break;
      }
      if (mounted) {
        setState(() => _lanIp = best ?? 'no LAN interface');
      }
    } catch (e) {
      if (mounted) setState(() => _lanIp = 'detection failed');
    }
  }

  Future<void> _toggleServer(bool on, AppStore store) async {
    // Wave CY.18.74: commit the port field BEFORE we read it for the
    // start call. The text field has its own "Apply port" button for
    // bouncing a running server without losing focus, but most users
    // don't notice the button — they type a port, then go straight
    // to the toggle. Without this commit, the toggle reads the
    // stale persisted pref and tries to bind to the OLD port; the
    // resulting "Port X is already in use" error confuses the user
    // because their field shows port Y. We parse + clamp + persist
    // up front so what the user sees == what the server attempts.
    if (on) {
      final parsed = int.tryParse(_portCtl.text.trim());
      if (parsed == null || parsed < 1 || parsed > 65535) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Port must be 1–65535')),
        );
        // Reset field to the persisted value so it's not visually
        // out of sync with what the toggle would have done.
        _portCtl.text = store.uiPrefs.lanServerPort.toString();
        return;
      }
      if (parsed != store.uiPrefs.lanServerPort) {
        store.setLanServerPort(parsed);
      }
    }
    store.setLanServerEnabled(on);
    if (on) {
      try {
        await PyreServer.instance.start(
          port: store.uiPrefs.lanServerPort,
          bind: store.uiPrefs.lanBindMode == 'localhost'
              ? BindMode.localhostOnly
              : BindMode.entireLan,
          store: store,
        );
      } catch (e) {
        if (mounted) {
          store.setLanServerEnabled(false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Server failed to start: $e')),
          );
        }
      }
    } else {
      await PyreServer.instance.stop();
    }
    if (mounted) setState(() {});
  }

  Future<void> _applyPortChange(AppStore store) async {
    final parsed = int.tryParse(_portCtl.text.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Port must be 1–65535')),
      );
      _portCtl.text = store.uiPrefs.lanServerPort.toString();
      return;
    }
    if (parsed == store.uiPrefs.lanServerPort) return;
    store.setLanServerPort(parsed);
    if (PyreServer.instance.running) {
      // Bounce the server so the new port takes effect.
      await PyreServer.instance.stop();
      try {
        await PyreServer.instance.start(
          port: parsed,
          bind: store.uiPrefs.lanBindMode == 'localhost'
              ? BindMode.localhostOnly
              : BindMode.entireLan,
          store: store,
        );
      } catch (e) {
        store.setLanServerEnabled(false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Restart failed: $e — server off')),
          );
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _setBindMode(String mode, AppStore store) async {
    if (mode == store.uiPrefs.lanBindMode) return;
    store.setLanBindMode(mode);
    if (PyreServer.instance.running) {
      await PyreServer.instance.stop();
      try {
        await PyreServer.instance.start(
          port: store.uiPrefs.lanServerPort,
          bind: mode == 'localhost'
              ? BindMode.localhostOnly
              : BindMode.entireLan,
          store: store,
        );
      } catch (e) {
        store.setLanServerEnabled(false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Restart failed: $e — server off')),
          );
        }
      }
    }
    if (mounted) setState(() {});
  }

  void _openPairModal(AppStore store) {
    if (!PyreServer.instance.running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Turn the server on first')),
      );
      return;
    }
    final port = PyreServer.instance.port;
    if (port == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => _PairModal(
        host: _lanIp,
        port: port,
        onPaired: () {
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Future<void> _revoke(PairedDevice d) async {
    final ok = await confirmDelete(
      context,
      title: 'Revoke ${d.name}?',
      message:
          'This device will be disconnected on its next sync. It can re-pair by scanning a new QR.',
      confirmLabel: 'Revoke',
    );
    if (!ok) return;
    // Wave CY.18.255 (audit FIX 2): revoke by the bearer HASH — the raw
    // token is never held server-side after pairing.
    await DeviceRegistry.instance.revoke(d.bearerHash);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final enabled = store.uiPrefs.lanServerEnabled;
    final running = PyreServer.instance.running;
    final actualPort = PyreServer.instance.port ?? store.uiPrefs.lanServerPort;
    final devices = DeviceRegistry.instance.paired;

    return Scaffold(
      appBar: AppBar(title: const Text('Network (LAN sync)')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  value: enabled,
                  onChanged: (v) => _toggleServer(v, store),
                  title: const Text('Run Pyre LAN server'),
                  subtitle: Text(
                    enabled
                        ? (running
                            ? 'Listening on http://$_lanIp:$actualPort'
                            : 'Configured but not running')
                        : 'Off — phones / web tabs can\'t reach this Pyre',
                    style: const TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                    ),
                  ),
                  activeThumbColor: EmberColors.primary,
                ),
                if (enabled && running) ...[
                  const Divider(height: 1, color: EmberColors.stroke),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            'http://$_lanIp:$actualPort',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          tooltip: 'Copy URL',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(
                                text: 'http://$_lanIp:$actualPort'));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('URL copied'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Port',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _portCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: '6767',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _applyPortChange(store),
                  ),
                  TextButton(
                    onPressed: () => _applyPortChange(store),
                    child: const Text('Apply port'),
                  ),
                  const Divider(color: EmberColors.stroke, height: 24),
                  const Text('Bind address',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  // ignore: deprecated_member_use
                  RadioListTile<String>(
                    value: 'lan',
                    // ignore: deprecated_member_use
                    groupValue: store.uiPrefs.lanBindMode,
                    title: const Text('Entire LAN (0.0.0.0)'),
                    subtitle: const Text(
                      'Phones on the same Wi-Fi can connect.',
                      style: TextStyle(fontSize: 12),
                    ),
                    // ignore: deprecated_member_use
                    onChanged: (v) {
                      if (v != null) _setBindMode(v, store);
                    },
                    activeColor: EmberColors.primary,
                    contentPadding: EdgeInsets.zero,
                  ),
                  // ignore: deprecated_member_use
                  RadioListTile<String>(
                    value: 'localhost',
                    // ignore: deprecated_member_use
                    groupValue: store.uiPrefs.lanBindMode,
                    title: const Text('Localhost only'),
                    subtitle: const Text(
                      'Only this machine. Useful for local web testing.',
                      style: TextStyle(fontSize: 12),
                    ),
                    // ignore: deprecated_member_use
                    onChanged: (v) {
                      if (v != null) _setBindMode(v, store);
                    },
                    activeColor: EmberColors.primary,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.lock_open,
                          size: 16, color: Colors.orangeAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: RichText(
                          text: const TextSpan(
                            style: TextStyle(
                              color: EmberColors.textMid,
                              fontSize: 12,
                              height: 1.4,
                            ),
                            children: [
                              TextSpan(
                                text: 'Traffic is not encrypted. ',
                                style: TextStyle(
                                  color: Colors.orangeAccent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text:
                                    'Pyre serves plain HTTP — anyone on the '
                                    'same network can read what is sent between '
                                    'this PC and your devices. Only enable '
                                    '"Entire LAN" on networks you trust (your '
                                    'home Wi-Fi), never on public or shared '
                                    'Wi-Fi.',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: EmberColors.stroke, height: 24),
                  // Wave CY.18.263: opt-in to syncing AI providers + their
                  // API keys to paired NATIVE devices (phones / other PCs).
                  // Off by default; the web view never receives keys.
                  SwitchListTile(
                    value: store.uiPrefs.syncProviderKeys,
                    onChanged: (v) {
                      // S1: setSyncProviderKeys restamps provider mtimes on
                      // enable so they re-ship to a receiver whose cursor has
                      // already advanced (the inert-toggle bug).
                      store.setSyncProviderKeys(v);
                      setState(() {});
                    },
                    title: const Text(
                        'Sync providers & API keys to paired devices'),
                    subtitle: const Text(
                      'Encrypted. Only your paired phones/PCs — never the '
                      'web view. Keys never leave in plaintext.',
                      style: TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 12,
                      ),
                    ),
                    activeThumbColor: EmberColors.primary,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 2, left: 0, right: 0),
                    child: Text(
                      'Turn this ON on BOTH devices — the one holding the keys '
                      'AND the one receiving them; the receiver ignores synced '
                      'keys while its own toggle is off. The encryption key is '
                      'derived from the device-pairing secret — it protects the '
                      'LAN connection, not data at rest.',
                      style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Paired devices',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.qr_code_2, size: 16),
                        label: const Text('Pair new'),
                        onPressed: running
                            ? () => _openPairModal(store)
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (devices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No paired devices. Tap "Pair new" to add your phone.',
                        style: TextStyle(
                          color: EmberColors.textMid,
                          fontSize: 13,
                        ),
                      ),
                    )
                  else
                    for (final d in devices)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.phone_android,
                                size: 18, color: EmberColors.textMid),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(d.name,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  Text(
                                    'last seen ${_relative(d.lastSeen)}',
                                    style: const TextStyle(
                                        color: EmberColors.textDim,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () => _revoke(d),
                              child: const Text('Revoke',
                                  style:
                                      TextStyle(color: Colors.redAccent)),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'About Pyre LAN sync:\n'
              'When the server is on, paired phones and browser tabs can '
              'read + write the same characters, chats, personas, and '
              'lorebooks as this PC. Data stays on your LAN — no cloud, '
              'no relay, no telemetry. The server only opens its port '
              'while this toggle is ON.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _relative(int ms) {
    if (ms == 0) return 'never';
    final delta =
        DateTime.now().millisecondsSinceEpoch - ms;
    if (delta < 60 * 1000) return 'just now';
    if (delta < 60 * 60 * 1000) {
      return '${(delta / (60 * 1000)).floor()}m ago';
    }
    if (delta < 24 * 60 * 60 * 1000) {
      return '${(delta / (60 * 60 * 1000)).floor()}h ago';
    }
    return '${(delta / (24 * 60 * 60 * 1000)).floor()}d ago';
  }
}

/// Pairing modal: issues a one-shot token (5-min TTL), renders the
/// `pyre://pair?…` URL as both a QR and selectable text. Polls the
/// device registry once per second so the modal can dismiss itself
/// when the redeem actually lands on the server.
class _PairModal extends StatefulWidget {
  final String host;
  final int port;
  final VoidCallback onPaired;
  const _PairModal({
    required this.host,
    required this.port,
    required this.onPaired,
  });

  @override
  State<_PairModal> createState() => _PairModalState();
}

class _PairModalState extends State<_PairModal> {
  late final String _token;
  late final DateTime _issuedAt;
  Timer? _tick;
  int _initialDeviceCount = 0;

  @override
  void initState() {
    super.initState();
    _token = DeviceRegistry.instance.issuePairingToken();
    _issuedAt = DateTime.now();
    _initialDeviceCount = DeviceRegistry.instance.paired.length;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      final now = DeviceRegistry.instance.paired.length;
      if (now > _initialDeviceCount) {
        // Pair succeeded — dismiss and notify parent so the list
        // refreshes.
        widget.onPaired();
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String get _pairUrl =>
      'pyre://pair?host=${widget.host}&port=${widget.port}&token=$_token';

  Duration get _remaining {
    const ttl = Duration(minutes: 5);
    return ttl - DateTime.now().difference(_issuedAt);
  }

  @override
  Widget build(BuildContext context) {
    final rem = _remaining;
    final expired = rem.isNegative;
    final minutes = rem.inMinutes.clamp(0, 99);
    final seconds = (rem.inSeconds - minutes * 60).clamp(0, 59);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.qr_code_2, size: 22),
                  const SizedBox(width: 8),
                  const Text('Pair new device',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (expired)
                const Text(
                  'This token has expired. Close and tap "Pair new" again.',
                  style: TextStyle(color: Colors.orangeAccent),
                )
              else ...[
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: QrImageView(
                      data: _pairUrl,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Open Pyre on your phone → More → Connect to LAN → '
                  'Scan QR. Token expires in '
                  '${minutes.toString().padLeft(2, '0')}:'
                  '${seconds.toString().padLeft(2, '0')}.',
                  style: const TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(color: EmberColors.stroke),
                const SizedBox(height: 8),
                const Text(
                  'No camera (web/PWA)? Type these into the manual form:',
                  style:
                      TextStyle(color: EmberColors.textMid, fontSize: 12),
                ),
                const SizedBox(height: 6),
                _kvRow('Host', widget.host),
                _kvRow('Port', widget.port.toString()),
                _kvRow('Token', _token, mono: true),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _kvRow(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: const TextStyle(
                    color: EmberColors.textDim, fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 14),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('$label copied'),
                    duration: const Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
    );
  }
}
