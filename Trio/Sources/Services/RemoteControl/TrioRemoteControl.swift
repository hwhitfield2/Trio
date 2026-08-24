import CoreData
import Foundation
import Swinject

class TrioRemoteControl: Injectable {
    static let shared = TrioRemoteControl()

    @Injected() internal var tempTargetsStorage: TempTargetsStorage!
    @Injected() internal var carbsStorage: CarbsStorage!
    @Injected() internal var nightscoutManager: NightscoutManager!
    @Injected() internal var overrideStorage: OverrideStorage!
    @Injected() internal var settings: SettingsManager!
    @Injected() internal var bolusSafetyValidator: BolusSafetyValidator!
    @Injected() internal var statusPublisher: FollowerStatusPublisher!

    private let timeWindow: TimeInterval = 600

    internal let viewContext: NSManagedObjectContext

    private init() {
        viewContext = CoreDataStack.shared.persistentContainer.viewContext
        injectServices(TrioApp.resolver)
    }

    func handleRemoteNotification(encryptedData: String, followerId: String? = nil) async throws {
        let isTrioRemoteControlEnabled = UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
        guard isTrioRemoteControlEnabled else {
            await logError("Remote command received, but remote control is disabled in settings. Ignoring the command.")
            return
        }

        if let followerId = followerId {
            try await handleFollowerNotification(encryptedData: encryptedData, followerId: followerId)
            return
        }

        let storedSecret = UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? ""
        guard !storedSecret.isEmpty else {
            await logError("Command rejected: shared secret is missing in settings. Cannot authenticate the command.")
            return
        }

        guard let messenger = SecureMessenger(sharedSecret: storedSecret) else {
            await logError("Command rejected: Failed to initialize security module. The shared secret might be invalid.")
            return
        }

        let commandPayload: CommandPayload
        do {
            commandPayload = try messenger.decrypt(base64EncodedString: encryptedData)
        } catch {
            await logError(
                "Command rejected: Decryption failed. Mismatched shared secret or corrupted message. Error: \(error.localizedDescription)"
            )
            return
        }

        guard await isTimestampAcceptable(for: commandPayload) else { return }

        debug(
            .remoteControl,
            "Command successfully decrypted and authenticated. Time difference: \(Int(Date().timeIntervalSince1970 - commandPayload.timestamp)) seconds."
        )

        try await dispatch(commandPayload, followerId: nil)
    }

    /// Handles a command sent by a paired follower app. The command is
    /// encrypted with the follower's own secret and must carry a strictly
    /// increasing sequence number, so a captured push can never be replayed —
    /// not even within the timestamp window — and a single follower can be
    /// revoked without affecting others.
    private func handleFollowerNotification(encryptedData: String, followerId: String) async throws {
        guard let follower = FollowerPairingManager.shared.follower(withId: followerId) else {
            await logError("Command rejected: unknown or revoked follower (id: \(followerId)).")
            return
        }

        guard let messenger = SecureMessenger(sharedSecret: follower.secret) else {
            await logError("Command rejected: failed to initialize security module for follower \(follower.name).")
            return
        }

        let commandPayload: CommandPayload
        do {
            commandPayload = try messenger.decrypt(base64EncodedString: encryptedData)
        } catch {
            await logError(
                "Command rejected: decryption failed for follower \(follower.name). Error: \(error.localizedDescription)"
            )
            return
        }

        guard await isTimestampAcceptable(for: commandPayload) else { return }

        guard let sequence = commandPayload.sequence else {
            await logError(
                "Command rejected: follower command is missing a sequence number.",
                payload: commandPayload
            )
            return
        }

        guard FollowerPairingManager.shared.validateAndConsumeSequence(followerId: followerId, sequence: sequence) else {
            await logError(
                "Command rejected: sequence number \(sequence) was already used (possible replay).",
                payload: commandPayload
            )
            return
        }

        debug(
            .remoteControl,
            "Follower command from \(follower.name) decrypted and authenticated (sequence \(sequence))."
        )

        try await dispatch(commandPayload, followerId: followerId)

        // Push a fresh status snapshot so the follower sees the effect of its
        // command (updated IOB/COB, active targets) without waiting for the
        // next loop cycle.
        await statusPublisher.publish(toFollowerId: followerId)
    }

    /// Tells a follower why its command did not do what it asked.
    ///
    /// Without this a rejected command is silent on the follower: the push was
    /// accepted, so its screen keeps saying it is waiting for the host, with no
    /// way to learn that the host said no. That is tolerable for a temp target
    /// and not for an emergency stop.
    private func notifyFollower(_ followerId: String?, _ reason: String) async {
        guard let followerId,
              let follower = FollowerPairingManager.shared.follower(withId: followerId),
              follower.isPushRegistered
        else { return }

        do {
            try await FollowerPushSender.shared.sendAlert(
                title: String(localized: "Command not carried out", comment: "Title of the alert sent to a follower whose command failed"),
                body: reason,
                sound: .silent,
                to: follower,
                extraData: ["command_error": reason]
            )
        } catch {
            debug(.remoteControl, "Could not tell follower \(follower.name) why the command failed: \(error)")
        }
    }

    private func isTimestampAcceptable(for commandPayload: CommandPayload) async -> Bool {
        let currentTime = Date().timeIntervalSince1970
        let timeDifference = currentTime - commandPayload.timestamp

        if timeDifference > timeWindow {
            await logError(
                "Command rejected: the message is too old (sent \(Int(timeDifference)) seconds ago).",
                payload: commandPayload
            )
            return false
        } else if timeDifference < -timeWindow {
            await logError(
                "Command rejected: the message has an invalid future timestamp.",
                payload: commandPayload
            )
            return false
        }
        return true
    }

    private func dispatch(_ commandPayload: CommandPayload, followerId: String?) async throws {
        switch commandPayload.commandType {
        case .unknown:
            let message = String(
                localized: "This version of Trio does not recognize that command. Update Trio on the host phone.",
                comment: "Error when a follower sends a command a older host build does not know"
            )
            await logError("Command rejected: \(message)", payload: commandPayload)
            await notifyFollower(followerId, message)
        case .bolus:
            try await handleBolusCommand(commandPayload)
        case .tempTarget:
            try await handleTempTargetCommand(commandPayload)
        case .cancelTempTarget:
            await cancelTempTarget(commandPayload)
        case .meal:
            try await handleMealCommand(commandPayload)
            if commandPayload.bolusAmount != nil {
                try await handleBolusCommand(commandPayload)
            }
        case .startOverride:
            await handleStartOverrideCommand(commandPayload)
        case .cancelOverride:
            await handleCancelOverrideCommand(commandPayload)
        case .statusRequest:
            guard followerId != nil else {
                await logError("Status request rejected: only paired followers can request status.", payload: commandPayload)
                return
            }
            // The follower-path caller publishes a snapshot after dispatch,
            // which is exactly what a status request asks for.
        case .historyRequest:
            guard let followerId = followerId else {
                await logError(
                    "History request rejected: only paired followers can request history.",
                    payload: commandPayload
                )
                return
            }
            // Sent here rather than left to the snapshot after dispatch: this
            // is a run of pushes, not the single fresh status every other
            // command ends with. The host clamps the window it was asked for.
            await statusPublisher.publishHistory(
                toFollowerId: followerId,
                hours: commandPayload.historyHours ?? BaseFollowerStatusPublisher.maximumHistoryHours
            )
        case .registerFollower:
            guard let followerId = followerId else {
                await logError(
                    "Push registration rejected: only paired followers can register for status pushes.",
                    payload: commandPayload
                )
                return
            }
            guard let token = commandPayload.pushToken, !token.isEmpty,
                  let transport = commandPayload.pushTransport, ["apns", "fcm"].contains(transport)
            else {
                await logError("Push registration rejected: missing or invalid push token/transport.", payload: commandPayload)
                return
            }
            FollowerPairingManager.shared.updatePushRegistration(
                followerId: followerId,
                token: token,
                transport: transport,
                bundleId: commandPayload.pushBundleId,
                environment: commandPayload.pushEnvironment,
                appVersion: commandPayload.appVersion,
                appBuild: commandPayload.appBuild,
                appPlatform: commandPayload.appPlatform
            )
            debug(
                .remoteControl,
                "Follower push registration stored (transport: \(transport), version: \(commandPayload.appVersion ?? "unreported"))."
            )
        case .suspendInsulin:
            guard let followerId = followerId,
                  let follower = FollowerPairingManager.shared.follower(withId: followerId)
            else {
                await logError(
                    "Insulin suspension rejected: only paired followers can suspend delivery.",
                    payload: commandPayload
                )
                return
            }

            switch await FollowerSuspensionManager.shared.suspend(requestedBy: follower) {
            case .suspended:
                await logSuccess(
                    "Insulin delivery suspended at the request of \(follower.name).",
                    payload: commandPayload,
                    customNotificationMessage: String(
                        localized: "Insulin suspended by a follower",
                        comment: "Notification shown on the host when a follower suspends insulin"
                    )
                )
            case .notPermitted:
                let message = String(
                    localized: "This follower is not allowed to suspend insulin on that host.",
                    comment: "Told to a follower whose suspend permission has been withdrawn"
                )
                await logError(
                    "Insulin suspension rejected: \(follower.name) is not allowed to suspend delivery.",
                    payload: commandPayload
                )
                await notifyFollower(followerId, message)
            case let .failed(reason):
                await logError("Insulin suspension failed: \(reason)", payload: commandPayload)
                await notifyFollower(
                    followerId,
                    String(
                        format: String(
                            localized: "Insulin was not suspended: %@",
                            comment: "Told to a follower when the pump refused to suspend"
                        ),
                        reason
                    )
                )
            }
        case .registerLiveActivity:
            guard let followerId = followerId else {
                await logError(
                    "Live Activity registration rejected: only paired followers can register an activity.",
                    payload: commandPayload
                )
                return
            }
            guard let token = commandPayload.liveActivityToken else {
                await logError("Live Activity registration rejected: no token in the command.", payload: commandPayload)
                return
            }
            FollowerPairingManager.shared.updateLiveActivityToken(followerId: followerId, token: token)
            debug(
                .remoteControl,
                token.isEmpty
                    ? "Follower Live Activity token cleared."
                    : "Follower Live Activity token stored."
            )
        }
    }
}
