import Foundation

struct EncryptedPushMessage: Decodable {
    let encryptedData: String
    /// Present when the sender is a paired follower app. Selects the
    /// per-follower secret used to decrypt `encryptedData`.
    let followerId: String?

    enum CodingKeys: String, CodingKey {
        case encryptedData = "encrypted_data"
        case followerId = "follower_id"
    }
}

struct CommandPayload: Decodable, Sendable {
    var user: String
    var commandType: TrioRemoteControl.CommandType
    var timestamp: TimeInterval
    var bolusAmount: Decimal?
    var target: Int?
    var duration: Int?
    var carbs: Int?
    var protein: Int?
    var fat: Int?
    var overrideName: String?
    var scheduledTime: TimeInterval?
    /// Monotonically increasing counter set by paired follower apps. Required
    /// on the follower command path, where it provides replay protection.
    var sequence: Int?
    var returnNotification: ReturnNotificationInfo?

    // Follower push registration (register_follower command). The follower
    // tells the host where to deliver encrypted status pushes.
    var pushToken: String?
    /// "apns" (iOS follower) or "fcm" (Android follower).
    var pushTransport: String?
    /// Bundle identifier of the follower app (APNS topic; iOS followers only).
    var pushBundleId: String?
    /// "production" or "sandbox" (iOS followers only).
    var pushEnvironment: String?

    struct ReturnNotificationInfo: Decodable, Sendable {
        let productionEnvironment: Bool
        let deviceToken: String
        let bundleId: String
        let teamId: String
        let keyId: String
        let apnsKey: String

        enum CodingKeys: String, CodingKey {
            case productionEnvironment = "production_environment"
            case deviceToken = "device_token"
            case bundleId = "bundle_id"
            case teamId = "team_id"
            case keyId = "key_id"
            case apnsKey = "apns_key"
        }
    }

    enum CodingKeys: String, CodingKey {
        case user
        case timestamp
        case target
        case duration
        case carbs
        case protein
        case fat
        case overrideName
        case commandType = "command_type"
        case bolusAmount = "bolus_amount"
        case scheduledTime = "scheduled_time"
        case sequence
        case returnNotification = "return_notification"
        case pushToken = "push_token"
        case pushTransport = "push_transport"
        case pushBundleId = "push_bundle_id"
        case pushEnvironment = "push_environment"
    }

    func humanReadableDescription() -> String {
        var description = "User: \(user). Command Type: \(commandType.description). "

        if let override = overrideName {
            description += "Override Name: \(override). "
        }

        switch commandType {
        case .bolus:
            if let amount = bolusAmount {
                description += "Bolus Amount: \(amount) units."
            } else {
                description += "Bolus Amount: unknown."
            }
        case .tempTarget:
            let targetDesc = target != nil ? "\(target!) mg/dL" : "unknown target"
            let durationDesc = duration != nil ? "\(duration!) minutes" : "unknown duration"
            description += "Temp Target: \(targetDesc), Duration: \(durationDesc)."
        case .cancelTempTarget:
            description += "Cancel Temp Target command."
        case .meal:
            let carbsDesc = carbs != nil ? "\(carbs!)g carbs" : "unknown carbs"
            let fatDesc = fat != nil ? "\(fat!)g fat" : "unknown fat"
            let proteinDesc = protein != nil ? "\(protein!)g protein" : "unknown protein"
            description += "Meal with \(carbsDesc), \(fatDesc), \(proteinDesc)."
        case .startOverride:
            if let override = overrideName {
                description += "Start Override: \(override)."
            } else {
                description += "Start Override: unknown override name."
            }
        case .cancelOverride:
            description += "Cancel Override command."
        case .statusRequest:
            description += "Status request."
        case .registerFollower:
            description += "Follower push registration (\(pushTransport ?? "unknown transport"))."
        }

        if let scheduledTime = scheduledTime {
            let date = Date(timeIntervalSince1970: scheduledTime)
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let dateString = formatter.string(from: date)
            description += " Scheduled for: \(dateString)."
        }

        return description
    }
}

extension TrioRemoteControl {
    enum CommandType: String, Codable {
        case bolus
        case tempTarget = "temp_target"
        case cancelTempTarget = "cancel_temp_target"
        case meal
        case startOverride = "start_override"
        case cancelOverride = "cancel_override"
        case statusRequest = "status_request"
        case registerFollower = "register_follower"

        var description: String {
            switch self {
            case .bolus:
                return "Bolus"
            case .tempTarget:
                return "Temporary Target"
            case .cancelTempTarget:
                return "Cancel Temporary Target"
            case .meal:
                return "Meal"
            case .startOverride:
                return "Start Override"
            case .cancelOverride:
                return "Cancel Override"
            case .statusRequest:
                return "Status Request"
            case .registerFollower:
                return "Register Follower"
            }
        }
    }
}
