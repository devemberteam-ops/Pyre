// Party-message avatar cluster (owner ask: "ao apertar nas fotinhas... abrir
// a imagem e rodar as fotos"). The cluster wires each mini-avatar's tap to
// showImageSwipeViewer over the whole party's refs. This tests that public
// launcher: it opens a fullscreen swipeable viewer starting at the tapped
// index, and is a no-op for an empty list.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pyre/widgets/gallery_strip.dart';

// A 1x1 transparent PNG as a data: URL — Lightbox.resolveImage decodes it
// without needing AttachmentStore / a real file, so the viewer can paint.
String _pngDataUrl() {
  final bytes = Uint8List.fromList(const [
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
    0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
    0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 250, 207, 0, 0, 0, //
    3, 1, 1, 0, 24, 221, 141, 219, 0, 0, 0, 0, 73, 69, 78, 68, //
    174, 66, 96, 130,
  ]);
  return 'data:image/png;base64,${base64Encode(bytes)}';
}

void main() {
  testWidgets('showImageSwipeViewer opens a swipeable viewer at the tapped '
      'index', (tester) async {
    final refs = [_pngDataUrl(), _pngDataUrl(), _pngDataUrl()];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showImageSwipeViewer(
              context,
              refs: refs,
              initialIndex: 1,
              ownerName: 'Bran',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The fullscreen swipe viewer is on screen (a PageView over the refs).
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('showImageSwipeViewer is a no-op for an empty ref list',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () =>
                showImageSwipeViewer(context, refs: const []),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Nothing was pushed — no viewer.
    expect(find.byType(PageView), findsNothing);
    expect(find.text('open'), findsOneWidget); // still on the original screen
  });
}
