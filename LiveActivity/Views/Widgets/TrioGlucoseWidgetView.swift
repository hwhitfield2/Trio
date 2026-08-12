import SwiftUI
import WidgetKit

/// Everything a widget view needs to render a snapshot: the same content state the live activity
/// receives, plus whether that reading has gone stale by the time this timeline entry is shown.
struct TrioWidgetContext {
    let state: LiveActivityAttributes.ContentState
    let isStale: Bool

    init(snapshot: TrioWidgetSnapshot, now: Date) {
        state = snapshot.state
        isStale = snapshot.isStale(asOf: now)
    }

    var additionalState: LiveActivityAttributes.ContentAdditionalState {
        state.detailedViewState
    }

    /// The glucose value's color, dimmed once the reading is stale.
    var glucoseColor: Color {
        isStale ? .secondary : state.glucoseColor
    }

    var iobText: String {
        NumberFormatter.insulinFormatter.string(from: additionalState.iob as NSNumber) ?? "--"
    }

    var tddText: String {
        NumberFormatter.insulinFormatter.string(from: additionalState.tdd as NSNumber) ?? "--"
    }

    var cobText: String {
        "\(additionalState.cob)"
    }

    var eventualGlucoseText: String {
        additionalState.formattedEventualBG(unit: state.unit)
    }
}

// MARK: - Entry point

struct TrioGlucoseWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    var entry: TrioGlucoseWidgetEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                widgetBody(for: TrioWidgetContext(snapshot: snapshot, now: entry.date))
            } else {
                TrioWidgetNoDataView()
            }
        }
        .privacySensitive()
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder private func widgetBody(for context: TrioWidgetContext) -> some View {
        switch family {
        case .systemMedium:
            TrioGlucoseWidgetMediumView(context: context)
        case .accessoryCircular:
            TrioGlucoseAccessoryCircularView(context: context)
        case .accessoryRectangular:
            TrioGlucoseAccessoryRectangularView(context: context)
        case .accessoryInline:
            TrioGlucoseAccessoryInlineView(context: context)
        default:
            TrioGlucoseWidgetSmallView(context: context)
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

// MARK: - Home screen

struct TrioGlucoseWidgetSmallView: View {
    let context: TrioWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(context.state.bg)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                if let direction = context.state.direction {
                    Text(direction)
                        .font(.title3)
                        .fontWeight(.bold)
                }
            }
            .foregroundStyle(context.glucoseColor)

            HStack(spacing: 5) {
                Text(context.state.trimmedChange.isEmpty ? "--" : context.state.trimmedChange)
                    .fontWeight(.semibold)

                Text(context.state.unit)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.caption)

            Divider()

            HStack(spacing: 12) {
                TrioWidgetValueLabel(
                    value: context.iobText,
                    unit: String(localized: "U", comment: "Insulin unit"),
                    label: "IOB",
                    isStale: context.isStale
                )

                TrioWidgetValueLabel(
                    value: context.cobText,
                    unit: String(localized: "g", comment: "gram of carbs"),
                    label: "COB",
                    isStale: context.isStale
                )
            }

            HStack(spacing: 4) {
                Text("Updated:")
                Text(context.state.formattedUpdatedTime)
                    .fontWeight(.semibold)
            }
            .font(.caption2)
            .foregroundStyle(context.isStale ? .red.opacity(0.6) : .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct TrioGlucoseWidgetMediumView: View {
    @Environment(\.colorScheme) private var colorScheme

    let context: TrioWidgetContext

    var body: some View {
        VStack(spacing: 4) {
            TrioGlucoseChartView(state: context.state, additionalState: context.additionalState)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) { activeStatusPills }

            TrioWidgetItemRow(context: context)
        }
    }

    /// The same override / temp target badges the detailed live activity draws over its chart.
    @ViewBuilder private var activeStatusPills: some View {
        HStack(spacing: 4) {
            if context.additionalState.isOverrideActive {
                statusPill(context.additionalState.overrideName, color: .purple)
            }

            if context.additionalState.isTempTargetActive {
                statusPill(context.additionalState.tempTargetName, color: Color("LoopGreen"))
            }
        }
    }

    private func statusPill(_ title: String, color: Color) -> some View {
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

/// The row of items below the chart, honoring the order the user set for the live activity.
struct TrioWidgetItemRow: View {
    let context: TrioWidgetContext

    private var items: [LiveActivityAttributes.LiveActivityItem] {
        let configured = context.additionalState.widgetItems.filter { $0 != .empty }
        return configured.isEmpty ? LiveActivityAttributes.LiveActivityItem.defaultItems : configured
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                TrioWidgetItemView(item: item, context: context)

                if index < items.count - 1 {
                    Divider().frame(height: 24)
                }
            }
        }
    }
}

struct TrioWidgetItemView: View {
    let item: LiveActivityAttributes.LiveActivityItem
    let context: TrioWidgetContext

    var body: some View {
        switch item {
        case .currentGlucoseLarge:
            HStack(alignment: .center, spacing: 2) {
                Text(context.state.bg)
                    .font(.title3)
                    .fontWeight(.bold)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                if let direction = context.state.direction {
                    Text(direction)
                        .font(.subheadline)
                        .fontWeight(.bold)
                }
            }
            .foregroundStyle(context.glucoseColor)

        case .currentGlucose:
            TrioWidgetValueLabel(
                value: context.state.bg,
                label: context.state.trimmedChange.isEmpty ? "--" : context.state.trimmedChange,
                isStale: context.isStale,
                valueColor: context.glucoseColor
            )

        case .iob:
            TrioWidgetValueLabel(
                value: context.iobText,
                unit: String(localized: "U", comment: "Insulin unit"),
                label: "IOB",
                isStale: context.isStale
            )

        case .cob:
            TrioWidgetValueLabel(
                value: context.cobText,
                unit: String(localized: "g", comment: "gram of carbs"),
                label: "COB",
                isStale: context.isStale
            )

        case .totalDailyDose:
            TrioWidgetValueLabel(
                value: context.tddText,
                unit: String(localized: "U", comment: "Insulin unit"),
                label: "TDD",
                isStale: context.isStale
            )

        case .eventualGlucose:
            TrioWidgetValueLabel(
                value: "⇢ " + context.eventualGlucoseText,
                label: String(localized: "Eventual", comment: "Live Activity label for eventual glucose"),
                isStale: context.isStale
            )

        case .updatedLabel:
            TrioWidgetValueLabel(
                value: context.state.formattedUpdatedTime,
                label: String(localized: "Updated", comment: "Live Activity label for the last update time"),
                isStale: context.isStale,
                valueColor: context.isStale ? .red.opacity(0.6) : .primary
            )

        case .empty:
            Color.clear.frame(width: 1)
        }
    }
}

/// A value with an optional unit above a caption, laid out like the live activity's widget items.
struct TrioWidgetValueLabel: View {
    let value: String
    var unit: String?
    let label: String
    let isStale: Bool
    var valueColor: Color = .primary

    var body: some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(isStale ? .secondary : valueColor)
                    .strikethrough(isStale, pattern: .solid, color: .red.opacity(0.6))

                if let unit {
                    Text(unit)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(isStale ? .secondary : valueColor)
                }
            }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// MARK: - Lock screen

struct TrioGlucoseAccessoryCircularView: View {
    let context: TrioWidgetContext

    var body: some View {
        VStack(spacing: -2) {
            Text(context.state.bg)
                .font(.title3)
                .fontWeight(.bold)
                .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

            if let direction = context.state.direction {
                Text(direction)
                    .font(.caption)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .widgetAccentable()
    }
}

struct TrioGlucoseAccessoryRectangularView: View {
    let context: TrioWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(context.state.bg)
                    .font(.title3)
                    .fontWeight(.bold)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                if let direction = context.state.direction {
                    Text(direction)
                        .font(.subheadline)
                        .fontWeight(.bold)
                }

                Text(context.state.trimmedChange)
                    .font(.subheadline)
            }
            .widgetAccentable()

            HStack(spacing: 6) {
                Text(verbatim: "IOB \(context.iobText)")
                Text(verbatim: "COB \(context.cobText)")
            }
            .font(.caption)

            Text(context.state.formattedUpdatedTime)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrioGlucoseAccessoryInlineView: View {
    let context: TrioWidgetContext

    var body: some View {
        Text(verbatim: "\(context.state.bg) \(context.state.direction ?? "") \(context.state.trimmedChange)")
    }
}

// MARK: - Empty state

/// Shown until Trio has published a snapshot, e.g. right after installing the widget.
struct TrioWidgetNoDataView: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("--")
                .font(.title2)
                .fontWeight(.bold)

            Text("Open Trio")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}
