// M-5: a stored slider value can fall OUTSIDE the widget's [min,max] range
// (an older build with a wider cap, a synced / hand-edited backup with
// `maxTokens > 4096` or `temp > 2`). Material's [Slider] asserts
// `min <= value <= max`, so an out-of-range value crashes in debug and renders
// oddly in release. `SliderCard` must clamp the value it hands to the Slider
// (without mutating the stored value) so it always renders.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/widgets/setting_slider.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  group('M-5: SliderCard clamps an out-of-range value for the Slider', () {
    testWidgets('value ABOVE max renders without an assert; Slider gets max',
        (tester) async {
      await tester.pumpWidget(_host(SliderCard(
        label: 'Max Response Tokens',
        subtitle: 'subtitle',
        value: 8000, // stored value from an older/wider build
        min: 64,
        max: 4096,
        divisions: 63,
        display: '8000',
        onChanged: (_) {},
      )));
      // No exception thrown during build/layout.
      expect(tester.takeException(), isNull);
      // The underlying Slider was handed the clamped value, not 8000.
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 4096);
      // The caller's display string is UNTOUCHED — we don't lose the real value.
      expect(find.text('8000'), findsOneWidget);
    });

    testWidgets('value BELOW min renders without an assert; Slider gets min',
        (tester) async {
      await tester.pumpWidget(_host(SliderCard(
        label: 'Temperature',
        subtitle: 'subtitle',
        value: -1, // below min
        min: 0,
        max: 2,
        divisions: 40,
        display: '-1.00',
        onChanged: (_) {},
      )));
      expect(tester.takeException(), isNull);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 0);
    });

    testWidgets('a temp > 2 (e.g. 3.5) clamps to max=2 and renders',
        (tester) async {
      await tester.pumpWidget(_host(SliderCard(
        label: 'Temperature',
        subtitle: 'subtitle',
        value: 3.5,
        min: 0,
        max: 2,
        divisions: 40,
        display: '3.50',
        onChanged: (_) {},
      )));
      expect(tester.takeException(), isNull);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 2);
    });

    testWidgets('an in-range value is passed through unchanged', (tester) async {
      await tester.pumpWidget(_host(SliderCard(
        label: 'Top-P',
        subtitle: 'subtitle',
        value: 0.7,
        min: 0,
        max: 1,
        divisions: 20,
        display: '0.70',
        onChanged: (_) {},
      )));
      expect(tester.takeException(), isNull);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 0.7);
    });
  });
}
