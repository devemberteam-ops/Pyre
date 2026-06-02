// Wave CY.18.69: client-side LAN sync handle.
//
// LanClient is the mobile / web counterpart to PyreServer. It holds
// the host:port + bearer token for the user's paired PC, exposes
// pair() / disconnect() / forceSync stubs, and notifies listeners
// when the connection state changes (so the status indicator in
// the app shell can redraw).
//
// Persistence:
//   host + port + deviceId → SharedPreferences (not secret)
//   bearerToken            → SecureKeys (OS keystore — Android
//                            EncryptedSharedPreferences / iOS Keychain
//                            / Windows Credential Manager / Linux
//                            libsecret / browser-AES on web)
//
// This is purely a state container plus the pair() HTTP call. The
// actual sync loop is Wave 70's SyncEngine; the per-call HTTP plumbing
// for /pull, /push, /llm/stream is Wave 71's RemoteBackend (for
// web/PWA) and the SyncEngine itself (for native mobile).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_keys.dart';

/// Wave CY.18.80: bearer persistence. On native we use the OS keystore
/// via SecureKeys (Android Keystore / iOS Keychain / Windows Credential
/// Manager / Linux libsecret) which gives real isolation from the
/// app's plaintext JSON blob and from `adb backup` style attacks. On
/// web, flutter_secure_storage_web encrypts the value with AES and
/// stores both ciphertext + key in localStorage — which is theatre,
/// because any XSS lifts both halves. Worse, the AES key derivation
/// has been observed to fail to round-trip across page reloads in
/// some browser combinations, leaving the bearer unreadable on the
/// next visit and bouncing the user back to the pair form.
///
/// On web we just write to SharedPreferences (which IS localStorage)
/// directly — simpler, deterministic, and no less secure than the
/// "encrypted" version it replaces.
Future<void> _writeBearer(String token) async {
  if (kIsWeb) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lan.bearerToken', token);
    return;
  }
  await SecureKeys.write('__lan__.bearerToken', token);
}

Future<String?> _readBearer() async {
  if (kIsWeb) {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('lan.bearerToken');
    return (v == null || v.isEmpty) ? null : v;
  }
  final v = await SecureKeys.read('__lan__.bearerToken');
  return v.isEmpty ? null : v;
}

Future<void> _deleteBearer() async {
  if (kIsWeb) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('lan.bearerToken');
    return;
  }
  await SecureKeys.delete('__lan__.bearerToken');
}

class LanClient extends ChangeNotifier {
  LanClient._();
  static final LanClient instance = LanClient._();

  static const String _prefHost = 'lan.host';
  static const String _prefPort = 'lan.port';
  static const String _prefDeviceId = 'lan.deviceId';
  static const String _prefServerName = 'lan.serverName';

  String? _host;
  int? _port;
  String? _bearer;
  String? _deviceId;
  String? _serverName;
  bool _loaded = false;

  String? get host => _host;
  int? get port => _port;
  String? get bearerToken => _bearer;
  String? get deviceId => _deviceId;

  /// Friendly name the user (or default) gave this server during
  /// pairing — currently `Pyre on <host>` but could be richer when
  /// the server starts returning a device name in /pair.
  String? get serverName => _serverName;

  bool get isPaired =>
      _host != null && _port != null && (_bearer?.isNotEmpty ?? false);

  /// Base URL of the paired server, e.g. `http://192.168.0.45:6767`.
  /// Returns null when not paired.
  String? get baseUrl {
    if (!isPaired) return null;
    return 'http://$_host:$_port';
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _host = prefs.getString(_prefHost);
      _port = prefs.getInt(_prefPort);
      _deviceId = prefs.getString(_prefDeviceId);
      _serverName = prefs.getString(_prefServerName);
      _bearer = await _readBearer();
    } catch (e) {
      debugPrint('[LanClient] load failed: $e');
    }
    notifyListeners();
  }

  /// Run the pairing handshake. Returns a human-readable error message
  /// on failure, null on success. On success, persists everything and
  /// notifies listeners.
  Future<String?> pair({
    required String host,
    required int port,
    required String pairingToken,
    String? deviceName,
  }) async {
    if (host.trim().isEmpty) return 'Host is required.';
    if (port < 1 || port > 65535) return 'Port must be 1–65535.';
    if (pairingToken.trim().isEmpty) return 'Token is required.';
    final url = Uri.parse('http://${host.trim()}:$port/pair');
    final body = jsonEncode({
      'pairingToken': pairingToken.trim(),
      'deviceName': (deviceName ?? '').trim().isEmpty
          ? _defaultDeviceName()
          : deviceName!.trim(),
      // Wave CY.18.259: declare whether this is a NATIVE peer. Native
      // (mobile/desktop) devices may receive encrypted API keys; the web
      // view never does, so it sends false (fail-closed).
      'native': !kIsWeb,
    });
    http.Response resp;
    try {
      resp = await http
          .post(url,
              headers: {'content-type': 'application/json'},
              body: body)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      return 'Server did not respond. Is the PC awake and on the same Wi-Fi?';
    } catch (e) {
      return 'Could not reach $host:$port — $e';
    }
    if (resp.statusCode == 401) {
      return 'Token rejected. It may have expired (5-min limit) or '
          'been redeemed already. Open the PC and tap "Pair new device" '
          'for a fresh QR.';
    }
    if (resp.statusCode != 200) {
      return 'Server returned ${resp.statusCode}: ${resp.body}';
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return 'Server replied with invalid JSON: ${resp.body}';
    }
    final bearer = json['bearerToken'] as String?;
    final devId = json['deviceId'] as String?;
    if (bearer == null || bearer.isEmpty) {
      return 'Server reply missing bearer token.';
    }

    _host = host.trim();
    _port = port;
    _bearer = bearer;
    _deviceId = devId;
    _serverName = 'Pyre on $_host';

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefHost, _host!);
      await prefs.setInt(_prefPort, _port!);
      if (_deviceId != null) {
        await prefs.setString(_prefDeviceId, _deviceId!);
      }
      await prefs.setString(_prefServerName, _serverName!);
      await _writeBearer(bearer);
    } catch (e) {
      // Persistence failure isn't fatal — the client works for this
      // session, just won't survive restart. Surface but don't undo.
      debugPrint('[LanClient] pair persist failed: $e');
    }
    notifyListeners();
    return null;
  }

  /// Forget the paired server locally. The server still has us in its
  /// registry until the user explicitly revokes from the desktop UI.
  Future<void> disconnect() async {
    _host = null;
    _port = null;
    _bearer = null;
    _deviceId = null;
    _serverName = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefHost);
      await prefs.remove(_prefPort);
      await prefs.remove(_prefDeviceId);
      await prefs.remove(_prefServerName);
      await _deleteBearer();
    } catch (e) {
      debugPrint('[LanClient] disconnect cleanup failed: $e');
    }
    notifyListeners();
  }

  /// Best-effort device label for /pair. Falls back to a generic tag
  /// when platform detection is unavailable (web). The user can
  /// rename later from the desktop "Paired devices" list (when
  /// Wave 70+ adds rename UI).
  String _defaultDeviceName() {
    if (kIsWeb) return 'Web tab';
    try {
      return 'Mobile device';
    } catch (_) {
      return 'Unnamed device';
    }
  }
}
