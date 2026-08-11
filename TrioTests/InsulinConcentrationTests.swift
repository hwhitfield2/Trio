import Foundation
import HealthKit
import LoopKit
import Testing

@testable import Trio

/// Pins the diluted-insulin (e.g. U-10) conversion semantics: Trio keeps every
/// insulin quantity in actual insulin units and converts to/from pump volume
/// units only at the pump boundary.
@Suite("Insulin Concentration Tests") struct InsulinConcentrationTests {
    private func settings(allowDilution: Bool, concentration: Decimal) -> TrioSettings {
        var settings = TrioSettings()
        settings.allowDilution = allowDilution
        settings.insulinConcentration = concentration
        return settings
    }

    // MARK: - Effective factor

    @Test("Dilution disabled always yields factor 1") func testDisabled() {
        #expect(settings(allowDilution: false, concentration: 0.1).insulinConcentrationFactor == 1)
        #expect(settings(allowDilution: false, concentration: 0.1).insulinConcentrationFactorDecimal == 1)
    }

    @Test("U-10 yields factor 0.1") func testU10() {
        let s = settings(allowDilution: true, concentration: 0.1)
        #expect(s.insulinConcentrationFactorDecimal == Decimal(string: "0.1")!)
        #expect(abs(s.insulinConcentrationFactor - 0.1) < 1e-12)
    }

    @Test("Insane stored concentrations fall back to 1") func testInsaneValues() {
        #expect(settings(allowDilution: true, concentration: 0).insulinConcentrationFactor == 1)
        #expect(settings(allowDilution: true, concentration: -0.5).insulinConcentrationFactor == 1)
        #expect(settings(allowDilution: true, concentration: 2).insulinConcentrationFactor == 1)
    }

    @Test("Default settings are standard U-100") func testDefaults() {
        #expect(TrioSettings().insulinConcentrationFactor == 1)
    }

    // MARK: - Concentration options

    @Test("Option factors match their labels") func testOptionFactors() {
        #expect(InsulinConcentrationOption.u100.factor == 1)
        #expect(InsulinConcentrationOption.u50.factor == Decimal(string: "0.5")!)
        #expect(InsulinConcentrationOption.u20.factor == Decimal(string: "0.2")!)
        #expect(InsulinConcentrationOption.u10.factor == Decimal(string: "0.1")!)
    }

    @Test("Option round-trips through its factor") func testOptionRoundTrip() {
        for option in InsulinConcentrationOption.allCases {
            #expect(InsulinConcentrationOption(factor: option.factor) == option)
        }
    }

    @Test("Unknown factors fall back to U-100") func testOptionFallback() {
        #expect(InsulinConcentrationOption(factor: 0.25) == .u100)
    }

    // MARK: - Delivery limits

    private let basalUnit = HKUnit.internationalUnitsPerHour
    private let bolusUnit = HKUnit.internationalUnit()

    @Test("U-10 delivery limits are pushed as 10× volume") func testLimitsToPump() {
        let pumpSettings = PumpSettings(insulinActionCurve: 6, maxBolus: 3, maxBasal: 1.5)

        let limits = pumpSettings.pumpDeliveryLimits(insulinConcentration: 0.1)

        #expect(abs((limits.maximumBasalRate?.doubleValue(for: basalUnit) ?? 0) - 15.0) < 1e-9)
        #expect(abs((limits.maximumBolus?.doubleValue(for: bolusUnit) ?? 0) - 30.0) < 1e-9)
    }

    @Test("Pump-reported limits are stored back as actual insulin units") func testLimitsFromPump() {
        let pumpSettings = PumpSettings(insulinActionCurve: 6, maxBolus: 3, maxBasal: 1.5)
        let reported = DeliveryLimits(
            maximumBasalRate: HKQuantity(unit: basalUnit, doubleValue: 30.0),
            maximumBolus: HKQuantity(unit: bolusUnit, doubleValue: 30.0)
        )

        let stored = pumpSettings.applyingPumpReported(limits: reported, insulinConcentration: 0.1)

        #expect(abs(Double(stored.maxBasal) - 3.0) < 1e-9)
        #expect(abs(Double(stored.maxBolus) - 3.0) < 1e-9)
        #expect(stored.insulinActionCurve == 6)
    }

    @Test("Missing pump-reported limits keep the user's values") func testLimitsFromPumpPartial() {
        let pumpSettings = PumpSettings(insulinActionCurve: 6, maxBolus: 3, maxBasal: 1.5)
        let reported = DeliveryLimits(maximumBasalRate: nil, maximumBolus: nil)

        let stored = pumpSettings.applyingPumpReported(limits: reported, insulinConcentration: 0.1)

        #expect(stored.maxBasal == 1.5)
        #expect(stored.maxBolus == 3)
    }

    @Test("Limits round-trip is the identity for standard U-100") func testLimitsIdentityU100() {
        let pumpSettings = PumpSettings(insulinActionCurve: 6, maxBolus: 10, maxBasal: 2)

        let limits = pumpSettings.pumpDeliveryLimits(insulinConcentration: 1)

        #expect(limits.maximumBasalRate?.doubleValue(for: basalUnit) == 2.0)
        #expect(limits.maximumBolus?.doubleValue(for: bolusUnit) == 10.0)
    }
}
