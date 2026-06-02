import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_store.dart';
import '../theme.dart';
import '../services/lan_client.dart';
import '../services/update_check.dart';
import 'api_connections_screen.dart';
import 'lan_connect_screen.dart';
import 'network_settings_screen.dart';
import 'backup_restore_screen.dart';
import 'botbooru_profile_screen.dart';
import 'character_creator_screen.dart';
import 'chat_settings_screen.dart';
import 'lorebooks_screen.dart';
import 'about_pyre_screen.dart';
import 'desktop_shortcuts_screen.dart';
import 'storage_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final activeProviderName = store.activeProvider?.name ?? 'Not set';
    final botbooruHandle =
        store.botbooruUsername.isEmpty ? 'Not set' : store.botbooruUsername;

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _MoreCard(rows: [
            _MoreRow(
              label: 'API Connections',
              trailing: activeProviderName,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ApiConnectionsScreen()),
              ),
            ),
            // Wave BC: BotBooru handle for the Character Creator's
            // {{creator}} substitution. Goes here next to API
            // Connections so identity-on-the-network configs cluster.
            // Wave CY.18.31: relabelled to "Profile" — the BotBooru
            // framing was niche, the screen itself explains usage.
            _MoreRow(
              label: 'Profile',
              trailing: botbooruHandle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const BotbooruProfileScreen()),
              ),
            ),
            // Wave CY.18.91: "Theme" placeholder removed. It showed
            // "Ember (dark)" with no onTap — a tease that suggested
            // configurability that doesn't exist yet. Theme variants
            // can come back when there's actually more than one to
            // pick from.
          ]),
          const SizedBox(height: 12),
          // Wave CY.18.193: Presets + Long-term Memory moved INTO Chat
          // Settings (a hub). Wave CY.18.202: Lorebooks moved BACK out
          // to this main menu — it's a content library, not a chat
          // setting. Card2 = Character Creator + Chat Settings +
          // Lorebooks.
          _MoreCard(rows: [
            // Wave CY.18.32: consolidated "Character Creator prompt"
            // + "Character Creator help" into a single entry that
            // opens the unified CharacterCreatorScreen.
            //
            // Wave CY.18.108: the separate "Creator Prompts" row was
            // folded INTO this screen — the forkable architect-prompt
            // preset now lives inside Character Creator (replacing the
            // old read-only base-prompt viewers). One creator-config
            // entry now, not two.
            _MoreRow(
              label: 'Character Creator',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const CharacterCreatorScreen()),
              ),
            ),
            _MoreRow(
              label: 'Chat Settings',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ChatSettingsScreen()),
              ),
            ),
            // Wave CY.18.202: Lorebooks returned to the More main menu
            // (was inside Chat Settings since Wave 193).
            _MoreRow(
              label: 'Lorebooks',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LorebooksScreen()),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          _MoreCard(rows: [
            _MoreRow(
              label: 'Storage',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StorageScreen()),
              ),
            ),
            _MoreRow(
              label: 'Backup and Restore',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const BackupRestoreScreen()),
              ),
            ),
            // Privacy + About merged into a single full screen. The
            // screen handles the brand summary, the privacy statement,
            // and the legal links — covers everything a user looking
            // for "what does this app do with my data" would expect to
            // find in one place.
            _MoreRow(
              label: 'About Pyre',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AboutPyreScreen()),
              ),
            ),
          ]),
          // Wave CY.18.69: LAN client entry for mobile + web. Mirror
          // of the desktop's "Network (LAN sync)" row — on the client
          // side it's a connect/disconnect flow rather than a
          // server-toggle. Hidden on desktop because the desktop IS
          // the server (it doesn't pair to itself).
          if (kIsWeb ||
              Platform.isAndroid ||
              Platform.isIOS) ...[
            const SizedBox(height: 12),
            _MoreCard(rows: [
              _MoreRow(
                label: 'Connect to LAN',
                trailing:
                    LanClient.instance.isPaired ? 'Paired' : 'Not paired',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const LanConnectScreen()),
                ),
              ),
            ]),
          ],
          // Wave CY.18.46: desktop-only section. Phone / tablet / web
          // builds skip this entirely so the More screen stays
          // identical on mobile.
          //
          // Wave CY.18.90: trimmed back to the LAN sync + Desktop
          // Shortcuts entries. The wide-layout toggle moved into
          // DesktopShortcutsScreen along with the remappable
          // shortcuts list; "Keyboard shortcuts" was renamed to
          // "Desktop Shortcuts" and now opens the configuration
          // screen instead of the palette.
          if (!kIsWeb &&
              (Platform.isWindows ||
                  Platform.isLinux ||
                  Platform.isMacOS)) ...[
            const SizedBox(height: 12),
            _MoreCard(rows: [
              _MoreRow(
                label: 'Desktop Shortcuts',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const DesktopShortcutsScreen()),
                ),
              ),
              // Wave CY.18.68: LAN sync server settings — desktop only
              // since the server can't run inside a browser tab or on
              // mobile (which is a client, not a server, in this app).
              _MoreRow(
                label: 'Network (LAN sync)',
                trailing:
                    store.uiPrefs.lanServerEnabled ? 'On' : 'Off',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const NetworkSettingsScreen()),
                ),
              ),
            ]),
          ],
          // Wave CY.18.266: version label + a persistent "Update available"
          // indicator that appears here (lots of room below the version) when
          // a newer release is published, so the user isn't reliant on the
          // transient launch snackbar.
          const _VersionFooter(),
        ],
      ),
    );
  }
}

/// The "Pyre 1.0" footer, plus a tappable "Update available" pill that shows
/// only when [availableUpdateNotifier] holds a newer release. Tapping it opens
/// the GitHub release page (where the new APK is downloaded). On first build it
/// kicks a one-shot [checkForUpdate] if the launch probe hasn't populated one
/// yet, so the indicator can appear even if the user reaches More before the
/// 4-second launch probe (or it failed transiently). Silent on failure.
class _VersionFooter extends StatefulWidget {
  const _VersionFooter();

  @override
  State<_VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends State<_VersionFooter> {
  @override
  void initState() {
    super.initState();
    if (availableUpdateNotifier.value == null) {
      // Fire-and-forget; checkForUpdate publishes to the notifier on success.
      checkForUpdate();
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {/* best-effort */}
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: availableUpdateNotifier,
      builder: (context, update, _) {
        return Column(
          children: [
            const SizedBox(height: 16),
            const Center(
              child: Text(
                // Wave CY.18.209: align with About Pyre's footer (Wave 340).
                // The real version is in pubspec.yaml (1.0.1) and is what the
                // update-check reads via PackageInfo; this is just a
                // human-facing label, kept consistent across both screens.
                'Pyre 1.0.2',
                style: TextStyle(color: EmberColors.textDim, fontSize: 11),
              ),
            ),
            if (update != null) ...[
              const SizedBox(height: 12),
              Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: update.url.isEmpty ? null : () => _open(update.url),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: EmberColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: EmberColors.primary.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.system_update_alt,
                            size: 20, color: EmberColors.primary),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Update available — Pyre ${update.latestVersion}',
                                style: const TextStyle(
                                    color: EmberColors.primary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13),
                              ),
                              if (update.notes.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    update.notes,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: EmberColors.textMid,
                                        fontSize: 11),
                                  ),
                                )
                              else
                                const Padding(
                                  padding: EdgeInsets.only(top: 2),
                                  child: Text(
                                    'Tap to download the latest release.',
                                    style: TextStyle(
                                        color: EmberColors.textMid,
                                        fontSize: 11),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Icon(Icons.download_rounded,
                            size: 20, color: EmberColors.primary),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MoreCard extends StatelessWidget {
  final List<_MoreRow> rows;
  const _MoreCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i < rows.length - 1) {
        children.add(const Divider(
          color: EmberColors.stroke,
          height: 1,
          indent: 16,
          endIndent: 16,
        ));
      }
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Column(children: children),
    );
  }
}

class _MoreRow extends StatelessWidget {
  final String label;
  final String? trailing;
  final VoidCallback? onTap;
  const _MoreRow({required this.label, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            if (trailing != null) ...[
              Text(
                trailing!,
                style:
                    const TextStyle(color: EmberColors.textMid, fontSize: 13),
              ),
              const SizedBox(width: 6),
            ],
            const Icon(Icons.chevron_right,
                color: EmberColors.textDim, size: 22),
          ],
        ),
      ),
    );
  }
}

// The previous _showAbout() dialog + _AboutLink widget + URL
// placeholders moved into about_pyre_screen.dart. The full-screen
// About now hosts the brand summary, the privacy statement, and the
// hosted legal links in one place.
