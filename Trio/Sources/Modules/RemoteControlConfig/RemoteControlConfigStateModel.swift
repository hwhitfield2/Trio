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

        // Web viewer pairing (read-only browser follower)
        @Published var pairingViewer: PairedFollower?
        @Published var viewerPairingPayload: String?
        /// Set once the browser's registration code has been scanned and
        /// stored, so the pairing sheet can say the viewer is connected.
        @Published var viewerRegistered: Bool = false
        @Published var viewerRegistrationError: String?
        /// An already-paired viewer whose browser is showing a fresh
        /// registration code (its push subscription rotated); drives the
        /// re-scan sheet.
        @Published var rescanViewer: PairedFollower?

        // Follower app versions
        /// Latest follower release, as published in the Trio repository.
        @Published var latestFollowerVersion: String?
        @Published var isCheckingFollowerVersion: Bool = false
        /// Set after nudging, so the row can say the nudge went out (or why it
        /// did not) without a modal.
        @Published var nudgeResult: String?

        // Emergency stop
        /// The follower suspension in force, if any.
        @Published var suspension: FollowerSuspension?

        override func subscribe() {
            units = settingsManager.settings.units
            isTrioRemoteControlEnabled = UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
            sharedSecret = UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? generateInitialSharedSecret()

            followers = FollowerPairingManager.shared.followers
            apnsTeamId = FollowerPairingManager.shared.apnsTeamId
            apnsKeyId = FollowerPairingManager.shared.apnsKeyId
            apnsKey = FollowerPairingManager.shared.apnsKey
            fcmServiceAccountJSON = FollowerPairingManager.shared.fcmServiceAccountJSON
            suspension = FollowerSuspensionManager.shared.current
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
            suspension = FollowerSuspensionManager.shared.current
        }

        func setMaySuspendInsulin(followerId: String, _ allowed: Bool) {
            FollowerPairingManager.shared.setMaySuspendInsulin(followerId: followerId, allowed)
            refreshFollowers()
        }

        /// Answers the alarm a follower's suspension raised, optionally starting
        /// insulin again. The same two answers the notification offers, for
        /// someone who opened the app instead of tapping it.
        func acknowledgeSuspension(resumeDelivery: Bool) {
            Task { @MainActor in
                await FollowerSuspensionManager.shared.acknowledge(resumeDelivery: resumeDelivery)
                refreshFollowers()
            }
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

        /// Creates a read-only web viewer and prepares its pairing QR payload.
        /// Mirrors `startPairing`, but a viewer bundle needs no APNS
        /// credentials or device token, so this cannot fail for those reasons.
        func startViewerPairing(name: String) {
            pairingError = nil
            viewerRegistered = false
            viewerRegistrationError = nil
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let viewer = FollowerPairingManager.shared
                .addViewer(named: trimmedName.isEmpty ? String(localized: "Web Viewer") : trimmedName)
            do {
                viewerPairingPayload = try FollowerPairingManager.shared.makeViewerPairingPayload(for: viewer)
                pairingViewer = viewer
            } catch {
                FollowerPairingManager.shared.removeFollower(withId: viewer.id)
                pairingError = error.localizedDescription
            }
            refreshFollowers()
        }

        func finishViewerPairing() {
            pairingViewer = nil
            viewerPairingPayload = nil
            viewerRegistered = false
            viewerRegistrationError = nil
            refreshFollowers()
        }

        /// Opens the re-scan flow for a viewer whose browser shows a new
        /// registration code (e.g. after the push service rotated its
        /// subscription).
        func beginViewerRescan(id: String) {
            viewerRegistered = false
            viewerRegistrationError = nil
            rescanViewer = FollowerPairingManager.shared.follower(withId: id)
        }

        func finishViewerRescan() {
            rescanViewer = nil
            viewerRegistered = false
            viewerRegistrationError = nil
            refreshFollowers()
        }

        /// Handles a QR string scanned during viewer pairing or re-scan.
        /// Returns true once a registration was accepted and stored, so the
        /// scanner can dismiss; stray codes return false without any error.
        ///
        /// The registration must name the exact viewer this scan is for — a
        /// registration is otherwise valid for as long as its pairing lives,
        /// so without the binding a stale code left on some other browser's
        /// screen could complete the wrong pairing.
        func handleScannedViewerRegistration(_ code: String, expectedViewerId: String) -> Bool {
            guard let registration = WebViewerPushRegistration.parse(code) else { return false }

            guard registration.followerId == expectedViewerId,
                  let follower = FollowerPairingManager.shared.follower(withId: registration.followerId),
                  follower.isViewerOnly
            else {
                viewerRegistrationError = String(
                    localized: "This browser code belongs to a different pairing. Start over with a fresh QR code.",
                    comment: "Scanned web viewer registration names an unknown or non-viewer follower"
                )
                return false
            }
            guard registration.verifyProof(secret: follower.secret) else {
                viewerRegistrationError = String(
                    localized: "This browser code could not be verified. Make sure the browser scanned this device's pairing code first.",
                    comment: "Scanned web viewer registration failed its authenticity check"
                )
                return false
            }

            FollowerPairingManager.shared.updateWebPushRegistration(
                followerId: registration.followerId,
                endpoint: registration.endpoint,
                p256dh: registration.p256dh,
                auth: registration.auth
            )
            viewerRegistrationError = nil
            viewerRegistered = true
            refreshFollowers()

            // Push a first snapshot right away, so the browser shows data
            // seconds after pairing instead of waiting for the next reading.
            Task.detached(priority: .utility) {
                await TrioRemoteControl.shared.statusPublisher.publish(toFollowerId: registration.followerId)
            }
            return true
        }

        func revokeFollower(id: String) {
            FollowerPairingManager.shared.removeFollower(withId: id)
            // A suspension outlives the pairing that caused it otherwise, and
            // would go on alarming for a follower that no longer exists.
            FollowerSuspensionManager.shared.clearState(followerId: id)
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
