import Foundation

/// Sound a follower device plays for an alert.
///
/// The raw values name the files installed into the follower app: iOS resolves
/// `alert_urgent.wav` from the app bundle, Android from `res/raw/alert_urgent`.
/// Keep in sync with FollowerApp/platform/sounds/.
enum FollowerAlertSound: String, Codable, CaseIterable, Identifiable {
    case silent
    case system
    case gentle
    case standard
    case urgent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .silent: return String(localized: "Silent (banner only)")
        case .system: return String(localized: "Default")
        case .gentle: return String(localized: "Gentle")
        case .standard: return String(localized: "Standard")
        case .urgent: return String(localized: "Urgent")
        }
    }

    /// What goes in the APNS `sound` field. Nil means deliver without a sound.
    var apnsSoundName: String? {
        switch self {
        case .silent: return nil
        case .system: return "default"
        case .gentle,
             .standard,
             .urgent: return "alert_\(rawValue).wav"
        }
    }

    /// Android binds a sound to a notification channel at creation time, so each
    /// sound needs its own channel. Matches AlertChannels.kt in the follower.
    var androidChannelId: String { "trio_alert_\(rawValue)" }
}

/// One glucose threshold the host watches on a follower's behalf.
struct FollowerAlertRule: Codable, Equatable {
    var isEnabled: Bool
    /// Always mg/dL on the wire and in storage, whatever the host displays.
    var threshold: Decimal
    var sound: FollowerAlertSound

    enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case threshold
        case sound
    }
}

/// Alerting when readings stop arriving, which is the failure the glucose
/// thresholds cannot catch.
struct FollowerStaleAlertRule: Codable, Equatable {
    var isEnabled: Bool
    var afterMinutes: Int
    var sound: FollowerAlertSound

    enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case afterMinutes = "after_minutes"
        case sound
    }
}

/// Which alerts a follower device receives, and how loudly.
///
/// Configured per follower on the host and evaluated on the host, so an alert
/// reaches the follower even when the follower app has been swiped away — a
/// local notification scheduled inside the app could not promise that.
struct FollowerAlertSettings: Codable, Equatable {
    var urgentLow: FollowerAlertRule
    var low: FollowerAlertRule
    var high: FollowerAlertRule
    var urgentHigh: FollowerAlertRule
    var stale: FollowerStaleAlertRule
    /// Minutes before an unresolved condition alerts again. 0 never repeats.
    var repeatMinutes: Int
    /// Whether the glucose value appears in the alert text. Off keeps health
    /// data off a locked screen, at the cost of having to open the app.
    var includeGlucoseInAlertText: Bool

    enum CodingKeys: String, CodingKey {
        case urgentLow = "urgent_low"
        case low
        case high
        case urgentHigh = "urgent_high"
        case stale
        case repeatMinutes = "repeat_minutes"
        case includeGlucoseInAlertText = "include_glucose"
    }

    static let `default` = FollowerAlertSettings(
        urgentLow: FollowerAlertRule(isEnabled: true, threshold: 55, sound: .urgent),
        low: FollowerAlertRule(isEnabled: true, threshold: 70, sound: .standard),
        high: FollowerAlertRule(isEnabled: true, threshold: 180, sound: .gentle),
        urgentHigh: FollowerAlertRule(isEnabled: false, threshold: 250, sound: .standard),
        stale: FollowerStaleAlertRule(isEnabled: true, afterMinutes: 20, sound: .gentle),
        repeatMinutes: 30,
        includeGlucoseInAlertText: true
    )

    /// A fired condition only clears once the value is back inside the band by
    /// this much, so a reading hovering on a threshold does not alert every
    /// five minutes.
    static let hysteresis: Decimal = 3

    /// Lowest and highest thresholds a rule may take, in mg/dL.
    static let thresholdRange: ClosedRange<Decimal> = 40 ... 400

    /// Keeps the four thresholds in order and inside the allowed range, so the
    /// host can never be left watching for a low above its own high.
    mutating func clampThresholds() {
        urgentLow.threshold = clamp(urgentLow.threshold)
        low.threshold = max(clamp(low.threshold), urgentLow.threshold + 1)
        high.threshold = max(clamp(high.threshold), low.threshold + 1)
        urgentHigh.threshold = max(clamp(urgentHigh.threshold), high.threshold + 1)
        // The upward cascade can push the top past the ceiling; walk back down.
        urgentHigh.threshold = clamp(urgentHigh.threshold)
        high.threshold = min(high.threshold, urgentHigh.threshold - 1)
        low.threshold = min(low.threshold, high.threshold - 1)
        urgentLow.threshold = min(urgentLow.threshold, low.threshold - 1)

        stale.afterMinutes = min(max(stale.afterMinutes, 5), 180)
        repeatMinutes = min(max(repeatMinutes, 0), 240)
    }

    private func clamp(_ value: Decimal) -> Decimal {
        min(max(value, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    }
}

/// Which alert fired. Ordered most to least severe: when several conditions are
/// true at once the follower should hear about the worst one.
enum FollowerAlertKind: String, Codable, CaseIterable {
    case urgentLow = "urgent_low"
    case low
    case high
    case urgentHigh = "urgent_high"
    case stale

    var displayName: String {
        switch self {
        case .urgentLow: return String(localized: "Urgent Low")
        case .low: return String(localized: "Low")
        case .high: return String(localized: "High")
        case .urgentHigh: return String(localized: "Urgent High")
        case .stale: return String(localized: "No Data")
        }
    }

    var isLow: Bool { self == .urgentLow || self == .low }
}

extension FollowerAlertSettings {
    func rule(for kind: FollowerAlertKind) -> FollowerAlertRule? {
        switch kind {
        case .urgentLow: return urgentLow
        case .low: return low
        case .high: return high
        case .urgentHigh: return urgentHigh
        case .stale: return nil
        }
    }

    func sound(for kind: FollowerAlertKind) -> FollowerAlertSound {
        kind == .stale ? stale.sound : (rule(for: kind)?.sound ?? .system)
    }

    /// The alert a reading warrants, or nil when everything is in range.
    ///
    /// `previous` is the kind currently in force for this follower; while one is
    /// active the matching threshold is widened by the hysteresis margin, so a
    /// value oscillating around it does not clear and re-fire repeatedly.
    func kind(forGlucose sgv: Decimal, previous: FollowerAlertKind?) -> FollowerAlertKind? {
        let margin = Self.hysteresis

        func bound(_ kind: FollowerAlertKind, _ threshold: Decimal) -> Decimal {
            guard previous == kind else { return threshold }
            return kind.isLow ? threshold + margin : threshold - margin
        }

        if urgentLow.isEnabled, sgv <= bound(.urgentLow, urgentLow.threshold) { return .urgentLow }
        if low.isEnabled, sgv <= bound(.low, low.threshold) { return .low }
        if urgentHigh.isEnabled, sgv >= bound(.urgentHigh, urgentHigh.threshold) { return .urgentHigh }
        if high.isEnabled, sgv >= bound(.high, high.threshold) { return .high }
        return nil
    }
}
