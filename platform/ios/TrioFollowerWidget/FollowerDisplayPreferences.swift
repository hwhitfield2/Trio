import Foundation

/// The follower's layout choices, written into the shared app group by the
/// Flutter app (`lib/models/display_preferences.dart`).
///
/// Trio carries the equivalent settings inside the Live Activity's content
/// state, because there the device that renders is the device that configures.
/// Here it cannot: a Live Activity update may be pushed by the host, which
/// knows nothing about how this follower likes to see things. Reading the
/// choices from the app group instead means a pushed update and a locally built
/// one are laid out identically, and changing a setting needs no round trip to
/// the host.
struct FollowerDisplayPreferences: Codable {
    enum WidgetStyle: String, Codable {
        case simple
        case detailed
    }

    enum GlucoseColorScheme: String, Codable {
        case dynamicColor = "dynamic"
        case staticColor = "static"
    }

    /// One slot in a detailed layout. Trio's list minus `totalDailyDose`: the
    /// host's status snapshot carries no TDD, so there would be nothing to show.
    enum Item: String, Codable {
        case currentGlucose
        case currentGlucoseLarge
        case iob
        case cob
        case eventualGlucose
        case updatedLabel
        case empty
    }

    /// This device's own glucose range, and which colouring to use for it.
    ///
    /// Written by the app in the host's display units — the same ones the
    /// readings arrive in — because nothing in this extension knows which units
    /// a payload is in. A null end, or a scheme of "host", follows the host.
    struct GlucoseRange: Codable {
        let low: Double?
        let high: Double?
        let scheme: String?

        static let followHost = GlucoseRange(low: nil, high: nil, scheme: nil)

        var forcesStatic: Bool { scheme == "static" }
        var forcesDynamic: Bool { scheme == "dynamic" }
    }

    var lockScreen: WidgetStyle = .simple
    var watch: WidgetStyle = .simple
    var glucoseColor: GlucoseColorScheme = .dynamicColor
    var glucoseRange: GlucoseRange = .followHost
    var items: [Item] = defaultItems

    enum CodingKeys: String, CodingKey {
        case lockScreen = "lock_screen"
        case watch
        case glucoseColor = "glucose_color"
        case glucoseRange = "glucose_range"
        case items
    }

    static let defaultItems: [Item] = [.currentGlucoseLarge, .iob, .cob, .updatedLabel]

    static let `default` = FollowerDisplayPreferences()

    /// Key the app writes them under; see `WidgetBridge.preferencesKey`.
    static let storageKey = "trio_follower_display"

    /// Same app group the status payload comes from, read the same way — from
    /// the extension's Info.plist, which carries the Apple team id.
    private static var appGroupId: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    /// Reads the current choices, falling back to the defaults whenever they
    /// have never been written or cannot be read. A widget must draw something,
    /// so nothing here is allowed to fail.
    static func load() -> FollowerDisplayPreferences {
        guard let appGroupId,
              let defaults = UserDefaults(suiteName: appGroupId),
              let raw = defaults.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FollowerDisplayPreferences.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    /// Decoded leniently: an unknown value means the app is newer than this
    /// extension, and falling back to a default draws something sensible rather
    /// than failing the whole payload and reverting every choice at once.
    /// An unknown item name becomes a blank slot, which keeps the rest of the
    /// row in the position the user put it in.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lockScreen = (try? container.decode(WidgetStyle.self, forKey: .lockScreen)) ?? .simple
        watch = (try? container.decode(WidgetStyle.self, forKey: .watch)) ?? .simple
        glucoseColor = (try? container.decode(GlucoseColorScheme.self, forKey: .glucoseColor)) ?? .dynamicColor
        glucoseRange = (try? container.decode(GlucoseRange.self, forKey: .glucoseRange)) ?? .followHost

        let names = (try? container.decode([String].self, forKey: .items)) ?? []
        let decodedItems = names.map { Item(rawValue: $0) ?? .empty }
        items = decodedItems.isEmpty ? Self.defaultItems : decodedItems
    }

    init(
        lockScreen: WidgetStyle = .simple,
        watch: WidgetStyle = .simple,
        glucoseColor: GlucoseColorScheme = .dynamicColor,
        glucoseRange: GlucoseRange = .followHost,
        items: [Item] = FollowerDisplayPreferences.defaultItems
    ) {
        self.lockScreen = lockScreen
        self.watch = watch
        self.glucoseColor = glucoseColor
        self.glucoseRange = glucoseRange
        self.items = items
    }
}
