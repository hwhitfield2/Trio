import Charts
import SwiftUI
import WidgetKit

// MARK: - Chart

/// Readings over the span the payload actually covers, coloured by the host's
/// own thresholds.
///
/// The domain is anchored to the newest reading rather than "now" so a stale
/// payload does not slide its points off the left edge, and the window comes
/// from the data because the host trims readings to fit its push budget.
struct FollowerChartView: View {
    @Environment(\.colorScheme) private var colorScheme

    let status: FollowerStatus
    var window: TimeInterval?
    var showThresholdLines = true

    var body: some View {
        let anchor = max(status.readingDate ?? Date(), status.chart.map(\.date).max() ?? Date())
        let span = window ?? status.chartWindow
        let start = anchor.addingTimeInterval(-span)
        let points = status.chart.filter { $0.date >= start }
        let values = points.map(\.v)
        let minValue = min(values.min() ?? status.low, status.low)
        let maxValue = max(values.max() ?? status.high, status.high)

        Chart {
            if showThresholdLines {
                RuleMark(y: .value("High", status.high))
                    .foregroundStyle(.orange)
                    .lineStyle(.init(lineWidth: 1, dash: [5]))

                RuleMark(y: .value("Low", status.low))
                    .foregroundStyle(.red)
                    .lineStyle(.init(lineWidth: 1, dash: [5]))
            }

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
        .chartXScale(domain: start ... anchor)
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

// MARK: - Widget 1: Glucose

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
        .followerContainerBackground(for: family)
    }

    @ViewBuilder private func content(for context: FollowerContext) -> some View {
        switch family {
        case .systemMedium:
            FollowerGlucoseMediumView(context: context)
        case .accessoryCircular:
            FollowerCircularView(context: context)
        case .accessoryRectangular:
            FollowerRectangularView(context: context)
        case .accessoryInline:
            FollowerInlineView(context: context)
        default:
            FollowerGlucoseSmallView(context: context)
        }
    }
}

struct FollowerGlucoseSmallView: View {
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
                    Text(context.status.direction).font(.title3).fontWeight(.bold)
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

struct FollowerGlucoseMediumView: View {
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

struct TrioFollowerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FollowerWidgetStore.glucoseKind, provider: FollowerProvider()) { entry in
            TrioFollowerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Glucose")
        .description("Glucose, trend and insulin on board from the paired Trio host.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

// MARK: - Bundle

@main struct TrioFollowerWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrioFollowerWidget()
        TrioFollowerTrendWidget()
        TrioFollowerLoopWidget()
    }
}
