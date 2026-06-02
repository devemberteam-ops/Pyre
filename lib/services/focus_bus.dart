// Wave CY.18.61: tiny singleton that lets cross-tree code (the
// Ctrl+F handler registered in main.dart's RootShell) reach into
// a screen's FocusNode without prop-drilling or InheritedWidget
// gymnastics.
//
// The active screen registers its search-field FocusNode in
// `initState`, clears it in `dispose`. The shortcut handler asks
// the bus to focus whatever's registered. If nothing's registered
// (screen not built yet, wrong tab active), the call is a no-op.
//
// Why not Provider? Because the registration lifetime is screen-
// scoped and we don't want every consumer rebuilding when the
// focus node changes identity. A static field with a one-line
// register/unregister is the simplest thing that works.

import 'package:flutter/widgets.dart';

class FocusBus {
  FocusBus._();

  /// Registered by Characters screen `initState`. Targets the
  /// list-filtering TextField. Cleared on dispose so a stale
  /// reference can't survive a hot-restart or tab rebuild.
  static FocusNode? charactersSearch;

  /// Best-effort focus + select-all on the registered node. Returns
  /// true if a node was registered and the focus call dispatched —
  /// callers don't need to inspect this; the return is only useful
  /// for tests.
  static bool focusCharactersSearch() {
    final node = charactersSearch;
    if (node == null) return false;
    if (!node.canRequestFocus) return false;
    node.requestFocus();
    return true;
  }
}
