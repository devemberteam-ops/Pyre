// Native stub for BotbooruWebFrame.
//
// On native builds (exe / apk) the app already embeds botbooru.com in a real
// webview. This stub makes the conditional-import below compile on every
// target without pulling in `package:web` or `dart:ui_web`.
//
// The stub widget is never rendered on native — discover_screen.dart's
// _buildBody() routes native traffic to the webview branch before reaching
// the web-frame branch.

import 'package:flutter/material.dart';

/// Stub implementation — always shows a "not available" placeholder.
/// Real implementation lives in botbooru_web_frame_web.dart (web only).
///
/// v2: onImport signature now carries (botbooruUrl, bbxOrigin) — the bbxOrigin
/// is the cross-origin bbx server endpoint the caller uses for the CORS fetch.
class BotbooruWebFrame extends StatelessWidget {
  /// Called when "Import this card" is tapped. Receives the canonical
  /// `https://botbooru.com/...` URL and the bbx origin string
  /// (`http://host:bbxPort`) for the cross-origin fetch.
  final void Function(String botbooruUrl, String bbxOrigin)? onImport;

  const BotbooruWebFrame({super.key, this.onImport});

  @override
  Widget build(BuildContext context) {
    // This widget is never rendered on native — placeholder guards accidental use.
    return const SizedBox.shrink();
  }
}
