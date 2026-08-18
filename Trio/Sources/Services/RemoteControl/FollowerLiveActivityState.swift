import Foundation

/// The content state of a follower's Live Activity, as ActivityKit expects to
/// decode it on the follower device.
///
/// ⚠️ This is a wire format shared with the follower app, and it is checked at
/// two ends that cannot see each other:
///
///   * `FollowerApp/platform/ios/Shared/FollowerActivityAttributes.swift`
///     declares `ContentState`. ActivityKit decodes the pushed JSON into it
///     with the default decoding strategy, so **the property names here must
///     match it exactly** — a rename on either side silently stops every
///     remote update, because a payload that fails to decode is simply dropped.
///   * `FollowerApp/lib/services/live_activity_bridge.dart` builds the same
///     structure in Dart when the app updates the activity itself. Both sides
///     must format identically or the Lock Screen would visibly change when it
///     switched between being updated locally and remotely.
///
/// Formatting therefore lives here rather than in the follower's widget: the
/// values are display strings, already converted to the host's units.
struct FollowerLiveActivityState: Encodable, Equatable {
    struct Point: Encodable, Equatable {
        /// Glucose in the host's display units.
        let v: Double
        /// Seconds since epoch.
        let t: Double
    }

    /// How this host colours glucose, so the follower's Lock Screen paints a
    /// reading the colour Trio's own chart would.
    ///
    /// The display low and high travel alongside, so only what the dynamic
    /// scheme needs is here. Display units throughout, like every other number
    /// in this state. Mirrors `FollowerGlucoseColorRanges` in the follower app.
    struct GlucoseColorRanges: Encodable, Equatable {
        /// `GlucoseColorScheme`'s raw value: "staticColor" or "dynamicColor".
        let scheme: String
        /// The glucose target in force, which the dynamic sweep shades green at.
        let target: Double
        /// The window that sweep runs across — the same hard-coded pair
        /// `GlucoseChartView` shades between, converted to display units.
        let sweepLow: Double
        let sweepHigh: Double
    }

    let bg: String
    let direction: String
    let change: String
    let iob: String
    let cob: String
    let readingDate: Double
    let low: Double
    let high: Double
    /// Absent when the snapshot carries no ranges, which is the same signal the
    /// follower already handles: colour by the low and high alone.
    let color: GlucoseColorRanges?
    let chart: [Point]

    // Drawn only by the follower's detailed layouts. Optional on both sides, so
    // a follower app that predates them still decodes what it does know.

    /// Predicted eventual glucose, pre-formatted in the host's display units.
    let eventual: String?
    let overrideName: String?
    let tempTargetName: String?
    /// Seconds since epoch of the host's last loop cycle.
    let lastLoop: Double?

    /// The window the dynamic colour scheme sweeps across, in mg/dL. Hard-coded
    /// in `GlucoseChartView` too, and deliberately wider than the display range:
    /// shading from red at the low itself would crowd every in-range reading
    /// into the greens.
    static let colorSweepLow: Double = 55
    static let colorSweepHigh: Double = 220

    /// Roughly two hours at a five-minute cadence, matching the follower's own
    /// chart budget. ActivityKit's payload limit is 4 KB and the chart
    /// dominates it.
    static let maxChartPoints = 24

    /// Matches the follower's widgets and Trio itself: a reading older than six
    /// minutes is no longer current.
    static let staleAfter: TimeInterval = 6 * 60

    var staleDate: Date { Date(timeIntervalSince1970: readingDate + Self.staleAfter) }

    /// The state as a JSON dictionary, ready to nest inside an APNS payload.
    /// Encoded with the default strategy, which is the only one ActivityKit
    /// decodes with.
    func asJSONObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FollowerPushError.transportFailure("Live Activity state did not encode to an object")
        }
        return object
    }

    /// Builds the state from the same snapshot that is pushed as encrypted
    /// status, so the Lock Screen can never disagree with the app.
    static func from(snapshot: FollowerStatusSnapshot) -> FollowerLiveActivityState? {
        guard let latest = snapshot.readings.first else { return nil }

        let mmol = snapshot.units == "mmol/L"

        func convert(_ mgdl: Double) -> Double {
            guard mmol else { return mgdl }
            // Rounded to one decimal before encoding, matching the Dart side's
            // `double.parse(x.toStringAsFixed(1))`, so the two never differ in
            // the last digit.
            return (mgdl / 18.0 * 10).rounded() / 10
        }

        func formatGlucose(_ sgv: Int) -> String {
            mmol ? oneDecimal(Double(sgv) / 18.0) : String(sgv)
        }

        var change = ""
        if snapshot.readings.count >= 2 {
            let delta = snapshot.readings[0].sgv - snapshot.readings[1].sgv
            let sign = delta >= 0 ? "+" : ""
            change = mmol
                ? sign + oneDecimal(Double(delta) / 18.0)
                : sign + String(delta)
        }

        return FollowerLiveActivityState(
            bg: formatGlucose(latest.sgv),
            direction: trendArrow(for: latest.direction),
            change: change,
            iob: snapshot.iob.map { oneDecimal($0) } ?? "--",
            cob: snapshot.cob.map { String(Int($0.rounded())) } ?? "--",
            readingDate: latest.date,
            // The host's display range when it has one — the follower's alert
            // thresholds say when to wake someone, not how to draw a chart.
            low: convert(snapshot.ranges?.low ?? snapshot.low),
            high: convert(snapshot.ranges?.high ?? snapshot.high),
            color: snapshot.ranges.map {
                GlucoseColorRanges(
                    scheme: $0.scheme,
                    target: convert($0.target),
                    sweepLow: convert(colorSweepLow),
                    sweepHigh: convert(colorSweepHigh)
                )
            },
            chart: snapshot.readings.prefix(maxChartPoints).map {
                Point(v: convert(Double($0.sgv)), t: $0.date)
            },
            eventual: snapshot.eventualBG.map { formatGlucose(Int($0.rounded())) },
            overrideName: snapshot.override?.name,
            tempTargetName: snapshot.tempTarget?.name,
            lastLoop: snapshot.lastLoop
        )
    }

    /// One decimal place, rounded the way Dart's `toStringAsFixed` rounds.
    ///
    /// Dart rounds the double's *exact* value to the nearest tenth, and on an
    /// exact tie takes the one further from zero. Two obvious shortcuts each
    /// get half of that wrong:
    ///
    ///   * `(value * 10).rounded()` — 0.35 is really 0.34999999999999997…, but
    ///     multiplying by ten rounds it up to exactly 3.5 before the second
    ///     rounding ever sees it, giving "0.4" where Dart gives "0.3".
    ///   * `String(format: "%.1f")` — correct on 0.35, but it breaks an exact
    ///     tie to even, giving "1.2" for 1.25 where Dart gives "1.3".
    ///
    /// So the decision is made on the exact decimal digits instead. Printing
    /// twenty places is far more than enough to tell a true tie (0.25 →
    /// 0.25000…) from a near miss (0.35 → 0.34999…).
    ///
    /// This matters because the same number is formatted here for a pushed
    /// Live Activity and in Dart for a local one; a Lock Screen reading 0.4
    /// above an app reading 0.3 is exactly what these two must never do.
    static func oneDecimal(_ value: Double) -> String {
        let digits = String(format: "%.20f", abs(value))
        let parts = digits.split(separator: ".")

        guard parts.count == 2, var whole = Int(parts[0]), let first = parts[1].first,
              var tenths = first.wholeNumberValue
        else {
            return String(format: "%.1f", value)
        }

        // The first dropped digit decides it: 5 or more rounds away from zero,
        // which covers both "past the half" and "exactly on it".
        if let next = parts[1].dropFirst().first, next >= "5" {
            tenths += 1
            if tenths == 10 {
                tenths = 0
                whole += 1
            }
        }

        let sign = value < 0 ? "-" : ""
        return "\(sign)\(whole).\(tenths)"
    }

    /// The same glyphs the follower app draws for a trend, so a remote update
    /// and a local one are indistinguishable.
    static func trendArrow(for direction: String?) -> String {
        switch direction {
        case "TripleUp",
             "DoubleUp": return "⇈"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown": return "↓"
        case "DoubleDown",
             "TripleDown": return "⇊"
        default: return ""
        }
    }
}
