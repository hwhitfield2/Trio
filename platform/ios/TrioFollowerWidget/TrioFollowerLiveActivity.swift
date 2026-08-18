import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
extension FollowerActivityAttributes.ContentState {
    static var preview: Self {
        let now = Date().timeIntervalSince1970
        return Self(
            bg: "120",
            direction: "→",
            change: "+2",
            iob: "1.5",
            cob: "20",
            readingDate: now,
            low: 70,
            high: 180,
            color: nil,
            chart: (0 ..< 24).map { index in
                Point(v: Double(110 + (index % 8) * 6), t: now - Double(23 - index) * 300)
            },
            eventual: "115",
            overrideName: nil,
            tempTargetName: nil,
            lastLoop: now
        )
    }
}

@available(iOS 16.2, *)
struct TrioFollowerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        let configuration = ActivityConfiguration(for: FollowerActivityAttributes.self) { context in
            // Read per-draw rather than once: the extension is long-lived, and a
            // settings change redraws the activity without a new content state.
            FollowerLiveActivityView(context: context, preferences: .load())
                .addFollowerIsWatchOS()
        } dynamicIsland: { context in
            let state = context.state
            let preferences = FollowerDisplayPreferences.load()
            let stale = context.readingIsStale
            let glucoseColor = state.glucoseColor(preferences)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(state.bg)
                            .font(.title2)
                            .fontWeight(.bold)
                            .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                        Text(state.direction).font(.headline)
                    }
                    .foregroundStyle(stale ? .secondary : glucoseColor)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(state.change).font(.headline)
                        Text(verbatim: "IOB \(state.iob)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        FollowerReadingAge(state: state, stale: stale)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    FollowerStatusPills(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActivityChart(state: state, preferences: preferences)
                        .frame(height: 44)
                        .privacySensitive()
                }
            } compactLeading: {
                Text(state.bg)
                    .fontWeight(.semibold)
                    .foregroundStyle(stale ? .secondary : glucoseColor)
            } compactTrailing: {
                Text(state.direction)
                    .foregroundStyle(stale ? .secondary : glucoseColor)
            } minimal: {
                Text(state.bg)
                    .fontWeight(.semibold)
                    .foregroundStyle(stale ? .secondary : glucoseColor)
            }
            .widgetURL(URL(string: "triofollower://"))
            .keylineTint(glucoseColor)
        }

        // The Smart Stack on Apple Watch and the CarPlay dashboard, which is the
        // only way the follower's glucose reaches either. Matches Trio, which
        // offers the same surface from the host.
        if #available(iOS 18.0, *) {
            return configuration.supplementalActivityFamilies([.small])
        } else {
            return configuration
        }
    }
}
