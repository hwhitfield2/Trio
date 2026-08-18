import SwiftUI

/// The colour the host would paint a reading, from the ranges it reported.
///
/// One implementation for the widgets and the Live Activity alike: they show
/// the same numbers side by side on the same Lock Screen, and two of these
/// would eventually disagree.
enum FollowerGlucoseColor {
    static func color(
        for value: Double,
        low: Double,
        high: Double,
        ranges: FollowerGlucoseColorRanges?
    ) -> Color {
        if let ranges, ranges.isDynamic {
            return hueBased(value, ranges: ranges)
        }
        // The host's own static scheme, boundaries included.
        if value >= high { return .orange }
        if value <= low { return .red }
        return .green
    }

    /// A port of Trio's `calculateHueBasedGlucoseColor`: red at the bottom of
    /// the sweep, green at the host's target, violet at the top.
    private static func hueBased(_ value: Double, ranges: FollowerGlucoseColorRanges) -> Color {
        let redHue = 0.0
        let greenHue = 120.0 / 360.0
        let purpleHue = 270.0 / 360.0

        let low = ranges.sweepLow
        let high = ranges.sweepHigh
        // A sweep that is not a range cannot be interpolated across; the static
        // colours are the honest answer rather than a divide by zero.
        guard high > low else { return .green }

        // The target normally sits well inside the sweep. One that does not
        // would interpolate backwards, or across zero. The margin is a share of
        // the sweep rather than a fixed number, because these are display units
        // and one mmol/L is eighteen mg/dL.
        let margin = (high - low) * 0.01
        let pivot = min(max(ranges.target, low + margin), high - margin)

        let hue: Double
        if value <= low {
            hue = redHue
        } else if value >= high {
            hue = purpleHue
        } else if value <= pivot {
            hue = redHue + (value - low) / (pivot - low) * (greenHue - redHue)
        } else {
            hue = greenHue + (value - pivot) / (high - pivot) * (purpleHue - greenHue)
        }

        return Color(hue: hue, saturation: 0.6, brightness: 0.9)
    }
}

/// The range a view actually draws with: what the payload carried, with this
/// device's own choices applied on top.
struct FollowerGlucoseRange {
    let low: Double
    let high: Double
    /// Nil means the static three colours — either because that is what the
    /// host uses, or because this device asked for it.
    let color: FollowerGlucoseColorRanges?
}

extension FollowerDisplayPreferences {
    /// Folds this device's range and scheme into what arrived.
    ///
    /// Applied even to content the app itself built, where it changes nothing:
    /// the app resolved the same choices before writing it. The case that
    /// matters is a Live Activity pushed by the *host*, which knows nothing
    /// about how this follower likes to see things.
    ///
    /// Mirrors `DisplayPreferences.resolveRanges` in
    /// `lib/models/display_preferences.dart`.
    func resolvedRange(
        low: Double,
        high: Double,
        color: FollowerGlucoseColorRanges?
    ) -> FollowerGlucoseRange {
        var resolvedLow = glucoseRange.low ?? low
        var resolvedHigh = glucoseRange.high ?? high

        // Overriding one end only can leave it the wrong side of the other; the
        // host's end gives way, since the overridden one is what was asked for.
        if resolvedLow >= resolvedHigh {
            if glucoseRange.low != nil, glucoseRange.high != nil {
                resolvedLow = low
                resolvedHigh = high
            } else if glucoseRange.low != nil {
                resolvedHigh = resolvedLow + 1
            } else {
                resolvedLow = resolvedHigh - 1
            }
        }

        let resolvedColor: FollowerGlucoseColorRanges?
        if glucoseRange.forcesStatic {
            resolvedColor = nil
        } else if glucoseRange.forcesDynamic, let color {
            resolvedColor = FollowerGlucoseColorRanges(
                scheme: "dynamicColor",
                target: color.target,
                sweepLow: color.sweepLow,
                sweepHigh: color.sweepHigh
            )
        } else {
            // Asking for the dynamic sweep from a host that reports none leaves
            // nothing to sweep between; the static colours are what is left.
            resolvedColor = color
        }

        return FollowerGlucoseRange(low: resolvedLow, high: resolvedHigh, color: resolvedColor)
    }
}
