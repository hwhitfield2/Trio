import Foundation

enum SettingsExport {
    enum Config {}
}

protocol SettingsExportProvider: Provider {}

// MARK: - Settings Backup (machine-readable export/import)

/// Machine-readable backup of Trio's configuration.
///
/// Unlike the CSV export — which is localized, unit-converted and meant for humans —
/// this container round-trips the raw storage models unchanged, so a backup written
/// by `exportBackup()` can be read back by `importBackup(from:)`.
/// Glucose-related values are stored in their internal representation (mg/dL).
struct TrioSettingsBackup: JSON {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = TrioSettingsBackup.currentSchemaVersion
    var exportDate: Date?
    var appVersion: String?
    var branch: String?

    var trioSettings: TrioSettings?
    var preferences: Preferences?
    var pumpSettings: PumpSettings?

    /// Effective insulin concentration the therapy values below are denominated
    /// in (1 = U-100, 0.1 = U-10). Written independently of `trioSettings` on
    /// purpose: every therapy figure in a backup is a *pumped volume*, so
    /// without this the same numbers mean something 2–10x different on a device
    /// running a different concentration. An import that finds therapy data but
    /// no concentration cannot know which, and must refuse rather than guess.
    var insulinConcentrationFactor: Decimal?

    var basalProfile: [BasalProfileEntry]?
    var insulinSensitivities: InsulinSensitivities?
    var carbRatios: CarbRatios?
    var bgTargets: BGTargets?

    var tempTargetPresets: [TempTargetPresetBackup]?
    var overridePresets: [OverridePresetBackup]?
    var mealPresets: [MealPresetBackup]?
}

/// Snapshot of a `TempTargetStored` preset. Target values in mg/dL.
struct TempTargetPresetBackup: JSON {
    var name: String
    var target: Decimal
    var duration: Decimal
    var halfBasalTarget: Decimal?
}

/// Snapshot of an `OverrideStored` preset. Target values in mg/dL.
struct OverridePresetBackup: JSON {
    var name: String
    var percentage: Double
    var indefinite: Bool
    var duration: Decimal
    var target: Decimal?
    var advancedSettings: Bool
    var smbIsOff: Bool
    var smbIsScheduledOff: Bool
    var start: Decimal?
    var end: Decimal?
    var smbMinutes: Decimal?
    var uamMinutes: Decimal?
    var isfAndCr: Bool
    var isf: Bool
    var cr: Bool
}

/// Snapshot of a `MealPresetStored` entry.
struct MealPresetBackup: JSON {
    var dish: String
    var carbs: Decimal?
    var fat: Decimal?
    var protein: Decimal?
}
