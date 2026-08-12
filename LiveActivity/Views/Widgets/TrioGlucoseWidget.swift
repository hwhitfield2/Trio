import SwiftUI
import WidgetKit

/// A single point in the widget's timeline: one snapshot, rendered as of `date`.
struct TrioGlucoseWidgetEntry: TimelineEntry {
    let date: Date
    /// The data Trio last published, or `nil` if the app has not published any yet.
    let snapshot: TrioWidgetSnapshot?
}

struct TrioGlucoseWidgetProvider: TimelineProvider {
    /// Spacing of the self-refresh entries, matching the CGM's five minute cadence.
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let entryCount = 6

    func placeholder(in _: Context) -> TrioGlucoseWidgetEntry {
        TrioGlucoseWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioGlucoseWidgetEntry) -> Void) {
        let snapshot = context.isPreview ? TrioWidgetSnapshot.placeholder : TrioWidgetSnapshotStore.shared.load()
        completion(TrioGlucoseWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioGlucoseWidgetEntry>) -> Void) {
        let snapshot = TrioWidgetSnapshotStore.shared.load()
        let now = Date()

        // Trio reloads this timeline whenever it publishes a new snapshot, so these entries exist
        // only for the case where the app goes quiet: they re-render the same data at later points
        // in time, which is what lets the reading eventually show up as stale.
        let entries = (0 ..< Self.entryCount).map { index in
            TrioGlucoseWidgetEntry(
                date: now.addingTimeInterval(Double(index) * Self.refreshInterval),
                snapshot: snapshot
            )
        }

        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// Home screen and lock screen widget showing the same data as Trio's Live Activity.
struct TrioGlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrioWidgetKind.glucose, provider: TrioGlucoseWidgetProvider()) { entry in
            TrioGlucoseWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "Trio://"))
        }
        .configurationDisplayName("Trio")
        .description(String(
            localized: "Shows the same glucose, insulin and carb data as the Trio Live Activity.",
            comment: "Description of the Trio glucose widget in the widget gallery"
        ))
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

extension TrioWidgetSnapshot {
    /// Sample data for the widget gallery and for SwiftUI previews.
    static var placeholder: TrioWidgetSnapshot {
        let now = Date()
        let chart = (0 ..< 36).map { index in
            LiveActivityAttributes.ChartItem(
                value: Decimal(110 + (index % 12) * 5),
                date: now.addingTimeInterval(Double(index - 35) * 300)
            )
        }

        let detailedState = LiveActivityAttributes.ContentAdditionalState(
            chart: chart,
            rotationDegrees: 0,
            cob: 20,
            iob: 1.5,
            tdd: 43.2,
            eventualBG: 124,
            isOverrideActive: false,
            overrideName: "",
            overrideDate: now,
            overrideDuration: 0,
            overrideTarget: 0,
            isTempTargetActive: false,
            tempTargetName: "",
            tempTargetDate: now,
            tempTargetDuration: 0,
            tempTargetTarget: 0,
            widgetItems: LiveActivityAttributes.LiveActivityItem.defaultItems
        )

        let state = LiveActivityAttributes.ContentState(
            unit: GlucoseUnits.mgdL.rawValue,
            bg: "120",
            direction: "→",
            change: "+2",
            date: now,
            highGlucose: 180,
            lowGlucose: 70,
            target: 100,
            glucoseColorScheme: GlucoseColorScheme.staticColor.rawValue,
            useDetailedViewIOS: true,
            useDetailedViewWatchOS: false,
            detailedViewState: detailedState,
            isInitialState: false
        )

        return TrioWidgetSnapshot(state: state, glucoseDate: now)
    }
}
