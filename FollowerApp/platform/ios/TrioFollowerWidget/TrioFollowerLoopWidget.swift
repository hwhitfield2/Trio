import SwiftUI
import WidgetKit

// MARK: - Widget 3: Loop & insulin

/// Answers "is the host's loop healthy and what is it doing": how long ago it
/// last ran, insulin and carbs on board, where it expects glucose to land, and
/// any active override or temp target. Deliberately has no chart — this is the
/// widget for a caregiver who wants reassurance rather than the curve.
struct TrioFollowerLoopWidgetEntryView: View {
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
            FollowerLoopAccessoryView(context: context, now: entry.date)
        case .systemMedium:
            FollowerLoopMediumView(context: context, now: entry.date)
        default:
            FollowerLoopSmallView(context: context, now: entry.date)
        }
    }
}

/// The loop-age dot: the one thing that says whether the host is still running.
struct FollowerLoopBadge: View {
    let context: FollowerContext
    let now: Date
    var showCaption = true

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(context.loopColor(asOf: now))
                .frame(width: 8, height: 8)

            Text(context.loopAgeText(asOf: now))
                .font(.caption)
                .fontWeight(.semibold)

            if showCaption {
                Text("since loop").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct FollowerLoopSmallView: View {
    let context: FollowerContext
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FollowerLoopBadge(context: context, now: now)

            HStack(spacing: 14) {
                FollowerValueLabel(value: context.status.iob ?? "--", unit: "U", label: "IOB")
                FollowerValueLabel(value: context.status.cob ?? "--", unit: "g", label: "COB")
            }

            FollowerValueLabel(
                value: "⇢ " + (context.status.eventualBg ?? "--"),
                label: String(localized: "Eventual")
            )

            if let active = activeName {
                Text(active)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.purple)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var activeName: String? {
        if let name = context.status.overrideName, !name.isEmpty { return name }
        if let name = context.status.tempTargetName, !name.isEmpty { return name }
        return nil
    }
}

struct FollowerLoopMediumView: View {
    @Environment(\.colorScheme) private var colorScheme

    let context: FollowerContext
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FollowerLoopBadge(context: context, now: now)

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(context.status.bg)
                        .font(.title3)
                        .fontWeight(.bold)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                    if !context.status.direction.isEmpty {
                        Text(context.status.direction).font(.subheadline).fontWeight(.bold)
                    }
                }
                .foregroundStyle(context.glucoseColor)
            }

            HStack(spacing: 0) {
                FollowerValueLabel(value: context.status.iob ?? "--", unit: "U", label: "IOB")
                    .frame(maxWidth: .infinity)
                Divider().frame(height: 26)
                FollowerValueLabel(value: context.status.cob ?? "--", unit: "g", label: "COB")
                    .frame(maxWidth: .infinity)
                Divider().frame(height: 26)
                FollowerValueLabel(
                    value: "⇢ " + (context.status.eventualBg ?? "--"),
                    label: String(localized: "Eventual")
                )
                .frame(maxWidth: .infinity)
                Divider().frame(height: 26)
                FollowerValueLabel(value: context.updatedText, label: String(localized: "Updated"))
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 4) {
                if let name = context.status.overrideName, !name.isEmpty {
                    pill(name, color: .purple)
                }
                if let name = context.status.tempTargetName, !name.isEmpty {
                    pill(name, color: .green)
                }
                if noActiveAdjustment {
                    Text("No override or temp target")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var noActiveAdjustment: Bool {
        (context.status.overrideName ?? "").isEmpty && (context.status.tempTargetName ?? "").isEmpty
    }

    private func pill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .lineLimit(1)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(colorScheme == .dark ? 0.6 : 0.8))
            }
    }
}

struct FollowerLoopAccessoryView: View {
    let context: FollowerContext
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            FollowerLoopBadge(context: context, now: now).widgetAccentable()

            Text(verbatim: "IOB \(context.status.iob ?? "--") · COB \(context.status.cob ?? "--")")
                .font(.caption)

            Text(verbatim: "⇢ \(context.status.eventualBg ?? "--")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrioFollowerLoopWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FollowerWidgetStore.loopKind, provider: FollowerProvider()) { entry in
            TrioFollowerLoopWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Loop & Insulin")
        .description("How long since the host last looped, plus insulin, carbs and the eventual glucose.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
