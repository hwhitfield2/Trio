import ActivityKit
import Foundation

/// The payload Trio hands to its home screen and lock screen widgets.
///
/// The widgets deliberately show the very same numbers as the Live Activity, so instead of defining
/// a parallel set of fields the snapshot carries the Live Activity's own `ContentState`. Everything
/// the Live Activity knows about - glucose and trend, IOB, COB, TDD, eventual glucose, an active
/// override or temp target, the glucose chart, and the user's chosen widget items - reaches the
/// widgets unchanged.
struct TrioWidgetSnapshot: Codable, Hashable {
    /// The content state as last built by `LiveActivityManager`.
    let state: LiveActivityAttributes.ContentState

    /// Date of the glucose reading shown in `state.bg`, used to decide whether it has gone stale.
    let glucoseDate: Date

    /// Mirrors the Live Activity's staleness rule: ActivityKit marks the activity stale six minutes
    /// after the reading it displays, at which point the views strike the glucose value through.
    static let staleThreshold: TimeInterval = 6 * 60

    /// Whether the reading carried by this snapshot is too old to still be shown as current.
    func isStale(asOf date: Date) -> Bool {
        date.timeIntervalSince(glucoseDate) > Self.staleThreshold
    }
}
