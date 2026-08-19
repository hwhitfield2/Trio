import Foundation
import LoopKit

/// Where the infusion set is, as confirmed by the user.
///
/// The two fill steps need opposite answers, which is why this is not a single
/// "are you disconnected?" flag: the tubing is filled with the set **off** the
/// body, and the cannula is primed once the set has been **inserted**. Trio
/// cannot observe either, so it asks, and refuses the step without a recent
/// answer.
enum TandemSetPlacement: String, Codable, Equatable {
    /// Set is off the body — required before filling tubing.
    case disconnected
    /// Set is inserted and connected — required before priming the cannula.
    case inserted
}

enum TandemCartridgeError: LocalizedError {
    case notEnabled
    case notInCartridgeChange
    case alreadyInCartridgeChange
    case sessionExpired
    case wrongStage
    case placementNotConfirmed(TandemSetPlacement)
    case cannulaFillUnsupported
    case primeAmountOutOfRange
    case rejected(step: String, status: UInt8, loadState: String?)
    case deliveryMustBeStoppedOnPump

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Cartridge changes from Trio are turned off. Enable them in the pump settings first."
        case .notInCartridgeChange:
            return "The pump is not in a cartridge change."
        case .alreadyInCartridgeChange:
            return "A cartridge change is already in progress."
        case .sessionExpired:
            return "This cartridge change has been open too long, so Trio no longer knows the pump's state. Cancel it and start again."
        case .wrongStage:
            return "That step is not available at this point in the cartridge change."
        case let .placementNotConfirmed(placement):
            switch placement {
            case .disconnected:
                return "Confirm the infusion set is disconnected from your body before filling the tubing."
            case .inserted:
                return "Confirm the new infusion set is inserted and connected before priming the cannula."
            }
        case .cannulaFillUnsupported:
            return "Priming the cannula from Trio is only supported on the Tandem Mobi. On the t:slim X2, prime the cannula on the pump itself."
        case .primeAmountOutOfRange:
            return "The prime amount must be between 0.01 U and 3 U."
        case let .rejected(step, status, loadState):
            if let loadState = loadState {
                return "The pump refused to \(step) (status \(status)) — \(loadState)."
            }
            return "The pump refused to \(step) (status \(status))."
        case .deliveryMustBeStoppedOnPump:
            return "The pump will not start a cartridge change while it is delivering insulin. Stop insulin on the pump first, then try again."
        }
    }
}

/// Driving a cartridge change — loading a new cartridge, filling the tubing and
/// priming the cannula — from Trio.
///
/// **This is the riskiest surface in the driver, for two reasons.**
///
/// First, it moves insulin outside of any dosing calculation: filling tubing
/// pushes insulin through the line, and priming pushes it into the infusion
/// site. Neither is IOB, and neither is safe if the set is on the body when it
/// should not be. Trio cannot see the set, so every insulin-moving step demands
/// a fresh, explicit confirmation of where the set is, and the two steps demand
/// opposite answers.
///
/// Second, unlike the bolus and temp-rate flows, there is no reference
/// implementation to copy. pumpX2 defines and unit-tests these message
/// encodings but never sends them, and its progress-state enums have a single
/// known value each. The **encodings** here are transcribed with the same
/// confidence as the rest of the driver; the **sequence** is reconstructed from
/// how the pump's own procedure works. It has not been run against a pump.
///
/// Because of that, nothing here is automatic. Each step is a separate,
/// user-initiated command, and Trio refuses to dose at all while a change is
/// open.
extension TandemPumpManager {
    // MARK: - Opt-in and confirmations

    /// User opt-in for driving cartridge changes from Trio.
    func setCartridgeChangeEnabled(_ enabled: Bool) {
        state.cartridgeChangeEnabled = enabled
        if !enabled {
            state.cartridgeSession = nil
            state.cartridgeDisconnectConfirmedAt = nil
            state.lastCartridgeEventDescription = nil
        }
        session.insulinDeliveryActionsEnabled = state.insulinDeliveryActionsAllowed
        notifyStateDidChange()
    }

    /// Record that the user has confirmed where the infusion set is. The
    /// confirmation is deliberately short-lived and is cleared whenever the
    /// stage advances, so one answer cannot authorise a later step.
    func confirmSetPlacement(_ placement: TandemSetPlacement) {
        state.confirmedSetPlacement = placement
        state.cartridgeDisconnectConfirmedAt = Date.now
        notifyStateDidChange()
    }

    private func requirePlacement(_ placement: TandemSetPlacement) -> TandemCartridgeError? {
        guard state.confirmedSetPlacement == placement, state.hasFreshDisconnectConfirmation() else {
            return .placementNotConfirmed(placement)
        }
        return nil
    }

    /// Common preconditions for a step that continues an open change.
    private func requireOpenSession(stages: [TandemCartridgeSession.Stage]) -> TandemCartridgeError? {
        guard state.cartridgeChangeEnabled else { return .notEnabled }
        guard let session = state.cartridgeSession else { return .notInCartridgeChange }
        guard !session.isStale() else { return .sessionExpired }
        guard stages.contains(session.stage) else { return .wrongStage }
        return nil
    }

    // MARK: - Steps

    /// Step 1: put the pump into cartridge-change mode. Delivery stops.
    func beginCartridgeChange(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            guard self.state.cartridgeChangeEnabled else {
                completion(TandemCartridgeError.notEnabled)
                return
            }
            guard !self.state.cartridgeChangeInProgress else {
                completion(TandemCartridgeError.alreadyInCartridgeChange)
                return
            }

            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }

            // The pump runs its own load state machine. Read it first: it tells
            // us whether a change is already under way (adopt it rather than
            // asking twice) and, if the command is refused, what the pump was
            // actually doing instead of a bare status byte.
            let loadStatus = self.readLoadStatus()
            if let loadStatus = loadStatus, loadStatus.isLoadingActive {
                self.log.info("Pump is already loading: \(loadStatus.localizedDescription); adopting the session")
                self.adoptExistingLoad(loadStatus)
                completion(nil)
                return
            }

            // A Tandem pump will not begin a load while it is delivering — its
            // own on-pump flow stops insulin first — so do the same here.
            if let error = self.stopDeliveryForLoad() {
                completion(error)
                return
            }

            switch self.session.send(TandemEnterChangeCartridgeModeRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    let after = self.readLoadStatus()
                    self.log.error(
                        "EnterChangeCartridgeMode refused with status \(response.status); load status: \(after?.localizedDescription ?? "unavailable")"
                    )
                    completion(TandemCartridgeError.rejected(
                        step: "start the cartridge change",
                        status: response.status,
                        loadState: after?.localizedDescription
                    ))
                    return
                }
                let now = Date.now
                self.state.cartridgeSession = TandemCartridgeSession(stage: .changeMode, startedAt: now)
                // The pump has stopped delivering, and any temp rate Trio set is
                // void. Reflect that immediately rather than waiting for a poll.
                self.state.activeTempBasal = nil
                self.state.suspended = true
                self.state.cartridgeDisconnectConfirmedAt = nil
                self.state.confirmedSetPlacement = nil
                self.emitCartridgeEvent(type: .rewind, title: "Cartridge change started", at: now)
                self.playFeedbackTone(.stateChange)
                self.notifyStateDidChange()
                completion(nil)
            case let .failure(error):
                // The pump may or may not have entered change mode. Force a
                // resync so the next status poll establishes the truth, and do
                // not claim a session we are not sure exists.
                self.state.lastSync = .distantPast
                completion(error)
            }
        }
    }

    /// Step 2: start filling the tubing. **Requires the set to be off the body.**
    func startFillTubing(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            if let error = self.requireOpenSession(stages: [.changeMode, .tubingFilled]) {
                completion(error)
                return
            }
            if let error = self.requirePlacement(.disconnected) {
                completion(error)
                return
            }
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }

            switch self.session.send(TandemEnterFillTubingModeRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    completion(TandemCartridgeError.rejected(step: "start filling the tubing", status: response.status, loadState: self.readLoadStatus()?.localizedDescription))
                    return
                }
                self.state.cartridgeSession?.stage = .fillingTubing
                self.emitCartridgeEvent(type: .prime, title: "Filling tubing", at: Date.now)
                self.playFeedbackTone(.stateChange)
                self.notifyStateDidChange()
                completion(nil)
            case let .failure(error):
                self.state.lastSync = .distantPast
                completion(error)
            }
        }
    }

    /// Step 3: stop filling the tubing.
    func stopFillTubing(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            if let error = self.requireOpenSession(stages: [.fillingTubing]) {
                completion(error)
                return
            }
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }

            switch self.session.send(TandemExitFillTubingModeRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    completion(TandemCartridgeError.rejected(step: "stop filling the tubing", status: response.status, loadState: self.readLoadStatus()?.localizedDescription))
                    return
                }
                self.state.cartridgeSession?.stage = .tubingFilled
                // The set now has to be inserted, so the previous "disconnected"
                // answer must not carry over to the cannula prime.
                self.state.cartridgeDisconnectConfirmedAt = nil
                self.state.confirmedSetPlacement = nil
                self.playFeedbackTone(.stateChange)
                self.notifyStateDidChange()
                completion(nil)
            case let .failure(error):
                // Leaving fill-tubing mode is the safe direction to assume, but
                // a lost reply could mean the pump is still filling. Ask the
                // pump to stop priming as a belt-and-braces measure, then force
                // a resync.
                self.log.error("Exiting fill-tubing mode failed (\(error.localizedDescription)); sending a prime suspend")
                _ = self.session.send(TandemPrimeTubingSuspendRequest())
                self.state.lastSync = .distantPast
                completion(error)
            }
        }
    }

    /// Step 4 (Mobi only): prime the cannula. **Requires the set to be inserted.**
    func fillCannula(units: Double, completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            guard self.state.pumpModel.supportsRemoteCannulaFill else {
                completion(TandemCartridgeError.cannulaFillUnsupported)
                return
            }
            if let error = self.requireOpenSession(stages: [.tubingFilled, .cannulaFilled]) {
                completion(error)
                return
            }
            if let error = self.requirePlacement(.inserted) {
                completion(error)
                return
            }
            guard let milliunits = Self.primeMilliunits(forUnits: units) else {
                completion(TandemCartridgeError.primeAmountOutOfRange)
                return
            }
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }

            switch self.session.send(TandemFillCannulaRequest(primeSizeMilliunits: milliunits)) {
            case let .success(response):
                guard response.status == 0 else {
                    completion(TandemCartridgeError.rejected(step: "prime the cannula", status: response.status, loadState: self.readLoadStatus()?.localizedDescription))
                    return
                }
                self.state.cartridgeSession?.stage = .cannulaFilled
                // Priming insulin fills the cannula's dead space; like every
                // pump, Tandem does not count it as delivered insulin, so this
                // is recorded as a prime with no dose rather than as a bolus.
                self.emitCartridgeEvent(
                    type: .prime,
                    title: "Cannula primed \(String(format: "%.2f", Double(milliunits) / 1000)) U",
                    at: Date.now
                )
                self.playFeedbackTone(.stateChange)
                self.notifyStateDidChange()
                completion(nil)
            case let .failure(error):
                self.state.lastSync = .distantPast
                completion(error)
            }
        }
    }

    /// Step 5: leave cartridge-change mode and hand delivery back to the pump.
    func finishCartridgeChange(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            guard self.state.cartridgeSession != nil else {
                completion(TandemCartridgeError.notInCartridgeChange)
                return
            }
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }

            switch self.session.send(TandemExitChangeCartridgeModeRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    completion(TandemCartridgeError.rejected(step: "finish the cartridge change", status: response.status, loadState: self.readLoadStatus()?.localizedDescription))
                    return
                }
                self.completeCartridgeSession(recordSiteChange: true)
                completion(nil)
            case let .failure(error):
                self.state.lastSync = .distantPast
                completion(error)
            }
        }
    }

    /// Abandon a change: best effort exit from whichever mode the pump is in.
    ///
    /// Every step is attempted regardless of the previous one's result, because
    /// leaving the pump in fill-tubing or change mode is worse than a failed
    /// command. A failure still clears Trio's session so the user is not stuck,
    /// and forces a resync so the pump's real state is re-read.
    func cancelCartridgeChange(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            guard self.state.cartridgeSession != nil else {
                completion(nil)
                return
            }
            if let error = self.prepareForCartridgeCommand() {
                // Cannot reach the pump. Still drop our session, but say so.
                self.completeCartridgeSession(recordSiteChange: false)
                completion(error)
                return
            }

            var firstFailure: (any LocalizedError)?

            if self.state.cartridgeSession?.stage == .fillingTubing {
                if case let .failure(error) = self.session.send(TandemExitFillTubingModeRequest()) {
                    self.log.error("Cancel: exiting fill-tubing mode failed: \(error.localizedDescription)")
                    firstFailure = firstFailure ?? error
                    _ = self.session.send(TandemPrimeTubingSuspendRequest())
                }
                _ = self.session.refreshTimeSinceReset()
            }

            if case let .failure(error) = self.session.send(TandemExitChangeCartridgeModeRequest()) {
                self.log.error("Cancel: exiting change-cartridge mode failed: \(error.localizedDescription)")
                firstFailure = firstFailure ?? error
            }

            self.completeCartridgeSession(recordSiteChange: false)
            if firstFailure != nil {
                self.state.lastSync = .distantPast
            }
            completion(firstFailure)
        }
    }

    /// Read the pump's load state on demand, without starting anything. Useful
    /// when a command was refused and the user wants to know what the pump
    /// thinks is going on.
    func refreshLoadStatus(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }
            self.refreshSuspendState()
            let status = self.readLoadStatus()
            if status == nil {
                completion(TandemCartridgeError.notInCartridgeChange)
            } else {
                completion(nil)
            }
            self.notifyStateDidChange()
        }
    }

    // MARK: - Progress from the pump

    /// Handle one control-stream progress event. Called off the BLE queue.
    func handleCartridgeStreamEvent(_ event: TandemCartridgeStreamEvent) {
        commandQueue.async {
            self.log.info("Cartridge progress: \(event.localizedDescription)")
            self.state.lastCartridgeEventDescription = event.localizedDescription

            // The pump confirming the cannula is filled is the one stream event
            // that advances Trio's own stage, so a prime that finished on the
            // pump is not left looking incomplete.
            if case let .fillCannula(stateId) = event,
               stateId == TandemCartridgeStreamEvent.cannulaFilledStateId,
               self.state.cartridgeSession != nil
            {
                self.state.cartridgeSession?.stage = .cannulaFilled
            }
            self.notifyStateDidChange()
        }
    }

    // MARK: - Pump load state

    /// Read the pump's load state machine. Unsigned and cheap, so it is safe to
    /// call before and after any cartridge command. Returns nil if the pump did
    /// not answer.
    func readLoadStatus() -> TandemLoadStatusResponse? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        switch session.send(TandemLoadStatusRequest()) {
        case let .success(response):
            state.lastCartridgeEventDescription = response.localizedDescription
            return response
        case let .failure(error):
            log.error("LoadStatus failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Take over a load the pump has already started — either the user began it
    /// on the pump, or an earlier attempt succeeded without Trio seeing the
    /// reply. Mapping the pump's state onto ours avoids asking it to enter a
    /// mode it is already in.
    private func adoptExistingLoad(_ loadStatus: TandemLoadStatusResponse) {
        let stage: TandemCartridgeSession.Stage
        switch loadStatus.loadState {
        case .changeCartridge,
             .loadCartridge:
            stage = .changeMode
        case .primeTubing:
            stage = loadStatus.primeTubingStatus == .start ? .fillingTubing : .changeMode
        case .primeCannula,
             .primeNudge:
            stage = .tubingFilled
        case .invalid,
             .unknown:
            stage = .changeMode
        }
        state.cartridgeSession = TandemCartridgeSession(stage: stage, startedAt: Date.now)
        state.activeTempBasal = nil
        state.suspended = true
        state.cartridgeDisconnectConfirmedAt = nil
        state.confirmedSetPlacement = nil
        notifyStateDidChange()
    }

    /// Make sure the pump is not delivering before asking it to start a load.
    ///
    /// On a Mobi Trio can stop delivery itself, which is what the pump's own
    /// flow does. On a t:slim X2 there is no remote suspend at all, so the user
    /// has to stop insulin on the pump — saying that is far more useful than
    /// relaying a status byte.
    private func stopDeliveryForLoad() -> (any LocalizedError)? {
        refreshSuspendState()
        if state.suspended { return nil }

        guard state.pumpModel.supportsRemoteBasalControl else {
            return TandemCartridgeError.deliveryMustBeStoppedOnPump
        }

        log.info("Suspending delivery before starting the cartridge change")
        if case let .failure(error) = session.refreshTimeSinceReset() {
            return error
        }
        switch session.send(TandemSuspendPumpingRequest()) {
        case let .success(response):
            guard response.status == 0 else {
                log.error("Suspend before cartridge change refused with status \(response.status)")
                return TandemCartridgeError.deliveryMustBeStoppedOnPump
            }
            state.suspended = true
            state.activeTempBasal = nil
            return nil
        case let .failure(error):
            return error
        }
    }

    /// Re-read whether the pump is delivering, so the precondition is not judged
    /// on stale status.
    private func refreshSuspendState() {
        switch session.send(TandemHomeScreenMirrorRequest()) {
        case let .success(response):
            // SUSPEND(4) and HYPO_SUSPEND_BASAL_IQ(5) both mean delivery stopped.
            state.suspended = response.basalStatusIconId == 4 || response.basalStatusIconId == 5
        case let .failure(error):
            log.error("HomeScreenMirror failed before the cartridge change: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Convert a prime amount in units to the milliunits the pump expects,
    /// rejecting anything outside what pumpX2 validates.
    static func primeMilliunits(forUnits units: Double) -> UInt16? {
        guard units.isFinite, units > 0 else { return nil }
        let milliunits = (units * 1000).rounded()
        guard milliunits >= Double(TandemFillCannulaRequest.minPrimeMilliunits),
              milliunits <= Double(TandemFillCannulaRequest.maxPrimeMilliunits)
        else { return nil }
        return UInt16(milliunits)
    }

    /// Connect, authenticate and refresh the signing time reference. Every
    /// cartridge command is signed, so this runs before each of them.
    private func prepareForCartridgeCommand() -> (any LocalizedError)? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        if let error = ensureConnectedAndAuthenticated() {
            return error
        }
        if case let .failure(error) = session.refreshTimeSinceReset() {
            return error
        }
        return nil
    }

    /// Clear the session and, when the change actually completed, tell Trio the
    /// infusion set was replaced so the site tracker restarts its clock.
    private func completeCartridgeSession(recordSiteChange: Bool) {
        state.cartridgeSession = nil
        state.cartridgeDisconnectConfirmedAt = nil
        state.confirmedSetPlacement = nil
        state.lastCartridgeEventDescription = nil
        state.suspended = false
        // The pump is delivering again but its reservoir, basal and suspend
        // state are all stale now; make the next poll a real one.
        state.lastSync = .distantPast

        if recordSiteChange {
            emitCartridgeEvent(
                type: .replaceComponent(componentType: .infusionSet),
                title: "Infusion set changed",
                at: Date.now
            )
        }
        playFeedbackTone(.stateChange)
        notifyStateDidChange()
    }

    /// Emit a cartridge-related pump event.
    ///
    /// These carry no dose on purpose. Priming insulin never reaches the
    /// bloodstream as active insulin, so counting it as IOB would make Trio
    /// under-deliver for hours after every set change.
    private func emitCartridgeEvent(type: PumpEventType, title: String, at date: Date) {
        let raw = withUnsafeBytes(of: UInt32(date.timeIntervalSince1970).littleEndian) { Data($0) }
            + Data([Self.rawMarker(for: type)])
        emitPumpEvents(
            [NewPumpEvent(date: date, dose: nil, raw: raw, title: title, type: type)],
            replacePendingEvents: false
        )
    }

    private static func rawMarker(for type: PumpEventType) -> UInt8 {
        switch type {
        case .rewind: return 0xC0
        case .prime: return 0xC1
        default: return 0xC2
        }
    }
}
