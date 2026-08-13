import Foundation

/// Finds out which follower release is current, so the host can tell the user
/// which of their followers are behind.
///
/// The follower app has no App Store listing to ask — it is built from this
/// repository — so the version is read where it is defined:
/// `FollowerApp/pubspec.yaml` on `main`. That mirrors `AppVersionChecker`,
/// which reads Trio's own version out of `Config.xcconfig` in the same repo.
@MainActor final class FollowerVersionChecker {
    static let shared = FollowerVersionChecker()

    private init() {}

    /// The latest follower version seen on GitHub.
    @Persisted(key: "followerLatestVersion") private var persistedLatestVersion: String? = nil
    /// When that was last fetched successfully.
    @Persisted(key: "followerLatestVersionChecked") private var lastChecked: Date? = .distantPast

    /// Checked at most this often on its own; the settings screen can always
    /// ask for a fresh look.
    private let refreshInterval: TimeInterval = 24 * 3600

    private static let pubspecURL =
        "https://raw.githubusercontent.com/nightscout/Trio/refs/heads/main/FollowerApp/pubspec.yaml"

    /// The last known release, without going to the network.
    var cachedLatestVersion: String? { persistedLatestVersion }

    /// The current release, fetched when the cached answer has gone stale.
    ///
    /// Returns the cached value on any failure: an unreachable GitHub should
    /// leave the settings screen showing what it knew, not blank it out.
    @discardableResult
    func latestVersion(forceRefresh: Bool = false) async -> String? {
        let age = Date().timeIntervalSince(lastChecked ?? .distantPast)
        if !forceRefresh, age < refreshInterval, persistedLatestVersion != nil {
            return persistedLatestVersion
        }

        guard let url = URL(string: Self.pubspecURL) else { return persistedLatestVersion }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let contents = String(data: data, encoding: .utf8),
                  let version = Self.parseVersion(fromPubspec: contents)
            else {
                return persistedLatestVersion
            }
            persistedLatestVersion = version
            lastChecked = Date()
            return version
        } catch {
            debug(.remoteControl, "Failed to fetch the latest follower version: \(error)")
            return persistedLatestVersion
        }
    }

    // MARK: - Helpers

    /// Pulls the marketing version out of a pubspec, dropping the build number.
    ///
    /// A pubspec line reads `version: 1.2.3+45`, where `+45` is the build. Only
    /// the part before the `+` is compared, so rebuilding the same version does
    /// not make every follower look out of date.
    static func parseVersion(fromPubspec contents: String) -> String? {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only the top-level key: `version:` nested under a dependency is
            // some package's version, not the app's.
            guard trimmed.hasPrefix("version:"), line.hasPrefix("version:") else { continue }
            let value = trimmed.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
            let version = value.split(separator: "+").first.map(String.init) ?? value
            let cleaned = version.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// Whether `available` is a later release than `installed`.
    ///
    /// Compares numerically component by component, so "0.10.0" counts as newer
    /// than "0.9.0" — which a string comparison would get backwards. An
    /// unreported or unparsable version is never called out of date: telling
    /// someone to update when the host simply does not know is worse than
    /// staying quiet.
    static func isVersion(_ available: String, newerThan installed: String) -> Bool {
        guard !available.isEmpty, !installed.isEmpty else { return false }

        let availableParts = available.split(separator: ".").map { Int($0) ?? 0 }
        let installedParts = installed.split(separator: ".").map { Int($0) ?? 0 }

        for index in 0 ..< max(availableParts.count, installedParts.count) {
            let left = index < availableParts.count ? availableParts[index] : 0
            let right = index < installedParts.count ? installedParts[index] : 0
            if left > right { return true }
            if left < right { return false }
        }
        return false
    }
}

extension PairedFollower {
    /// Whether this follower is running something older than `latestVersion`.
    func isOutdated(comparedTo latestVersion: String?) -> Bool {
        guard let latestVersion, let appVersion, !appVersion.isEmpty else { return false }
        return FollowerVersionChecker.isVersion(latestVersion, newerThan: appVersion)
    }
}
