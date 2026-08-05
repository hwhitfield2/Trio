import Foundation
import Testing

@testable import Trio

@Suite("Safety Envelope Tests") struct SafetyEnvelopeTests {
    // MARK: - Fixtures

    private func limits(
        maxIOB: Decimal = 6,
        maxBasal: Decimal = 4,
        maxDailyBasal: Decimal = 1.25,
        currentBasal: Decimal = 1,
        maxBolus: Decimal = 5,
        maxSMBBasalMinutes: Decimal = 30,
        smbIntervalMinutes: Decimal = 3,
        bolusIncrement: Decimal = 0.25,
        thresholdSetting: Decimal = 60,
        minBG: Decimal = 90,
        maxHourlyInsulin: Decimal = 3,
        maxDailyInsulin: Decimal = 60,
        maxRateEscalationPerCycle: Decimal = 2
    ) -> SafetyEnvelope.SafetyLimits {
        SafetyEnvelope.SafetyLimits(
            maxIOB: maxIOB,
            maxBasal: maxBasal,
            maxDailyBasal: maxDailyBasal,
            currentBasal: currentBasal,
            maxBolus: maxBolus,
            maxSMBBasalMinutes: maxSMBBasalMinutes,
            smbIntervalMinutes: smbIntervalMinutes,
            bolusIncrement: bolusIncrement,
            thresholdSetting: thresholdSetting,
            minBG: minBG,
            maxHourlyInsulin: maxHourlyInsulin,
            maxDailyInsulin: maxDailyInsulin,
            maxRateEscalationPerCycle: maxRateEscalationPerCycle
        )
    }

    private func state(
        currentIOB: Decimal? = 0,
        glucose: Decimal? = 120,
        minPredictedGlucose: Decimal? = nil,
        triggeringReadingAgeMinutes: Decimal = 2,
        minutesSinceLastBolus: Decimal = 60,
        insulinDeliveredLastHour: Decimal = 0,
        insulinDeliveredLast24h: Decimal = 0,
        lastEnactedRate: Decimal? = nil
    ) -> SafetyEnvelope.SafetyState {
        SafetyEnvelope.SafetyState(
            currentIOB: currentIOB,
            glucose: glucose,
            minPredictedGlucose: minPredictedGlucose,
            triggeringReadingAgeMinutes: triggeringReadingAgeMinutes,
            minutesSinceLastBolus: minutesSinceLastBolus,
            insulinDeliveredLastHour: insulinDeliveredLastHour,
            insulinDeliveredLast24h: insulinDeliveredLast24h,
            lastEnactedRate: lastEnactedRate
        )
    }

    // MARK: - oref formula ports

    @Test("maxSafeBasal is the min of the three oref limits") func testMaxSafeBasal() {
        // basal-set-temp.js: min(max_basal, 3 × max_daily_basal, 4 × current_basal)
        #expect(SafetyEnvelope.maxSafeBasal(limits: limits(maxBasal: 4, maxDailyBasal: 1.25, currentBasal: 1)) == 3.75)
        #expect(SafetyEnvelope.maxSafeBasal(limits: limits(maxBasal: 2, maxDailyBasal: 1.25, currentBasal: 1)) == 2)
        #expect(SafetyEnvelope.maxSafeBasal(limits: limits(maxBasal: 10, maxDailyBasal: 3, currentBasal: 0.5)) == 2)
    }

    @Test("hypo threshold matches the oref min_bg table") func testHypoThreshold() {
        // determine-basal.js comment: min_bg thresholds: 80→60, 90→65, 100→70, 110→75, 120→80
        #expect(SafetyEnvelope.hypoThreshold(minBG: 80, thresholdSetting: 60) == 60)
        #expect(SafetyEnvelope.hypoThreshold(minBG: 90, thresholdSetting: 60) == 65)
        #expect(SafetyEnvelope.hypoThreshold(minBG: 100, thresholdSetting: 60) == 70)
        #expect(SafetyEnvelope.hypoThreshold(minBG: 110, thresholdSetting: 60) == 75)
        #expect(SafetyEnvelope.hypoThreshold(minBG: 120, thresholdSetting: 60) == 80)
        // User setting raises the threshold but is clamped to 120.
        #expect(SafetyEnvelope.hypoThreshold(minBG: 90, thresholdSetting: 90) == 90)
        #expect(SafetyEnvelope.hypoThreshold(minBG: 90, thresholdSetting: 200) == 120)
        // Floor of 60 regardless of low min_bg.
        #expect(SafetyEnvelope.hypoThreshold(minBG: 70, thresholdSetting: 0) == 60)
    }

    // MARK: - Low-glucose suspend

    @Test("LGS forces zero-temp and vetoes SMB") func testLowGlucoseSuspend() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 3, durationMinutes: 30, smbUnits: 1),
            limits: limits(),
            state: state(glucose: 60) // threshold for minBG 90 is 65
        )
        #expect(verdict.outcome == .suspended)
        #expect(verdict.dose.rate == 0)
        #expect(verdict.dose.smbUnits == 0)
    }

    @Test("Predicted p10 low also suspends") func testPredictedLowSuspend() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 30, smbUnits: 0.5),
            limits: limits(),
            state: state(glucose: 140, minPredictedGlucose: 55)
        )
        #expect(verdict.outcome == .suspended)
        #expect(verdict.dose.rate == 0)
        #expect(verdict.dose.smbUnits == 0)
    }

    // MARK: - Data-age gate

    @Test("Stale trigger allows reduce/hold but no SMB and no above-profile rate") func testDataAgeGate() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 3, durationMinutes: 30, smbUnits: 1),
            limits: limits(currentBasal: 1),
            state: state(triggeringReadingAgeMinutes: 12)
        )
        #expect(verdict.outcome == .holdOnly)
        #expect(verdict.dose.smbUnits == 0)
        #expect(verdict.dose.rate == 1)
    }

    @Test("Stale trigger still allows lowering below profile") func testDataAgeGateAllowsReduction() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 0, durationMinutes: 30, smbUnits: 0),
            limits: limits(currentBasal: 1),
            state: state(triggeringReadingAgeMinutes: 12)
        )
        #expect(verdict.outcome == .holdOnly)
        #expect(verdict.dose.rate == 0)
    }

    // MARK: - Per-dose caps

    @Test("Basal clamped to maxSafeBasal") func testBasalClamp() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 10, durationMinutes: 30, smbUnits: 0),
            limits: limits(maxBasal: 4, maxDailyBasal: 1.25, currentBasal: 1, maxHourlyInsulin: 100),
            state: state()
        )
        #expect(verdict.dose.rate == 3.75)
        #expect(verdict.clamps.contains(.maxSafeBasal(before: 10, after: 3.75)))
    }

    @Test("SMB capped by basal-minutes rule") func testSMBBasalMinutesCap() {
        // currentBasal 1 U/hr × 30 min / 60 = 0.5 U cap
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 30, smbUnits: 2),
            limits: limits(currentBasal: 1, maxSMBBasalMinutes: 30),
            state: state(currentIOB: 0)
        )
        #expect(verdict.dose.smbUnits == 0.5)
    }

    @Test("SMB reduced to maxIOB headroom") func testMaxIOBHeadroom() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 30, smbUnits: 0.75),
            limits: limits(maxIOB: 3, currentBasal: 2),
            state: state(currentIOB: 2.5)
        )
        // headroom = 3 − 2.5 = 0.5
        #expect(verdict.dose.smbUnits == 0.5)
    }

    @Test("SMB vetoed when IOB is unavailable") func testIOBUnavailable() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 30, smbUnits: 0.5),
            limits: limits(),
            state: state(currentIOB: nil)
        )
        #expect(verdict.dose.smbUnits == 0)
        #expect(verdict.clamps.contains(.iobUnavailable))
    }

    @Test("SMB blocked inside the minimum interval") func testSMBInterval() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 30, smbUnits: 0.3),
            limits: limits(smbIntervalMinutes: 3),
            state: state(minutesSinceLastBolus: 2)
        )
        #expect(verdict.dose.smbUnits == 0)
    }

    @Test("SMB floored to bolus increment") func testBolusIncrementFloor() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 30, smbUnits: 0.4),
            limits: limits(currentBasal: 2, bolusIncrement: 0.25),
            state: state()
        )
        #expect(verdict.dose.smbUnits == 0.25)
    }

    // MARK: - Rolling ceilings

    @Test("Hourly ceiling blocks SMB once exhausted") func testHourlyCeiling() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 30, smbUnits: 0.5),
            limits: limits(currentBasal: 1, maxHourlyInsulin: 2),
            state: state(insulinDeliveredLastHour: 2)
        )
        #expect(verdict.dose.smbUnits == 0)
        #expect(verdict.dose.rate <= 1)
    }

    @Test("Daily ceiling blocks SMB and above-profile basal once exhausted") func testDailyCeiling() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 3, durationMinutes: 30, smbUnits: 0.5),
            limits: limits(currentBasal: 1, maxDailyInsulin: 50),
            state: state(insulinDeliveredLast24h: 50)
        )
        #expect(verdict.dose.smbUnits == 0)
        #expect(verdict.dose.rate == 1)
    }

    // MARK: - Escalation and duration

    @Test("Rate escalation limited per cycle") func testEscalationLimiter() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 3.5, durationMinutes: 30, smbUnits: 0),
            limits: limits(maxBasal: 10, maxDailyBasal: 3, currentBasal: 1, maxRateEscalationPerCycle: 1),
            state: state(lastEnactedRate: 1)
        )
        #expect(verdict.dose.rate == 2)
    }

    @Test("Temp basal duration capped so silence decays to profile") func testDurationCap() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: 1, durationMinutes: 120, smbUnits: 0),
            limits: limits(),
            state: state()
        )
        #expect(verdict.dose.durationMinutes == 30)
    }

    @Test("Negative proposals floored to zero") func testNegativeFloor() {
        let verdict = SafetyEnvelope.apply(
            .init(rate: -1, durationMinutes: 30, smbUnits: -0.5),
            limits: limits(),
            state: state()
        )
        #expect(verdict.dose.rate >= 0)
        #expect(verdict.dose.smbUnits == 0)
    }

    // MARK: - Property-based sweep

    /// Deterministic LCG so the sweep is reproducible without seeding system RNG.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        /// Uniform Decimal in [0, upper) with one decimal place.
        mutating func decimal(upTo upper: Int) -> Decimal {
            Decimal(Int(next() % UInt64(upper * 10))) / 10
        }
    }

    @Test("No possible proposal exceeds the caps") func testFuzzedProposalsNeverExceedCaps() {
        var rng = LCG(state: 0xDEAD_BEEF)
        let testLimits = limits(
            maxIOB: 5,
            maxBasal: 4,
            maxDailyBasal: 1.5,
            currentBasal: 1,
            maxBolus: 3,
            maxHourlyInsulin: 3,
            maxDailyInsulin: 40
        )
        let safeBasal = SafetyEnvelope.maxSafeBasal(limits: testLimits)

        for _ in 0 ..< 2000 {
            let proposal = SafetyEnvelope.ProposedDose(
                rate: rng.decimal(upTo: 50),
                durationMinutes: rng.decimal(upTo: 300),
                smbUnits: rng.decimal(upTo: 20)
            )
            let iob = rng.decimal(upTo: 8)
            let glucose = 40 + rng.decimal(upTo: 300)
            let testState = state(
                currentIOB: iob,
                glucose: glucose,
                minutesSinceLastBolus: rng.decimal(upTo: 120),
                insulinDeliveredLastHour: rng.decimal(upTo: 5),
                insulinDeliveredLast24h: rng.decimal(upTo: 60)
            )
            let verdict = SafetyEnvelope.apply(proposal, limits: testLimits, state: testState)

            #expect(verdict.dose.rate >= 0)
            #expect(verdict.dose.smbUnits >= 0)
            #expect(verdict.dose.rate <= safeBasal)
            #expect(verdict.dose.smbUnits <= testLimits.maxBolus)
            #expect(verdict.dose.durationMinutes <= testLimits.maxTempBasalDurationMinutes)
            // SMB never exceeds remaining maxIOB headroom (zero if already over cap).
            #expect(verdict.dose.smbUnits <= max(testLimits.maxIOB - iob, 0))
            // Below threshold ⇒ suspended, no insulin.
            let threshold = SafetyEnvelope.hypoThreshold(
                minBG: testLimits.minBG,
                thresholdSetting: testLimits.thresholdSetting
            )
            if glucose < threshold {
                #expect(verdict.outcome == .suspended)
                #expect(verdict.dose.rate == 0)
                #expect(verdict.dose.smbUnits == 0)
            }
        }
    }
}
