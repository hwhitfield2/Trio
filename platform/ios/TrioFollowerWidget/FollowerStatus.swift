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

    /// Share of the plotted readings below, inside and above the host's range.
    struct Stats: Codable {
        let low: Int
        let inRange: Int
        let high: Int

        enum CodingKeys: String, CodingKey {
            case low
            case inRange = "in_range"
            case high
        }
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
    /// The host's display low and high, already in display units, so the guide
    /// lines and the colouring here are the host's own and not this device's
    /// idea of a range.
    let low: Double
    let high: Double
    /// Which scheme the host colours with, and what the dynamic one needs.
    /// Optional: an app build that predates it sends nothing, and the static
    /// three colours are what this extension drew before anyway.
    let colorRanges: FollowerGlucoseColorRanges?
    let chart: [ChartPoint]
    let stats: Stats?

    enum CodingKeys: String, CodingKey {
        case units
        case bg
        case direction
        case change
        case glucoseDate
        case hostDate
        case lastLoop
        case iob
        case cob
        case eventualBg
        case tempTargetName
        case overrideName
        case low
        case high
        case colorRanges = "color"
        case chart
        case stats
    }

    /// Mirrors Trio's own widget: a reading older than six minutes is shown as
    /// no longer current.
    static let staleThreshold: TimeInterval = 6 * 60

    var readingDate: Date? {
        guard let glucoseDate else { return nil }
        return Date(timeIntervalSince1970: glucoseDate / 1000)
    }

    var lastLoopDate: Date? {
        guard let lastLoop else { return nil }
        return Date(timeIntervalSince1970: lastLoop / 1000)
    }

    func isStale(asOf date: Date) -> Bool {
        guard let readingDate else { return true }
        return date.timeIntervalSince(readingDate) > Self.staleThreshold
    }

    /// The numeric glucose value, for colouring. `nil` when there is no reading.
    var glucoseValue: Double? { Double(bg) }

    /// The colour the host would paint this value, unless the user asked for a
    /// single colour instead.
    func color(
        for value: Double?,
        scheme: FollowerDisplayPreferences.GlucoseColorScheme = .dynamicColor
    ) -> Color {
        guard scheme == .dynamicColor, let value else { return .primary }
        return FollowerGlucoseColor.color(for: value, low: low, high: high, ranges: colorRanges)
    }

    func glucoseColor(_ scheme: FollowerDisplayPreferences.GlucoseColorScheme) -> Color {
        color(for: glucoseValue, scheme: scheme)
    }

    /// The span the chart actually covers, so a plot never stretches a couple of
    /// hours of readings across a fixed six-hour axis. The host trims readings to
    /// fit its push budget, so the real span varies.
    var chartWindow: TimeInterval {
        guard let oldest = chart.map(\.t).min(), let newest = chart.map(\.t).max() else {
            return 6 * 3600
        }
        let span = (newest - oldest) / 1000
        return min(max(span, 3600), 6 * 3600)
    }

    static var placeholder: FollowerStatus {
        let now = Date().timeIntervalSince1970 * 1000
        return FollowerStatus(
            units: "mg/dL",
            bg: "120",
            direction: "→",
            change: "+2",
            glucoseDate: now,
            hostDate: now,
            lastLoop: now - 4 * 60_000,
            iob: "1.5",
            cob: "20",
            eventualBg: "124",
            tempTargetName: nil,
            overrideName: nil,
            low: 70,
            high: 180,
            colorRanges: nil,
            chart: (0 ..< 36).map { index in
                ChartPoint(
                    v: Double(110 + (index % 12) * 5),
                    t: now - Double(35 - index) * 300_000
                )
            },
            stats: Stats(low: 4, inRange: 82, high: 14)
        )
    }
}

// MARK: - Store

enum FollowerWidgetStore {
    /// Widget kinds. `glucose` keeps its original string so widgets already on a
    /// home screen keep working across the update that added the other two.
    static let glucoseKind = "TrioFollowerWidget"
    static let trendKind = "TrioFollowerTrendWidget"
    static let loopKind = "TrioFollowerLoopWidget"

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

/// Shared by all three widgets: they render the same payload, just differently.
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

        // The app reloads these timelines whenever a status push arrives, including
        // in the background. These entries only cover the case where the host goes
        // quiet: they re-render the same data later, which is what lets the reading
        // eventually show up as stale. The tail is deliberately short — WidgetKit
        // only re-reads the app group when it asks for a new timeline.
        let entries = (0 ..< Self.entryCount).map { index in
            FollowerEntry(
                date: now.addingTimeInterval(Double(index) * Self.refreshInterval),
                status: status
            )
        }

        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Shared view pieces

/// What each view needs: the payload plus whether it has gone stale by the time
/// this entry is shown.
struct FollowerContext {
    let status: FollowerStatus
    let isStale: Bool
    /// The follower's own layout choices, read per render: the extension is
    /// long-lived, so a value cached at launch would go stale the moment the
    /// user changed a setting.
    let preferences: FollowerDisplayPreferences

    init(status: FollowerStatus, now: Date, preferences: FollowerDisplayPreferences = .load()) {
        self.status = status
        self.preferences = preferences
        isStale = status.isStale(asOf: now)
    }

    var glucoseColor: Color {
        isStale ? .secondary : status.glucoseColor(preferences.glucoseColor)
    }

    /// Chart point colouring, which follows the same choice.
    func color(for value: Double?) -> Color {
        status.color(for: value, scheme: preferences.glucoseColor)
    }

    var updatedText: String {
        guard let date = status.readingDate else { return "--" }
        return DateFormatter.followerTime.string(from: date)
    }

    /// How long ago the host's loop last ran, e.g. "4 min".
    func loopAgeText(asOf now: Date) -> String {
        guard let date = status.lastLoopDate else { return "--" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return String(localized: "now") }
        return "\(minutes) min"
    }

    /// Green while the host is looping, amber when it is late, red when silent.
    func loopColor(asOf now: Date) -> Color {
        guard let date = status.lastLoopDate else { return .secondary }
        let minutes = now.timeIntervalSince(date) / 60
        if minutes <= 6 { return .green }
        if minutes <= 15 { return .orange }
        return .red
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

/// A value with an optional unit above a caption.
struct FollowerValueLabel: View {
    let value: String
    var unit: String?
    let label: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline).fontWeight(.bold).foregroundStyle(valueColor)

                if let unit {
                    Text(unit).font(.caption).fontWeight(.bold).foregroundStyle(valueColor)
                }
            }

            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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

extension View {
    /// The background every widget family wants: opaque on the home screen,
    /// clear behind the lock screen's own treatment.
    @ViewBuilder func followerContainerBackground(for family: WidgetFamily) -> some View {
        switch family {
        case .accessoryCircular:
            containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryInline,
             .accessoryRectangular:
            containerBackground(for: .widget) { Color.clear }
        default:
            containerBackground(for: .widget) { Color(.systemBackground) }
        }
    }
}
