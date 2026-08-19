import Foundation
import UIKit

/// What a migrated host pushes to each of its followers: the new device's
/// push address, so commands start reaching the new phone instead of the one
/// the pairing bundle named. Encrypted with the follower's own secret — the
/// same channel and key as status snapshots — so only the paired follower
/// can read or act on it.
struct FollowerHostUpdate: Codable {
    struct APNSAddress: Codable {
        let deviceToken: String
        let bundleId: String
        let production: Bool

        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case bundleId = "bundle_id"
            case production
        }
    }

    let type: String
    /// Unix seconds. The follower only ever applies updates newer than the
    /// last one it applied, so a delayed or replayed push cannot point it
    /// back at a dead device.
    let timestamp: TimeInterval
    let hostName: String
    let apns: APNSAddress

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case hostName = "host_name"
        case apns
    }

    static let updateType = "host_migration"
}

/// Delivers the new device's push address to followers carried over by a
/// device-setup transfer.
///
/// A migrated follower still addresses commands to the old phone — its
/// pairing bundle names that device's APNS token — so until this push lands,
/// the new host receives nothing from it. The attempt runs whenever it might
/// newly succeed: right after the transfer is applied, and again every time
/// the APNS device token changes (which is exactly the moment a fresh install
/// first learns its own address). The flag on each follower is only cleared
/// once APNS/FCM accepted the push, so failed attempts retry on the next
/// trigger rather than silently stranding a follower.
final class FollowerHostMigrationNotifier {
    static let shared = FollowerHostMigrationNotifier()

    private init() {}

    /// Tells every flagged follower where this device can be reached. Safe to
    /// call at any time, including concurrently: without a device token,
    /// flagged followers, or push registration nothing is sent and the flags
    /// stay put for the next try. Overlapping triggers can at worst send a
    /// follower the same address twice, which it applies once by timestamp.
    func notifyPendingFollowers() async {
        let pending = FollowerPairingManager.shared.followersNeedingHostUpdate
        guard !pending.isEmpty else { return }

        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken"), !deviceToken.isEmpty else {
            debug(.remoteControl, "Host migration: \(pending.count) follower(s) waiting, but no device token yet.")
            return
        }

        let update = FollowerHostUpdate(
            type: FollowerHostUpdate.updateType,
            timestamp: Date().timeIntervalSince1970,
            hostName: await MainActor.run { UIDevice.current.name },
            apns: FollowerHostUpdate.APNSAddress(
                deviceToken: deviceToken,
                bundleId: Bundle.main.bundleIdentifier ?? "",
                production: UserDefaults.standard.bool(forKey: "isAPNSProduction")
            )
        )

        for follower in pending {
            guard follower.isPushRegistered else {
                // Never registered a push address — unreachable from here. The
                // flag stays, and the Remote Control screen says this follower
                // must re-pair by QR code.
                debug(.remoteControl, "Host migration: \(follower.name) has no push registration; it must re-pair.")
                continue
            }
            guard let messenger = SecureMessenger(sharedSecret: follower.secret) else { continue }

            do {
                let encrypted = try messenger.encrypt(data: JSONEncoder().encode(update))
                try await FollowerPushSender.shared.sendHostUpdate(encryptedUpdate: encrypted, to: follower)
                FollowerPairingManager.shared.setNeedsHostUpdate(followerId: follower.id, false)
                debug(.remoteControl, "Host migration: told \(follower.name) the new device address.")
            } catch {
                debug(.remoteControl, "Host migration: could not reach \(follower.name) yet: \(error)")
            }
        }
    }
}
