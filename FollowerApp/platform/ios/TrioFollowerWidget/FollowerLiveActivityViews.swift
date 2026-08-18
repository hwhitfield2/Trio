import ActivityKit
import Charts
import SwiftUI
import WidgetKit

// MARK: - Presentation helpers

@available(iOS 16.2, *)
extension FollowerActivityAttributes.ContentState {
    /// The range this device draws against: what arrived — from the app or
    /// straight from the host — with whatever the follower chose to see
    /// instead.
    func range(_ preferences: FollowerDisplayPreferences) -> FollowerGlucoseRange {
        preferences.resolvedRange(low: low, high: high, color: color)
    }

    /// The colour that range gives this value, unless the user asked for a
    /// single colour instead.
    func color(for value: Double?, preferences: FollowerDisplayPreferences) -> Color {
        guard preferences.glucoseColor == .dynamicColor, let value else { return .primary }
        let range = range(preferences)
        return FollowerGlucoseColor.color(
            for: value,
            low: range.low,
            high: range.high,
            ranges: range.color
        )
    }

    func glucoseColor(_ preferences: FollowerDisplayPreferences) -> Color {
        color(for: glucoseValue, preferences: preferences)
    }
}

@available(iOS 16.2, *)
extension ActivityViewContext where Attributes == FollowerActivityAttributes {
    /// Whether the reading on screen has aged out.
    ///
    /// The `isStale` half is the one that matters. A Live Activity view is
    /// rendered only when new content arrives, so a view that decided this
    /// from `Date()` alone would draw the last reading as current forever once
    /// updates stopped — which is exactly what a stale Lock Screen looks like.
    /// The system re-renders at the activity's stale date and flips this flag,
    /// so the strikethrough appears without anything having to be pushed.
    ///
    /// The date comparison is the iOS 16 fallback, and also catches a state
    /// that was already old when it arrived.
    var readingIsStale: Bool {
        if #available(iOS 17.0, *), isStale { return true }
        return state.isStale(asOf: Date())
    }
}

/// How long ago the reading was taken, counting up by itself.
///
/// A relative date is the one thing on the Lock Screen that keeps moving
/// without a content update, on every iOS version — so the activity can never
/// look fresher than the data behind it.
@available(iOS 16.2, *)
struct FollowerReadingAge: View {
    let state: FollowerActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        Text(state.reading, style: .relative)
            .font(.caption2)
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(stale ? .red.opacity(0.8) : .secondary)
    }
}

/// Whether the activity is being drawn in the Apple Watch Smart Stack or on
/// CarPlay rather than on the phone.
///
/// `activityFamily` only exists from iOS 18, and the views need an answer on
/// every version, so it is republished as an environment value the way Trio
/// does it.
private struct FollowerWatchOSKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var followerIsWatchOS: Bool {
        get { self[FollowerWatchOSKey.self] }
        set { self[FollowerWatchOSKey.self] = newValue }
    }
}

@available(iOS 18.0, *)
struct FollowerWatchOSModifier: ViewModifier {
    @Environment(\.activityFamily) var activityFamily

    func body(content: Content) -> some View {
        content.environment(\.followerIsWatchOS, activityFamily == .small)
    }
}

extension View {
    @ViewBuilder func addFollowerIsWatchOS() -> some View {
        if #available(iOS 18.0, *) {
            modifier(FollowerWatchOSModifier())
        } else {
            self
        }
    }

    /// The Smart Stack draws on its own opaque card, the Lock Screen over the
    /// wallpaper — so the two want different padding and backgrounds.
    @ViewBuilder func followerActivityChrome(isWatchOS: Bool) -> some View {
        padding(.all, isWatchOS ? 10 : 14)
            .frame(minHeight: 0, maxHeight: .infinity)
            // Glucose is on the Lock Screen while the activity runs; honour the
            // user's sensitive-content setting the way the widgets do.
            .privacySensitive()
            .foregroundStyle(Color.primary)
            .activityBackgroundTint(isWatchOS ? .black : nil)
    }
}

// MARK: - Chart

/// The activity's own chart. Separate from the widgets' because the payload is
/// its own compact shape and the window is shorter.
@available(iOS 16.2, *)
struct LiveActivityChart: View {
    let state: FollowerActivityAttributes.ContentState
    var preferences: FollowerDisplayPreferences = .default

    var body: some View {
        let anchor = state.chart.map(\.date).max() ?? state.reading
        let start = anchor.addingTimeInterval(-2 * 3600)
        let points = state.chart.filter { $0.date >= start }
        let values = points.map(\.v)
        let range = state.range(preferences)
        let minValue = min(values.min() ?? range.low, range.low)
        let maxValue = max(values.max() ?? range.high, range.high)

        Chart {
            RuleMark(y: .value("High", range.high))
                .foregroundStyle(.orange.opacity(0.7))
                .lineStyle(.init(lineWidth: 1, dash: [4]))
            RuleMark(y: .value("Low", range.low))
                .foregroundStyle(.red.opacity(0.7))
                .lineStyle(.init(lineWidth: 1, dash: [4]))

            ForEach(points, id: \.self) { point in
                PointMark(x: .value("Time", point.date), y: .value("Glucose", point.v))
                    .symbolSize(10)
                    .foregroundStyle(state.color(for: point.v, preferences: preferences))
            }

            FollowerTreatmentChartContent(marks: FollowerTreatmentMarks.marks(
                boluses: (state.boluses ?? []).map { (date: $0.date, units: $0.a) },
                carbs: (state.carbs ?? []).map { (date: $0.date, grams: $0.g) },
                points: points.map { (date: $0.date, value: $0.v) }
            ))
        }
        .chartYScale(domain: minValue ... maxValue)
        .chartXScale(domain: start ... anchor)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
    }
}

// MARK: - Item views

/// One slot of a detailed layout. The follower has no Total Daily Dose to show
/// — the host's status snapshot carries none — so Trio's list is otherwise
/// reproduced here.
@available(iOS 16.2, *)
struct FollowerLiveActivityItemView: View {
    let item: FollowerDisplayPreferences.Item
    let state: FollowerActivityAttributes.ContentState
    let preferences: FollowerDisplayPreferences
    let stale: Bool

    var body: some View {
        switch item {
        case .currentGlucose:
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(state.bg)
                        .font(.title3)
                        .fontWeight(.bold)
                        .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                    Text(state.direction).font(.subheadline)
                }
                .foregroundStyle(stale ? .secondary : state.glucoseColor(preferences))
                Text(state.change).font(.caption).foregroundStyle(.secondary)
            }
        case .currentGlucoseLarge:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(state.bg)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                Text(state.direction).font(.title3).fontWeight(.bold)
            }
            .foregroundStyle(stale ? .secondary : state.glucoseColor(preferences))
        case .iob:
            labelled(value: state.iob + " U", caption: "IOB")
        case .cob:
            labelled(value: state.cob + " g", caption: "COB")
        case .eventualGlucose:
            labelled(value: "⇢ " + (state.eventual ?? "--"), caption: "Eventual")
        case .updatedLabel:
            VStack(spacing: 1) {
                let updated = state.lastLoopDate ?? state.reading
                Text(updated, style: .time)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                Text("Updated").font(.caption2).foregroundStyle(.secondary)
            }
        case .empty:
            EmptyView()
        }
    }

    private func labelled(value: String, caption: LocalizedStringKey) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.callout).fontWeight(.semibold)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The override and temp target badges Trio draws over its detailed chart.
@available(iOS 16.2, *)
struct FollowerStatusPills: View {
    let state: FollowerActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            if let name = state.overrideName, !name.isEmpty {
                pill(name, color: .purple)
            }
            if let name = state.tempTargetName, !name.isEmpty {
                pill(name, color: .green)
            }
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.75))
            }
    }
}

// MARK: - Lock Screen / Smart Stack

@available(iOS 16.2, *)
struct FollowerLiveActivityView: View {
    @Environment(\.followerIsWatchOS) var isWatchOS

    let context: ActivityViewContext<FollowerActivityAttributes>
    let preferences: FollowerDisplayPreferences

    private var state: FollowerActivityAttributes.ContentState { context.state }
    private var stale: Bool { context.readingIsStale }

    var body: some View {
        if isWatchOS {
            watch.followerActivityChrome(isWatchOS: true)
        } else {
            phone.followerActivityChrome(isWatchOS: false)
        }
    }

    // MARK: Watch and CarPlay

    @ViewBuilder private var watch: some View {
        if preferences.watch == .detailed {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(state.bg)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                    Text(state.direction).font(.headline)
                    Text(state.change).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .foregroundStyle(stale ? .secondary : state.glucoseColor(preferences))

                LiveActivityChart(state: state, preferences: preferences)
            }
        } else {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(state.bg)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .strikethrough(stale, pattern: .solid, color: .red.opacity(0.6))
                    Text(state.direction).font(.title3).fontWeight(.bold)
                }
                .foregroundStyle(stale ? .secondary : state.glucoseColor(preferences))

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.change).font(.headline)
                    // How old, not when: the Smart Stack card can sit
                    // untouched for hours, and a clock time there says
                    // nothing about whether it is still worth reading.
                    FollowerReadingAge(state: state, stale: stale)
                }
            }
        }
    }

    // MARK: Lock Screen

    @ViewBuilder private var phone: some View {
        if preferences.lockScreen == .detailed {
            VStack(spacing: 6) {
                LiveActivityChart(state: state, preferences: preferences)
                    .frame(height: 60)
                    .overlay(alignment: .topLeading) { FollowerStatusPills(state: state) }

                HStack(alignment: .center) {
                    ForEach(Array(preferences.items.enumerated()), id: \.offset) { _, item in
                        if item != .empty {
                            FollowerLiveActivityItemView(
                                item: item,
                                state: state,
                                preferences: preferences,
                                stale: stale
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text(context.attributes.hostName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(verbatim: "·").font(.caption2).foregroundStyle(.secondary)
                    FollowerReadingAge(state: state, stale: stale)
                }
            }
        } else {
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
                        FollowerReadingAge(state: state, stale: stale)
                    }
                }
                .foregroundStyle(stale ? .secondary : state.glucoseColor(preferences))

                LiveActivityChart(state: state, preferences: preferences).frame(height: 46)
            }
        }
    }
}
