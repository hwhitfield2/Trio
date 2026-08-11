import Foundation
import Testing

@testable import Trio

/// Trio stores and runs everything in pumped volume units; the concentration
/// setting only drives the real-insulin display/entry conversion in the
/// therapy-settings editors and the in-place rescale when the setting changes.
@Suite("Insulin Concentration Tests") struct InsulinConcentrationTests {
    private func settings(allowDilution: Bool, concentration: Decimal) -> TrioSettings {
        var settings = TrioSettings()
        settings.allowDilution = allowDilution
        settings.insulinConcentration = concentration
        return settings
    }

    // MARK: - Factor resolution

    @Test("disabled dilution always resolves to factor 1") func testDisabledFactor() {
        #expect(settings(allowDilution: false, concentration: 0.1).insulinConcentrationFactorDecimal == 1)
    }

    @Test("enabled dilution resolves the stored factor") func testEnabledFactor() {
        #expect(settings(allowDilution: true, concentration: 0.1).insulinConcentrationFactorDecimal == 0.1)
        #expect(settings(allowDilution: true, concentration: 0.2).insulinConcentrationFactorDecimal == 0.2)
        #expect(settings(allowDilution: true, concentration: 0.5).insulinConcentrationFactorDecimal == 0.5)
    }

    @Test("insane stored factors fall back to 1") func testInsaneFactors() {
        #expect(settings(allowDilution: true, concentration: 0).insulinConcentrationFactorDecimal == 1)
        #expect(settings(allowDilution: true, concentration: -1).insulinConcentrationFactorDecimal == 1)
        #expect(settings(allowDilution: true, concentration: 2).insulinConcentrationFactorDecimal == 1)
    }

    @Test("option enum maps factors both ways") func testOptionMapping() {
        #expect(InsulinConcentrationOption.u10.factor == 0.1)
        #expect(InsulinConcentrationOption(factor: 0.1) == .u10)
        #expect(InsulinConcentrationOption(factor: 0.42) == .u100) // unknown → U-100
    }

    // MARK: - Editor display conversions (U-10)

    @Test("amounts: stored volume displays as real insulin and round-trips") func testAmountConversion() {
        let u10 = settings(allowDilution: true, concentration: 0.1)
        // A stored 0.5 U/hr volume basal is 0.05 U/hr of actual insulin.
        #expect(u10.realInsulinAmount(fromVolume: 0.5) == 0.05)
        #expect(u10.volumeInsulinAmount(fromReal: 0.05) == 0.5)
        // Pump-supported volume rates survive the display round trip exactly.
        for volume in [Decimal(0.05), 0.1, 0.15, 1.25, 30] {
            #expect(u10.volumeInsulinAmount(fromReal: u10.realInsulinAmount(fromVolume: volume)) == volume)
        }
    }

    @Test("ratios: stored volume ISF/CR display as real insulin and round-trip") func testRatioConversion() {
        let u10 = settings(allowDilution: true, concentration: 0.1)
        // Stored ISF of 50 mg/dL per pumped unit = 500 mg/dL per real unit.
        #expect(u10.realInsulinRatio(fromVolume: 50) == 500)
        #expect(u10.volumeInsulinRatio(fromReal: 500) == 50)
        // Stored CR of 10 g per pumped unit = 100 g per real unit.
        #expect(u10.realInsulinRatio(fromVolume: 10) == 100)
        for volume in [Decimal(0.1), 5, 36.5, 720] {
            #expect(u10.volumeInsulinRatio(fromReal: u10.realInsulinRatio(fromVolume: volume)) == volume)
        }
    }

    @Test("U-100 conversions are the identity") func testIdentityConversion() {
        let u100 = settings(allowDilution: false, concentration: 1)
        #expect(u100.realInsulinAmount(fromVolume: 1.25) == 1.25)
        #expect(u100.realInsulinRatio(fromVolume: 45) == 45)
    }

    // MARK: - Rescale on concentration change

    @Test("U-100 to U-10 multiplies amounts by 10 and divides ratios by 10") func testRescaleToU10() {
        let rescale = InsulinConcentrationRescale(from: 1, to: 0.1)
        #expect(rescale.amountScale == 10)
        #expect(rescale.ratioScale == 0.1)
        #expect(!rescale.isIdentity)
    }

    @Test("U-10 back to U-100 inverts the scales") func testRescaleBackToU100() {
        let rescale = InsulinConcentrationRescale(from: 0.1, to: 1)
        #expect(rescale.amountScale == 0.1)
        #expect(rescale.ratioScale == 10)
    }

    @Test("unchanged concentration is the identity rescale") func testIdentityRescale() {
        #expect(InsulinConcentrationRescale(from: 0.1, to: 0.1).isIdentity)
        #expect(InsulinConcentrationRescale(from: 1, to: 1).isIdentity)
    }

    @Test("rescaling preserves the real-insulin meaning of stored values") func testRescalePreservesRealMeaning() {
        let factors: [Decimal] = [1, 0.5, 0.2, 0.1]
        for oldFactor in factors {
            for newFactor in factors {
                let old = settings(allowDilution: true, concentration: oldFactor)
                let new = settings(allowDilution: true, concentration: newFactor)
                let rescale = InsulinConcentrationRescale(from: oldFactor, to: newFactor)

                // A basal rate keeps delivering the same actual insulin…
                let storedRate: Decimal = 0.6
                #expect(
                    new.realInsulinAmount(fromVolume: storedRate * rescale.amountScale) ==
                        old.realInsulinAmount(fromVolume: storedRate)
                )

                // …and ISF/CR keep the same real-unit strength.
                let storedISF: Decimal = 48
                #expect(
                    new.realInsulinRatio(fromVolume: storedISF * rescale.ratioScale) ==
                        old.realInsulinRatio(fromVolume: storedISF)
                )
            }
        }
    }

    @Test("chained rescales compose (U-100 → U-10 → U-50)") func testChainedRescales() {
        let first = InsulinConcentrationRescale(from: 1, to: 0.1)
        let second = InsulinConcentrationRescale(from: 0.1, to: 0.5)
        let direct = InsulinConcentrationRescale(from: 1, to: 0.5)
        let stored: Decimal = 1.5
        #expect(stored * first.amountScale * second.amountScale == stored * direct.amountScale)
        #expect(stored * first.ratioScale * second.ratioScale == stored * direct.ratioScale)
    }

    // MARK: - Picker-wheel Double round-trip resilience

    /// The therapy editor wheel round-trips every selection through Double
    /// (tag Double(value), binding Decimal(Double)). On the factor-scaled
    /// real-unit basal grids the exact Decimal comes back unequal for ~5% of
    /// values, so grid lookups must snap to the closest value, never fall
    /// back to index 0 (the minimum rate).
    @Test(
        "every factor-scaled basal grid value survives the wheel's Double round trip via closest-index snapping"
    ) func testWheelRoundTripSnapsToSameGridSlot() {
        // The pump-supported volume grid as Trio builds it: Decimal(Double).
        let volumeGrid: [Decimal] = stride(from: 0.05, through: 10.0, by: 0.05).map { Decimal($0) }

        for factor in [Decimal(1), 0.5, 0.2, 0.1] {
            let realGrid = volumeGrid.map { $0 * factor }
            for (index, gridValue) in realGrid.enumerated() {
                // What the wheel hands back after tag/binding round trip.
                let roundTripped = Decimal(Double(truncating: gridValue as NSNumber))
                let resolved = realGrid.firstIndex(of: roundTripped)
                    ?? realGrid.findClosestIndex(to: roundTripped) ?? 0
                #expect(
                    resolved == index,
                    "factor \(factor): grid[\(index)] = \(gridValue) resolved to \(resolved)"
                )
            }
        }
    }

    /// A rescale performed with no pump connected cannot snap to supported
    /// rates, so stored rates can be off the editor grid (e.g. U-50→U-20:
    /// 0.15 × 2.5 = 0.375). The editor's load path must resolve them to the
    /// closest grid slot rather than the minimum rate.
    @Test("off-grid stored rates resolve to the closest grid slot") func testOffGridRatesSnapClosest() {
        let volumeGrid: [Decimal] = stride(from: 0.05, through: 10.0, by: 0.05).map { Decimal($0) }
        let u20 = settings(allowDilution: true, concentration: 0.2)
        let realGrid = volumeGrid.map { u20.realInsulinAmount(fromVolume: $0) }

        // Stored 0.375 volume (rescaled U-50→U-20 from 0.15) → real 0.075.
        let realRate = u20.realInsulinAmount(fromVolume: 0.375)
        let resolved = realGrid.firstIndex(of: realRate) ?? realGrid.findClosestIndex(to: realRate) ?? 0
        // Closest real grid values are 0.07 and 0.08 (grid step 0.01) — must
        // be one of the neighbors (within half a step plus grid noise), never
        // index 0 (= 0.01 real U/hr).
        #expect(resolved != 0)
        #expect(abs(realGrid[resolved] - realRate) <= Decimal(0.006))
    }
}
