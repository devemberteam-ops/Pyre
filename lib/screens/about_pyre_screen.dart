// About Pyre — full screen, merged with Privacy.
//
// A single full screen reachable from More → About Pyre that folds
// together:
//
//   1. Hero — what Pyre is (BYOK, on-device, RP-friendly).
//   2. Privacy — a short static statement: Pyre collects nothing.
//      No analytics, no telemetry, no crash reports leave the device.
//   3. Legal & support — links to the hosted Privacy Policy, ToS,
//      help/support email.
//   4. Version footer.

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/stability_mode.dart';
import '../theme.dart';

// Mirrors more_screen.dart placeholders. When these get real hosted
// URLs, both surfaces must be updated together.
//
// TODO(before-first-release): host these. See more_screen.dart for
// the same TODO with hosting options.
const _privacyPolicyUrl = 'https://pyrechat.app/legal/privacy-policy/';
const _termsOfServiceUrl = 'https://pyrechat.app/legal/terms-of-use/';
const _supportUrl = 'https://pyrechat.app/help/faq/';
const _koFiUrl = 'https://ko-fi.com/pyredevs';

class AboutPyreScreen extends StatefulWidget {
  const AboutPyreScreen({super.key});

  @override
  State<AboutPyreScreen> createState() => _AboutPyreScreenState();
}

class _AboutPyreScreenState extends State<AboutPyreScreen> {
  // Windows-only "Stability mode" toggle state. Reflects the real on-disk
  // marker file (StabilityMode.isEnabled), not a cached value.
  bool _stabilityOn = false;

  // Version shown in the footer. Read at runtime from PackageInfo (same source
  // update_check.dart uses) so it always matches pubspec.yaml and can never
  // drift like a hard-coded string. Empty until the async load completes.
  String _version = '';

  @override
  void initState() {
    super.initState();
    if (StabilityMode.supported) {
      _stabilityOn = StabilityMode.isEnabled();
    }
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _version = info.version);
    }).catchError((_) {
      // Leave _version empty → footer shows a bare "Pyre" rather than a wrong
      // number. Non-fatal.
    });
  }

  Future<void> _setStability(bool value) async {
    await StabilityMode.setEnabled(value);
    if (!mounted) return;
    // Re-read actual state so the switch never lies if the write failed.
    setState(() => _stabilityOn = StabilityMode.isEnabled());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _stabilityOn
              ? 'Stability mode will apply the next time you start Pyre.'
              : 'Stability mode off — restart Pyre to return to normal.',
        ),
      ),
    );
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About Pyre')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          // -------- Hero --------
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: EmberColors.primary.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.local_fire_department,
                          color: EmberColors.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Pyre',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A powerful, private roleplay frontend.',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'BYOK: bring your own API key. All characters, '
                    'chats, presets and lorebooks live on this '
                    'device. Pyre connects directly to the AI '
                    'provider you configure — there\'s no Pyre '
                    'backend in between.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Imports SillyTavern v1/v2 cards, presets, and '
                    'lorebooks. Browses botbooru.com inside the app.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // -------- Privacy --------
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              'Privacy',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: EmberColors.textDim,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Pyre collects nothing',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'No analytics, no telemetry, no crash reports — '
                    'nothing leaves your device. There\'s no Pyre '
                    'server and no account.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Your characters, chats and keys live only on your '
                    'device — and, if you turn it on, sync directly to '
                    'your other devices over your own network.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // -------- Legal & support --------
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(
              'Legal & support',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: EmberColors.textDim,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.coffee_outlined,
                      color: EmberColors.primary),
                  title: const Text('Support Pyre'),
                  subtitle: const Text(
                    'Free, obviously. Throw a coffee on the bonfire if you want.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  trailing: const Icon(Icons.open_in_new,
                      size: 18, color: EmberColors.textDim),
                  onTap: () => _open(_koFiUrl),
                ),
                const Divider(
                    color: EmberColors.stroke, height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.shield_outlined,
                      color: EmberColors.primary),
                  title: const Text('Privacy Policy'),
                  trailing: const Icon(Icons.open_in_new,
                      size: 18, color: EmberColors.textDim),
                  onTap: () => _open(_privacyPolicyUrl),
                ),
                const Divider(
                    color: EmberColors.stroke, height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.description_outlined,
                      color: EmberColors.primary),
                  title: const Text('Terms of Use'),
                  trailing: const Icon(Icons.open_in_new,
                      size: 18, color: EmberColors.textDim),
                  onTap: () => _open(_termsOfServiceUrl),
                ),
                const Divider(
                    color: EmberColors.stroke, height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.help_outline,
                      color: EmberColors.primary),
                  title: const Text('Help & support'),
                  trailing: const Icon(Icons.open_in_new,
                      size: 18, color: EmberColors.textDim),
                  onTap: () => _open(_supportUrl),
                ),
              ],
            ),
          ),

          // -------- Troubleshooting (Windows-only) --------
          // Stability mode: an opt-in escape hatch for the rare
          // flutter_windows.dll access-violation seen when the NVIDIA GeForce
          // overlay (which hooks the DXGI present chain) is active. It steers
          // the engine onto MSAA accessibility + the low-power GPU on the next
          // launch. Default off — only flip it if Pyre crashes during heavy
          // window interaction.
          if (StabilityMode.supported) ...[
            const SizedBox(height: 20),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text(
                'Troubleshooting',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: EmberColors.textDim,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      value: _stabilityOn,
                      onChanged: _setStability,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      title: const Text('Stability mode'),
                      subtitle: const Text(
                        'For rare crashes during heavy use on some NVIDIA '
                        'setups (often when the GeForce overlay is on). Uses a '
                        'safer graphics + accessibility path. Takes effect '
                        'after you restart Pyre.',
                        style: TextStyle(
                            color: EmberColors.textMid,
                            fontSize: 12,
                            height: 1.4),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 2, 16, 6),
                      child: Text(
                        'Tip: if crashes continue, turning off the NVIDIA '
                        'in-game overlay for Pyre is the most reliable fix.',
                        style: TextStyle(
                            color: EmberColors.textDim,
                            fontSize: 11,
                            height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),
          Center(
            child: Text(
              _version.isEmpty ? 'Pyre' : 'Pyre $_version',
              style: const TextStyle(color: EmberColors.textDim, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
