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
                environment: commandPayload.pushEnvironment
            )
            debug(.remoteControl, "Follower push registration stored (transport: \(transport)).")
        }
    }
}
