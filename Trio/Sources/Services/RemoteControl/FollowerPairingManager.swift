import CryptoSwift
import Foundation
import Swinject
import UIKit

/// A follower device (Trio Follower app on iOS or Android) that has been paired
/// with this host and may send remote commands using its own per-device secret.
struct PairedFollower: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// Per-follower secret (base64-encoded 32 random bytes). The command
    /// encryption key is SHA-256 of the UTF-8 bytes of this string, matching
    /// `SecureMessenger`.
    var secret: String
    var createdAt: Date
    /// Highest command sequence number accepted from this follower. Commands
    /// must arrive with a strictly greater sequence number, which prevents
    /// replay of captured pushes even inside the timestamp window.
    var lastSequence: Int
    var lastSeenAt: Date?

    // Push address registered by the follower (register_follower command);
    // used to deliver encrypted status snapshots from the host.
    var pushToken: String?
    /// "apns" (iOS follower) or "fcm" (Android follower).
    var pushTransport: String?
    /// APNS topic for iOS followers.
    var pushBundleId: String?
    /// "production" or "sandbox" for iOS followers.
    var pushEnvironment: String?

    // The follower build that last registered. Optional for the same reason as
    // the fields below: followers paired before this existed must still decode.
    var appVersion: String?
    var appBuild: String?
    /// "ios" or "android".
    var appPlatform: String?
    var appVersionReportedAt: Date?

    /// APNS token of the follower's Live Activity, registered by the follower
    /// app when the user opts in to remote Lock Screen updates. Optional for
    /// the same reason as `alerts`: followers paired before this existed must
    /// still decode.
    var liveActivityToken: String?

    /// Whether this follower may stop insulin delivery in an emergency.
    ///
    /// Optional, and treated as allowed when absent: followers paired before
    /// this existed keep working, and the feature is there to be reached for.
    /// Turn it off for a follower who should be able to watch but not act.
    var maySuspend: Bool?

    var maySuspendInsulin: Bool { maySuspend ?? true }

    /// Which alerts this follower receives, and how loudly.
    ///
    /// Optional because the keychain already holds followers paired before this
    /// existed: the synthesized decoder ignores property defaults, so a
    /// non-optional here would fail to decode every existing pairing and quietly
    /// unpair everyone.
    var alerts: FollowerAlertSettings?

    /// The alert profile to evaluate against, falling back to the defaults for
    /// followers that have never been configured.
    var alertSettings: FollowerAlertSettings { alerts ?? .default }

    var isPushRegistered: Bool { !(pushToken ?? "").isEmpty }

    /// Live Activities are iOS-only, so an Android follower never has one.
    var isLiveActivityRegistered: Bool {
        pushTransport == "apns" && !(liveActivityToken ?? "").isEmpty
    }

    /// Six-digit verification code derived from the secret. Shown on the host
    /// after creating a pairing and on the follower after scanning the QR code
    /// so the user can confirm both devices hold the same secret.
    var verificationCode: String {
        Self.verificationCode(forSecret: secret)
    }

    static func verificationCode(forSecret secret: String) -> String {
        let digest = Array(Data(secret.utf8).sha256().prefix(4))
        let value = digest.reduce(0) { ($0 << 8) | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }
}

/// Everything a follower app needs to operate, delivered in a single QR code
/// scan. Treat the encoded payload like a password: it contains the per-device
/// secret and the APNS key.
struct FollowerPairingBundle: Codable {
    struct APNSInfo: Codable {
        let deviceToken: String
        let bundleId: String
        let teamId: String
        let keyId: String
        let apnsKey: String
        let production: Bool

        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case bundleId = "bundle_id"
            case teamId = "team_id"
            case keyId = "key_id"
            case apnsKey = "apns_key"
            case production
        }
    }

    struct Limits: Codable {
        let maxBolus: Decimal
        let maxCarbs: Decimal
        let units: String

        enum CodingKeys: String, CodingKey {
            case maxBolus = "max_bolus"
            case maxCarbs = "max_carbs"
            case units
        }
    }

    let version: Int
    let type: String
    let followerId: String
    let followerName: String
    let hostName: String
    let secret: String
    let apns: APNSInfo
    let limits: Limits
    /// Whether the host has an FCM service account configured. Android
    /// followers need this for the status display; without it they can still
    /// send commands but receive no data pushes.
    let fcmAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case followerId = "follower_id"
        case followerName = "follower_name"
        case hostName = "host_name"
        case secret
        case apns
        case limits
        case fcmAvailable = "fcm_available"
    }

    static let pairingType = "trio-follower-pairing"
}

enum FollowerPairingError: LocalizedError {
    case missingDeviceToken
    case missingAPNSCredentials

    var errorDescription: String? {
        switch self {
        case .missingDeviceToken:
            return String(
                localized: "Trio has not received a push notification device token yet. Make sure notifications are allowed and try again."
            )
        case .missingAPNSCredentials:
            return String(
                localized: "Enter your Apple Developer Team ID, APNS Key ID and APNS key before pairing a follower."
            )
        }
    }
}

/// Manages the list of paired follower devices and creates pairing bundles.
/// Secrets are stored in the keychain, never in plain user defaults.
final class FollowerPairingManager: Injectable {
    static let shared = FollowerPairingManager()

    enum StorageKeys {
        static let followers = "followerPairing.followers"
        static let apnsTeamId = "followerPairing.apnsTeamId"
        static let apnsKeyId = "followerPairing.apnsKeyId"
        static let apnsKey = "followerPairing.apnsKey"
        static let fcmServiceAccount = "followerPairing.fcmServiceAccount"
    }

    @Injected() private var keychain: Keychain!
    @Injected() private var settings: SettingsManager!

    private let queue = DispatchQueue(label: "FollowerPairingManager.queue")

    init(resolver: Resolver = TrioApp.resolver) {
        injectServices(resolver)
    }

    // MARK: - Followers

    var followers: [PairedFollower] {
        queue.sync { loadFollowers() }
    }

    func follower(withId id: String) -> PairedFollower? {
        followers.first { $0.id == id }
    }

    @discardableResult func addFollower(named name: String) -> PairedFollower {
        let follower = PairedFollower(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: Self.generateSecret(),
            createdAt: Date(),
            lastSequence: 0,
            lastSeenAt: nil,
            // Left nil rather than seeded, so a follower that was never
            // configured follows any later change to the defaults.
            alerts: nil
        )
        queue.sync {
            var all = loadFollowers()
            all.append(follower)
            saveFollowers(all)
        }
        return follower
    }

    func removeFollower(withId id: String) {
        queue.sync {
            var all = loadFollowers()
            all.removeAll { $0.id == id }
            saveFollowers(all)
        }
    }

    /// Stores the push address a follower registered so the host can deliver
    /// encrypted status snapshots to it.
    func updatePushRegistration(
        followerId: String,
        token: String,
        transport: String,
        bundleId: String?,
        environment: String?,
        appVersion: String? = nil,
        appBuild: String? = nil,
        appPlatform: String? = nil
    ) {
        queue.sync {
            var all = loadFollowers()
            guard let index = all.firstIndex(where: { $0.id == followerId }) else { return }
            all[index].pushToken = token
            all[index].pushTransport = transport
            all[index].pushBundleId = bundleId
            all[index].pushEnvironment = environment
            // Only overwrite what was actually reported: a follower too old to
            // send its version should keep showing nothing rather than have the
            // last known value wiped.
            if let appVersion, !appVersion.isEmpty {
                all[index].appVersion = appVersion
                all[index].appBuild = appBuild
                all[index].appPlatform = appPlatform
                all[index].appVersionReportedAt = Date()
            }
            saveFollowers(all)
        }
    }

    /// Allows or forbids this follower stopping insulin delivery.
    func setMaySuspendInsulin(followerId: String, _ allowed: Bool) {
        queue.sync {
            var all = loadFollowers()
            guard let index = all.firstIndex(where: { $0.id == followerId }) else { return }
            all[index].maySuspend = allowed
            saveFollowers(all)
        }
    }

    /// Stores (or, with an empty token, clears) the follower's Live Activity
    /// push address.
    func updateLiveActivityToken(followerId: String, token: String) {
        queue.sync {
            var all = loadFollowers()
            guard let index = all.firstIndex(where: { $0.id == followerId }) else { return }
            all[index].liveActivityToken = token.isEmpty ? nil : token
            saveFollowers(all)
        }
    }

    /// Stores a follower's alert profile, keeping the thresholds ordered and in
    /// range. Returns what was actually stored, which may differ from what was
    /// passed once clamped.
    @discardableResult
    func updateAlertSettings(followerId: String, _ settings: FollowerAlertSettings) -> FollowerAlertSettings? {
        queue.sync {
            var all = loadFollowers()
            guard let index = all.firstIndex(where: { $0.id == followerId }) else { return nil }
            var clamped = settings
            clamped.clampThresholds()
            all[index].alerts = clamped
            saveFollowers(all)
            return clamped
        }
    }

    /// Validates that `sequence` is strictly greater than the last accepted
    /// sequence for the follower and records it. Returns `false` when the
    /// command must be rejected as a replay (or out-of-order duplicate).
    func validateAndConsumeSequence(followerId: String, sequence: Int) -> Bool {
        queue.sync {
            var all = loadFollowers()
            guard let index = all.firstIndex(where: { $0.id == followerId }) else {
                return false
            }
            guard sequence > all[index].lastSequence else {
                return false
            }
            all[index].lastSequence = sequence
            all[index].lastSeenAt = Date()
            saveFollowers(all)
            return true
        }
    }

    // MARK: - APNS credentials

    var apnsTeamId: String {
        get { stringValue(forKey: StorageKeys.apnsTeamId) }
        set { keychain.setValue(newValue, forKey: StorageKeys.apnsTeamId) }
    }

    var apnsKeyId: String {
        get { stringValue(forKey: StorageKeys.apnsKeyId) }
        set { keychain.setValue(newValue, forKey: StorageKeys.apnsKeyId) }
    }

    var apnsKey: String {
        get { stringValue(forKey: StorageKeys.apnsKey) }
        set { keychain.setValue(newValue, forKey: StorageKeys.apnsKey) }
    }

    private func stringValue(forKey key: String) -> String {
        ((try? keychain.getValue(String.self, forKey: key).get()) ?? nil) ?? ""
    }

    var hasAPNSCredentials: Bool {
        !apnsTeamId.isEmpty && !apnsKeyId.isEmpty && !apnsKey.isEmpty
    }

    /// Raw Firebase service-account JSON used to push status to Android
    /// followers over FCM. Optional — iOS followers use APNS.
    var fcmServiceAccountJSON: String {
        get { stringValue(forKey: StorageKeys.fcmServiceAccount) }
        set { keychain.setValue(newValue, forKey: StorageKeys.fcmServiceAccount) }
    }

    var hasFCMCredentials: Bool {
        FCMServiceAccount(json: fcmServiceAccountJSON) != nil
    }

    // MARK: - Pairing bundle

    /// Builds the JSON string encoded into the pairing QR code for a follower.
    func makePairingPayload(for follower: PairedFollower) throws -> String {
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken"), !deviceToken.isEmpty else {
            throw FollowerPairingError.missingDeviceToken
        }
        guard hasAPNSCredentials else {
            throw FollowerPairingError.missingAPNSCredentials
        }

        let bundle = FollowerPairingBundle(
            version: 1,
            type: FollowerPairingBundle.pairingType,
            followerId: follower.id,
            followerName: follower.name,
            hostName: UIDevice.current.name,
            secret: follower.secret,
            apns: FollowerPairingBundle.APNSInfo(
                deviceToken: deviceToken,
                bundleId: Bundle.main.bundleIdentifier ?? "",
                teamId: apnsTeamId,
                keyId: apnsKeyId,
                apnsKey: apnsKey,
                production: UserDefaults.standard.bool(forKey: "isAPNSProduction")
            ),
            limits: FollowerPairingBundle.Limits(
                maxBolus: settings.pumpSettings.maxBolus,
                maxCarbs: settings.settings.maxCarbs,
                units: settings.settings.units.rawValue
            ),
            fcmAvailable: hasFCMCredentials
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(bundle)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "FollowerPairingManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode pairing payload"]
            )
        }
        return json
    }

    // MARK: - Private

    private func loadFollowers() -> [PairedFollower] {
        ((try? keychain.getValue([PairedFollower].self, forKey: StorageKeys.followers).get()) ?? nil) ?? []
    }

    private func saveFollowers(_ followers: [PairedFollower]) {
        keychain.setValue(followers, forKey: StorageKeys.followers)
    }

    private static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes should never fail in practice; fall back to
            // SystemRandomNumberGenerator rather than producing a weak secret.
            var generator = SystemRandomNumberGenerator()
            bytes = (0 ..< 32).map { _ in UInt8.random(in: UInt8.min ... UInt8.max, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
    }
}
