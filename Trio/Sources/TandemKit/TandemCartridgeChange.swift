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
    case rejected(step: String, status: UInt8, detail: String?)
    case deliveryMustBeStoppedOnPump
    case suspendDidNotTake
    case bolusInProgress
    case alarmNotCleared(String)
    case noAlarmToAcknowledge
    case resumeRefused(status: UInt8, detail: String?)

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
        case let .rejected(step, status, detail):
            // The pump gives one status byte and no reason, so the detail is
            // what it said about itself immediately afterwards.
            if let detail = detail {
                return "The pump refused to \(step) (status \(status)). The pump reports: \(detail)."
            }
            return "The pump refused to \(step) (status \(status))."
        case .deliveryMustBeStoppedOnPump:
            return "The pump will not start a cartridge change while it is delivering insulin. Stop insulin on the pump first, then try again."
        case .suspendDidNotTake:
            return "Trio asked the pump to stop insulin and the pump accepted, but it is still delivering. Stop insulin on the pump itself, then try again."
        case .bolusInProgress:
            return "A bolus is being delivered. Wait for it to finish, then start the cartridge change."
        case let .alarmNotCleared(names):
            return "Trio asked the pump to acknowledge \(names), but the pump still reports it. Clear it in the pump's own app, then try again."
        case .noAlarmToAcknowledge:
            return "The pump is not reporting an alarm Trio can acknowledge from here."
        case let .resumeRefused(status, detail):
            var text =
                "The cartridge change is done, but the pump refused to restart insulin (status \(status)). Insulin is still stopped — resume it from the pump settings screen."
            if let detail = detail {
                text += " The pump reports: \(detail)."
            }
            return text
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

            // The pump will not begin a load while it is delivering: pumpX2
            // documents "insulin must be suspended" as the precondition. Meet
            // it, and confirm with the pump that it is met.
            if let error = self.stopDeliveryForLoad() {
                completion(error)
                return
            }

            switch self.session.send(TandemEnterChangeCartridgeModeRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    let detail = self.pumpStateSummary()
                    completion(TandemCartridgeError.rejected(
                        step: "start the cartridge change",
                        status: response.status,
                        detail: detail
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

    /// Step 2: the user has physically installed the new cartridge. Leaving
    /// change-cartridge mode is what makes the pump check it — on hardware,
    /// ExitChangeCartridgeMode immediately produced the detecting-cartridge
    /// stream (20%…100%), exactly as pumpX2 documents ("called once the new
    /// cartridge has been inserted"). It is a mid-flow step, not the finish.
    func confirmCartridgeInserted(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            if let error = self.requireOpenSession(stages: [.changeMode]) {
                completion(error)
                return
            }
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }

            switch self.session.send(TandemExitChangeCartridgeModeRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    completion(TandemCartridgeError.rejected(
                        step: "check the new cartridge",
                        status: response.status,
                        detail: self.pumpStateSummary()
                    ))
                    return
                }
                self.state.cartridgeSession?.stage = .cartridgeLoaded
                self.playFeedbackTone(.stateChange)
                self.notifyStateDidChange()
                completion(nil)
            case let .failure(error):
                self.state.lastSync = .distantPast
                completion(error)
            }
        }
    }

    /// Step 3: open fill-tubing mode. **Requires the set to be off the body.**
    ///
    /// Opening the mode is all Trio can do: on a Mobi the fill itself is
    /// driven by press-and-holding the button on the pump, and the pump
    /// refuses to leave the mode until some insulin has been pushed
    /// (prime status "entered, cannot exit"). The screen says so.
    func startFillTubing(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            if let error = self.requireOpenSession(stages: [.cartridgeLoaded, .tubingFilled]) {
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
                    completion(TandemCartridgeError.rejected(step: "start filling the tubing", status: response.status, detail: self.pumpStateSummary()))
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

    /// Step 4: stop filling the tubing.
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
                    completion(TandemCartridgeError.rejected(step: "stop filling the tubing", status: response.status, detail: self.pumpStateSummary()))
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

    /// Step 5 (Mobi only): prime the cannula. **Requires the set to be inserted.**
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
                    completion(TandemCartridgeError.rejected(step: "prime the cannula", status: response.status, detail: self.pumpStateSummary()))
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

    /// Step 6: resume insulin. The pump already left change-cartridge mode
    /// back when the new cartridge was detected, so there is nothing left to
    /// exit — finishing means undoing the suspend the change began with.
    func finishCartridgeChange(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            if let error = self.requireOpenSession(stages: [.tubingFilled, .cannulaFilled]) {
                completion(error)
                return
            }
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }

            // A load that was interrupted along the way leaves started-but-
            // not-finished alerts behind (incomplete fill tubing, incomplete
            // cartridge change, ...), and the pump will not resume delivery
            // over them. The user finishing the change IS the completion of
            // those operations, so clear the leftovers first — and only those;
            // a Low Insulin alert or any alarm is left standing to speak.
            if let leftovers = self.readActiveAlerts()?.incompleteLoadAlertBits, !leftovers.isEmpty {
                self.log.info("Clearing incomplete-load alerts before resuming: bits \(leftovers)")
                for bit in leftovers {
                    self.dismissNotification(bit: bit, type: .alert)
                }
                if let remaining = self.readActiveAlerts()?.incompleteLoadAlertBits, !remaining.isEmpty {
                    self.log.error("Incomplete-load alerts still active after dismissal: bits \(remaining)")
                }
            }
            if case let .failure(error) = self.session.refreshTimeSinceReset() {
                completion(error)
                return
            }

            switch self.session.send(TandemResumePumpingRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    // The load is done either way; what failed is restarting
                    // insulin, and the user must hear that in those words,
                    // with the pump's own account of why attached.
                    let detail = self.pumpStateSummary()
                    self.completeCartridgeSession(recordSiteChange: true, resumed: false)
                    completion(TandemCartridgeError.resumeRefused(status: response.status, detail: detail))
                    return
                }
                self.completeCartridgeSession(recordSiteChange: true, resumed: true)
                completion(nil)
            case let .failure(error):
                // Unknown whether the resume landed. Close the change (the
                // load itself is complete), assume still suspended so nothing
                // doses on top of an unknown state, and force a resync.
                self.completeCartridgeSession(recordSiteChange: true, resumed: false)
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
                self.completeCartridgeSession(recordSiteChange: false, resumed: false)
                completion(error)
                return
            }

            var firstFailure: (any LocalizedError)?
            let stage = self.state.cartridgeSession?.stage

            if stage == .fillingTubing {
                switch self.session.send(TandemExitFillTubingModeRequest()) {
                case let .success(response) where response.status != 0:
                    // Seen live: the pump refuses to leave fill-tubing mode
                    // before any insulin has moved. It stays in the mode, so
                    // at least stop the prime, and let the summary tell the
                    // user the pump is still waiting on its button.
                    self.log.error("Cancel: pump refused to leave fill-tubing mode (status \(response.status)); sending a prime suspend")
                    _ = self.session.send(TandemPrimeTubingSuspendRequest())
                case let .failure(error):
                    self.log.error("Cancel: exiting fill-tubing mode failed: \(error.localizedDescription)")
                    firstFailure = firstFailure ?? error
                    _ = self.session.send(TandemPrimeTubingSuspendRequest())
                default:
                    break
                }
                _ = self.session.refreshTimeSinceReset()
            }

            // Only a pump still in change-cartridge mode has a mode to leave.
            // From the detection step onwards the pump has already exited it —
            // sending the exit again would not be a cancel, it would ask the
            // pump to detect whatever cartridge is in it.
            if stage == .changeMode {
                if case let .failure(error) = self.session.send(TandemExitChangeCartridgeModeRequest()) {
                    self.log.error("Cancel: exiting change-cartridge mode failed: \(error.localizedDescription)")
                    firstFailure = firstFailure ?? error
                }
            }

            self.completeCartridgeSession(recordSiteChange: false, resumed: false)
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
            if self.pumpStateSummary() == nil {
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

            // Two stream events advance Trio's own stage. Detection means the
            // pump has accepted the new cartridge (it streams this the moment
            // change mode is exited), and the cannula-filled confirmation
            // means a prime that finished on the pump is not left looking
            // incomplete.
            if case .detectingCartridge = event,
               self.state.cartridgeSession?.stage == .changeMode
            {
                self.state.cartridgeSession?.stage = .cartridgeLoaded
            }
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
        case .changeCartridge:
            stage = .changeMode
        case .loadCartridge:
            // Past detection: the cartridge is in and the pump has checked it.
            stage = .cartridgeLoaded
        case .primeTubing:
            stage = .fillingTubing
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
    /// pumpX2 states the precondition for `EnterChangeCartridgeMode` outright —
    /// *insulin must be suspended* — so this is not a guess. On a Mobi Trio can
    /// suspend remotely; on a t:slim X2 there is no remote suspend at all, so
    /// the user has to stop insulin on the pump, and saying that is far more
    /// useful than relaying a status byte.
    ///
    /// Everything here is checked against the pump rather than against Trio's
    /// own record, because the whole point is to establish a state the pump
    /// agrees with.
    private func stopDeliveryForLoad() -> (any LocalizedError)? {
        // The pump runs one insulin operation at a time. In microbolus-basal
        // mode Trio boluses every few minutes, so a change started at the wrong
        // moment lands on a pump that is mid-delivery.
        if bolusIsInProgress() {
            return TandemCartridgeError.bolusInProgress
        }

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
        case let .failure(error):
            return error
        }

        // Do not take the suspend's own status byte as proof. Ask the pump what
        // it is doing: an accepted-but-ineffective suspend would otherwise
        // resurface as an unexplained refusal one command later, which is
        // exactly the failure this path exists to prevent.
        _ = session.refreshTimeSinceReset()
        let iconId = refreshSuspendState()
        guard state.suspended else {
            log.error("Suspend accepted but the pump still shows basal icon \(iconId.map { String($0) } ?? "unknown")")
            return TandemCartridgeError.suspendDidNotTake
        }
        state.activeTempBasal = nil
        return nil
    }

    /// True while the pump is requesting or delivering a bolus.
    private func bolusIsInProgress() -> Bool {
        switch session.send(TandemCurrentBolusStatusRequest()) {
        case let .success(status):
            // 1 = delivering, 2 = requesting, 0 = already delivered or invalid.
            return status.statusId == 1 || status.statusId == 2
        case let .failure(error):
            // Not knowing is not the same as knowing there is one, and the next
            // command will fail on its own if the pump is unreachable.
            log.error("CurrentBolusStatus failed before the cartridge change: \(error.localizedDescription)")
            return false
        }
    }

    /// Re-read whether the pump is delivering, so the precondition is not judged
    /// on stale status.
    @discardableResult
    private func refreshSuspendState() -> UInt8? {
        switch session.send(TandemHomeScreenMirrorRequest()) {
        case let .success(response):
            // SUSPEND(4) and HYPO_SUSPEND_BASAL_IQ(5) both mean delivery stopped.
            state.suspended = response.basalStatusIconId == 4 || response.basalStatusIconId == 5
            return response.basalStatusIconId
        case let .failure(error):
            log.error("HomeScreenMirror failed before the cartridge change: \(error.localizedDescription)")
            return nil
        }
    }

    /// Ask the pump what it is doing, in one line, and record it for the screen.
    ///
    /// Used after a refusal and by the "check what the pump is doing" button.
    /// `EnterChangeCartridgeMode` requires insulin to be suspended and says
    /// nothing about why it declined, so whether insulin is actually stopped is
    /// the most useful fact to report — more than the load state, which is idle
    /// by definition before a change starts.
    @discardableResult
    func pumpStateSummary() -> String? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        let alarms = readActiveAlarms()
        let alerts = readActiveAlerts()
        let iconId = refreshSuspendState()
        let loadStatus = readLoadStatus()
        log.info(
            "Pump state: \(loadStatus?.diagnosticDescription ?? "load=?") basalIcon=\(iconId.map { String($0) } ?? "?") alarms=\(alarms.map { String($0.bitmask, radix: 16) } ?? "?") alerts=\(alerts.map { String($0.bitmask, radix: 16) } ?? "?")"
        )

        var parts: [String] = []
        // The alarm leads because it explains everything after it: an alarming
        // pump has already stopped insulin and will refuse new operations.
        if let alarmNames = alarms?.localizedNames {
            parts.append(String(localized: "the pump is alarming: \(alarmNames)"))
        }
        if iconId != nil {
            parts.append(
                state.suspended
                    ? String(localized: "insulin is stopped")
                    : String(localized: "insulin is still running")
            )
        }
        if let loadStatus = loadStatus {
            parts.append(loadStatus.localizedDescription)
        }
        if let alertNames = alerts?.localizedLoadRelatedNames {
            parts.append(String(localized: "alerts: \(alertNames)"))
        }
        guard !parts.isEmpty else { return nil }
        let summary = parts.joined(separator: ", ")
        state.lastCartridgeEventDescription = summary
        return summary
    }

    /// Read the pump's active-alarm bitmask and remember it, so the cartridge
    /// screen can offer to acknowledge the ones the change itself addresses.
    private func readActiveAlarms() -> TandemAlarmStatusResponse? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        switch session.send(TandemAlarmStatusRequest()) {
        case let .success(response):
            state.activeAlarmBits = response.bitmask
            return response
        case let .failure(error):
            log.error("AlarmStatus failed: \(error.localizedDescription)")
            state.activeAlarmBits = nil
            return nil
        }
    }

    private func readActiveAlerts() -> TandemAlertStatusResponse? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        switch session.send(TandemAlertStatusRequest()) {
        case let .success(response):
            state.activeAlertBits = response.bitmask
            return response
        case let .failure(error):
            log.error("AlertStatus failed: \(error.localizedDescription)")
            state.activeAlertBits = nil
            return nil
        }
    }

    /// Dismiss one notification, logging rather than failing on refusal — the
    /// caller verifies the outcome by re-reading the status bitmask, which is
    /// the only proof that counts.
    private func dismissNotification(bit: Int, type: TandemDismissNotificationRequest.NotificationType) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        if case let .failure(error) = session.refreshTimeSinceReset() {
            log.error("Time refresh before dismissing bit \(bit) failed: \(error.localizedDescription)")
            return
        }
        switch session.send(TandemDismissNotificationRequest(
            notificationId: UInt32(bit),
            notificationType: type
        )) {
        case let .success(response):
            if response.status != 0 {
                log.error("Dismiss of \(type) bit \(bit) returned status \(response.status)")
            }
        case let .failure(error):
            log.error("Dismiss of \(type) bit \(bit) failed: \(error.localizedDescription)")
        }
    }

    /// Acknowledge the active alarms whose remedy is this cartridge change —
    /// and only those. The equivalent of tapping OK on the pump app's alarm
    /// banner, which on a Mobi is the only place an alarm can be acknowledged.
    ///
    /// Deliberate constraints:
    /// - runs only on an explicit button press, with the alarm named on screen;
    /// - touches only the cartridge-change alarm family (cartridge faults,
    ///   empty cartridge, cartridge removed, occlusion, resume-pump) — a
    ///   temperature or hardware alarm is not Trio's to clear;
    /// - verifies by re-reading AlarmStatus, because the dismiss encoding's
    ///   `notificationId` is a reconstruction (pumpX2 never sends it) and the
    ///   reply's status byte alone is not proof.
    func acknowledgeCartridgeAlarms(completion: @escaping ((any LocalizedError)?) -> Void) {
        commandQueue.async {
            if let error = self.prepareForCartridgeCommand() {
                completion(error)
                return
            }
            let alarmBits = self.readActiveAlarms()?.cartridgeRelatedBits ?? []
            let alertBits = self.readActiveAlerts()?.incompleteLoadAlertBits ?? []
            guard !alarmBits.isEmpty || !alertBits.isEmpty else {
                self.pumpStateSummary()
                self.notifyStateDidChange()
                completion(TandemCartridgeError.noAlarmToAcknowledge)
                return
            }

            self.log.info("Acknowledging pump notifications: alarm bits \(alarmBits), alert bits \(alertBits)")
            for bit in alarmBits {
                self.dismissNotification(bit: bit, type: .alarm)
            }
            for bit in alertBits {
                self.dismissNotification(bit: bit, type: .alert)
            }

            // The re-read is the actual verdict.
            let alarmsAfter = self.readActiveAlarms()?.cartridgeRelatedBits ?? []
            let alertsAfter = self.readActiveAlerts()?.incompleteLoadAlertBits ?? []
            self.pumpStateSummary()
            self.notifyStateDidChange()
            if !alarmsAfter.isEmpty || !alertsAfter.isEmpty {
                var seen = Set<String>()
                let names = (alarmsAfter.map(TandemAlarmStatusResponse.name(forBit:))
                    + alertsAfter.compactMap { TandemAlertStatusResponse.loadRelated[$0] })
                    .filter { seen.insert($0).inserted }
                    .joined(separator: " + ")
                completion(TandemCartridgeError.alarmNotCleared(names))
            } else {
                completion(nil)
            }
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
    private func completeCartridgeSession(recordSiteChange: Bool, resumed: Bool) {
        state.cartridgeSession = nil
        state.cartridgeDisconnectConfirmedAt = nil
        state.confirmedSetPlacement = nil
        state.lastCartridgeEventDescription = nil
        state.suspended = !resumed
        // The pump's reservoir, basal and suspend state are all stale now;
        // make the next poll a real one.
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
