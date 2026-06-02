// Wave CY.18.90: user-remappable desktop keyboard shortcuts.
//
// Pre-Wave the shortcuts (Ctrl+, Ctrl+N, Ctrl+K, Ctrl+F) were
// hardcoded as `SingleActivator` constants directly in main.dart's
// build method. This service turns them into a small reactive
// preference layer so the new Desktop Shortcuts screen (Wave 90)
// can remap them per action and persist the choice.
//
// Why a separate service and not just inline `Map<String, ...>` in
// AppStore? Two reasons:
//   1. The mapping from "stored binding" → SingleActivator has its
//      own logic (key serialisation, modifier flags, default
//      fallback). Keeping it next to the UiPrefs schema would mix
//      data + UI in models.dart, which we've tried to avoid.
//   2. Multiple surfaces consume this — main.dart's CallbackShortcuts
//      map, the command palette's row labels, the Desktop Shortcuts
//      screen's chips. One source of truth, three readers.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/models.dart';

/// Stable identifiers for every desktop shortcut we expose. New
/// shortcuts MUST get a new id here AND a default binding +
/// human label below.
class ShortcutAction {
  static const openSettings = 'openSettings';
  static const newChat = 'newChat';
  static const searchCharacters = 'searchCharacters';
  static const commandPalette = 'commandPalette';

  /// Ordered list — UI uses this to render rows in a stable sequence.
  static const all = [
    openSettings,
    newChat,
    searchCharacters,
    commandPalette,
  ];
}

/// One key combo: the activating key + which modifiers must be held.
/// Serialises to JSON inside [UiPrefs.desktopShortcuts]. Use
/// [toActivator] to feed `CallbackShortcuts.bindings` and [label]
/// to render the human-readable chip.
class ShortcutBinding {
  /// `LogicalKeyboardKey.keyId` — stable across Flutter versions.
  /// We persist the raw int because `LogicalKeyboardKey` is not
  /// JSON-serialisable directly. Deserialise via
  /// `LogicalKeyboardKey.findKeyByKeyId(int)`.
  final int keyId;
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;

  const ShortcutBinding({
    required this.keyId,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  factory ShortcutBinding.fromJson(Map<String, dynamic> j) =>
      ShortcutBinding(
        keyId: (j['keyId'] as num).toInt(),
        ctrl: (j['ctrl'] as bool?) ?? false,
        shift: (j['shift'] as bool?) ?? false,
        alt: (j['alt'] as bool?) ?? false,
        meta: (j['meta'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'keyId': keyId,
        if (ctrl) 'ctrl': true,
        if (shift) 'shift': true,
        if (alt) 'alt': true,
        if (meta) 'meta': true,
      };

  /// Convert to a Flutter [SingleActivator] for `CallbackShortcuts`.
  /// Returns null if the persisted keyId no longer resolves to a
  /// known logical key (shouldn't happen but we guard rather than
  /// crash on a corrupt prefs JSON).
  SingleActivator? toActivator() {
    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    if (key == null) return null;
    return SingleActivator(
      key,
      control: ctrl,
      shift: shift,
      alt: alt,
      meta: meta,
    );
  }

  /// Human-readable label like "Ctrl + ," / "Shift + Alt + K".
  /// Used by the command palette and the Desktop Shortcuts chip.
  String label() {
    final parts = <String>[];
    if (ctrl) parts.add('Ctrl');
    if (alt) parts.add('Alt');
    if (shift) parts.add('Shift');
    if (meta) parts.add('Meta');
    parts.add(_keyLabel(keyId));
    return parts.join(' + ');
  }

  /// Friendly label for common keys. Falls back to the key's debug
  /// name (`LogicalKeyboardKey.keyLabel`) if the key isn't in our
  /// pretty-name table.
  static String _keyLabel(int keyId) {
    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    if (key == null) return '?';
    // Common one-char keys: keyLabel is the upper-case char.
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.period) return '.';
    if (key == LogicalKeyboardKey.slash) return '/';
    if (key == LogicalKeyboardKey.semicolon) return ';';
    if (key == LogicalKeyboardKey.quote) return "'";
    if (key == LogicalKeyboardKey.bracketLeft) return '[';
    if (key == LogicalKeyboardKey.bracketRight) return ']';
    if (key == LogicalKeyboardKey.backslash) return '\\';
    if (key == LogicalKeyboardKey.minus) return '-';
    if (key == LogicalKeyboardKey.equal) return '=';
    if (key == LogicalKeyboardKey.backquote) return '`';
    final label = key.keyLabel;
    if (label.isNotEmpty) return label;
    // Fallback: debugName ("LogicalKeyboardKey.f5") → "F5"
    final debug = key.debugName ?? '';
    final dot = debug.lastIndexOf('.');
    if (dot >= 0) return debug.substring(dot + 1);
    return debug;
  }

  Map<String, dynamic> toComparable() => {
        'k': keyId,
        if (ctrl) 'c': true,
        if (shift) 's': true,
        if (alt) 'a': true,
        if (meta) 'm': true,
      };
}

/// The factory defaults — restore this set when the user clicks
/// "Restore defaults" on the shortcuts screen. SingleActivator's
/// `meta` flag handles the macOS Command-key remap, but we ship
/// Ctrl as the cross-platform default because Pyre's desktop user
/// base is overwhelmingly Windows + Linux today.
final Map<String, ShortcutBinding> kDefaultShortcutBindings = {
  ShortcutAction.openSettings: ShortcutBinding(
    keyId: LogicalKeyboardKey.comma.keyId,
    ctrl: true,
  ),
  ShortcutAction.newChat: ShortcutBinding(
    keyId: LogicalKeyboardKey.keyN.keyId,
    ctrl: true,
  ),
  ShortcutAction.searchCharacters: ShortcutBinding(
    keyId: LogicalKeyboardKey.keyF.keyId,
    ctrl: true,
  ),
  ShortcutAction.commandPalette: ShortcutBinding(
    keyId: LogicalKeyboardKey.keyK.keyId,
    ctrl: true,
  ),
};

/// Human labels for the Desktop Shortcuts screen + command palette.
/// Keys MUST match [ShortcutAction.all].
const Map<String, String> kShortcutActionLabels = {
  ShortcutAction.openSettings: 'Open Settings',
  ShortcutAction.newChat: 'New chat — pick a character',
  ShortcutAction.searchCharacters: 'Search characters',
  ShortcutAction.commandPalette: 'Show the command palette',
};

/// Resolve the effective binding for an action: persisted value if
/// the user remapped it, otherwise the factory default. Always
/// returns a non-null binding — the four canonical actions always
/// have defaults.
ShortcutBinding effectiveBinding(String actionId, UiPrefs prefs) {
  final raw = prefs.desktopShortcuts[actionId];
  if (raw is Map) {
    try {
      return ShortcutBinding.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {/* fall through to default */}
  }
  return kDefaultShortcutBindings[actionId]!;
}

/// True iff a candidate binding is already in use by a DIFFERENT
/// action. The Desktop Shortcuts screen calls this on capture so
/// users can't bind two actions to the same combo by accident (the
/// CallbackShortcuts map would silently overwrite one of them
/// otherwise — the user would think their remap "didn't take").
String? conflictingAction(
  ShortcutBinding candidate,
  String forActionId,
  UiPrefs prefs,
) {
  final cand = candidate.toComparable();
  for (final id in ShortcutAction.all) {
    if (id == forActionId) continue;
    final other = effectiveBinding(id, prefs).toComparable();
    if (_mapEquals(cand, other)) {
      return id;
    }
  }
  return null;
}

bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
