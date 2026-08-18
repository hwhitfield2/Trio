import 'package:flutter/material.dart';

import '../models/glucose_ranges.dart';

/// The static scheme's three colours, matching Trio's own
/// `getDynamicGlucoseColor`: a reading is red below the host's low, orange at
/// or above its high, green in between.
const glucoseLowColor = Colors.red;
const glucoseInRangeColor = Colors.green;
const glucoseHighColor = Colors.orange;

/// The window the dynamic scheme sweeps its hue across, in mg/dL.
///
/// Hard-coded on the host too, and deliberately wider than the host's low and
/// high: shading from red at the low itself would leave every in-range reading
/// crowded into the greens. Keep in step with `GlucoseChartView` in Trio — the
/// point of all of this is that the same reading is the same colour on both
/// screens.
const _dynamicLow = 55.0;
const _dynamicHigh = 220.0;

/// The colour the host would paint [sgv] (mg/dL), given the ranges it reports.
Color glucoseColorFor(double sgv, GlucoseRanges ranges) {
  if (ranges.isDynamic) {
    return _hueBasedColor(sgv, target: ranges.target);
  }
  if (sgv >= ranges.high) return glucoseHighColor;
  if (sgv <= ranges.low) return glucoseLowColor;
  return glucoseInRangeColor;
}

/// Red at the bottom of the window, green at the host's target, violet at the
/// top, and the rainbow in between — a port of Trio's
/// `calculateHueBasedGlucoseColor`.
Color _hueBasedColor(double sgv, {required double target}) {
  const redHue = 0.0;
  const greenHue = 120.0;
  const purpleHue = 270.0;

  // The host's target normally sits well inside the window; a host reporting
  // one that does not would otherwise interpolate across zero, or backwards.
  final pivot = target.clamp(_dynamicLow + 1, _dynamicHigh - 1).toDouble();

  final double hue;
  if (sgv <= _dynamicLow) {
    hue = redHue;
  } else if (sgv >= _dynamicHigh) {
    hue = purpleHue;
  } else if (sgv <= pivot) {
    hue = redHue + (sgv - _dynamicLow) / (pivot - _dynamicLow) * (greenHue - redHue);
  } else {
    hue = greenHue + (sgv - pivot) / (_dynamicHigh - pivot) * (purpleHue - greenHue);
  }

  // Saturation and brightness are the host's, not a guess: SwiftUI's
  // Color(hue:saturation:brightness:) is HSV, which is what HSVColor is.
  return HSVColor.fromAHSV(1, hue, 0.6, 0.9).toColor();
}
