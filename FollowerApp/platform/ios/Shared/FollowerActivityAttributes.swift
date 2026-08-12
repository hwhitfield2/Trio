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
        /// Low and high thresholds in display units, for colouring.
        let low: Double
        let high: Double
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

        var reading: Date { Date(timeIntervalSince1970: readingDate) }

        var lastLoopDate: Date? { lastLoop.map { Date(timeIntervalSince1970: $0) } }

        var isOverrideActive: Bool { !(overrideName ?? "").isEmpty }
        var isTempTargetActive: Bool { !(tempTargetName ?? "").isEmpty }

        /// Matches the widgets and Trio itself: older than six minutes is no
        /// longer current.
        func isStale(asOf date: Date) -> Bool {
            date.timeIntervalSince(reading) > 6 * 60
        }

        var glucoseValue: Double? { Double(bg) }
    }

    /// Fixed for the life of the activity. The host's name lets someone paired
    /// with more than one host tell the activities apart.
    let hostName: String
}
