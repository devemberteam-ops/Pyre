// WS-J — Display settings.
//
// New home for cross-platform appearance / display knobs. Currently hosts the
// global "App text size" slider (moved out of the inline More list — the More
// screen now links here via a "Display" row). The slider behaviour is
// IDENTICAL to before: it tracks a local value while dragging and commits
// through [AppStore.setUiScale], which clamps + persists and triggers the
// whole-app rebuild that re-applies the scale. This screen is the future home
// for related display settings.
//
// Also hosts the "Wide desktop layout" toggle (relocated here from
// DesktopShortcutsScreen — it's a display preference, so it belongs next to
// text size). Gated via [_isDesktopLike]: desktop builds AND web (a
// desktop-browser PWA shares the desktop responsive layout since
// 2026-07-03); on mobile builds the card simply isn't built.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart' show UiPrefs;
import '../state/app_store.dart';
import '../theme.dart';

/// True where the wide-layout preference has any effect: desktop builds AND
/// web (2026-07-03 — a desktop-browser PWA now shares the desktop responsive
/// layout; on a phone-sized web viewport the toggle is harmlessly inert,
/// exactly like a narrow desktop window). Platform isn't available on web,
/// so check kIsWeb first.
bool get _isDesktopLike {
  if (kIsWeb) return true;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Display')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          const _DisplayCard(),
          // Desktop + web: the wide-layout preference. Hidden on mobile
          // builds, where it has no effect.
          if (_isDesktopLike) ...const [
            SizedBox(height: 12),
            _DesktopLayoutCard(),
          ],
        ],
      ),
    );
  }
}

/// "Wide desktop layout" toggle — relocated from DesktopShortcutsScreen.
///
/// Behaviour is identical to before: it reads/writes
/// [UiPrefs.desktopWideLayout] via [AppStore.setDesktopWideLayout]. The
/// actual layout decision still happens at render time in main.dart
/// (this flag combined with the window width).
class _DesktopLayoutCard extends StatelessWidget {
  const _DesktopLayoutCard();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        value: store.uiPrefs.desktopWideLayout,
        onChanged: store.setDesktopWideLayout,
        title: const Text(
          'Wide desktop layout',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          'Off: same mobile layout, centered in a narrow column '
          '(phone-in-a-window).\n'
          'On: side rail + wider content. Recommended for larger '
          'windows.',
          style: TextStyle(
            color: EmberColors.textMid,
            fontSize: 12,
            height: 1.4,
          ),
        ),
        activeThumbColor: EmberColors.primary,
      ),
    );
  }
}

/// "App text size" card — a global UI text-scale slider.
///
/// Range is [UiPrefs.kUiScaleMin]–[UiPrefs.kUiScaleMax]; the live value shows
/// as a percentage, and a "Reset" affordance snaps back to 100%. The slider
/// tracks a local value while dragging (so it stays smooth) and commits
/// through [AppStore.setUiScale], which clamps + persists and triggers the
/// whole-app rebuild that re-applies the scale.
class _DisplayCard extends StatefulWidget {
  const _DisplayCard();

  @override
  State<_DisplayCard> createState() => _DisplayCardState();
}

class _DisplayCardState extends State<_DisplayCard> {
  // Local "in-flight" value while the thumb is being dragged. Null means
  // "not dragging — read the live value straight from the store".
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final stored = store.uiPrefs.clampedUiScale;
    final value = _dragValue ?? stored;
    final pct = (value * 100).round();
    final isDefault = (stored - 1.0).abs() < 0.001 && _dragValue == null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'App text size',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '$pct%',
                  style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
                // "Reset" only when the user has moved off 100%.
                if (!isDefault)
                  TextButton(
                    onPressed: () {
                      setState(() => _dragValue = null);
                      store.setUiScale(1.0);
                    },
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Reset'),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
            Padding(
              padding: EdgeInsets.only(top: 2, bottom: 2),
              child: Text(
                'Make all text in the app larger or smaller. '
                'This adds to your device font-size setting.',
                style: TextStyle(
                  color: EmberColors.textMid,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            Row(
              children: [
                Text('A',
                    style: TextStyle(
                        fontSize: 13, color: EmberColors.textDim)),
                Expanded(
                  child: Slider(
                    value: value,
                    min: UiPrefs.kUiScaleMin,
                    max: UiPrefs.kUiScaleMax,
                    // 0.8 → 1.4 in 0.05 steps = 12 divisions.
                    divisions: 12,
                    label: '$pct%',
                    onChanged: (v) => setState(() => _dragValue = v),
                    onChangeEnd: (v) {
                      store.setUiScale(v);
                      setState(() => _dragValue = null);
                    },
                  ),
                ),
                Text('A',
                    style: TextStyle(
                        fontSize: 22, color: EmberColors.textDim)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
