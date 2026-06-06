import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_store.dart';
import '../theme.dart';

/// First-run onboarding. Shown once when the user opens Pyre on a
/// fresh install with no provider configured.
///
/// Wave CY.18.39: collapsed from a 3-step flow (welcome → provider
/// picker → paste key) into a SINGLE welcome screen. The old picker
/// step felt forced and the paste-key step duplicated work that the
/// API Connections screen already handles better. New users now see
/// a single overview of what Pyre is + a "Get started" button that
/// drops them straight into the app.
///
/// A quiet implied-consent line sits under the Get started button —
/// no checkbox, no gate. Continuing accepts the Terms of Use and
/// Privacy Policy, which live in full under More -> About Pyre.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;

  void _getStarted() {
    if (_busy) return;
    setState(() => _busy = true);
    context.read<AppStore>().markOnboardingSeen();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: EmberColors.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.local_fire_department,
                  color: EmberColors.primary,
                  size: 30,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Welcome to Pyre',
                style:
                    TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'A powerful, private roleplay frontend. You bring the AI — '
                'Pyre is the interface.',
                style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    _bulletRow(
                      Icons.vpn_key_outlined,
                      'Bring your own key',
                      'Pyre talks directly to the AI provider you choose. '
                          'No middle-man server.',
                    ),
                    _bulletRow(
                      Icons.shield_outlined,
                      'Your data stays on this device',
                      'Characters, chats, API keys — all local. We don\'t '
                          'have a backend that sees them.',
                    ),
                    _bulletRow(
                      Icons.tune_outlined,
                      'Built for roleplay',
                      'SillyTavern card import, group chats, presets, '
                          'lorebooks, branching variants.',
                    ),
                    _bulletRow(
                      Icons.explore_outlined,
                      'Discover marketplace',
                      'Browse botbooru.com inside the app and import '
                          'characters in one tap.',
                    ),
                    _bulletRow(
                      Icons.auto_awesome,
                      'Experimental power tools',
                      'AI Character Creator for characters, scenarios & '
                          'personas, branch-aware Checkpoints, Live '
                          'Sheet state tracking, Script story-direction, and '
                          'scene-aware dynamic backgrounds. Heavier features, '
                          'tuned but evolving.',
                    ),
                    _bulletRow(
                      Icons.check_circle_outline,
                      'Set up once, you\'re good',
                      'Add an API provider in More → API Connections, '
                          'grab a card (or build one), maybe make a persona '
                          '— that\'s it. Pyre ships with best-practice '
                          'prompts tuned for roleplay, so you don\'t need '
                          'to fiddle with nerd settings to get a good '
                          'experience out of the box.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy ? null : _getStarted,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Get started',
                            style: TextStyle(fontSize: 15)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'By continuing, you accept the Terms of Use and Privacy '
                'Policy.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bulletRow(IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: EmberColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
