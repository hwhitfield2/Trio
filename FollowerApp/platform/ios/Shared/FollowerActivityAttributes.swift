import ActivityKit
import Foundation

/// The Live Activity's data, shared by the app (which starts and updates the
/// activity) and the widget extension (which renders it).
///
/// Deliberately Foundation-only: this file is compiled into the Runner target
/// as well, whose deployment target is whatever the Flutter template ships, so
/// it must not depend on SwiftUI or on anything newer than the app supports.
/// Presentation lives in the widget extension.
///
/// Every displayed value arrives pre-formatted from `WidgetBridge` in Dart, so
/// nothing here repeats the app's unit conversion or rounding.
@available(iOS 16.2, *)
struct FollowerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        struct Point: Codable, Hashable {
            /// Glucose in the host's display units.
            let v: Double
            /// Seconds since epoch. Seconds rather than milliseconds because
            /// ActivityKit's payload budget is 4 KB and the chart dominates it.
            let t: Double

            var date: Date { Date(timeIntervalSince1970: t) }
        }

        let bg: String
        let direction: String
        let change: String
        let iob: String
        let cob: String
        /// Seconds since epoch of the reading in `bg`.
        let readingDate: Double
        /// The host's display low and high, in display units: the guide lines,
        /// and the range a reading is coloured against.
        let low: Double
        let high: Double
        /// Which scheme the host colours with, and what the dynamic one needs.
        /// Optional like everything below: a host or app build that predates it
        /// sends nothing, and the static three colours are what the Lock Screen
        /// drew before anyway.
        let color: FollowerGlucoseColorRanges?
        let chart: [Point]

        // Everything below is only drawn by the detailed layouts, and only when
        // there is something to draw. Optional so that a host or an app build
        // that predates them still decodes: the synthesised decoder treats a
        // missing key as nil, and ignores keys it does not know.

        /// Predicted eventual glucose, pre-formatted in display units.
        let eventual: String?
        let overrideName: String?
        let tempTargetName: String?
        /// Seconds since epoch of the host's last loop cycle.
        let lastLoop: Double?

        /// Matches the widgets and Trio itself: older than six minutes is no
        /// longer current.
        static let staleAfter: TimeInterval = 6 * 60

        var reading: Date { Date(timeIntervalSince1970: readingDate) }

        var lastLoopDate: Date? { lastLoop.map { Date(timeIntervalSince1970: $0) } }

        var isOverrideActive: Bool { !(overrideName ?? "").isEmpty }
        var isTempTargetActive: Bool { !(tempTargetName ?? "").isEmpty }

        /// When this reading stops being current. Handed to ActivityKit as the
        /// activity's stale date, which is what gets the system to re-render
        /// the Lock Screen at that moment — nothing else would, because a Live
        /// Activity is only redrawn when new content arrives.
        var staleDate: Date { reading.addingTimeInterval(Self.staleAfter) }

        func isStale(asOf date: Date) -> Bool {
            date.timeIntervalSince(reading) > Self.staleAfter
        }

        var glucoseValue: Double? { Double(bg) }
    }

    /// Fixed for the life of the activity. The host's name lets someone paired
    /// with more than one host tell the activities apart.
    let hostName: String
}

/// How the host colours glucose, as it reports it to this device.
///
/// The display low and high travel with the payload already, so only what the
/// dynamic scheme needs is here. Every value is in the host's display units —
/// the same ones the readings themselves arrive in — so nothing that reads it
/// has to know whether that is mg/dL or mmol/L.
///
/// Keep in sync with `GlucoseRanges.toPayload` in
/// `lib/models/glucose_ranges.dart`, and with `FollowerLiveActivityState` on
/// the host, which builds the same object for a pushed update.
struct FollowerGlucoseColorRanges: Codable, Hashable {
    /// `GlucoseColorScheme`'s raw value on the host: "staticColor" or
    /// "dynamicColor".
    let scheme: String
    /// The glucose target in force on the host, which the dynamic sweep shades
    /// to green at.
    let target: Double
    /// The window the sweep runs across: red at `sweepLow`, violet at
    /// `sweepHigh`. Wider than the display range on purpose — see the host's
    /// `GlucoseChartView`.
    let sweepLow: Double
    let sweepHigh: Double

    var isDynamic: Bool { scheme == "dynamicColor" }
}
