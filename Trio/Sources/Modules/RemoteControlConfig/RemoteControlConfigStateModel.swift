import SwiftUI

extension RemoteControlConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Published var units: GlucoseUnits = .mgdL
        @Published var isTrioRemoteControlEnabled: Bool = false
        @Published var sharedSecret: String = ""

        // Follower app pairing
        @Published var followers: [PairedFollower] = []
        @Published var apnsTeamId: String = ""
        @Published var apnsKeyId: String = ""
        @Published var apnsKey: String = ""
        @Published var fcmServiceAccountJSON: String = ""
        @Published var pairingFollower: PairedFollower?
        @Published var pairingPayload: String?
        @Published var pairingError: String?

        // Follower app versions
        /// Latest follower release, as published in the Trio repository.
        @Published var latestFollowerVersion: String?
        @Published var isCheckingFollowerVersion: Bool = false
        /// Set after nudging, so the row can say the nudge went out (or why it
        /// did not) without a modal.
        @Published var nudgeResult: String?

        override func subscribe() {
            units = settingsManager.settings.units
            isTrioRemoteControlEnabled = UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
            sharedSecret = UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? generateInitialSharedSecret()

            followers = FollowerPairingManager.shared.followers
            apnsTeamId = FollowerPairingManager.shared.apnsTeamId
            apnsKeyId = FollowerPairingManager.shared.apnsKeyId
            apnsKey = FollowerPairingManager.shared.apnsKey
            fcmServiceAccountJSON = FollowerPairingManager.shared.fcmServiceAccountJSON
            refreshLatestFollowerVersion()

            $isTrioRemoteControlEnabled
                .receive(on: DispatchQueue.main)
                .sink { value in
                    UserDefaults.standard.set(value, forKey: "isTrioRemoteControlEnabled")
                }
                .store(in: &lifetime)

            $sharedSecret
                .receive(on: DispatchQueue.main)
                .sink { value in
                    UserDefaults.standard.set(value, forKey: "trioRemoteControlSharedSecret")
                }
                .store(in: &lifetime)

            $apnsTeamId
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { FollowerPairingManager.shared.apnsTeamId = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .store(in: &lifetime)

            $apnsKeyId
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { FollowerPairingManager.shared.apnsKeyId = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .store(in: &lifetime)

            $apnsKey
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { FollowerPairingManager.shared.apnsKey = $0 }
                .store(in: &lifetime)

            $fcmServiceAccountJSON
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { FollowerPairingManager.shared.fcmServiceAccountJSON = $0 }
                .store(in: &lifetime)
        }

        func refreshFollowers() {
            followers = FollowerPairingManager.shared.followers
        }

        /// Looks up the current follower release. Cached for a day unless the
        /// user asks again.
        func refreshLatestFollowerVersion(force: Bool = false) {
            Task { @MainActor in
                // Show what was known before the fetch, so opening the screen
                // offline still says something.
                if latestFollowerVersion == nil {
                    latestFollowerVersion = FollowerVersionChecker.shared.cachedLatestVersion
                }
                isCheckingFollowerVersion = true
                latestFollowerVersion = await FollowerVersionChecker.shared.latestVersion(forceRefresh: force)
                isCheckingFollowerVersion = false
            }
        }

        /// Followers running something older than the current release. Ones that
        /// have never reported a version are left out — the host cannot know
        /// they are behind, so it should not say they are.
        var outdatedFollowers: [PairedFollower] {
            followers.filter { $0.isOutdated(comparedTo: latestFollowerVersion) }
        }

        /// Sends the follower a notification saying a newer build exists.
        func nudgeFollower(id: String) {
            guard let follower = FollowerPairingManager.shared.follower(withId: id),
                  let latest = latestFollowerVersion
            else { return }

            Task { @MainActor in
                do {
                    try await FollowerPushSender.shared.sendUpdateNudge(latestVersion: latest, to: follower)
                    nudgeResult = String(
                        format: String(localized: "Update notice sent to %@.", comment: "Follower nudge confirmation"),
                        follower.name
                    )
                } catch {
                    nudgeResult = String(
                        format: String(
                            localized: "Could not reach %@: %@",
                            comment: "Follower nudge failure, with the follower name and the reason"
                        ),
                        follower.name,
                        error.localizedDescription
                    )
                }
            }
        }

        /// Nudges every follower that is behind, in one go.
        func nudgeOutdatedFollowers() {
            for follower in outdatedFollowers {
                nudgeFollower(id: follower.id)
            }
        }

        /// Creates a new paired follower and prepares the QR payload. On
        /// failure the follower is removed again so no orphaned pairing stays
        /// behind, and the error is surfaced to the view.
        func startPairing(name: String) {
            pairingError = nil
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let follower = FollowerPairingManager.shared
                .addFollower(named: trimmedName.isEmpty ? String(localized: "Follower") : trimmedName)
            do {
                pairingPayload = try FollowerPairingManager.shared.makePairingPayload(for: follower)
                pairingFollower = follower
            } catch {
                FollowerPairingManager.shared.removeFollower(withId: follower.id)
                pairingError = error.localizedDescription
            }
            refreshFollowers()
        }

        func finishPairing() {
            pairingFollower = nil
            pairingPayload = nil
            refreshFollowers()
        }

        func revokeFollower(id: String) {
            FollowerPairingManager.shared.removeFollower(withId: id)
            // Drop any armed alert condition with the pairing, so re-pairing the
            // same device does not inherit a stale "already alerted" state.
            FollowerAlertManager.shared.clearState(followerId: id)
            refreshFollowers()
        }

        func alertSettings(forFollowerId id: String) -> FollowerAlertSettings {
            FollowerPairingManager.shared.follower(withId: id)?.alertSettings ?? .default
        }

        /// Persists an edited alert profile and hands back what was stored, which
        /// is clamped into a valid ordering.
        func updateAlertSettings(
            followerId: String,
            _ settings: FollowerAlertSettings
        ) -> FollowerAlertSettings? {
            let stored = FollowerPairingManager.shared.updateAlertSettings(followerId: followerId, settings)
            refreshFollowers()
            return stored
        }

        func generateNewSharedSecret() {
            let newSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            sharedSecret = newSecret
            UserDefaults.standard.set(newSecret, forKey: "trioRemoteControlSharedSecret")
        }

        private func generateInitialSharedSecret() -> String {
            let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            UserDefaults.standard.set(secret, forKey: "trioRemoteControlSharedSecret")
            return secret
        }
    }
}

extension RemoteControlConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
