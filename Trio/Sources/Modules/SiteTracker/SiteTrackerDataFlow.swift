import Foundation

enum SiteTracker {
    enum Config {}
}

protocol SiteTrackerProvider {}

/// Body zones for rotation logging. Pure and dependency-free.
enum SiteBodyLocation: String, CaseIterable, Identifiable {
    case leftAbdomen
    case rightAbdomen
    case leftThigh
    case rightThigh
    case leftArm
    case rightArm
    case leftLowerBack
    case rightLowerBack
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftAbdomen: return String(localized: "Left Abdomen")
        case .rightAbdomen: return String(localized: "Right Abdomen")
        case .leftThigh: return String(localized: "Left Thigh")
        case .rightThigh: return String(localized: "Right Thigh")
        case .leftArm: return String(localized: "Left Arm")
        case .rightArm: return String(localized: "Right Arm")
        case .leftLowerBack: return String(localized: "Left Lower Back")
        case .rightLowerBack: return String(localized: "Right Lower Back")
        case .other: return String(localized: "Other")
        }
    }
}

/// Pure rotation-summary math over logged site changes, kept dependency-free for tests.
enum SiteRotationMath {
    struct Entry: Identifiable, Equatable {
        let location: SiteBodyLocation
        let count: Int
        let lastUsed: Date?

        var id: String { location.rawValue }
    }

    /// A location is flagged as heavily used when it carries at least this share of
    /// all located site changes in the window.
    static let heavyUseShare = 0.4
    /// A location counts as rested when it has not been used for this long.
    static let restedInterval: TimeInterval = 30 * 24 * 60 * 60

    /// Per-location usage count and last-used date, most recently used first.
    /// Changes without a location are ignored.
    static func summary(of changes: [(location: SiteBodyLocation?, date: Date)]) -> [Entry] {
        var counts: [SiteBodyLocation: Int] = [:]
        var lastUsed: [SiteBodyLocation: Date] = [:]
        for change in changes {
            guard let location = change.location else { continue }
            counts[location, default: 0] += 1
            lastUsed[location] = max(lastUsed[location] ?? .distantPast, change.date)
        }
        return counts
            .map { Entry(location: $0.key, count: $0.value, lastUsed: lastUsed[$0.key]) }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    static func isHeavilyUsed(count: Int, total: Int) -> Bool {
        guard total > 0, count > 0 else { return false }
        return Double(count) / Double(total) >= heavyUseShare
    }

    static func isRested(lastUsed: Date?, now: Date) -> Bool {
        guard let lastUsed = lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) >= restedInterval
    }
}
