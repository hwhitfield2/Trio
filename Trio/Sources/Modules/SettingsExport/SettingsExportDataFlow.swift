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
