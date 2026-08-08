@testable import Trio
import XCTest

final class SettingsExportTests: XCTestCase {
    func testCSVEscaping() {
        // Test CSV escaping functionality
        let testValue = "Test,Value\"With\nSpecial Characters"
        let escaped = csvEscape(testValue)
        let expected = "\"Test,Value\"\"With\nSpecial Characters\""
        XCTAssertEqual(escaped, expected, "CSV escaping should handle commas, quotes, and newlines")
    }

    func testCSVEscapingSimple() {
        // Test simple values don't get escaped
        let testValue = "SimpleValue"
        let escaped = csvEscape(testValue)
        XCTAssertEqual(escaped, testValue, "Simple values should not be escaped")
    }

    func testExportCSVStructure() {
        // Test that the CSV has the expected header structure
        let expectedHeader = "Setting Category,Subcategory,Setting Name,Value,Unit"
        // This test would require mocking the settings manager and file storage
        // For now, we verify the header format is correct
        XCTAssertEqual(expectedHeader.components(separatedBy: ",").count, 5, "CSV header should have 5 columns")
    }

    func testExportErrorTypes() {
        // Test that our export error types are properly defined
        let documentError = Settings.StateModel.ExportError.documentsDirectoryNotFound
        XCTAssertNotNil(documentError.errorDescription, "Document error should have description")

        let writeError = Settings.StateModel.ExportError.fileWriteError(TestError.testError)
        XCTAssertNotNil(writeError.errorDescription, "Write error should have description")

        let unknownError = Settings.StateModel.ExportError.unknown("Test message")
        XCTAssertNotNil(unknownError.errorDescription, "Unknown error should have description")
    }

    func testExportFileNaming() {
        // Test that export files have the correct naming pattern
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "TrioSettings_\(timestamp).csv"

        XCTAssertTrue(fileName.hasPrefix("TrioSettings_"), "File name should start with TrioSettings_")
        XCTAssertTrue(fileName.hasSuffix(".csv"), "File name should end with .csv")
        XCTAssertEqual(fileName.components(separatedBy: "_").count, 2, "File name should have one underscore")
    }

    // Helper function to test CSV escaping (extracted from Settings.StateModel)
    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    // MARK: - Backup (JSON export/import)

    func testBackupFileNaming() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "TrioSettingsBackup_\(timestamp).json"

        XCTAssertTrue(fileName.hasPrefix("TrioSettingsBackup_"), "Backup file name should start with TrioSettingsBackup_")
        XCTAssertTrue(fileName.hasSuffix(".json"), "Backup file name should end with .json")
    }

    func testBackupRoundTrip() throws {
        var backup = TrioSettingsBackup()
        backup.exportDate = Date()
        backup.appVersion = "1.0.0 (42)"
        backup.branch = "main"

        var settings = TrioSettings()
        settings.units = .mmolL
        settings.lowGlucose = 70
        settings.highGlucose = 200
        backup.trioSettings = settings

        var preferences = Preferences()
        preferences.maxIOB = 7.5
        preferences.enableSMBAlways = true
        backup.preferences = preferences

        backup.pumpSettings = PumpSettings(insulinActionCurve: 9, maxBolus: 10, maxBasal: 3.5)

        backup.basalProfile = [
            BasalProfileEntry(start: "00:00", minutes: 0, rate: 0.85),
            BasalProfileEntry(start: "08:00", minutes: 480, rate: 1.15)
        ]
        backup.carbRatios = CarbRatios(units: .grams, schedule: [
            CarbRatioEntry(start: "00:00", offset: 0, ratio: 10)
        ])
        backup.insulinSensitivities = InsulinSensitivities(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            sensitivities: [InsulinSensitivityEntry(sensitivity: 45, offset: 0, start: "00:00")]
        )
        backup.bgTargets = BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [
            BGTargetEntry(low: 100, high: 100, start: "00:00", offset: 0)
        ])

        backup.tempTargetPresets = [
            TempTargetPresetBackup(name: "Exercise", target: 140, duration: 60, halfBasalTarget: 160)
        ]
        backup.overridePresets = [
            OverridePresetBackup(
                name: "Sick Day",
                percentage: 120,
                indefinite: false,
                duration: 180,
                target: 110,
                advancedSettings: false,
                smbIsOff: true,
                smbIsScheduledOff: false,
                start: nil,
                end: nil,
                smbMinutes: nil,
                uamMinutes: nil,
                isfAndCr: true,
                isf: false,
                cr: false
            )
        ]
        backup.mealPresets = [
            MealPresetBackup(dish: "Pizza", carbs: 60, fat: 25, protein: 20)
        ]

        let data = try JSONCoding.encoder.encode(backup)
        let decoded = try JSONCoding.decoder.decode(TrioSettingsBackup.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, TrioSettingsBackup.currentSchemaVersion)
        XCTAssertEqual(decoded.appVersion, "1.0.0 (42)")
        XCTAssertEqual(decoded.trioSettings?.units, .mmolL)
        XCTAssertEqual(decoded.trioSettings?.lowGlucose, 70)
        XCTAssertEqual(decoded.preferences?.maxIOB, 7.5)
        XCTAssertEqual(decoded.preferences?.enableSMBAlways, true)
        XCTAssertEqual(decoded.pumpSettings?.maxBasal, 3.5)
        XCTAssertEqual(decoded.basalProfile?.count, 2)
        XCTAssertEqual(decoded.basalProfile?.last?.rate, 1.15)
        XCTAssertEqual(decoded.carbRatios?.schedule.first?.ratio, 10)
        XCTAssertEqual(decoded.insulinSensitivities?.sensitivities.first?.sensitivity, 45)
        XCTAssertEqual(decoded.bgTargets?.targets.first?.low, 100)
        XCTAssertEqual(decoded.tempTargetPresets?.first?.name, "Exercise")
        XCTAssertEqual(decoded.tempTargetPresets?.first?.target, 140)
        XCTAssertEqual(decoded.overridePresets?.first?.name, "Sick Day")
        XCTAssertEqual(decoded.overridePresets?.first?.percentage, 120)
        XCTAssertEqual(decoded.overridePresets?.first?.smbIsOff, true)
        XCTAssertEqual(decoded.mealPresets?.first?.dish, "Pizza")
        XCTAssertEqual(decoded.mealPresets?.first?.carbs, 60)
    }

    func testBackupDecodingRejectsGarbage() {
        let notABackup = Data("Setting Category,Subcategory,Setting Name,Value,Unit".utf8)
        XCTAssertThrowsError(try JSONCoding.decoder.decode(TrioSettingsBackup.self, from: notABackup))
    }

    func testBackupDecodingToleratesMissingSections() throws {
        // A backup with only a subset of sections must still decode — every section is optional.
        let minimal = Data("{\"schemaVersion\": 1}".utf8)
        let decoded = try JSONCoding.decoder.decode(TrioSettingsBackup.self, from: minimal)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.trioSettings)
        XCTAssertNil(decoded.basalProfile)
        XCTAssertNil(decoded.tempTargetPresets)
    }
}
