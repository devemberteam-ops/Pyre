import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Show an "Exported — …" confirmation SnackBar that is GUARANTEED to dismiss.
///
/// THE BUG IT FIXES. The "Share" action opens the OS share sheet, which puts
/// the app into an inactive lifecycle state. That freezes the SnackBar's vsync
/// ticker, so the entrance animation can fail to reach `completed` — and
/// Flutter only arms the built-in auto-dismiss timer AFTER that entrance
/// completes. The result is a confirmation bar that hangs on screen forever.
/// The `hideCurrentSnackBar()` callers run before showing this only clears a
/// PRIOR bar; it can never rescue the one being shown now.
///
/// THE FIX. Alongside the normal built-in timer, arm our OWN frame-independent
/// dismissal. A plain [Timer] fires even while the app is inactive / frames
/// are paused, and `controller.close()` targets exactly THIS SnackBar (a no-op
/// if it has already gone). So the bar always clears — whether or not the user
/// ever opened the share sheet.
///
/// [onShare] is the (fire-and-forget) handler for the optional Share button;
/// it should do its own error handling. Pass `null` for a plain notice with no
/// action button (still guaranteed to dismiss). [visible] is the normal
/// built-in display time; the guaranteed close fires one second after it.
void showExportSnack(
  ScaffoldMessengerState messenger,
  String banner,
  Future<void> Function()? onShare, {
  Duration visible = const Duration(seconds: 4),
}) {
  final controller = messenger.showSnackBar(
    SnackBar(
      content: Text(banner),
      action: onShare == null
          ? null
          : SnackBarAction(label: 'Share', onPressed: () => onShare()),
      duration: visible,
    ),
  );
  Timer(visible + const Duration(seconds: 1), () {
    try {
      controller.close();
    } catch (_) {
      // Messenger gone (user navigated away) — nothing to close.
    }
  });
}

/// Deliver a freshly-exported file to the user the right way for the platform.
///
/// THE BUG IT FIXES (Android/iOS). Exports are written under
/// `getApplicationDocumentsDirectory()`, which on mobile is the app's PRIVATE
/// storage — invisible in any file manager. So an "Exported to PyreExports/"
/// notice points at a file the user can never find: it effectively went
/// nowhere. Just opening the OS share sheet isn't enough either — on many
/// devices it has no plain "save to this device" target (it's all Drive /
/// Messages / Quick Share), so "I just want the file in Downloads" is
/// impossible.
///
/// THE FIX. On mobile we open the system **Save** dialog (Storage Access
/// Framework via [FilePicker.saveFile]) for the primary file, so the user picks
/// a real, browsable location (Downloads, etc.) and the PNG/JSON actually lands
/// there. Afterwards we surface a self-dismissing confirmation with a **Share**
/// action, so the upload-to-botbooru / send-to-Discord path (which can include
/// the gallery [files]) is still one tap away. On DESKTOP the documents folder
/// is already user-accessible, so we keep the passive "Exported — …"
/// confirmation + Share button (see [showExportSnack]).
///
/// [files] is the full set to SHARE (card + any gallery images / the chat
/// file). [saveBytes] / [saveFileName] are the PRIMARY artifact to SAVE on
/// mobile (the card PNG, or the chat file); when null on mobile we fall back to
/// the share sheet. [saveExtensions] narrows the Save dialog's type (e.g.
/// `['png']`). [savedBanner] is the desktop confirmation text;
/// [shareSubject]/[shareText] label the shared payload. Never throws.
Future<void> deliverExport(
  ScaffoldMessengerState messenger,
  List<XFile> files, {
  required String savedBanner,
  required String shareSubject,
  required String shareText,
  Uint8List? saveBytes,
  String? saveFileName,
  List<String>? saveExtensions,
}) async {
  Future<void> share() async {
    try {
      await Share.shareXFiles(files, subject: shareSubject, text: shareText);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Share failed: $e')));
    }
  }

  final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  if (isMobile) {
    if (saveBytes != null && saveFileName != null) {
      String? savedPath;
      try {
        savedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save $saveFileName',
          fileName: saveFileName,
          bytes: saveBytes, // required on Android/iOS — writes via SAF
          type: saveExtensions == null ? FileType.any : FileType.custom,
          allowedExtensions: saveExtensions,
        );
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
      // Saved → confirm + offer Share; cancelled → still offer Share so the
      // flow is never a dead end. Both bars are guaranteed to dismiss.
      showExportSnack(
        messenger,
        savedPath != null ? 'Saved to your device' : 'Not saved — share it?',
        share,
      );
      return;
    }
    // No bytes to save (shouldn't happen for our callers) — share instead.
    await share();
    return;
  }
  // Desktop: the file is in the user's Documents/PyreExports — tell them where
  // it landed, offer a Share button, and guarantee the bar dismisses itself.
  messenger.hideCurrentSnackBar();
  showExportSnack(messenger, savedBanner, share);
}
