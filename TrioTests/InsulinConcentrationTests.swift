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
        #expect(settings(allowDilution: true, concentration: 0.05).insulinConcentrationFactorDecimal == 0.05)
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
        #expect(InsulinConcentrationOption.u5.factor == 0.05)
        #expect(InsulinConcentrationOption(factor: 0.05) == .u5)
        #expect(InsulinConcentrationOption(factor: 0.42) == .u100) // unknown → U-100
    }

    @Test("U-5 derives its display name and mixing recipe") func testU5Copy() {
        #expect(InsulinConcentrationOption.u5.displayName == "U-5")
        // 1 part U-100 + 19 parts diluent = 5% insulin.
        #expect(InsulinConcentrationOption.u5.dilutionRecipe?.contains("19 parts") == true)
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

    @Test("U-100 to U-5 multiplies amounts by 20, and back divides") func testRescaleToU5() {
        let rescale = InsulinConcentrationRescale(from: 1, to: 0.05)
        #expect(rescale.amountScale == 20)
        #expect(rescale.ratioScale == 0.05)
        #expect(!rescale.isIdentity)

        let back = InsulinConcentrationRescale(from: 0.05, to: 1)
        #expect(back.amountScale == 0.05)
        #expect(back.ratioScale == 20)
    }

    @Test("unchanged concentration is the identity rescale") func testIdentityRescale() {
        #expect(InsulinConcentrationRescale(from: 0.1, to: 0.1).isIdentity)
        #expect(InsulinConcentrationRescale(from: 1, to: 1).isIdentity)
    }

    @Test("rescaling preserves the real-insulin meaning of stored values") func testRescalePreservesRealMeaning() {
        let factors: [Decimal] = [1, 0.5, 0.2, 0.1, 0.05]
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

        for factor in [Decimal(1), 0.5, 0.2, 0.1, 0.05] {
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

    // MARK: - Concentration ledger (re-reading history recorded on an old scale)

    /// Therapy settings are rescaled in place at a switch, but pump history is
    /// not: it records what the pump actually metered and must keep matching the
    /// pump's screens and the uploads. The ledger is what lets IOB, TDD, and
    /// autotune read pre-switch events on the scale now in force.
    private func change(_ daysAgo: Double, scale: Decimal) -> InsulinConcentrationChange {
        InsulinConcentrationChange(date: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60), amountScale: scale)
    }

    @Test("no recorded switch leaves history untouched") func testLedgerIdentity() {
        let ledger: [InsulinConcentrationChange] = []
        #expect(ledger.isEmptyOrIdentity)
        #expect(ledger.scale(forEventAt: Date()) == 1)
    }

    @Test("events before a switch scale, events after it do not") func testLedgerAppliesOnlyToOlderEvents() {
        // Switched U-100 → U-10 one day ago: everything recorded before it was
        // metered in ten-times-smaller volume units.
        let ledger = [change(1, scale: 10)]

        let beforeSwitch = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let afterSwitch = Date().addingTimeInterval(-1 * 60 * 60)
        #expect(ledger.scale(forEventAt: beforeSwitch) == 10)
        #expect(ledger.scale(forEventAt: afterSwitch) == 1)
    }

    @Test("several switches inside one window compose") func testLedgerComposesSwitches() {
        // U-100 → U-10 three days ago (x10), then U-10 → U-50 one day ago (x0.2).
        let ledger = [change(3, scale: 10), change(1, scale: 0.2)]

        // An event older than both must cross both switches.
        #expect(ledger.scale(forEventAt: Date().addingTimeInterval(-5 * 24 * 60 * 60)) == 2)
        // Between them: only the later switch applies.
        #expect(ledger.scale(forEventAt: Date().addingTimeInterval(-2 * 24 * 60 * 60)) == Decimal(0.2))
        // After both: unchanged.
        #expect(ledger.scale(forEventAt: Date()) == 1)
    }

    @Test("the U-5 switch composes at the ledger's largest scale") func testLedgerU5Switches() {
        // U-100 → U-5 three days ago (x20), then U-5 → U-20 one day ago (x0.25).
        let ledger = [change(3, scale: 20), change(1, scale: 0.25)]

        #expect(ledger.scale(forEventAt: Date().addingTimeInterval(-5 * 24 * 60 * 60)) == 5)
        #expect(ledger.scale(forEventAt: Date().addingTimeInterval(-2 * 24 * 60 * 60)) == Decimal(0.25))
        #expect(ledger.scale(forEventAt: Date()) == 1)
    }

    @Test("a scaled bolus keeps its real meaning across a switch") func testScaledEventPreservesRealInsulin() {
        let u100 = settings(allowDilution: false, concentration: 1)
        let u10 = settings(allowDilution: true, concentration: 0.1)
        let ledger = [change(1, scale: 10)]

        // 0.2 U metered under U-100 = 0.2 U of actual insulin.
        let recorded = PumpHistoryEvent(
            id: "a", type: .bolus,
            timestamp: Date().addingTimeInterval(-2 * 24 * 60 * 60),
            amount: 0.2
        )
        let realBefore = u100.realInsulinAmount(fromVolume: recorded.amount ?? 0)

        let normalised = recorded.scalingInsulin(by: ledger.scale(forEventAt: recorded.timestamp))
        // Read on the U-10 scale it must still be 0.2 U of actual insulin.
        #expect(normalised.amount == 2)
        #expect(u10.realInsulinAmount(fromVolume: normalised.amount ?? 0) == realBefore)
    }

    @Test("scaling touches insulin only, never carbs or timing") func testScalingLeavesNonInsulinFields() {
        let event = PumpHistoryEvent(
            id: "b", type: .tempBasal, timestamp: Date(),
            amount: 0.5, duration: 30, durationMin: 30, rate: 0.5,
            carbInput: 40, note: "note"
        )
        let scaled = event.scalingInsulin(by: 10)
        #expect(scaled.amount == 5)
        #expect(scaled.rate == 5)
        #expect(scaled.duration == 30)
        #expect(scaled.durationMin == 30)
        #expect(scaled.carbInput == 40)
        #expect(scaled.timestamp == event.timestamp)
        #expect(scaled.note == "note")
    }

    @Test("scaling by 1 is a no-op") func testScalingIdentity() {
        let event = PumpHistoryEvent(id: "c", type: .bolus, timestamp: Date(), amount: 1.25)
        #expect(event.scalingInsulin(by: 1) == event)
    }

    // MARK: - Unit disambiguation

    /// Therapy settings are entered in actual insulin while everything Trio
    /// delivers is shown in pumped units, and both are labelled "U". At U-100
    /// they are the same number and the caption must stay out of the way.
    @Test("no unit caption without dilution") func testNoCaptionAtU100() {
        let u100 = settings(allowDilution: false, concentration: 1)
        #expect(u100.pumpedEquivalentCaption(forRealAmount: 1.5, unit: "U") == nil)
        #expect(u100.pumpedEquivalentCaption(forRealRatio: 45, unit: "mg/dL") == nil)
    }

    @Test("unit caption names both quantities under dilution") func testCaptionUnderDilution() {
        let u10 = settings(allowDilution: true, concentration: 0.1)
        let amount = u10.pumpedEquivalentCaption(forRealAmount: 1.5, unit: "U")
        #expect(amount?.contains("1.5") == true)
        #expect(amount?.contains("15") == true)

        // Ratios move the other way: 500 mg/dL per real unit is 50 per pumped
        // unit. A bare "50" is a substring of "500", so anchor the pumped half
        // to its separator.
        let ratio = u10.pumpedEquivalentCaption(forRealRatio: 500, unit: "mg/dL")
        #expect(ratio?.contains("500") == true)
        #expect(ratio?.contains("· 50 ") == true)
    }

    @Test("unit caption converts by 20 at U-5") func testCaptionAtU5() {
        let u5 = settings(allowDilution: true, concentration: 0.05)
        let amount = u5.pumpedEquivalentCaption(forRealAmount: 1.5, unit: "U")
        #expect(amount?.contains("1.5") == true)
        #expect(amount?.contains("30") == true)

        let ratio = u5.pumpedEquivalentCaption(forRealRatio: 500, unit: "mg/dL")
        #expect(ratio?.contains("500") == true)
        #expect(ratio?.contains("25") == true)
    }

    // MARK: - Picker range extension

    /// Rescaling preserves stored values exactly, so a preserved value can sit
    /// outside a freshly scaled picker range and the range must widen to reach
    /// it — in whole steps only, so the wheel's grid stays aligned.
    @Test("picker ranges widen in whole steps to cover preserved values") func testPickerExtension() {
        // A U-5 real-unit grid: step 0.0025, covering 0.0025…0.25.
        let setting = PickerSetting(value: 0.05, step: 0.0025, min: 0.0025, max: 0.25, type: .insulinUnitPerHour)

        // A preserved real Max Basal of 0.3 overshoots the max by 20 steps.
        let extended = setting.extended(toCover: 0.3)
        #expect(extended.max >= 0.3)
        #expect(extended.min == setting.min)
        // Whole steps only: the distance moved is an exact multiple of the step.
        let movedSteps = (extended.max - setting.max) / extended.step
        var rounded = Decimal()
        var raw = movedSteps
        NSDecimalRound(&rounded, &raw, 0, .plain)
        #expect(rounded == movedSteps)

        // And the value itself lands on the extended grid.
        let offset = (Decimal(0.3) - extended.min) / extended.step
        var offsetRounded = Decimal()
        var offsetRaw = offset
        NSDecimalRound(&offsetRounded, &offsetRaw, 0, .plain)
        #expect(offsetRounded == offset)

        // Already-covered values change nothing.
        let untouched = setting.extended(toCover: 0.05)
        #expect(untouched.min == setting.min)
        #expect(untouched.max == setting.max)
    }
}
