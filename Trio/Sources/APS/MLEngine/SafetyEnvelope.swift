import Foundation

/// Deterministic hard-cap layer for the ML dosing engine (docs/ML_DOSING_REPLACEMENT_PLAN.md §2.4).
///
/// Every dose proposed by any controller (ML or otherwise) must pass through
/// `SafetyEnvelope.apply(_:limits:state:)` before enactment. The envelope is pure —
/// no I/O, no clock reads, no randomness — so every verdict is exactly reproducible
/// from its inputs, and property-based tests can assert that no possible proposal
/// produces a dose above cap.
///
/// The per-dose rules are direct ports of the oref JS safety logic
/// (`trio-oref/lib/basal-set-temp.js`, `determine-basal.js`) so that removing the JS
/// algorithm does not remove its guardrails. The rolling-window ceilings and the
/// escalation limiter are additions from the plan.
///
/// The envelope is intentionally NOT Injectable, NOT observable, and has no
/// configuration beyond `SafetyLimits`: it cannot be toggled off.
enum SafetyEnvelope {
    // MARK: - Inputs

    /// Caps in force for one evaluation. Values come from the user's existing therapy
    /// settings (`Preferences`, `PumpSettings`) plus the current profile basal —
    /// no adaptation tier may write to them.
    struct SafetyLimits: Equatable {
        let maxIOB: Decimal
        let maxBasal: Decimal
        let maxDailyBasal: Decimal
        let currentBasal: Decimal
        let maxDailySafetyMultiplier: Decimal
        let currentBasalSafetyMultiplier: Decimal
        let maxBolus: Decimal
        let maxSMBBasalMinutes: Decimal
        let smbIntervalMinutes: Decimal
        let bolusIncrement: Decimal
        /// User threshold setting (mg/dL), combined with minBG exactly as oref does.
        let thresholdSetting: Decimal
        /// Lower bound of the target range (mg/dL) used for the threshold formula.
        let minBG: Decimal
        /// Rolling 60-min ceiling on insulin delivered above profile basal (U).
        let maxHourlyInsulin: Decimal
        /// Rolling 24-h ceiling on total delivered insulin (U).
        let maxDailyInsulin: Decimal
        /// Longest temp basal the engine may issue; silence must decay to profile basal.
        let maxTempBasalDurationMinutes: Decimal
        /// A dosing cycle whose triggering CGM value is older than this may only reduce/hold.
        let maxDataAgeForDosingMinutes: Decimal
        /// Max increase of the temp rate vs. the previous cycle's enacted rate (U/hr).
        let maxRateEscalationPerCycle: Decimal

        init(
            preferences: Preferences,
            pumpSettings: PumpSettings,
            currentBasal: Decimal,
            maxDailyBasal: Decimal,
            minBG: Decimal,
            maxHourlyInsulin: Decimal,
            maxDailyInsulin: Decimal,
            maxTempBasalDurationMinutes: Decimal = 30,
            maxDataAgeForDosingMinutes: Decimal = 10,
            maxRateEscalationPerCycle: Decimal = 2
        ) {
            maxIOB = preferences.maxIOB
            maxBasal = pumpSettings.maxBasal
            self.maxDailyBasal = maxDailyBasal
            self.currentBasal = currentBasal
            maxDailySafetyMultiplier = preferences.maxDailySafetyMultiplier
            currentBasalSafetyMultiplier = preferences.currentBasalSafetyMultiplier
            maxBolus = pumpSettings.maxBolus
            maxSMBBasalMinutes = preferences.maxSMBBasalMinutes
            smbIntervalMinutes = preferences.smbInterval
            bolusIncrement = preferences.bolusIncrement
            thresholdSetting = preferences.threshold_setting
            self.minBG = minBG
            self.maxHourlyInsulin = maxHourlyInsulin
            self.maxDailyInsulin = maxDailyInsulin
            self.maxTempBasalDurationMinutes = maxTempBasalDurationMinutes
            self.maxDataAgeForDosingMinutes = maxDataAgeForDosingMinutes
            self.maxRateEscalationPerCycle = maxRateEscalationPerCycle
        }

        init(
            maxIOB: Decimal,
            maxBasal: Decimal,
            maxDailyBasal: Decimal,
            currentBasal: Decimal,
            maxDailySafetyMultiplier: Decimal = 3,
            currentBasalSafetyMultiplier: Decimal = 4,
            maxBolus: Decimal,
            maxSMBBasalMinutes: Decimal = 30,
            smbIntervalMinutes: Decimal = 3,
            bolusIncrement: Decimal = 0.1,
            thresholdSetting: Decimal = 60,
            minBG: Decimal = 90,
            maxHourlyInsulin: Decimal,
            maxDailyInsulin: Decimal,
            maxTempBasalDurationMinutes: Decimal = 30,
            maxDataAgeForDosingMinutes: Decimal = 10,
            maxRateEscalationPerCycle: Decimal = 2
        ) {
            self.maxIOB = maxIOB
            self.maxBasal = maxBasal
            self.maxDailyBasal = maxDailyBasal
            self.currentBasal = currentBasal
            self.maxDailySafetyMultiplier = maxDailySafetyMultiplier
            self.currentBasalSafetyMultiplier = currentBasalSafetyMultiplier
            self.maxBolus = maxBolus
            self.maxSMBBasalMinutes = maxSMBBasalMinutes
            self.smbIntervalMinutes = smbIntervalMinutes
            self.bolusIncrement = bolusIncrement
            self.thresholdSetting = thresholdSetting
            self.minBG = minBG
            self.maxHourlyInsulin = maxHourlyInsulin
            self.maxDailyInsulin = maxDailyInsulin
            self.maxTempBasalDurationMinutes = maxTempBasalDurationMinutes
            self.maxDataAgeForDosingMinutes = maxDataAgeForDosingMinutes
            self.maxRateEscalationPerCycle = maxRateEscalationPerCycle
        }
    }

    /// Snapshot of the world at decision time. Assembled by the caller; the envelope
    /// never reads storage or the clock itself.
    struct SafetyState: Equatable {
        let currentIOB: Decimal?
        /// Estimated current glucose (mg/dL) from the StateEstimator (or raw CGM).
        let glucose: Decimal?
        /// Lowest point of the pessimistic (p10) predicted trajectory, if a model ran.
        let minPredictedGlucose: Decimal?
        /// Age of the triggering CGM value at decision time.
        let triggeringReadingAgeMinutes: Decimal
        let minutesSinceLastBolus: Decimal
        /// Insulin delivered above profile basal in the last 60 min (U).
        let insulinDeliveredLastHour: Decimal
        /// Total insulin delivered in the last 24 h (U).
        let insulinDeliveredLast24h: Decimal
        /// Rate enacted by the previous cycle, if a temp is running (U/hr).
        let lastEnactedRate: Decimal?
    }

    /// A dose a controller wants to enact. `smbUnits == 0` means basal-only.
    struct ProposedDose: Equatable {
        var rate: Decimal
        var durationMinutes: Decimal
        var smbUnits: Decimal

        static let zeroTemp = ProposedDose(rate: 0, durationMinutes: 30, smbUnits: 0)
    }

    // MARK: - Outputs

    /// Every rule that modified (or vetoed) the proposal, with before/after values,
    /// in application order. Feeds the DecisionAudit "what"/"why" fields.
    enum AppliedClamp: Equatable {
        case dataAgeGate(readingAgeMinutes: Decimal, smbBefore: Decimal, rateBefore: Decimal)
        case lowGlucoseSuspend(glucose: Decimal, threshold: Decimal)
        case predictedLowSuspend(minPredicted: Decimal, threshold: Decimal)
        case iobUnavailable
        case maxSafeBasal(before: Decimal, after: Decimal)
        case maxBolus(before: Decimal, after: Decimal)
        case smbBasalMinutes(before: Decimal, after: Decimal)
        case maxIOBHeadroom(before: Decimal, after: Decimal, headroom: Decimal)
        case smbInterval(minutesSinceLastBolus: Decimal)
        case hourlyInsulinCeiling(before: Decimal, after: Decimal, deliveredLastHour: Decimal)
        case dailyInsulinCeiling(before: Decimal, after: Decimal, deliveredLast24h: Decimal)
        case rateEscalation(before: Decimal, after: Decimal, lastRate: Decimal)
        case durationCap(before: Decimal, after: Decimal)
        case negativeValueFloor
        case bolusIncrementFloor(before: Decimal, after: Decimal)
    }

    enum Outcome: Equatable {
        /// Proposal allowed, possibly clamped.
        case allowed
        /// Low-glucose suspend: zero-temp enforced, SMB vetoed.
        case suspended
        /// Data too old for new dosing: proposal reduced to hold/reduce only.
        case holdOnly
    }

    struct Verdict: Equatable {
        let dose: ProposedDose
        let outcome: Outcome
        let clamps: [AppliedClamp]
    }

    // MARK: - Ported oref formulas

    /// `basal-set-temp.js getMaxSafeBasal`:
    /// min(max_basal, max_daily_safety_multiplier × max_daily_basal, current_basal_safety_multiplier × current_basal).
    /// Zero-basal profiles/segments: a multiplier term with a zero basal would clamp
    /// every dose to 0 and disable dosing entirely, so zero-valued scale terms are
    /// treated as absent — the user-set max_basal always applies.
    static func maxSafeBasal(limits: SafetyLimits) -> Decimal {
        var cap = limits.maxBasal
        if limits.maxDailyBasal > 0 {
            cap = min(cap, limits.maxDailySafetyMultiplier * limits.maxDailyBasal)
        }
        if limits.currentBasal > 0 {
            cap = min(cap, limits.currentBasalSafetyMultiplier * limits.currentBasal)
        }
        return cap
    }

    /// `determine-basal.js` threshold: `min_bg - 0.5*(min_bg-40)`, then
    /// `min(max(threshold_setting, computed, 60), 120)`.
    /// min_bg thresholds: 80→60, 90→65, 100→70, 110→75, 120→80.
    static func hypoThreshold(minBG: Decimal, thresholdSetting: Decimal) -> Decimal {
        let computed = minBG - Decimal(0.5) * (minBG - 40)
        return min(max(thresholdSetting, max(computed, 60)), 120)
    }

    /// oref SMB size cap: `current_basal × maxSMBBasalMinutes / 60`.
    /// With a zero scheduled basal the scale falls back to max_daily_basal, then to
    /// a quarter of max_basal (mirrors determine-basal.js `scale_basal`), so a
    /// zero-basal profile does not silently disable SMBs.
    static func smbBasalMinutesCap(limits: SafetyLimits) -> Decimal {
        let scaleBasal: Decimal
        if limits.currentBasal > 0 {
            scaleBasal = limits.currentBasal
        } else if limits.maxDailyBasal > 0 {
            scaleBasal = limits.maxDailyBasal
        } else {
            scaleBasal = limits.maxBasal / 4
        }
        return scaleBasal * limits.maxSMBBasalMinutes / 60
    }

    // MARK: - Evaluation

    /// Applies the full cap stack in a fixed order:
    /// data-age gate → LGS → per-dose caps → maxIOB headroom → SMB interval →
    /// rolling ceilings → escalation limiter → duration cap → increment flooring.
    /// The result's `clamps` records every rule that changed the proposal.
    static func apply(_ proposed: ProposedDose, limits: SafetyLimits, state: SafetyState) -> Verdict {
        var dose = proposed
        var clamps: [AppliedClamp] = []

        // Floor negative inputs before anything else.
        if dose.rate < 0 || dose.smbUnits < 0 || dose.durationMinutes < 0 {
            dose.rate = max(dose.rate, 0)
            dose.smbUnits = max(dose.smbUnits, 0)
            dose.durationMinutes = max(dose.durationMinutes, 0)
            clamps.append(.negativeValueFloor)
        }

        let threshold = hypoThreshold(minBG: limits.minBG, thresholdSetting: limits.thresholdSetting)

        // Low-glucose suspend overrides everything: zero-temp, no SMB.
        if let glucose = state.glucose, glucose < threshold {
            clamps.append(.lowGlucoseSuspend(glucose: glucose, threshold: threshold))
            return Verdict(
                dose: ProposedDose(rate: 0, durationMinutes: min(30, limits.maxTempBasalDurationMinutes), smbUnits: 0),
                outcome: .suspended,
                clamps: clamps
            )
        }
        if let minPredicted = state.minPredictedGlucose, minPredicted < threshold {
            clamps.append(.predictedLowSuspend(minPredicted: minPredicted, threshold: threshold))
            return Verdict(
                dose: ProposedDose(rate: 0, durationMinutes: min(30, limits.maxTempBasalDurationMinutes), smbUnits: 0),
                outcome: .suspended,
                clamps: clamps
            )
        }

        // Data-age gate: stale trigger ⇒ reduce/hold only. Raising delivery or issuing
        // an SMB requires a fresh value; lowering below profile basal stays allowed.
        var outcome: Outcome = .allowed
        if state.triggeringReadingAgeMinutes > limits.maxDataAgeForDosingMinutes {
            let rateBefore = dose.rate
            let smbBefore = dose.smbUnits
            dose.smbUnits = 0
            dose.rate = min(dose.rate, limits.currentBasal)
            if smbBefore != 0 || rateBefore != dose.rate {
                clamps.append(.dataAgeGate(
                    readingAgeMinutes: state.triggeringReadingAgeMinutes,
                    smbBefore: smbBefore,
                    rateBefore: rateBefore
                ))
            }
            outcome = .holdOnly
        }

        // Basal rate: oref maxSafeBasal.
        let safeBasal = maxSafeBasal(limits: limits)
        if dose.rate > safeBasal {
            clamps.append(.maxSafeBasal(before: dose.rate, after: safeBasal))
            dose.rate = safeBasal
        }

        if dose.smbUnits > 0 {
            // Any SMB requires known IOB.
            guard let currentIOB = state.currentIOB else {
                clamps.append(.iobUnavailable)
                dose.smbUnits = 0
                return finalize(dose, outcome: outcome, clamps: &clamps, limits: limits)
            }

            // Absolute pump max bolus.
            if dose.smbUnits > limits.maxBolus {
                clamps.append(.maxBolus(before: dose.smbUnits, after: limits.maxBolus))
                dose.smbUnits = limits.maxBolus
            }

            // oref basal-minutes SMB cap.
            let minutesCap = smbBasalMinutesCap(limits: limits)
            if dose.smbUnits > minutesCap {
                clamps.append(.smbBasalMinutes(before: dose.smbUnits, after: minutesCap))
                dose.smbUnits = minutesCap
            }

            // maxIOB headroom (oref: insulinReq > max_iob - iob ⇒ reduce accordingly).
            let headroom = max(limits.maxIOB - currentIOB, 0)
            if dose.smbUnits > headroom {
                clamps.append(.maxIOBHeadroom(before: dose.smbUnits, after: headroom, headroom: headroom))
                dose.smbUnits = headroom
            }

            // Minimum spacing between boluses.
            if state.minutesSinceLastBolus < limits.smbIntervalMinutes, dose.smbUnits > 0 {
                clamps.append(.smbInterval(minutesSinceLastBolus: state.minutesSinceLastBolus))
                dose.smbUnits = 0
            }
        }

        // Rolling 60-min ceiling: SMB + above-profile basal commitment this cycle.
        // Basal commitment is evaluated over a 5-min cycle: (rate − profile) × 5/60.
        let cycleBasalCommitment = max(dose.rate - limits.currentBasal, 0) * 5 / 60
        let hourlyProjected = state.insulinDeliveredLastHour + dose.smbUnits + cycleBasalCommitment
        if hourlyProjected > limits.maxHourlyInsulin {
            let allowedExtra = max(limits.maxHourlyInsulin - state.insulinDeliveredLastHour, 0)
            let smbBefore = dose.smbUnits
            dose.smbUnits = min(dose.smbUnits, allowedExtra)
            let remainingForBasal = allowedExtra - dose.smbUnits
            let rateBefore = dose.rate
            let allowedAboveProfile = remainingForBasal * 60 / 5
            dose.rate = min(dose.rate, limits.currentBasal + allowedAboveProfile)
            if smbBefore != dose.smbUnits {
                clamps.append(.hourlyInsulinCeiling(
                    before: smbBefore,
                    after: dose.smbUnits,
                    deliveredLastHour: state.insulinDeliveredLastHour
                ))
            }
            if rateBefore != dose.rate {
                clamps.append(.hourlyInsulinCeiling(
                    before: rateBefore,
                    after: dose.rate,
                    deliveredLastHour: state.insulinDeliveredLastHour
                ))
            }
        }

        // Rolling 24-h ceiling on the SMB (basal continues at profile if exhausted).
        if state.insulinDeliveredLast24h + dose.smbUnits > limits.maxDailyInsulin {
            let allowed = max(limits.maxDailyInsulin - state.insulinDeliveredLast24h, 0)
            if dose.smbUnits > allowed {
                clamps.append(.dailyInsulinCeiling(
                    before: dose.smbUnits,
                    after: allowed,
                    deliveredLast24h: state.insulinDeliveredLast24h
                ))
                dose.smbUnits = allowed
            }
            let rateBefore = dose.rate
            dose.rate = min(dose.rate, limits.currentBasal)
            if rateBefore != dose.rate {
                clamps.append(.dailyInsulinCeiling(
                    before: rateBefore,
                    after: dose.rate,
                    deliveredLast24h: state.insulinDeliveredLast24h
                ))
            }
        }

        // Escalation limiter: rate may rise at most maxRateEscalationPerCycle per cycle.
        if let lastRate = state.lastEnactedRate {
            let ceiling = lastRate + limits.maxRateEscalationPerCycle
            if dose.rate > ceiling {
                clamps.append(.rateEscalation(before: dose.rate, after: ceiling, lastRate: lastRate))
                dose.rate = ceiling
            }
        }

        return finalize(dose, outcome: outcome, clamps: &clamps, limits: limits)
    }

    private static func finalize(
        _ proposed: ProposedDose,
        outcome: Outcome,
        clamps: inout [AppliedClamp],
        limits: SafetyLimits
    ) -> Verdict {
        var dose = proposed

        // Bounded lifetime: silence must decay to profile basal (plan §2.1).
        if dose.durationMinutes > limits.maxTempBasalDurationMinutes {
            clamps.append(.durationCap(before: dose.durationMinutes, after: limits.maxTempBasalDurationMinutes))
            dose.durationMinutes = limits.maxTempBasalDurationMinutes
        }

        // Floor the SMB to the pump bolus increment (oref: floor(microBolus*roundSMBTo)/roundSMBTo).
        if dose.smbUnits > 0, limits.bolusIncrement > 0 {
            let floored = floorToIncrement(dose.smbUnits, increment: limits.bolusIncrement)
            if floored != dose.smbUnits {
                clamps.append(.bolusIncrementFloor(before: dose.smbUnits, after: floored))
                dose.smbUnits = floored
            }
        }

        return Verdict(dose: dose, outcome: outcome, clamps: clamps)
    }

    /// Rounds `value` down to a multiple of `increment` (never up — dosing must not
    /// exceed what the controller asked for).
    static func floorToIncrement(_ value: Decimal, increment: Decimal) -> Decimal {
        guard increment > 0 else { return value }
        let quotient = (value as NSDecimalNumber)
            .dividing(by: increment as NSDecimalNumber)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .down,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
        return quotient.multiplying(by: increment as NSDecimalNumber).decimalValue
    }
}
