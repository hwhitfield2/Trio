import Foundation
import LoopKit

/// The microbolus-basal engine.
///
/// Both models can bolus, so both can run basal this way. On a **t:slim X2** it
/// is the only way to close the loop at all, since that firmware has no remote
/// temp-rate command. On a **Mobi** it is an alternative to native temp rates,
/// and buys finer control: a Tandem temp rate is a whole percentage of the
/// pump's profile, capped at 250% and a 15-minute minimum, whereas microboluses
/// follow oref's requested rate at milliunit resolution with no ceiling beyond
/// Trio's own limits. The trade is that it replaces the pump's delivery engine
/// with Trio's.
///
/// When the user selects microbolus-basal mode (and has set the pump's own basal
/// profile to 0 U/hr with Control-IQ off), Trio drives ALL basal delivery by
/// converting oref's requested basal rate into a stream of small boluses.
///
/// Each loop cycle Trio calls `enactTempBasal(rate, duration)`. We integrate the
/// previously-commanded rate over the elapsed time into an "owed" accumulator,
/// then deliver whatever has accrued as a single microbolus (rounded down to the
/// 0.001 U increment, delivered once it reaches the pump's 0.05 U remote-bolus
/// floor). Amounts below the minimum pulse keep accumulating until they cross
/// the threshold, so even sub-minimum rates are delivered on average.
///
/// Deliveries are recorded as **automatic bolus** pump events (not temp-basal):
/// bolus and temp-basal contribute identically to IOB, and recording as bolus
/// avoids Trio's `maxBasal` temp-basal filter, which would otherwise drop a
/// high-reconstructed-rate pulse and cause an IOB undercount → over-delivery.
///
/// This mode and native temp rates are mutually exclusive — see
/// `TandemBasalControlMode`.
extension TandemPumpManager {
    /// Never deliver more than this in a single basal pulse (safety backstop).
    static let maxSingleMicrobolusUnits: Double = 2.0
    /// Discard/clamp runaway accrual beyond this (safety backstop).
    static let maxOwedBasalUnits: Double = 5.0
    /// The pump's own scheduled basal must be at or below this to be "zero".
    static let basalPreconditionEpsilonUnitsPerHour: Double = 0.05
    /// Longest gap over which the previous rate is integrated. A longer gap
    /// (loop stalled, BLE lost, app backgrounded) is treated as a break: the
    /// accrual resets rather than back-filling a large stale dose.
    static let maxIntegrationInterval: TimeInterval = .minutes(15)

    /// Handle a temp-basal request as an accumulated microbolus. commandQueue only.
    func enactMicrobolusBasal(unitsPerHour: Double, duration _: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        let now = Date()

        // While delivery is NOT safe/active — suspended, or the pump is still
        // covering basal itself (preconditions not met) — do NOT accrue owed.
        // Accruing during those windows would later dump insulin the pump has
        // already delivered (double-dose) or that we intentionally withheld.
        // Reset owed and keep the integration baseline current so we only start
        // integrating fresh once delivery becomes safe again.
        if state.microbolusSuspended {
            state.owedBasalInsulin = 0
            state.lastBasalRate = max(0, unitsPerHour)
            state.lastBasalUpdate = now
            notifyStateDidChange()
            completion(nil)
            return
        }

        guard microbolusBasalPreconditionsMet() else {
            state.owedBasalInsulin = 0
            state.lastBasalRate = max(0, unitsPerHour)
            state.lastBasalUpdate = now
            log.error(
                "Microbolus-basal precondition failed: pump basal \(state.profileBasalRate) U/hr, Control-IQ \(state.controlIQEnabled). Not delivering."
            )
            notifyStateDidChange()
            completion(.configuration(TandemUnsupportedError.microbolusBasalPreconditionFailed))
            return
        }

        // Safe to deliver: integrate the previously-commanded rate over the
        // elapsed step. On a long gap, do NOT back-fill — reset the accrual so a
        // stalled loop can't dump hours of stale basal on resume.
        if let last = state.lastBasalUpdate {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > Self.maxIntegrationInterval {
                log
                    .error(
                        "Basal integration gap of \(Int(elapsed))s exceeds cap; resetting accrual (was \(state.owedBasalInsulin) U)"
                    )
                state.owedBasalInsulin = 0
            } else if elapsed > 0 {
                state.owedBasalInsulin += max(0, state.lastBasalRate) * elapsed / 3600
            }
        }
        state.lastBasalRate = max(0, unitsPerHour)
        state.lastBasalUpdate = now

        // Clamp runaway accrual.
        if state.owedBasalInsulin > Self.maxOwedBasalUnits {
            log.error("Owed basal \(state.owedBasalInsulin)U exceeds cap; clamping to \(Self.maxOwedBasalUnits)U")
            state.owedBasalInsulin = Self.maxOwedBasalUnits
        }

        // Never deliver a basal pulse while a tracked (SMB/manual) bolus is
        // active — the pump allows one bolus at a time. Keep accruing.
        guard state.activeBolus == nil else {
            log.info("Bolus in progress; deferring basal microbolus (owed \(state.owedBasalInsulin) U)")
            notifyStateDidChange()
            completion(nil)
            return
        }

        // Round owed down to a deliverable 0.001 U (1 milliunit) pulse, capped.
        // The +1e-6 nudge keeps binary-float artifacts from flooring one
        // milliunit low.
        var deliverable = (state.owedBasalInsulin * 1000 + 1E-6).rounded(.down) / 1000
        deliverable = min(deliverable, Self.maxSingleMicrobolusUnits)
        let milliunits = UInt32((deliverable * 1000).rounded())

        guard deliverable > 0, milliunits >= TandemInitiateBolusRequest.minBolusMilliunits else {
            // Below the minimum pulse; keep accruing for a later cycle.
            notifyStateDidChange()
            completion(nil)
            return
        }

        switch initiateBolusCommand(milliunits: milliunits) {
        case let .delivered(bolusId):
            releaseBolusPermission(bolusId: bolusId)
            recordDeliveredBasal(units: deliverable, at: now, bolusId: bolusId)
            completion(nil)

        case let .uncertain(bolusId, error):
            // The signed initiate may have reached the pump. Assume it delivered
            // so we do NOT re-deliver next cycle: subtract owed and record it.
            // Worst case this over-states IOB (→ under-, not over-, delivery),
            // which is the safe direction. A basal pulse is tiny and completes
            // in seconds, so release the (now unneeded) permission rather than
            // leaving it to block the next cycle's pulse or an SMB.
            log.error("Basal microbolus uncertain (\(error.localizedDescription)); recording as delivered")
            releaseBolusPermission(bolusId: bolusId)
            recordDeliveredBasal(units: deliverable, at: now, bolusId: bolusId)
            completion(nil)

        case .rejected:
            // The pump refused this pulse (e.g. below its true minimum, or a
            // transient state). Keep the owed insulin so it accumulates into a
            // larger, acceptable pulse next cycle. Non-fatal for the loop.
            log.error("Basal microbolus rejected; keeping owed \(state.owedBasalInsulin) U")
            notifyStateDidChange()
            completion(nil)

        case let .notSent(error):
            log.error("Basal microbolus not sent: \(error.localizedDescription)")
            notifyStateDidChange()
            completion(.communication(error))
        }
    }

    /// Record a delivered basal microbolus as an automatic bolus event and
    /// subtract it from the owed accumulator. commandQueue only.
    private func recordDeliveredBasal(units: Double, at date: Date, bolusId: UInt16) {
        state.owedBasalInsulin = max(0, state.owedBasalInsulin - units)
        if state.owedBasalInsulin <= 0.0001 {
            state.owedBasalInsulin = 0
        }
        // Remember this id so reconcileBolusStatus does not also record this
        // pump-side bolus (it is recorded here, at wall-clock time — the pump's
        // whole-second timestamp would differ and defeat timestamp dedup).
        state.noteBolusId(bolusId)

        let dose = DoseEntry(
            type: .bolus,
            startDate: date,
            value: units,
            unit: .units,
            deliveredUnits: units,
            insulinType: state.insulinType,
            automatic: true,
            isMutable: false
        )
        let event = NewPumpEvent(
            date: date,
            dose: dose,
            raw: withUnsafeBytes(of: bolusId.littleEndian) { Data($0) } + Data([0xBA]),
            title: "Basal microbolus \(units) U (id \(bolusId))",
            type: .bolus
        )
        emitPumpEvents([event], replacePendingEvents: false)
        playFeedbackTone(.dose, forAutomaticDose: true)
        // NOTE: do NOT bump state.lastSync here — that is reserved for real
        // status syncs. Bumping it would make ensureCurrentPumpData skip the
        // next status poll, letting a pump-side basal/Control-IQ change go
        // unseen while the precondition check runs against stale state.
        notifyStateDidChange()
    }

    /// Maximum age of the status sync the precondition may rely on. Beyond this
    /// the pump's basal/Control-IQ state is considered unknown and delivery is
    /// refused (fail closed).
    static let preconditionMaxStaleness: TimeInterval = .minutes(10)

    /// True when it is safe to microbolus basal: the pump's own scheduled basal
    /// is ~0 and Control-IQ is off, verified against a RECENT status sync. Stale
    /// or missing status fails closed.
    func microbolusBasalPreconditionsMet() -> Bool {
        guard state.lastSync != .distantPast,
              Date.now.timeIntervalSince(state.lastSync) < Self.preconditionMaxStaleness
        else { return false }
        return state.profileBasalRate <= Self.basalPreconditionEpsilonUnitsPerHour && !state.controlIQEnabled
    }

    /// Trio-commanded suspend: stop microbolusing (a true stop with basal zeroed).
    /// commandQueue only.
    func suspendMicrobolusBasal(completion: @escaping ((any Error)?) -> Void) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        state.microbolusSuspended = true
        state.owedBasalInsulin = 0
        state.lastBasalUpdate = Date() // reset the integration baseline
        let now = Date()
        let dose = DoseEntry(type: .suspend, startDate: now, value: 0, unit: .units)
        let raw = withUnsafeBytes(of: UInt32(now.timeIntervalSince1970).littleEndian) { Data($0) } + Data([0x5B])
        emitPumpEvents(
            [NewPumpEvent(date: now, dose: dose, raw: raw, title: "Suspend", type: .suspend)],
            replacePendingEvents: false
        )
        playFeedbackTone(.stateChange)
        notifyStateDidChange()
        completion(nil)
    }

    /// Resume microbolusing. Does not back-fill insulin owed during suspension.
    /// commandQueue only.
    func resumeMicrobolusBasal(completion: @escaping ((any Error)?) -> Void) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        state.microbolusSuspended = false
        state.owedBasalInsulin = 0
        state.lastBasalUpdate = Date()
        let now = Date()
        let dose = DoseEntry(type: .resume, startDate: now, value: 0, unit: .units)
        let raw = withUnsafeBytes(of: UInt32(now.timeIntervalSince1970).littleEndian) { Data($0) } + Data([0x5C])
        emitPumpEvents(
            [NewPumpEvent(date: now, dose: dose, raw: raw, title: "Resume", type: .resume)],
            replacePendingEvents: false
        )
        playFeedbackTone(.stateChange)
        notifyStateDidChange()
        completion(nil)
    }
}
