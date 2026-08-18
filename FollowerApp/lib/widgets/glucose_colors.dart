import 'package:flutter/material.dart';

import '../models/glucose_ranges.dart';

/// The static scheme's three colours, matching Trio's own
/// `getDynamicGlucoseColor`: a reading is red below the host's low, orange at
/// or above its high, green in between.
const glucoseLowColor = Colors.red;
const glucoseInRangeColor = Colors.green;
const glucoseHighColor = Colors.orange;

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

  const sweepLow = GlucoseRanges.dynamicSweepLow;
  const sweepHigh = GlucoseRanges.dynamicSweepHigh;

  // The host's target normally sits well inside the window; a host reporting
  // one that does not would otherwise interpolate across zero, or backwards.
  // The margin is a share of the sweep, so the native widgets — which work in
  // display units, where one mmol/L is eighteen mg/dL — can clamp identically.
  const margin = (sweepHigh - sweepLow) * 0.01;
  final pivot = target.clamp(sweepLow + margin, sweepHigh - margin).toDouble();

  final double hue;
  if (sgv <= sweepLow) {
    hue = redHue;
  } else if (sgv >= sweepHigh) {
    hue = purpleHue;
  } else if (sgv <= pivot) {
    hue = redHue + (sgv - sweepLow) / (pivot - sweepLow) * (greenHue - redHue);
  } else {
    hue = greenHue + (sgv - pivot) / (sweepHigh - pivot) * (purpleHue - greenHue);
  }

  // Saturation and brightness are the host's, not a guess: SwiftUI's
  // Color(hue:saturation:brightness:) is HSV, which is what HSVColor is.
  return HSVColor.fromAHSV(1, hue, 0.6, 0.9).toColor();
}
