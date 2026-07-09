import 'package:flutter/material.dart';

import '../theme.dart';

/// A bottom-sheet action menu that stays FULLY REACHABLE.
///
/// 2026-07-09 (issue #2, Falgrom on a Pixel 10 / gesture nav): the character
/// kebab menu's bottom items (e.g. "Delete character") landed inside Android's
/// gesture-navigation safe area, so tapping them fired a system gesture instead
/// of the action. In landscape it was worse — the default `showModalBottomSheet`
/// caps its height at 9/16 of the screen with NO scroll, so a tall menu (or a
/// short landscape height) simply pushed items off-screen.
///
/// This helper fixes all of that once:
///   - `isScrollControlled: true` drops the 9/16 cap so we control the height;
///   - the content is capped at 85% of the screen and made SCROLLABLE, so every
///     item is reachable no matter how many there are or how short the screen is;
///   - a `SafeArea` pads the bottom gesture-nav inset so the last item never
///     sits under the gesture strip.
///
/// [itemsBuilder] receives the sheet's own `BuildContext` so callers can keep
/// using `Navigator.pop(sheet)` inside their `onTap`s.
Future<T?> showMenuSheet<T>(
  BuildContext context, {
  required List<Widget> Function(BuildContext sheet) itemsBuilder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        // 1.2.1 audit fix (env-matrix finding #1): the cap was measured off
        // the FULL screen height, but this SafeArea reserves the top status
        // bar AND bottom gesture-nav insets OUTSIDE that same 85%-tall box —
        // it doesn't grow the box to compensate, so the total rendered sheet
        // was `cap + insets` tall. On short/landscape screens that pushed
        // the panel's top edge to (or above) the very top of the screen,
        // invading the status bar. Subtracting the insets BEFORE applying
        // the percentage keeps the total height within the intended 85%.
        constraints: BoxConstraints(
          maxHeight:
              (MediaQuery.of(sheet).size.height -
                  MediaQuery.of(sheet).viewPadding.vertical) *
              0.85,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: itemsBuilder(sheet),
          ),
        ),
      ),
    ),
  );
}
