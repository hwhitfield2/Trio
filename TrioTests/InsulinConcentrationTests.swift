import Foundation
import Testing

@testable import Trio

/// Trio stores, runs AND displays everything in pumped volume units, therapy
/// settings included, so every screen matches the pump 1:1. The concentration
/// setting drives only the actual-insulin caption beneath each therapy value
/// and the in-place rescale when the setting changes.
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

    // MARK: - Volume/actual-insulin conversion primitives (U-10)
    //
    // These back the captions and the rescale; no editor converts for display
    // any more.

    @Test("amounts: a stored volume maps to actual insulin and round-trips") func testAmountConversion() {
        let u10 = settings(allowDilution: true, concentration: 0.1)
        // A stored 0.5 U/hr volume basal is 0.05 U/hr of actual insulin.
        #expect(u10.realInsulinAmount(fromVolume: 0.5) == 0.05)
        #expect(u10.volumeInsulinAmount(fromReal: 0.05) == 0.5)
        // Pump-supported volume rates survive the display round trip exactly.
        for volume in [Decimal(0.05), 0.1, 0.15, 1.25, 30] {
            #expect(u10.volumeInsulinAmount(fromReal: u10.realInsulinAmount(fromVolume: volume)) == volume)
        }
    }

    @Test("ratios: a stored volume ISF/CR maps to actual insulin and round-trips") func testRatioConversion() {
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
    /// (tag Double(value), binding Decimal(Double)), and the exact Decimal can
    /// come back unequal, so grid lookups must snap to the closest value and
    /// never fall back to index 0 (the minimum rate). The grid is the pump's
    /// own volume grid at every concentration — the editors no longer scale it.
    @Test(
        "every basal grid value survives the wheel's Double round trip via closest-index snapping"
    ) func testWheelRoundTripSnapsToSameGridSlot() {
        // The pump-supported volume grid as Trio builds it: Decimal(Double).
        let volumeGrid: [Decimal] = stride(from: 0.05, through: 10.0, by: 0.05).map { Decimal($0) }

        for (index, gridValue) in volumeGrid.enumerated() {
            // What the wheel hands back after tag/binding round trip.
            let roundTripped = Decimal(Double(truncating: gridValue as NSNumber))
            let resolved = volumeGrid.firstIndex(of: roundTripped)
                ?? volumeGrid.findClosestIndex(to: roundTripped) ?? 0
            #expect(resolved == index, "grid[\(index)] = \(gridValue) resolved to \(resolved)")
        }
    }

    /// A concentration rescale multiplies stored ISF/CR by `ratioScale`, so an
    /// ordinary undiluted therapy lands far below the clinical grid's floor —
    /// a U-100 ISF of 50 stores 5.0 at U-10 and 2.5 at U-5, against a floor of
    /// 9. If the editor grid were not scaled with the concentration, loading
    /// that schedule would snap it to the grid minimum and the next save would
    /// write the snapped value: a silent multi-fold therapy change. This is the
    /// regression that guards it, and it must exercise the low band, not skip it.
    @Test("a rescaled schedule stays on the ISF grid at every concentration")
    func testRescaledISFStaysOnGrid() {
        // The clinical tiers the ISF editor is built from, per actual unit.
        let realTiers: [Decimal] = stride(from: 9.0, through: 399.0, by: 1.0).map { Decimal($0) }

        for factor in [Decimal(1), 0.5, 0.2, 0.1, 0.05] {
            // The editor's grid at this concentration.
            let grid = realTiers.map { $0 * factor }
            // Every clinical ISF a user could hold before switching, rescaled.
            for realISF in stride(from: 9.0, through: 399.0, by: 1.0) {
                let stored = Decimal(realISF) * factor
                let resolved = grid.firstIndex(of: stored) ?? grid.findClosestIndex(to: stored) ?? 0
                #expect(
                    grid[resolved] == stored,
                    "factor \(factor): rescaled ISF \(stored) resolved to \(grid[resolved]), not itself"
                )
            }
        }
    }

    /// The same for carb ratio, whose grid floor is 1 g/U: a U-100 ratio of
    /// 10 stores 1.0 at U-10 and 0.5 at U-5.
    @Test("a rescaled schedule stays on the carb ratio grid at every concentration")
    func testRescaledCarbRatioStaysOnGrid() {
        let realRatios: [Decimal] = stride(from: 10.0, to: 300.0, by: 1.0).map { (Decimal($0)) / 10 }

        for factor in [Decimal(1), 0.5, 0.2, 0.1, 0.05] {
            let grid = realRatios.map { $0 * factor }
            for realRatio in realRatios {
                let stored = realRatio * factor
                let resolved = grid.firstIndex(of: stored) ?? grid.findClosestIndex(to: stored) ?? 0
                #expect(
                    grid[resolved] == stored,
                    "factor \(factor): rescaled CR \(stored) resolved to \(grid[resolved]), not itself"
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

        // Stored 0.375 U/hr of volume, rescaled U-50→U-20 from 0.15 and never
        // rounded against a pump. The editor shows volume, so it resolves the
        // stored value directly.
        let stored: Decimal = 0.375
        let resolved = volumeGrid.firstIndex(of: stored) ?? volumeGrid.findClosestIndex(to: stored) ?? 0
        // Neighbours are 0.35 and 0.40 — must be one of them (within half a
        // step plus grid noise), never index 0 (= 0.05 U/hr).
        #expect(resolved != 0)
        #expect(abs(volumeGrid[resolved] - stored) <= Decimal(0.026))
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

    /// Every "U" in Trio is a pumped volume, therapy settings included, so the
    /// editors match the pump 1:1. The caption is what carries the actual
    /// insulin a value represents — the unit a prescription is written in. At
    /// U-100 the two coincide and the caption must stay out of the way.
    @Test("no unit caption without dilution") func testNoCaptionAtU100() {
        let u100 = settings(allowDilution: false, concentration: 1)
        #expect(u100.actualInsulinCaption(forVolumeAmount: 1.5, unit: "U") == nil)
        #expect(u100.actualInsulinCaption(forVolumeRatio: 45, unit: "mg/dL") == nil)
    }

    @Test("caption names the actual insulin a pumped value carries") func testCaptionUnderDilution() {
        let u10 = settings(allowDilution: true, concentration: 0.1)
        // A shown 15 U of volume is 1.5 U of actual insulin.
        let amount = u10.actualInsulinCaption(forVolumeAmount: 15, unit: "U")
        #expect(amount?.contains("1.5") == true)
        // The old convention's phrasing must be gone, so a half-applied
        // inversion cannot pass by matching a substring.
        #expect(amount?.contains("pump meters") == false)

        // Ratios move the other way: 50 mg/dL per pumped unit is 500 per real unit.
        let ratio = u10.actualInsulinCaption(forVolumeRatio: 50, unit: "mg/dL")
        #expect(ratio?.contains("500") == true)
        #expect(ratio?.contains("pumped unit") == false)
    }

    @Test("caption converts by 20 at U-5") func testCaptionAtU5() {
        let u5 = settings(allowDilution: true, concentration: 0.05)
        let amount = u5.actualInsulinCaption(forVolumeAmount: 30, unit: "U")
        #expect(amount?.contains("1.5") == true)

        let ratio = u5.actualInsulinCaption(forVolumeRatio: 25, unit: "mg/dL")
        #expect(ratio?.contains("500") == true)
    }

    /// The caption is the only place a diluted user sees the fine real-unit
    /// quantities, so it must not round them away: the finest real step any
    /// supported pump/concentration pair produces is 0.00125 U/hr (a 0.025 U/hr
    /// Medtronic increment at U-5).
    @Test("caption keeps the finest real quantum a pump can produce") func testCaptionPrecision() {
        let u5 = settings(allowDilution: true, concentration: 0.05)
        let fine = u5.actualInsulinCaption(forVolumeAmount: Decimal(string: "0.025")!, unit: "U/hr")
        #expect(fine?.contains("0.00125") == true)
        // A 0.05 U/hr pump increment at U-5 is 0.0025 U/hr.
        let coarser = u5.actualInsulinCaption(forVolumeAmount: Decimal(string: "0.05")!, unit: "U/hr")
        #expect(coarser?.contains("0.0025") == true)
    }

    // MARK: - Picker range extension

    /// Rescaling preserves stored values exactly, so a preserved value can sit
    /// outside a freshly scaled picker range and the range must widen to reach
    /// it — in whole steps only, so the wheel's grid stays aligned.
    @Test("picker ranges widen in whole steps to cover preserved values") func testPickerExtension() {
        // The Max Bolus volume grid: step 0.5, covering 0.5…30.
        let setting = PickerSetting(value: 10, step: 0.5, min: 0.5, max: 30, type: .insulinUnit)

        // A U-100 Max Bolus of 10 U becomes 200 U of volume at U-5, far past
        // the grid's ceiling — the grid must widen rather than snap it down.
        let extended = setting.extended(toCover: 200)
        #expect(extended.max >= 200)
        #expect(extended.min == setting.min)
        // Whole steps only: the distance moved is an exact multiple of the step.
        let movedSteps = (extended.max - setting.max) / extended.step
        var rounded = Decimal()
        var raw = movedSteps
        NSDecimalRound(&rounded, &raw, 0, .plain)
        #expect(rounded == movedSteps)

        // And the value itself lands on the extended grid.
        let offset = (Decimal(200) - extended.min) / extended.step
        var offsetRounded = Decimal()
        var offsetRaw = offset
        NSDecimalRound(&offsetRounded, &offsetRaw, 0, .plain)
        #expect(offsetRounded == offset)

        // Already-covered values change nothing.
        let untouched = setting.extended(toCover: 10)
        #expect(untouched.min == setting.min)
        #expect(untouched.max == setting.max)
    }
}
