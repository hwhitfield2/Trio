import ActivityKit
import Charts
import SwiftUI
import WidgetKit

// MARK: - Presentation helpers

@available(iOS 16.2, *)
extension FollowerActivityAttributes.ContentState {
    func color(for value: Double?) -> Color {
        guard let value else { return .primary }
        if value <= low { return .red }
        if value >= high { return .orange }
        return .green
    }

    var glucoseColor: Color { color(for: glucoseValue) }

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
            chart: (0 ..< 24).map { index in
                Point(v: Double(110 + (index % 8) * 6), t: now - Double(23 - index) * 300)
            }
        )
    }
}

/// The activity's own chart. Separate from the widgets' because the payload is
/// its own compact shape and the window is shorter.
@available(iOS 16.2, *)
struct LiveActivityChart: View {
    let state: FollowerActivityAttributes.ContentState

    var body: some View {
        let anchor = state.chart.map(\.date).max() ?? state.reading
        let start = anchor.addingTimeInterval(-2 * 3600)
        let points = state.chart.filter { $0.date >= start }
        let values = points.map(\.v)
        let minValue = min(values.min() ?? state.low, state.low)
        let maxValue = max(values.max() ?? state.high, state.high)

        Chart {
            RuleMark(y: .value("High", state.high))
                .foregroundStyle(.orange.opacity(0.7))
                .lineStyle(.init(lineWidth: 1, dash: [4]))
            RuleMark(y: .value("Low", state.low))
                .foregroundStyle(.red.opacity(0.7))
                .lineStyle(.init(lineWidth: 1, dash: [4]))

            ForEach(points, id: \.self) { point in
                PointMark(x: .value("Time", point.date), y: .value("Glucose", point.v))
                    .symbolSize(10)
                    .foregroundStyle(state.color(for: point.v))
            }
        }
        .chartYScale(domain: minValue ... maxValue)
        .chartXScale(domain: start ... anchor)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
    }
}

// MARK: - Live Activity

@available(iOS 16.2, *)
struct TrioFollowerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FollowerActivityAttributes.self) { context in
            lockScreen(context)
        } dynamicIsland: { context in
            let state = context.state
            let stale = state.isStale(asOf: Date())

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(state.bg)
                            .font(.title2)
                            .fontWeight(.bold)
                            .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                        Text(state.direction).font(.headline)
                    }
                    .foregroundStyle(stale ? .secondary : state.glucoseColor)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(state.change).font(.headline)
                        Text(verbatim: "IOB \(state.iob)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActivityChart(state: state)
                        .frame(height: 44)
                        .privacySensitive()
                }
            } compactLeading: {
                Text(state.bg)
                    .fontWeight(.semibold)
                    .foregroundStyle(stale ? .secondary : state.glucoseColor)
            } compactTrailing: {
                Text(state.direction)
                    .foregroundStyle(stale ? .secondary : state.glucoseColor)
            } minimal: {
                Text(state.bg)
                    .fontWeight(.semibold)
                    .foregroundStyle(stale ? .secondary : state.glucoseColor)
            }
            .widgetURL(URL(string: "triofollower://"))
            .keylineTint(state.glucoseColor)
        }
    }

    @ViewBuilder private func lockScreen(
        _ context: ActivityViewContext<FollowerActivityAttributes>
    ) -> some View {
        let state = context.state
        let stale = state.isStale(asOf: Date())

        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(state.bg)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                Text(state.direction).font(.title3).fontWeight(.bold)
                Text(state.change).font(.headline).foregroundStyle(.secondary)

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.attributes.hostName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(verbatim: "IOB \(state.iob) · COB \(state.cob)")
                        .font(.caption)
                }
            }
            .foregroundStyle(stale ? .secondary : state.glucoseColor)

            LiveActivityChart(state: state).frame(height: 46)
        }
        .padding(14)
        // Glucose is visible on the lock screen while the activity runs; honour
        // the user's sensitive-content setting the way the widgets do.
        .privacySensitive()
        .activityBackgroundTint(nil)
    }
}
