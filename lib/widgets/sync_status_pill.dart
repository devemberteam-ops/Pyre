// SYNC W5 (transparency UI): the long-promised SyncStatusPill.
//
// Until now the sync loop ran entirely INVISIBLY — it ticked ~3s after boot,
// on resume, every 30s, on pair, and on "Force sync now", but the user had no
// way to SEE that any of it happened. To them sync was "a total mystery". This
// widget is the fix: a small, glanceable pill that listens to
// `SyncEngine.instance` (a ChangeNotifier) and reflects its live state.
//
// States (driven by SyncEngine.status + lastSuccessAt + lastError):
//   * NOT PAIRED / disconnected      → hidden (SizedBox.shrink). Cleanest:
//                                       there's nothing to say when there's no
//                                       server. Also makes the pill safe to
//                                       drop into a shared app-bar slot — it
//                                       simply vanishes on web/desktop/unpaired.
//   * syncing                        → spinner + "Syncing…".
//   * success / idle (have a time)   → check + "Synced <relative> ago".
//   * idle, never-synced             → a muted "Waiting to sync".
//   * warning / offline              → muted "Offline — will retry" with the
//                                       lastError on tap/long-press + tooltip.
//   * serverIsNewer                  → an "Update app" hint (overlays the
//                                       success state — it's the more important
//                                       thing to surface once we're caught up).
//
// Native-only safe: SyncEngine is inert on web/desktop (the desktop is the
// passive server; web uses RemoteBackend's direct calls). We additionally guard
// on `LanClient.instance.isPaired` so the pill hides wherever there's no paired
// server, regardless of platform. No timer of its own — it repaints when the
// engine notifies (status flips, metric updates). The relative time can go
// slightly stale between ticks, but the engine notifies at least every 30s
// (the poll), so "Synced 2m ago" never drifts far, and the LAN screen's
// explicit "Last synced" line carries the precise value.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/lan_client.dart';
import '../services/sync_engine.dart';
import '../theme.dart';

/// PURE helper: a compact `<n><unit> ago` style label for how long ago [then]
/// was, relative to [now]. No I/O, no clock read — both instants are passed in
/// so it's trivially unit-testable.
///
/// Buckets (matches the casual phrasing the chat world expects):
///   * < 10s            → "just now"
///   * < 60s            → "Ns ago"   (e.g. "42s ago")
///   * < 60m            → "Nm ago"   (e.g. "3m ago")
///   * < 24h            → "Nh ago"   (e.g. "5h ago")
///   * otherwise        → "Nd ago"   (e.g. "2d ago")
///
/// A future [then] (clock skew between devices, or a then slightly ahead of
/// now) clamps to "just now" rather than emitting a negative number.
String relativeSyncTime(DateTime now, DateTime then) {
  final diff = now.difference(then);
  final secs = diff.inSeconds;
  if (secs < 10) return 'just now';
  if (secs < 60) return '${secs}s ago';
  final mins = diff.inMinutes;
  if (mins < 60) return '${mins}m ago';
  final hours = diff.inHours;
  if (hours < 24) return '${hours}h ago';
  final days = diff.inDays;
  return '${days}d ago';
}

/// A small pill that reflects the live sync state. Drop it anywhere — it hides
/// itself when there's no paired server (web/desktop/unpaired). Wrap nothing;
/// it sizes to its content.
class SyncStatusPill extends StatelessWidget {
  const SyncStatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    // Hard guard: the engine is inert on web (RemoteBackend path), and there's
    // nothing to show until a server is paired. Hiding here keeps the pill safe
    // to embed in shared widgets (e.g. a chat app-bar) without per-callsite
    // platform checks.
    if (kIsWeb) return const SizedBox.shrink();

    return AnimatedBuilder(
      // Rebuild on every SyncEngine notify (status flip, metric update) AND on
      // LanClient changes (pair/disconnect flips isPaired → show/hide).
      animation: Listenable.merge([SyncEngine.instance, LanClient.instance]),
      builder: (context, _) {
        final eng = SyncEngine.instance;
        if (!LanClient.instance.isPaired ||
            eng.status == SyncStatus.disconnected) {
          return const SizedBox.shrink();
        }
        return _buildPill(context, eng);
      },
    );
  }

  Widget _buildPill(BuildContext context, SyncEngine eng) {
    // Resolve (icon, label, color, spinning) for the current state. The
    // serverIsNewer hint takes precedence once we're not actively syncing —
    // it's the one thing the user should act on.
    IconData? icon;
    String label;
    Color color;
    var spinning = false;
    String? tooltip;

    switch (eng.status) {
      case SyncStatus.syncing:
        spinning = true;
        label = 'Syncing…';
        color = EmberColors.primary;
        icon = null; // replaced by the spinner
        break;
      case SyncStatus.success:
      case SyncStatus.idle:
        if (eng.serverIsNewer) {
          icon = Icons.system_update_alt;
          label = 'Update app';
          color = EmberColors.primary;
          tooltip =
              'The PC is running a newer Pyre. Update this app to stay in sync.';
        } else if (eng.lastSuccessAt != null) {
          icon = Icons.check_circle_outline;
          label = 'Synced ${relativeSyncTime(DateTime.now(), eng.lastSuccessAt!)}';
          color = EmberColors.success;
        } else {
          // Paired but no successful tick yet (just paired, first tick pending).
          icon = Icons.schedule;
          label = 'Waiting to sync';
          color = EmberColors.textMid;
        }
        break;
      case SyncStatus.warning:
      case SyncStatus.offline:
        icon = Icons.cloud_off;
        label = 'Offline — will retry';
        color = EmberColors.textMid;
        tooltip = eng.lastError;
        break;
      case SyncStatus.disconnected:
        // Handled in build() (returns shrink); keep the switch exhaustive.
        return const SizedBox.shrink();
    }

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: EmberColors.bgElevated,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinning)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            )
          else if (icon != null)
            Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    // The error/hint text is available on tap (snackbar) AND hover (tooltip).
    if (tooltip == null || tooltip.isEmpty) return pill;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tooltip!), duration: const Duration(seconds: 4)),
          );
        },
        child: pill,
      ),
    );
  }
}
