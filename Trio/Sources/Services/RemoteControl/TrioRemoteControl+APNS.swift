import Foundation

extension TrioRemoteControl {
    internal func handleAPNSChanges(deviceToken: String?) async throws {
        let previousDeviceToken = UserDefaults.standard.string(forKey: "deviceToken")
        let previousIsAPNSProduction = UserDefaults.standard.bool(forKey: "isAPNSProduction")

        let isAPNSProduction = isRunningInAPNSProductionEnvironment()
        var shouldUploadProfiles = false

        if let token = deviceToken, token != previousDeviceToken {
            UserDefaults.standard.set(token, forKey: "deviceToken")
            debug(.remoteControl, "Device token updated: \(token)")
            shouldUploadProfiles = true
        }

        if previousIsAPNSProduction != isAPNSProduction {
            UserDefaults.standard.set(isAPNSProduction, forKey: "isAPNSProduction")
            debug(.remoteControl, "APNS environment changed to: \(isAPNSProduction ? "Production" : "Sandbox")")
            shouldUploadProfiles = true
        }

        if shouldUploadProfiles {
            try await nightscoutManager.uploadProfiles()
        } else {
            debug(.remoteControl, "No changes detected in device token or APNS environment.")
        }

        // Registration fires on every launch, which makes this the reliable
        // retry point for followers migrated from another device that could
        // not be reached yet: a no-op unless any are still flagged.
        await FollowerHostMigrationNotifier.shared.notifyPendingFollowers()
    }

    private func isRunningInAPNSProductionEnvironment() -> Bool {
        BuildDetails.shared.isTestFlightBuild()
    }
}
