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
import 'package:url_launcher/url_launcher.dart';

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
          const SizedBox(height: 20),
          const Center(
            child: Text(
              'Pyre 1.0.5',
              style: TextStyle(color: EmberColors.textDim, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
