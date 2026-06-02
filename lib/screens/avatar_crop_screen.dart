// Avatar crop modal — pan + zoom interaction port of js/cropper.js.
//
// Uses InteractiveViewer to position the source image inside a fixed-size
// square viewport. The "Save" action rasterises the viewport's visible
// region into a 512x512 PNG, base64-encoded into a data: URL — matching
// the rest of the app's avatar storage format.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';

class AvatarCropScreen extends StatefulWidget {
  final Uint8List sourceBytes;
  const AvatarCropScreen({super.key, required this.sourceBytes});

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final GlobalKey _captureKey = GlobalKey();
  final TransformationController _tx = TransformationController();
  bool _saving = false;

  @override
  void dispose() {
    _tx.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final boundary = _captureKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      // Render at 2x for crisp 512px output from a 256pt viewport.
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw 'failed to encode';
      final data = bytes.buffer.asUint8List();
      if (!mounted) return;
      Navigator.of(context).pop(data);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Crop failed: $e')));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EmberColors.bgDeep,
      appBar: AppBar(
        title: const Text('Crop avatar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset',
            onPressed: () => _tx.value = Matrix4.identity(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            const Text(
              'Pinch to zoom · drag to position',
              style: TextStyle(color: EmberColors.textMid),
            ),
            const SizedBox(height: 16),
            // Square cropper viewport at 256 logical px → 512 px output.
            ClipOval(
              child: RepaintBoundary(
                key: _captureKey,
                child: SizedBox(
                  width: 256,
                  height: 256,
                  child: ColoredBox(
                    color: EmberColors.bgElevated,
                    child: InteractiveViewer(
                      transformationController: _tx,
                      minScale: 0.5,
                      maxScale: 4,
                      child: Image.memory(
                        widget.sourceBytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).pop(null),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Use this crop'),
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Push the crop screen and return the resulting PNG bytes (or null if
/// the user cancelled).
Future<Uint8List?> cropAvatar(
    BuildContext context, Uint8List sourceBytes) async {
  return Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AvatarCropScreen(sourceBytes: sourceBytes),
    ),
  );
}
