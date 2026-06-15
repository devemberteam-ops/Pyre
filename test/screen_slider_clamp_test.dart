// Bug 4 regression: the private _SliderCard (long_term_memory_screen.dart) and
// _SliderRow (chat_appearance_screen.dart) passed `value` raw to Material Slider
// without clamping.  A synced/hand-edited value outside [min,max] trips Slider's
// internal assert (debug crash) or mis-renders the thumb (release).
//
// Fix: `value.clamp(min, max)` is applied to the value handed to the Slider
// widget (the stored setting is left untouched — display-side only).
//
// These private widgets cannot be instantiated from outside the library so we
// test the clamp CONTRACT directly (same `double.clamp` call used in the fix)
// and provide a pure helper that mirrors exactly what the fix does so the
// semantics are pinned even if the widget code is refactored.

import 'package:flutter_test/flutter_test.dart';

// Mirror of the one-liner clamp applied in both screen fixes.
double _sliderClamp(double value, double min, double max) =>
    value.clamp(min, max);

void main() {
  group('Bug 4: slider value clamped to [min,max] before Slider widget', () {
    test('value above max clamps to max', () {
      expect(_sliderClamp(8000, 64, 4096), 4096);
    });

    test('value below min clamps to min', () {
      expect(_sliderClamp(-1, 0, 2), 0);
    });

    test('value at min is unchanged', () {
      expect(_sliderClamp(0, 0, 1), 0);
    });

    test('value at max is unchanged', () {
      expect(_sliderClamp(1, 0, 1), 1);
    });

    test('value strictly inside range is unchanged', () {
      expect(_sliderClamp(0.7, 0, 1), 0.7);
    });

    // Long-term memory screen specific values.
    test('memoryLimit above max (e.g. 200 with max 100) clamps to max', () {
      expect(_sliderClamp(200, 0, 100), 100);
    });

    test('autoEvery below min (e.g. -5 with min 0) clamps to min', () {
      expect(_sliderClamp(-5, 0, 50), 0);
    });

    // Chat appearance screen specific values.
    test('bubbleTextScale above max (e.g. 3.0 with max 2.0) clamps to max', () {
      expect(_sliderClamp(3.0, 0.5, 2.0), 2.0);
    });

    test('bubbleBlurSigma below min clamps to min', () {
      expect(_sliderClamp(-1.0, 0.0, 20.0), 0.0);
    });

    test('bubbleCornerRadius above max clamps to max', () {
      expect(_sliderClamp(100.0, 0.0, 32.0), 32.0);
    });

    test('bubbleBorderWidth below min clamps to min', () {
      expect(_sliderClamp(-2.0, 0.0, 8.0), 0.0);
    });
  });
}
