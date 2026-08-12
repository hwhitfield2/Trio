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

        override func subscribe() {
            units = settingsManager.settings.units
            isTrioRemoteControlEnabled = UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
            sharedSecret = UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? generateInitialSharedSecret()

            followers = FollowerPairingManager.shared.followers
            apnsTeamId = FollowerPairingManager.shared.apnsTeamId
            apnsKeyId = FollowerPairingManager.shared.apnsKeyId
            apnsKey = FollowerPairingManager.shared.apnsKey
            fcmServiceAccountJSON = FollowerPairingManager.shared.fcmServiceAccountJSON

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
