import Foundation

/// Decides when a paired follower should be alerted, and sends the alert.
///
/// Evaluation lives on the host rather than in the follower app on purpose: an
/// alert push reaches a follower phone even when the follower app has been
/// swiped away, which a locally scheduled notification cannot promise. That
/// matters most for exactly the alert that matters most.
final class FollowerAlertManager {
    static let shared = FollowerAlertManager()

    private init() {}

    /// Per-follower alerting state. Not secret, and it changes on every alert,
    /// so it lives in user defaults rather than churning the keychain.
    struct AlertState: Codable {
        /// The condition currently in force, if any.
        var kind: String?
        var firedAt: Date?
        /// Set by the follower's "snooze" command.
        var mutedUntil: Date?
    }

    private static let stateKey = "followerAlerts.state"
    private let queue = DispatchQueue(label: "FollowerAlertManager.queue")

    // MARK: - State

    func state(forFollowerId id: String) -> AlertState {
        queue.sync { loadStates()[id] ?? AlertState() }
    }

    func setMuted(followerId: String, until date: Date?) {
        queue.sync {
            var states = loadStates()
            var state = states[followerId] ?? AlertState()
            state.mutedUntil = date
            states[followerId] = state
            saveStates(states)
        }
    }

    func clearState(followerId: String) {
        queue.sync {
            var states = loadStates()
            states.removeValue(forKey: followerId)
            saveStates(states)
        }
    }

    private func loadStates() -> [String: AlertState] {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let decoded = try? JSONDecoder().decode([String: AlertState].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveStates(_ states: [String: AlertState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }

    // MARK: - Evaluation

    /// Evaluates every push-registered follower against the latest reading and
    /// sends whatever alerts are due.
    ///
    /// - Parameters:
    ///   - glucose: newest reading in mg/dL, or nil when there is none at all.
    ///   - readingDate: when that reading was taken.
    ///   - units: the host's display units, used only for the alert text.
    func evaluate(glucose: Decimal?, readingDate: Date?, units: GlucoseUnits) async {
        let followers = FollowerPairingManager.shared.followers.filter(\.isPushRegistered)
        guard !followers.isEmpty else { return }

        let now = Date()
        for follower in followers {
            let settings = follower.alertSettings
            var state = state(forFollowerId: follower.id)

            if let mutedUntil = state.mutedUntil, mutedUntil > now { continue }

            let previous = state.kind.flatMap(FollowerAlertKind.init(rawValue:))
            let kind = self.kind(
                glucose: glucose,
                readingDate: readingDate,
                settings: settings,
                previous: previous,
                now: now
            )

            guard let kind else {
                // Back in range: forget the condition so the next excursion
                // alerts immediately rather than waiting out a repeat interval.
                if state.kind != nil {
                    state.kind = nil
                    state.firedAt = nil
                    persist(state, for: follower.id)
                }
                continue
            }

            let isNewCondition = previous != kind
            let repeatDue: Bool = {
                guard settings.repeatMinutes > 0, let firedAt = state.firedAt else { return false }
                return now.timeIntervalSince(firedAt) >= Double(settings.repeatMinutes) * 60
            }()
            guard isNewCondition || repeatDue else { continue }

            state.kind = kind.rawValue
            state.firedAt = now
            persist(state, for: follower.id)

            let text = alertText(kind: kind, glucose: glucose, settings: settings, units: units)
            do {
                try await FollowerPushSender.shared.sendAlert(
                    title: text.title,
                    body: text.body,
                    sound: settings.sound(for: kind),
                    to: follower
                )
                debug(.remoteControl, "Alert '\(kind.rawValue)' pushed to follower \(follower.name)")
            } catch {
                debug(.remoteControl, "Failed to push alert to follower \(follower.name): \(error)")
            }
        }
    }

    private func persist(_ state: AlertState, for followerId: String) {
        queue.sync {
            var states = loadStates()
            states[followerId] = state
            saveStates(states)
        }
    }

    /// Staleness wins over any glucose condition: a reading old enough to alert
    /// on is not a reading worth alarming about.
    private func kind(
        glucose: Decimal?,
        readingDate: Date?,
        settings: FollowerAlertSettings,
        previous: FollowerAlertKind?,
        now: Date
    ) -> FollowerAlertKind? {
        if settings.stale.isEnabled {
            let age = readingDate.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if age >= Double(settings.stale.afterMinutes) * 60 { return .stale }
        }

        guard let glucose, let readingDate else { return nil }
        // Do not alarm on a reading that is quietly old even when the stale rule
        // is switched off.
        guard now.timeIntervalSince(readingDate) < 30 * 60 else { return nil }

        return settings.kind(forGlucose: glucose, previous: previous)
    }

    private func alertText(
        kind: FollowerAlertKind,
        glucose: Decimal?,
        settings: FollowerAlertSettings,
        units: GlucoseUnits
    ) -> (title: String, body: String) {
        guard settings.includeGlucoseInAlertText else {
            // Nothing about the condition, not even in the title: a lock screen
            // reading "Trio · Urgent Low" would leak exactly what the toggle is
            // there to hide.
            return (
                String(localized: "Trio Follower"),
                String(localized: "Open Trio Follower to see the latest status.")
            )
        }

        let title = "Trio · \(kind.displayName)"
        guard kind != .stale else {
            return (
                title,
                String(
                    localized: "No new glucose reading for \(settings.stale.afterMinutes) minutes."
                )
            )
        }

        guard let glucose else { return (title, kind.displayName) }
        let formatted = Self.formatGlucose(glucose, units: units)
        return (title, String(localized: "Glucose \(formatted) \(units.rawValue)."))
    }

    static func formatGlucose(_ mgdl: Decimal, units: GlucoseUnits) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp
        if units == .mmolL {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return formatter.string(from: mgdl.asMmolL as NSDecimalNumber) ?? "--"
        }
        formatter.maximumFractionDigits = 0
        return formatter.string(from: mgdl as NSDecimalNumber) ?? "--"
    }
}
