import Foundation

// MARK: - Restore from another device (device-setup QR transfer)

/// A person moving Trio to a new phone should not have to walk the whole
/// wizard just to re-enter what their old phone already knows. Scanning the
/// setup code applies everything — settings, therapy profiles, presets and
/// the remote-control identity with its followers — after which onboarding
/// skips straight to what a transfer cannot carry: the diagnostics consent
/// and the notification/Bluetooth permissions of THIS phone.
extension Onboarding.StateModel {
    /// The SettingsExport module owns the transfer logic (validation, the
    /// backup apply with its insulin-concentration safety, the follower
    /// migration); onboarding borrows a wired instance of its state model
    /// rather than duplicating any of it.
    private func makeDeviceSetupImporter() -> SettingsExport.StateModel {
        let importer = SettingsExport.StateModel()
        importer.resolver = resolver ?? TrioApp.resolver
        return importer
    }

    /// Why the scanned transfer must be refused, or nil when it is sound —
    /// the same checks a backup file import runs.
    func validateScannedDeviceSetup(_ transfer: DeviceSetupTransfer) -> String? {
        makeDeviceSetupImporter().validateDeviceSetup(transfer)?.localizedDescription
    }

    /// What the confirmation dialog tells the user before anything is applied.
    func scannedDeviceSetupDescription(_ transfer: DeviceSetupTransfer) -> String {
        var lines: [String] = []
        if let hostName = transfer.hostName {
            lines.append(String(localized: "Setup code from \(hostName)."))
        }
        lines.append(String(
            localized: "This sets up Trio exactly like the other phone: all settings, therapy profiles and presets."
        ))
        if let followerCount = transfer.remoteControl?.followers?.count, followerCount > 0 {
            lines.append(String(
                localized: "Remote control moves with it, including \(followerCount) paired follower(s) — they switch to this phone automatically. Turn off remote control on the old phone afterwards."
            ))
        }
        lines.append(String(
            localized: "The guided setup will be skipped. You still choose diagnostics sharing and grant permissions, and you pair your pump and CGM afterwards."
        ))
        return lines.joined(separator: "\n\n")
    }

    /// Applies a scanned transfer. On success the wizard's therapy and
    /// algorithm chapters are skipped and — critically — `saveOnboardingData()`
    /// must NOT run at the end, or the wizard's untouched defaults would
    /// overwrite everything just imported. `didImportDeviceSetup` is what the
    /// navigation reads to keep both promises.
    func applyScannedDeviceSetup(_ transfer: DeviceSetupTransfer) async -> Result<String, SettingsExport.StateModel.ImportError> {
        isApplyingDeviceSetup = true
        defer { isApplyingDeviceSetup = false }

        switch await makeDeviceSetupImporter().applyDeviceSetup(transfer) {
        case let .success(summary):
            didImportDeviceSetup = true
            return .success(summary.message)
        case let .failure(error):
            return .failure(error)
        }
    }
}
