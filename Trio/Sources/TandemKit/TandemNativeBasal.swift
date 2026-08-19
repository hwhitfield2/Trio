import Foundation
import LoopKit

/// Native basal control for the Tandem Mobi.
///
/// Unlike the t:slim X2, the Mobi implements the temp-rate, suspend and resume
/// control opcodes, so Trio can close the loop with the pump's own delivery
/// engine instead of the microbolus workaround.
///
/// The one awkward part of the protocol is that a temp rate is a **percentage
/// of the pump's active profile basal rate**, not an absolute U/hr value. oref
/// thinks in absolute rates, so every command converts using the profile rate
/// read from the pump, and the *achieved* rate — the percentage actually
/// applied to that profile rate — is what gets recorded for IOB. Two
/// consequences the user has to live with, surfaced in the settings screen:
///
/// - the pump must have a non-zero basal profile, or there is nothing to take a
///   percentage of;
/// - the reachable range is 0-250% of the profile rate, so a high temp is
///   capped at 2.5x the scheduled rate.
extension TandemPumpManager {
    /// The pump's own basal profile must be at least this to be usable as a
    /// percentage base.
    static let minimumProfileBasalForTempRate: Double = 0.001

    /// Maximum age of the status sync a temp-rate conversion may rely on. Older
    /// than this and the profile rate (or the Control-IQ state) is considered
    /// unknown, and the command is refused rather than sent against a stale
    /// baseline.
    static let tempBasalContextMaxStaleness: TimeInterval = .minutes(10)

    // MARK: - Temp basal

    /// Enact a temp basal using the pump's own temp-rate command. commandQueue only.
    func enactNativeTempBasal(
        unitsPerHour: Double,
        duration: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        // LoopKit expresses "cancel the running temp basal" as a zero-length
        // request.
        guard duration >= .minutes(1) else {
            stopNativeTempBasal { error in
                completion(error.map { PumpManagerError.communication($0) })
            }
            return
        }

        if let error = ensureConnectedAndAuthenticated() {
            completion(.communication(error))
            return
        }

        // The percentage is meaningless against a stale profile rate, and
        // Control-IQ may have been switched on since the last poll, so refresh
        // both before converting.
        refreshBasalContext()
        guard let context = currentBasalContext() else {
            completion(.deviceState(TandemUnsupportedError.basalContextStale))
            return
        }
        guard !context.controlIQEnabled else {
            completion(.configuration(TandemUnsupportedError.controlIQActive))
            return
        }
        guard context.profileBasalRate >= Self.minimumProfileBasalForTempRate else {
            completion(.configuration(TandemUnsupportedError.zeroProfileBasal))
            return
        }

        let percent = Self.tempRatePercent(forRate: unitsPerHour, profileRate: context.profileBasalRate)
        let achievedRate = context.profileBasalRate * Double(percent) / 100
        let clampedDuration = min(
            max(duration, TandemTempRateLimits.minDuration),
            TandemTempRateLimits.maxDuration
        )
        let minutes = UInt32((clampedDuration / 60).rounded())

        if percent == TandemTempRateLimits.maxPercent, unitsPerHour > achievedRate {
            log.error(
                "Requested \(unitsPerHour) U/hr exceeds 250% of the pump profile rate \(context.profileBasalRate) U/hr; delivering \(achievedRate) U/hr"
            )
        }

        // Signed commands need a fresh pump time reference.
        if case let .failure(error) = session.refreshTimeSinceReset() {
            completion(.communication(error))
            return
        }

        // The pump runs at most one temp rate; clear any running one first so a
        // new command cannot be rejected as a duplicate.
        if let active = state.activeTempBasal, active.isActive() {
            sendStopTempRate(tempRateId: active.tempRateId)
            if case let .failure(error) = session.refreshTimeSinceReset() {
                completion(.communication(error))
                return
            }
        }

        let startDate = Date.now
        let request = TandemSetTempRateRequest(minutes: minutes, percent: UInt16(percent))
        switch session.send(request) {
        case let .success(response):
            guard response.status == 0 else {
                log.error("SetTempRate rejected with status \(response.status)")
                // Any rate that was running was stopped above, so tell Trio the
                // old temp basal has ended rather than leaving it to expire on
                // paper while the pump is back on its profile.
                if state.activeTempBasal != nil {
                    clearTempBasal()
                }
                completion(.deviceState(TandemUnsupportedError.tempBasalRejected(response.status)))
                return
            }
            recordTempBasal(
                tempRateId: response.tempRateId,
                unitsPerHour: achievedRate,
                percent: percent,
                startDate: startDate,
                duration: clampedDuration
            )
            completion(nil)

        case let .failure(error):
            if TandemPumpManager.isDefiniteNonDelivery(error) {
                completion(.communication(error))
                return
            }
            // The request was signed and may well have reached the pump — a
            // timeout usually means the reply was lost, not the command. Record
            // it as applied, which is the better estimate of what the pump is
            // doing, and force a resync so the next cycle reads the truth from
            // the pump. Still report the failure so Trio retries this cycle.
            log.error("SetTempRate outcome unknown (\(error.localizedDescription)); recording it and forcing a resync")
            recordTempBasal(
                tempRateId: 0,
                unitsPerHour: achievedRate,
                percent: percent,
                startDate: startDate,
                duration: clampedDuration
            )
            state.lastSync = .distantPast
            completion(.communication(error))
        }
    }

    /// Percentage of profile basal that best approximates `rate`, clamped to
    /// what the pump accepts.
    static func tempRatePercent(forRate rate: Double, profileRate: Double) -> Int {
        guard profileRate > 0 else { return TandemTempRateLimits.minPercent }
        let raw = (max(0, rate) / profileRate * 100).rounded()
        guard raw.isFinite else { return TandemTempRateLimits.minPercent }
        return min(max(Int(raw), TandemTempRateLimits.minPercent), TandemTempRateLimits.maxPercent)
    }

    /// Stop a running temp rate, returning the pump to its profile. commandQueue only.
    func stopNativeTempBasal(completion: @escaping ((any LocalizedError)?) -> Void) {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        guard let active = state.activeTempBasal, active.isActive() else {
            // Nothing running on the pump. Drop any expired record without
            // emitting a cancel event, so repeated cancels do not spam the
            // treatment log.
            if state.activeTempBasal != nil {
                state.activeTempBasal = nil
                notifyStateDidChange()
            }
            completion(nil)
            return
        }

        if let error = ensureConnectedAndAuthenticated() {
            completion(error)
            return
        }
        if case let .failure(error) = session.refreshTimeSinceReset() {
            completion(error)
            return
        }

        switch session.send(TandemStopTempRateRequest()) {
        case let .success(response):
            guard response.status == 0 else {
                log.error("StopTempRate rejected with status \(response.status)")
                completion(TandemUnsupportedError.tempBasalRejected(response.status))
                return
            }
            clearTempBasal()
            playFeedbackTone(.stateChange)
            completion(nil)
        case let .failure(error):
            // Assume the stop landed: continuing to report a temp basal that
            // may already be over would overstate IOB in the direction that
            // makes Trio under-deliver, and the next status sync corrects it.
            log.error("StopTempRate failed (\(error.localizedDescription)); clearing local temp basal anyway")
            clearTempBasal()
            state.lastSync = .distantPast
            completion(error)
        }
    }

    /// Best-effort stop used before replacing a running temp rate. commandQueue only.
    private func sendStopTempRate(tempRateId: UInt16) {
        switch session.send(TandemStopTempRateRequest()) {
        case let .success(response) where response.status != 0:
            log.error("Pre-replacement StopTempRate returned status \(response.status) for id \(tempRateId)")
        case let .failure(error):
            log.error("Pre-replacement StopTempRate failed: \(error.localizedDescription)")
        case .success:
            break
        }
    }

    // MARK: - Suspend / resume

    /// Suspend all delivery on the pump. commandQueue only.
    func suspendNativeDelivery(completion: @escaping ((any Error)?) -> Void) {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        if let error = ensureConnectedAndAuthenticated() {
            completion(error)
            return
        }
        if case let .failure(error) = session.refreshTimeSinceReset() {
            completion(error)
            return
        }

        switch session.send(TandemSuspendPumpingRequest()) {
        case let .success(response):
            guard response.status == 0 else {
                log.error("SuspendPumping rejected with status \(response.status)")
                completion(TandemUnsupportedError.suspendRejected(response.status))
                return
            }
            // Suspension ends any running temp rate on the pump.
            state.activeTempBasal = nil
            state.suspended = true
            emitDeliveryStateEvent(suspend: true)
            playFeedbackTone(.stateChange)
            notifyStateDidChange()
            completion(nil)
        case let .failure(error):
            log.error("SuspendPumping failed: \(error.localizedDescription)")
            state.lastSync = .distantPast
            completion(error)
        }
    }

    /// Resume delivery on the pump. commandQueue only.
    func resumeNativeDelivery(completion: @escaping ((any Error)?) -> Void) {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        if let error = ensureConnectedAndAuthenticated() {
            completion(error)
            return
        }
        if case let .failure(error) = session.refreshTimeSinceReset() {
            completion(error)
            return
        }

        switch session.send(TandemResumePumpingRequest()) {
        case let .success(response):
            guard response.status == 0 else {
                log.error("ResumePumping rejected with status \(response.status)")
                completion(TandemUnsupportedError.resumeRejected(response.status))
                return
            }
            state.suspended = false
            emitDeliveryStateEvent(suspend: false)
            playFeedbackTone(.stateChange)
            notifyStateDidChange()
            completion(nil)
        case let .failure(error):
            log.error("ResumePumping failed: \(error.localizedDescription)")
            state.lastSync = .distantPast
            completion(error)
        }
    }

    // MARK: - Bookkeeping

    /// The pump state a temp-rate conversion depends on, if it is fresh enough
    /// to trust.
    private struct BasalContext {
        let profileBasalRate: Double
        let controlIQEnabled: Bool
    }

    private func currentBasalContext() -> BasalContext? {
        guard state.lastSync != .distantPast,
              Date.now.timeIntervalSince(state.lastSync) < Self.tempBasalContextMaxStaleness
        else { return nil }
        return BasalContext(profileBasalRate: state.profileBasalRate, controlIQEnabled: state.controlIQEnabled)
    }

    /// Re-read the two values a temp rate depends on. Leaves `lastSync` alone on
    /// failure so a stale context is caught by `currentBasalContext()`.
    private func refreshBasalContext() {
        var succeeded = true

        switch session.send(TandemCurrentBasalStatusRequest()) {
        case let .success(response):
            state.profileBasalRate = Double(response.profileBasalRate) / 1000
            state.currentBasalRate = Double(response.currentBasalRate) / 1000
        case let .failure(error):
            succeeded = false
            log.error("CurrentBasalStatus failed before temp rate: \(error.localizedDescription)")
        }

        switch session.send(TandemControlIQInfoV1Request()) {
        case let .success(response):
            state.controlIQEnabled = response.closedLoopEnabled
        case let .failure(error):
            succeeded = false
            log.error("ControlIQInfo failed before temp rate: \(error.localizedDescription)")
        }

        if succeeded {
            state.lastSync = Date.now
        }
    }

    /// Track the temp rate and report it to Trio. commandQueue only.
    private func recordTempBasal(
        tempRateId: UInt16,
        unitsPerHour: Double,
        percent: Int,
        startDate: Date,
        duration: TimeInterval
    ) {
        state.activeTempBasal = TandemActiveTempBasal(
            tempRateId: tempRateId,
            unitsPerHour: unitsPerHour,
            percent: percent,
            startDate: startDate,
            duration: duration
        )

        let dose = DoseEntry(
            type: .tempBasal,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(duration),
            value: unitsPerHour,
            unit: .unitsPerHour,
            insulinType: state.insulinType,
            automatic: true
        )
        let event = NewPumpEvent(
            date: startDate,
            dose: dose,
            raw: withUnsafeBytes(of: tempRateId.littleEndian) { Data($0) }
                + withUnsafeBytes(of: UInt32(startDate.timeIntervalSince1970).littleEndian) { Data($0) },
            title: "Temp basal \(unitsPerHour) U/hr (\(percent)%) for \(Int(duration / 60)) min",
            type: .tempBasal
        )
        emitPumpEvents([event], replacePendingEvents: false)
        notifyStateDidChange()
    }

    /// Forget the temp basal and tell Trio it has ended, by reporting a
    /// zero-length temp basal — the representation oref reads as "temp cancelled".
    private func clearTempBasal() {
        state.activeTempBasal = nil
        let now = Date.now
        let dose = DoseEntry(
            type: .tempBasal,
            startDate: now,
            endDate: now,
            value: 0,
            unit: .unitsPerHour,
            insulinType: state.insulinType,
            automatic: true
        )
        let event = NewPumpEvent(
            date: now,
            dose: dose,
            raw: withUnsafeBytes(of: UInt32(now.timeIntervalSince1970).littleEndian) { Data($0) } + Data([0x7C]),
            title: "Temp basal cancelled",
            type: .tempBasal
        )
        emitPumpEvents([event], replacePendingEvents: false)
        notifyStateDidChange()
    }

    private func emitDeliveryStateEvent(suspend: Bool) {
        let now = Date.now
        let dose = DoseEntry(type: suspend ? .suspend : .resume, startDate: now, value: 0, unit: .units)
        let raw = withUnsafeBytes(of: UInt32(now.timeIntervalSince1970).littleEndian) { Data($0) }
            + Data([suspend ? 0x5D : 0x5E])
        emitPumpEvents(
            [NewPumpEvent(
                date: now,
                dose: dose,
                raw: raw,
                title: suspend ? "Suspend" : "Resume",
                type: suspend ? .suspend : .resume
            )],
            replacePendingEvents: false
        )
    }
}
