import Charts
import SwiftUI
import WidgetKit

// MARK: - Payload

/// The status payload the Flutter app writes into the shared app group.
///
/// Every displayed value arrives pre-formatted, so this extension never repeats
/// the app's unit conversion or rounding. Keep in sync with `WidgetBridge` in
/// `lib/services/widget_bridge.dart`.
struct FollowerStatus: Codable {
    struct ChartPoint: Codable, Hashable {
        /// Glucose in the host's display units.
        let v: Double
        /// Milliseconds since epoch.
        let t: Double

        var date: Date { Date(timeIntervalSince1970: t / 1000) }
    }

    let units: String
    let bg: String
    let direction: String
    let change: String
    let glucoseDate: Double?
    let hostDate: Double?
    let lastLoop: Double?
    let iob: String?
    let cob: String?
    let eventualBg: String?
    let tempTargetName: String?
    let overrideName: String?
    /// Low and high thresholds, already in display units.
    let low: Double
    let high: Double
    let chart: [ChartPoint]

    /// Mirrors Trio's own widget: a reading older than six minutes is shown as
    /// no longer current.
    static let staleThreshold: TimeInterval = 6 * 60

    var readingDate: Date? {
        guard let glucoseDate else { return nil }
        return Date(timeIntervalSince1970: glucoseDate / 1000)
    }

    func isStale(asOf date: Date) -> Bool {
        guard let readingDate else { return true }
        return date.timeIntervalSince(readingDate) > Self.staleThreshold
    }

    /// The numeric glucose value, for colouring. `nil` when there is no reading.
    var glucoseValue: Double? { Double(bg) }

    func color(for value: Double?) -> Color {
        guard let value else { return .primary }
        if value <= low { return .red }
        if value >= high { return .orange }
        return .green
    }

    var glucoseColor: Color { color(for: glucoseValue) }

    static var placeholder: FollowerStatus {
        let now = Date().timeIntervalSince1970 * 1000
        return FollowerStatus(
            units: "mg/dL",
            bg: "120",
            direction: "→",
            change: "+2",
            glucoseDate: now,
            hostDate: now,
            lastLoop: now,
            iob: "1.5",
            cob: "20",
            eventualBg: "124",
            tempTargetName: nil,
            overrideName: nil,
            low: 70,
            high: 180,
            chart: (0 ..< 36).map { index in
                ChartPoint(
                    v: Double(110 + (index % 12) * 5),
                    t: now - Double(35 - index) * 300_000
                )
            }
        )
    }
}

// MARK: - Store

enum FollowerWidgetStore {
    static let kind = "TrioFollowerWidget"
    private static let payloadKey = "trio_follower_status"

    /// App group shared with the host app. Written into the extension's
    /// Info.plist at build time because it carries the Apple team id.
    private static var appGroupId: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    static func load() -> FollowerStatus? {
        guard let appGroupId,
              let defaults = UserDefaults(suiteName: appGroupId),
              let raw = defaults.string(forKey: payloadKey),
              let data = raw.data(using: .utf8)
        else { return nil }

        return try? JSONDecoder().decode(FollowerStatus.self, from: data)
    }
}

// MARK: - Timeline

struct FollowerEntry: TimelineEntry {
    let date: Date
    let status: FollowerStatus?
}

struct FollowerProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let entryCount = 6

    func placeholder(in _: Context) -> FollowerEntry {
        FollowerEntry(date: Date(), status: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FollowerEntry) -> Void) {
        let status = context.isPreview ? FollowerStatus.placeholder : FollowerWidgetStore.load()
        completion(FollowerEntry(date: Date(), status: status))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<FollowerEntry>) -> Void) {
        let status = FollowerWidgetStore.load()
        let now = Date()

        // The app reloads this timeline whenever a status push arrives, including
        // in the background. These entries only cover the case where the host goes
        // quiet: they re-render the same data later, which is what lets the reading
        // eventually show up as stale.
        let entries = (0 ..< Self.entryCount).map { index in
            FollowerEntry(
                date: now.addingTimeInterval(Double(index) * Self.refreshInterval),
                status: status
            )
        }

        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Views

/// What each view needs: the payload plus whether it has gone stale by the time
/// this entry is shown.
struct FollowerContext {
    let status: FollowerStatus
    let isStale: Bool

    init(status: FollowerStatus, now: Date) {
        self.status = status
        isStale = status.isStale(asOf: now)
    }

    var glucoseColor: Color { isStale ? .secondary : status.glucoseColor }

    var updatedText: String {
        guard let date = status.readingDate else { return "--" }
        return DateFormatter.followerTime.string(from: date)
    }
}

extension DateFormatter {
    static let followerTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

struct TrioFollowerWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    var entry: FollowerEntry

    var body: some View {
        Group {
            if let status = entry.status {
                content(for: FollowerContext(status: status, now: entry.date))
            } else {
                FollowerNoDataView()
            }
        }
        .privacySensitive()
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private func content(for context: FollowerContext) -> some View {
        switch family {
        case .systemMedium:
            FollowerMediumView(context: context)
        case .accessoryCircular:
            FollowerCircularView(context: context)
        case .accessoryRectangular:
            FollowerRectangularView(context: context)
        case .accessoryInline:
            FollowerInlineView(context: context)
        default:
            FollowerSmallView(context: context)
        }
    }

    @ViewBuilder private var background: some View {
        switch family {
        case .accessoryCircular:
            AccessoryWidgetBackground()
        case .accessoryInline,
             .accessoryRectangular:
            Color.clear
        default:
            Color(.systemBackground)
        }
    }
}

struct FollowerSmallView: View {
    let context: FollowerContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(context.status.bg)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                if !context.status.direction.isEmpty {
                    Text(context.status.direction)
                        .font(.title3)
                        .fontWeight(.bold)
                }
            }
            .foregroundStyle(context.glucoseColor)

            HStack(spacing: 5) {
                Text(context.status.change.isEmpty ? "--" : context.status.change)
                    .fontWeight(.semibold)

                Text(context.status.units)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.caption)

            Divider()

            HStack(spacing: 12) {
                FollowerValueLabel(value: context.status.iob ?? "--", unit: "U", label: "IOB")
                FollowerValueLabel(value: context.status.cob ?? "--", unit: "g", label: "COB")
            }

            HStack(spacing: 4) {
                Text("Updated:")
                Text(context.updatedText).fontWeight(.semibold)
            }
            .font(.caption2)
            .foregroundStyle(context.isStale ? .red.opacity(0.6) : .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct FollowerMediumView: View {
    @Environment(\.colorScheme) private var colorScheme

    let context: FollowerContext

    var body: some View {
        VStack(spacing: 4) {
            FollowerChartView(status: context.status)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) { activePills }

            HStack(spacing: 8) {
                HStack(alignment: .center, spacing: 2) {
                    Text(context.status.bg)
                        .font(.title3)
                        .fontWeight(.bold)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                    if !context.status.direction.isEmpty {
                        Text(context.status.direction).font(.subheadline).fontWeight(.bold)
                    }
                }
                .foregroundStyle(context.glucoseColor)

                Divider().frame(height: 24)
                FollowerValueLabel(value: context.status.iob ?? "--", unit: "U", label: "IOB")
                Divider().frame(height: 24)
                FollowerValueLabel(value: context.status.cob ?? "--", unit: "g", label: "COB")
                Divider().frame(height: 24)
                FollowerValueLabel(value: context.updatedText, label: "Updated")
            }
        }
    }

    @ViewBuilder private var activePills: some View {
        HStack(spacing: 4) {
            if let name = context.status.overrideName, !name.isEmpty {
                pill(name, color: .purple)
            }
            if let name = context.status.tempTargetName, !name.isEmpty {
                pill(name, color: .green)
            }
        }
    }

    private func pill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(colorScheme == .dark ? 0.6 : 0.8))
            }
    }
}

/// Six hours of readings, coloured by the host's own thresholds.
struct FollowerChartView: View {
    @Environment(\.colorScheme) private var colorScheme

    let status: FollowerStatus

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-6 * 3600)
        let points = status.chart.filter { $0.date > start }
        let values = points.map(\.v)
        let minValue = min(values.min() ?? status.low, status.low)
        let maxValue = max(values.max() ?? status.high, status.high)

        Chart {
            RuleMark(y: .value("High", status.high))
                .foregroundStyle(.orange)
                .lineStyle(.init(lineWidth: 1, dash: [5]))

            RuleMark(y: .value("Low", status.low))
                .foregroundStyle(.red)
                .lineStyle(.init(lineWidth: 1, dash: [5]))

            ForEach(points, id: \.self) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("Glucose", point.v)
                )
                .symbolSize(16)
                .foregroundStyle(status.color(for: point.v))
            }
        }
        .chartYScale(domain: minValue ... maxValue)
        .chartYAxis(.hidden)
        .chartXScale(domain: start ... now)
        .chartXAxis {
            AxisMarks(position: .automatic) { _ in
                AxisGridLine(stroke: .init(lineWidth: 0.65, dash: [2, 3]))
                    .foregroundStyle(Color.primary.opacity(colorScheme == .light ? 1 : 0.5))
            }
        }
        .chartPlotStyle { plotContent in
            plotContent
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .light ? Color.black.opacity(0.08) : .clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct FollowerValueLabel: View {
    let value: String
    var unit: String?
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline).fontWeight(.bold)

                if let unit {
                    Text(unit).font(.caption).fontWeight(.bold)
                }
            }

            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct FollowerCircularView: View {
    let context: FollowerContext

    var body: some View {
        VStack(spacing: -2) {
            Text(context.status.bg)
                .font(.title3)
                .fontWeight(.bold)
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

            if !context.status.direction.isEmpty {
                Text(context.status.direction).font(.caption)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .widgetAccentable()
    }
}

struct FollowerRectangularView: View {
    let context: FollowerContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(context.status.bg)
                    .font(.title3)
                    .fontWeight(.bold)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                if !context.status.direction.isEmpty {
                    Text(context.status.direction).font(.subheadline).fontWeight(.bold)
                }

                Text(context.status.change).font(.subheadline)
            }
            .widgetAccentable()

            HStack(spacing: 6) {
                Text(verbatim: "IOB \(context.status.iob ?? "--")")
                Text(verbatim: "COB \(context.status.cob ?? "--")")
            }
            .font(.caption)

            Text(context.updatedText).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FollowerInlineView: View {
    let context: FollowerContext

    var body: some View {
        Text(verbatim: "\(context.status.bg) \(context.status.direction) \(context.status.change)")
    }
}

/// Shown until the follower has received its first status from the host.
struct FollowerNoDataView: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("--").font(.title2).fontWeight(.bold)
            Text("Open Trio Follower").font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

// MARK: - Widget

struct TrioFollowerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FollowerWidgetStore.kind, provider: FollowerProvider()) { entry in
            TrioFollowerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Trio Follower")
        .description("Glucose, insulin and carbs from the paired Trio host.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

@main struct TrioFollowerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrioFollowerWidget()
    }
}
