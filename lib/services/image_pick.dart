// 2026-07-07 (Gui): "abre a galeria mas não de um jeito muito legal" — the
// native photo gallery, not the SAF document browser. file_picker's
// FileType.image opens the Android/iOS document UI (a "Files"-style chooser);
// image_picker opens the polished system Photos grid. This module routes pure-
// IMAGE picks through image_picker on phones and falls back to file_picker on
// desktop/web (where image_picker has no gallery UI).
//
// NOT for card/backup imports: a chara_card PNG carries embedded metadata the
// photo picker can re-encode away, and those flows also accept .json/.zip — so
// they keep using file_picker directly. This is for photos only.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// A picked image, source-agnostic. [bytes] is always populated. [path] is a
/// real filesystem path on native platforms (null on web) for callers that
/// hand a `file://` URI onward (e.g. the Discover webview upload bridge).
class PickedImage {
  final String name;
  final Uint8List bytes;
  final String? path;
  const PickedImage({required this.name, required this.bytes, this.path});

  /// Lowercase extension parsed from [name] (without the dot), or '' if none.
  String get ext {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }
}

bool get _nativeGallery =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Pick ONE image. Phones → native gallery / photo picker; desktop/web →
/// file dialog filtered to images. Null when the user cancels.
Future<PickedImage?> pickOneImage() async {
  if (_nativeGallery) {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return null;
    return PickedImage(
        name: x.name, bytes: await x.readAsBytes(), path: x.path);
  }
  final res = await FilePicker.platform.pickFiles(
    type: FileType.image,
    withData: true,
  );
  if (res == null || res.files.isEmpty) return null;
  final f = res.files.first;
  final bytes = f.bytes;
  if (bytes == null) return null;
  return PickedImage(name: f.name, bytes: bytes, path: f.path);
}

/// Pick one or more images. Phones → gallery multi-select; desktop/web →
/// file dialog. Empty list when cancelled.
Future<List<PickedImage>> pickImages({bool multiple = false}) async {
  if (_nativeGallery) {
    if (!multiple) {
      final one = await pickOneImage();
      return one == null ? const [] : [one];
    }
    final xs = await ImagePicker().pickMultiImage();
    return [
      for (final x in xs)
        PickedImage(name: x.name, bytes: await x.readAsBytes(), path: x.path),
    ];
  }
  final res = await FilePicker.platform.pickFiles(
    type: FileType.image,
    withData: true,
    allowMultiple: multiple,
  );
  if (res == null) return const [];
  return [
    for (final f in res.files)
      if (f.bytes != null)
        PickedImage(name: f.name, bytes: f.bytes!, path: f.path),
  ];
}
