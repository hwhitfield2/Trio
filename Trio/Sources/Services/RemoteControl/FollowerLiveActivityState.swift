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

    let bg: String
    let direction: String
    let change: String
    let iob: String
    let cob: String
    let readingDate: Double
    let low: Double
    let high: Double
    let chart: [Point]

    // Drawn only by the follower's detailed layouts. Optional on both sides, so
    // a follower app that predates them still decodes what it does know.

    /// Predicted eventual glucose, pre-formatted in the host's display units.
    let eventual: String?
    let overrideName: String?
    let tempTargetName: String?
    /// Seconds since epoch of the host's last loop cycle.
    let lastLoop: Double?

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
            low: convert(snapshot.low),
            high: convert(snapshot.high),
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
    /// `String(format: "%.1f")` rounds a half to even, Dart rounds it away
    /// from zero — so 1.25 U would print as "1.2" here and "1.3" in the app,
    /// and the Lock Screen would disagree with the screen behind it whenever
    /// the value landed exactly on a half.
    static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded(.toNearestOrAwayFromZero) / 10
        return String(format: "%.1f", rounded)
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
