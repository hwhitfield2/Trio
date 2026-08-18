import SwiftUI
import WidgetKit

// MARK: - Widget 2: Trend & range

/// Answers "how has the day been going", rather than "what is it right now":
/// the chart gets the whole widget, with the share of readings low / in range /
/// high underneath.
struct TrioFollowerTrendWidgetEntryView: View {
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
        .followerContainerBackground(for: family)
    }

    @ViewBuilder private func content(for context: FollowerContext) -> some View {
        switch family {
        case .accessoryRectangular:
            FollowerTrendAccessoryView(context: context)
        default:
            FollowerTrendView(context: context, isLarge: family == .systemLarge)
        }
    }
}

struct FollowerTrendView: View {
    let context: FollowerContext
    var isLarge = false

    private var windowText: String {
        let hours = Int((context.status.chartWindow / 3600).rounded())
        return "\(hours)h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(context.status.bg)
                    .font(.title2)
                    .fontWeight(.bold)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                    .foregroundStyle(context.glucoseColor)

                if !context.status.direction.isEmpty {
                    Text(context.status.direction)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(context.glucoseColor)
                }

                Text(context.status.change).font(.subheadline).foregroundStyle(.secondary)

                Spacer()

                Text(context.updatedText)
                    .font(.caption2)
                    .foregroundStyle(context.isStale ? .red.opacity(0.6) : .secondary)
            }

            FollowerChartView(status: context.status, colorSchemeChoice: context.preferences.glucoseColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let stats = context.status.stats {
                FollowerRangeBar(stats: stats, window: windowText, showLabels: isLarge)
            } else {
                Text(verbatim: "\(context.status.units) · \(windowText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Time in range as a single stacked bar, which reads at a glance in a way three
/// percentages side by side do not.
struct FollowerRangeBar: View {
    let stats: FollowerStatus.Stats
    let window: String
    var showLabels = false

    private var total: Double {
        max(Double(stats.low + stats.inRange + stats.high), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    segment(width: geometry.size.width, value: stats.low, color: .red)
                    segment(width: geometry.size.width, value: stats.inRange, color: .green)
                    segment(width: geometry.size.width, value: stats.high, color: .orange)
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)

            HStack(spacing: 6) {
                Text(verbatim: "\(stats.inRange)% in range")
                    .fontWeight(.semibold)

                if showLabels {
                    Text(verbatim: "\(stats.low)% low")
                        .foregroundStyle(.red)
                    Text(verbatim: "\(stats.high)% high")
                        .foregroundStyle(.orange)
                }

                Spacer()
                Text(window).foregroundStyle(.secondary)
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    private func segment(width: CGFloat, value: Int, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width * CGFloat(Double(value) / total)))
    }
}

struct FollowerTrendAccessoryView: View {
    let context: FollowerContext

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(context.status.bg).fontWeight(.bold)
                if !context.status.direction.isEmpty {
                    Text(context.status.direction)
                }
                Text(context.status.change)
            }
            .font(.headline)
            .widgetAccentable()

            if let stats = context.status.stats {
                Text(verbatim: "\(stats.inRange)% in range · \(stats.low)% low")
                    .font(.caption2)
            }

            Text(context.updatedText).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrioFollowerTrendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FollowerWidgetStore.trendKind, provider: FollowerProvider()) { entry in
            TrioFollowerTrendWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Trend & Range")
        .description("The glucose chart with the share of readings low, in range and high.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}
