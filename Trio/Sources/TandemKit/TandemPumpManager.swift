import AudioToolbox
import CoreBluetooth
import Foundation
import HealthKit
import LoopKit

/// Pump driver for the Tandem **t:slim X2** and **Mobi**.
///
/// Capability summary (dictated by the reverse-engineered protocol):
/// - Pairing + live status monitoring on both models. The t:slim X2 on software
///   7.1-7.6 uses the 16-character challenge/response code; software 7.7+ and
///   every Mobi use the 6-digit EC-JPAKE handshake.
/// - Remote bolus on t:slim X2 software 7.6+ (API 2.5) and on the Mobi, gated
///   behind an explicit user opt-in ("remote bolus"), delivered through the
///   pump's own permission/initiate/status message flow.
/// - Remote basal control — temp rate, suspend, resume — on the **Mobi only**.
///   Those opcodes are not implemented in t:slim X2 firmware, where Control-IQ
///   owns basal delivery. So:
///   - on a **Mobi**, Trio can close the loop natively (see
///     TandemNativeBasal.swift), with the pump's own Control-IQ turned off;
///   - on a **t:slim X2**, Trio is a monitor, treatment log and remote bolus
///     interface, unless the experimental microbolus-basal mode is enabled
///     (see TandemMicrobolusBasal.swift).
class TandemPumpManager: DeviceManager {
    static let pluginIdentifier = "Tandem"
    let managerIdentifier = "Tandem"
    var localizedTitle: String { state.pumpModel.localizedTitle }

    // Internal (not private): the microbolus-basal engine lives in a separate
    // file (TandemMicrobolusBasal.swift) and needs to log through this instance.
    let log = TandemLogger(category: "TandemPumpManager")

    let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    /// Serializes all pump exchanges; session.send blocks on responses.
    // Internal (not private): the microbolus-basal engine extension in
    // TandemMicrobolusBasal.swift dispatches onto and asserts this queue.
    let commandQueue = DispatchQueue(label: "org.nightscout.trio.TandemPumpManager.commandQueue", qos: .userInitiated)

    var state: TandemPumpState
    private var oldState: TandemPumpState

    let bluetooth: TandemBluetoothManager
    let session: TandemPumpSession

    var rawState: PumpManager.RawStateValue {
        state.rawValue
    }

    init(state: TandemPumpState) {
        self.state = state
        oldState = TandemPumpState(rawValue: state.rawValue)
        bluetooth = TandemBluetoothManager()
        session = TandemPumpSession(bluetooth: bluetooth)
        session.delegate = self
        bluetooth.peripheralIdentifier = state.peripheralIdentifier
        session.insulinDeliveryActionsEnabled = state.insulinDeliveryActionsAllowed
        // Only the legacy flow can restore a signing key without talking to the
        // pump — a JPAKE pump's key is salted with a nonce it issues on each
        // connection, so it is established during authentication instead.
        if state.pairingCodeType == .legacy16, !state.pairingCode.isEmpty {
            session.setAuthenticationKey(Data(state.pairingCode.utf8))
        }
    }

    required convenience init?(rawState: RawStateValue) {
        self.init(state: TandemPumpState(rawValue: rawState))
    }

    var isOnboarded: Bool {
        state.isOnboarded
    }

    var delegateQueue: DispatchQueue! {
        get { pumpDelegate.queue }
        set { pumpDelegate.queue = newValue }
    }

    var pumpManagerDelegate: PumpManagerDelegate? {
        get { pumpDelegate.delegate }
        set { pumpDelegate.delegate = newValue }
    }

    // MARK: - Capabilities

    /// The Tandem BLE bolus cargo is in milliunits (0.001 U). Empirically
    /// confirmed on firmware 7.6.0.1 via the settings minimum-dose test: the
    /// pump ACCEPTS a 0.05 U remote bolus and REJECTS smaller amounts
    /// (status 1 at initiate), matching pumpx2's 0.05 U floor. Volumes
    /// therefore run from that floor up to 25 U in 0.001 U steps. The first
    /// element (0.05) also becomes Trio's `bolusIncrement` preference, so
    /// oref never recommends an SMB the pump would refuse. The
    /// microbolus-basal engine accrues in milliunits and delivers pulses at
    /// or above the floor, so sub-floor amounts are not lost — they
    /// accumulate until they clear it.
    static let onboardingSupportedBolusVolumes: [Double] =
        (50 ... 25000).map { Double($0) / 1000 }

    /// Both models: basal 0-15 U/hr. 0.001 U/hr granularity so the
    /// microbolus-basal engine can honor fine-grained oref rates; the pump's
    /// own profile is never written by Trio.
    static let onboardingSupportedBasalRates: [Double] =
        (0 ... 15000).map { Double($0) / 1000 }

    static var onboardingSupportedMaximumBolusVolumes: [Double] {
        onboardingSupportedBolusVolumes
    }

    /// Tandem profiles allow 16 segments.
    static var onboardingMaximumBasalScheduleEntryCount: Int { 16 }

    var supportedBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    var supportedMaximumBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    var supportedBasalRates: [Double] { Self.onboardingSupportedBasalRates }
    var maximumBasalScheduleEntryCount: Int { Self.onboardingMaximumBasalScheduleEntryCount }
    var minimumBasalScheduleEntryDuration: TimeInterval { .minutes(15) }

    // Arithmetic floor-to-milliunit instead of scanning the supported-value
    // arrays (25k/15k entries). The +1e-6 nudge keeps binary-float artifacts
    // (e.g. 0.003 * 1000 == 2.999...) from flooring one milliunit low.
    // Amounts below the pump's 0.05 U remote-bolus floor round to 0 (not
    // deliverable), matching the supported-volumes array.
    func roundToSupportedBolusVolume(units: Double) -> Double {
        let milliunits = (units * 1000 + 1E-6).rounded(.down)
        guard milliunits >= Double(TandemInitiateBolusRequest.minBolusMilliunits) else { return 0 }
        return min(milliunits, 25000) / 1000
    }

    func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        let milliunitsPerHour = (unitsPerHour * 1000 + 1E-6).rounded(.down)
        return min(max(milliunitsPerHour, 0), 15000) / 1000
    }

    var debugDescription: String {
        state.debugDescription
    }

    // MARK: - Alerts (pump alerts surface on the pump itself)

    func acknowledgeAlert(alertIdentifier _: LoopKit.Alert.AlertIdentifier, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [LoopKit.Alert.Sound] { [] }

    private func device(_ state: TandemPumpState) -> HKDevice {
        HKDevice(
            name: state.pumpModel.localizedTitle,
            manufacturer: "Tandem Diabetes Care",
            model: state.pumpModelNumber.isEmpty ? state.pumpModel.shortTitle : state.pumpModelNumber,
            hardwareVersion: nil,
            firmwareVersion: state.firmwareVersion.isEmpty ? nil : state.firmwareVersion,
            softwareVersion: nil,
            localIdentifier: state.pumpSerial.isEmpty ? nil : state.pumpSerial,
            udiDeviceIdentifier: nil
        )
    }
}

extension TandemPumpManager {
    var pumpRecordsBasalProfileStartEvents: Bool { false }

    var pumpReservoirCapacity: Double { state.pumpModel.reservoirCapacity }

    var lastSync: Date? { state.lastSync }

    var status: PumpManagerStatus {
        status(state)
    }

    private func status(_ state: TandemPumpState) -> PumpManagerStatus {
        PumpManagerStatus(
            timeZone: TimeZone.current,
            device: device(state),
            pumpBatteryChargeRemaining: state.batteryPercent.map { Double($0) / 100 },
            basalDeliveryState: state.basalDeliveryState,
            bolusState: state.bolusDeliveryState,
            insulinType: state.insulinType
        )
    }

    func setMustProvideBLEHeartbeat(_: Bool) {}

    func estimatedDuration(toBolus units: Double) -> TimeInterval {
        // Rough estimate: the t:slim X2 delivers a standard bolus at
        // several units per minute; used only for progress display.
        units / 6.0 * TimeInterval(minutes: 1)
    }

    func createBolusProgressReporter(reportingOn: DispatchQueue) -> (any DoseProgressReporter)? {
        guard let bolus = state.activeBolus else { return nil }
        return TandemDoseProgressReporter(
            pumpManager: self,
            units: bolus.units,
            startDate: bolus.startDate,
            estimatedDuration: estimatedDuration(toBolus: bolus.units),
            reportingQueue: reportingOn
        )
    }

    // MARK: - Connection helpers

    /// Connect, authenticate if needed, and refresh identity/time state.
    /// Must be called on commandQueue.
    // Internal (not private): the native-basal engine in TandemNativeBasal.swift
    // needs the same connect-and-authenticate preamble.
    func ensureConnectedAndAuthenticated() -> TandemSessionError? {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        guard !state.pairingCode.isEmpty else {
            return .notAuthenticated
        }

        if !bluetooth.isConnected {
            var connectionError: TandemConnectionError?
            let semaphore = DispatchSemaphore(value: 0)
            bluetooth.ensureConnected { error in
                connectionError = error
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 35) == .success else {
                return .timeout
            }
            if let error = connectionError {
                return .transport(error)
            }
        }

        // Authenticate per LINK, not per "did we just connect". A signing key
        // belongs to the connection whose handshake produced it — JPAKE keys
        // are derived from a per-connection nonce — and CoreBluetooth can
        // re-establish a dropped link on its own (state restoration, pending
        // connects). A key carried across that boundary signs every control
        // command with the wrong nonce, and the pump answers each one with its
        // generic ErrorResponse while unsigned status reads keep working.
        if !session.isAuthenticatedForCurrentLink {
            if let error = authenticateSession() {
                return error
            }
            if case let .failure(error) = refreshIdentity() {
                return error
            }
        }

        return nil
    }

    /// Tear the link down and bring it back with a fresh handshake.
    ///
    /// Two failure modes end here, and a fresh link cures both. A **stale
    /// signing key**: a JPAKE key is only valid on the link whose nonce
    /// produced it, so a key carried across a silent CoreBluetooth reconnect
    /// gets every signed command refused (this is what the annunciation
    /// retry recovers from). And a **wedged link**: a connection CoreBluetooth
    /// still reports as up but that has stopped carrying answers, which the
    /// status sync recovers from — over such a link every read times out
    /// forever while the pump screen says "Connected".
    ///
    /// A pump that was just dropped on purpose can be slow to take the next
    /// connection, so the reconnect gets a second attempt before giving up —
    /// the first field run of this path ended in a bare connect timeout that
    /// swallowed the far more informative refusal before it.
    ///
    /// Must be called on commandQueue.
    func reauthenticateOverFreshLink(notes: inout [String]) -> TandemSessionError? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        let started = Date.now
        bluetooth.disconnect()
        var waited: TimeInterval = 0
        while bluetooth.isConnected, waited < 10 {
            Thread.sleep(forTimeInterval: 0.2)
            waited += 0.2
        }
        notes.append(bluetooth.isConnected
            ? "re-key: link did NOT drop within 10s of disconnecting"
            : String(format: "re-key: link dropped after %.1fs", waited))

        var lastError: TandemSessionError = .notConnected
        for attempt in 1 ... 2 {
            if let error = ensureConnectedAndAuthenticated() {
                notes.append("re-key: reconnect attempt \(attempt) failed — \(error.localizedDescription)")
                lastError = error
                continue
            }
            if case let .failure(error) = session.refreshTimeSinceReset() {
                notes.append("re-key: time refresh after reconnect failed — \(error.localizedDescription)")
                lastError = error
                continue
            }
            notes.append(String(
                format: "re-key: reconnected and re-keyed, %.1fs total",
                Date.now.timeIntervalSince(started)
            ))
            return nil
        }
        return lastError
    }

    /// Run whichever pairing handshake this pump uses.
    ///
    /// JPAKE pumps re-key on every connection: the signing key is derived from
    /// the stored shared secret plus a nonce the pump issues now, so this is not
    /// a no-op even for an already-paired pump. Only the long-lived derived
    /// secret is persisted, and only when it changes.
    private func authenticateSession() -> TandemSessionError? {
        switch state.pairingCodeType {
        case .legacy16:
            if case let .failure(error) = session.authenticate(pairingCode: state.pairingCode) {
                return error
            }
            return nil
        case .jpake6:
            let result = session.authenticateJpake(
                pairingCode: state.pairingCode,
                derivedSecret: state.jpakeDerivedSecret
            )
            switch result {
            case let .success(keys):
                if keys.derivedSecret != state.jpakeDerivedSecret {
                    state.jpakeDerivedSecret = keys.derivedSecret
                    notifyStateDidChange()
                }
                return nil
            case let .failure(error):
                return error
            }
        }
    }

    private func refreshIdentity() -> Result<Void, TandemSessionError> {
        switch session.send(TandemApiVersionRequest()) {
        case let .success(response):
            state.apiVersionMajor = Int(response.majorVersion)
            state.apiVersionMinor = Int(response.minorVersion)
        case let .failure(error):
            return .failure(error)
        }

        switch session.send(TandemPumpVersionRequest()) {
        case let .success(response):
            state.pumpSerial = String(response.serialNum)
            state.pumpModelNumber = String(response.modelNum)
            state.firmwareVersion = String(response.armSwVer)
        case let .failure(error):
            return .failure(error)
        }

        // The advertised Bluetooth name is the primary way to tell the models
        // apart, but a peripheral restored by CoreBluetooth may not carry one.
        // The API version is an unambiguous fallback: the Mobi starts at 3.5,
        // the t:slim X2 stops at 3.4.
        if let model = TandemPumpModel.from(bluetoothName: bluetooth.peripheralName)
            ?? TandemPumpModel.from(apiVersionMajor: state.apiVersionMajor, minor: state.apiVersionMinor),
            model != state.pumpModel
        {
            log.info("Identified pump as \(model.localizedTitle)")
            state.pumpModel = model
            // A pump that turns out not to support remote basal must not keep a
            // basal opt-in that would let Trio send commands it cannot honor.
            if !model.supportsRemoteBasalControl, state.remoteBasalEnabled {
                state.remoteBasalEnabled = false
                state.activeTempBasal = nil
                session.insulinDeliveryActionsEnabled = state.insulinDeliveryActionsAllowed
            }
        }

        if case let .failure(error) = session.refreshTimeSinceReset() {
            return .failure(error)
        }

        notifyStateDidChange()
        return .success(())
    }

    // MARK: - Status polling

    func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        commandQueue.async {
            guard Date.now.timeIntervalSince(self.state.lastSync) > .minutes(2) else {
                self.log.info("Skipping status update - data is fresh")
                completion?(nil)
                return
            }
            self.syncPumpData(completion: completion)
        }
    }

    /// A pushed pump event lands on top of a status read this recent is ignored:
    /// the read it would ask for has just happened.
    static let pushCoalescingInterval: TimeInterval = 10

    /// Identifier of the phone notification Trio raises for a pump alarm.
    ///
    /// It contains "ERROR" deliberately: Trio routes an alert whose identifier
    /// names a fault or error as an error-class notification that deep-links to
    /// the pump screen, and posts it regardless of the pump-warnings setting.
    /// An alarming pump has stopped insulin, and on a Mobi — which has no
    /// display of its own — this notification is the only way the user finds
    /// out at all.
    static let alarmAlertIdentifier = "tandemPumpAlarmError"

    /// Raise, update or retract the phone notification for the pump's alarm
    /// state. Called only after a successful alarm read, so a lost connection
    /// never reads as "the alarm cleared".
    ///
    /// Only alarms notify. Alerts are the pump's advisory tier and do not stop
    /// delivery; putting Low Insulin on the lock screen every few minutes would
    /// teach people to ignore the one notification that matters.
    func updateAlarmNotification() {
        // With no delegate attached there is nothing to hand the alert to, and
        // recording it as notified would mean the next poll saw no change and
        // never tried again. Leave the bits unrecorded instead.
        guard pumpDelegate.delegate != nil else { return }

        let bits = state.activeAlarmBits ?? 0
        guard bits != state.notifiedAlarmBits else { return }
        state.notifiedAlarmBits = bits

        let identifier = Alert.Identifier(
            managerIdentifier: managerIdentifier,
            alertIdentifier: Self.alarmAlertIdentifier
        )

        guard bits != 0, let names = state.activeAlarmNames else {
            log.info("Pump alarms cleared; retracting the alarm notification")
            pumpDelegate.notify { delegate in
                delegate?.retractAlert(identifier: identifier)
            }
            return
        }

        log.info("Pump alarm active: \(names); raising a notification")
        let content = Alert.Content(
            title: String(localized: "Pump Alarm"),
            body: String(
                localized: "\(names). The pump has stopped insulin and will refuse commands until the alarm is acknowledged."
            ),
            acknowledgeActionButtonLabel: String(localized: "OK")
        )
        let alert = Alert(
            identifier: identifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate
        )
        pumpDelegate.notify { delegate in
            delegate?.issueAlert(alert)
        }
    }

    /// Read the pump now, ignoring the two-minute freshness window.
    ///
    /// This is what the pump screen's refresh does. It deliberately does not
    /// clear `lastSync` first: a refresh that fails would otherwise erase the
    /// record of the last good read, and the screen would report a pump it has
    /// been talking to all day as never synced.
    func refreshPumpData(completion: ((Date?) -> Void)? = nil) {
        commandQueue.async {
            self.syncPumpData(completion: completion)
        }
    }

    /// Full status refresh. Must be called on commandQueue.
    ///
    /// One sweep of reads — and, when the sweep fails in a way only the link
    /// can explain, one retry over a deliberately torn-down and re-keyed
    /// connection. CoreBluetooth happily holds a connection to a pump that has
    /// stopped answering, so without the retry every poll spent its timeouts
    /// on the same wedged link: the pump screen said "Connected" while the
    /// sync aged into signal loss, and the dosing freshness gates failed
    /// closed on the stale sync. Same cure the annunciation path already uses,
    /// applied to the read everything else depends on.
    private func syncPumpData(completion: ((Date?) -> Void)?) {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        // Only a link that was already up is worth recycling: when the pump is
        // simply out of range the connect attempt itself just failed, and a
        // second attempt right now would spend another timeout saying so.
        let linkWasUp = bluetooth.isConnected
        var outcome = runSyncSweep()

        if !outcome.succeeded, outcome.linkShapedFailure, linkWasUp {
            var notes: [String] = []
            if let error = reauthenticateOverFreshLink(notes: &notes) {
                log.error(
                    "Recycling the silent link failed: \(error.localizedDescription) (\(notes.joined(separator: "; ")))"
                )
            } else {
                log.info("Recycled a silent link; retrying the status read (\(notes.joined(separator: "; ")))")
                outcome = runSyncSweep()
            }
        }

        notifyStateDidChange()
        completion?(outcome.succeeded ? state.lastSync : nil)
    }

    /// Outcome of one sweep of status reads.
    private struct SyncSweepOutcome {
        var succeeded = false
        /// A failure only the link can explain — timeout, disconnect,
        /// transport error, unparseable reply — as opposed to the pump
        /// answering and refusing. Only these are worth a reconnect.
        var linkShapedFailure = false
    }

    /// One pass of the status reads. Must be called on commandQueue.
    private func runSyncSweep() -> SyncSweepOutcome {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        var outcome = SyncSweepOutcome()

        if let error = ensureConnectedAndAuthenticated() {
            log.error("Sync failed to connect: \(error.localizedDescription)")
            outcome.linkShapedFailure = Self.isLinkShapedFailure(error)
            return outcome
        }

        var encounteredError = false

        // A failed core read fails the sweep. When the failure is link-shaped
        // the rest of the sweep is abandoned too: each remaining read would
        // spend its own 12-second timeout on a link that has already proven
        // silent, and the caller is about to recycle it anyway. A pump that
        // answers with a refusal keeps the sweep going — the link is fine.
        func coreReadFailed(_ name: String, _ error: TandemSessionError) -> Bool {
            encounteredError = true
            log.error("\(name) failed: \(error.localizedDescription)")
            if Self.isLinkShapedFailure(error) {
                outcome.linkShapedFailure = true
                return true
            }
            return false
        }

        switch session.send(TandemInsulinStatusRequest()) {
        case let .success(response):
            state.reservoir = Double(response.currentInsulinAmount)
            state.reservoirIsEstimate = response.isEstimate
            pumpDelegate.notify { delegate in
                delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoir, at: Date.now) { _ in }
            }
        case let .failure(error):
            if coreReadFailed("InsulinStatus", error) { return outcome }
        }

        let batteryResult: Result<Int, TandemSessionError>
        if state.apiVersionMajor > 2 || (state.apiVersionMajor == 2 && state.apiVersionMinor >= 5) {
            batteryResult = session.send(TandemCurrentBatteryV2Request()).map { Int($0.currentBatteryIbc) }
        } else {
            batteryResult = session.send(TandemCurrentBatteryV1Request()).map { Int($0.currentBatteryIbc) }
        }
        switch batteryResult {
        case let .success(percent):
            state.batteryPercent = percent
        case let .failure(error):
            if coreReadFailed("CurrentBattery", error) { return outcome }
        }

        switch session.send(TandemCurrentBasalStatusRequest()) {
        case let .success(response):
            state.profileBasalRate = Double(response.profileBasalRate) / 1000
            state.currentBasalRate = Double(response.currentBasalRate) / 1000
        case let .failure(error):
            if coreReadFailed("CurrentBasalStatus", error) { return outcome }
        }

        switch session.send(TandemControlIQInfoV1Request()) {
        case let .success(response):
            state.controlIQEnabled = response.closedLoopEnabled
        case let .failure(error):
            // Not fatal: older firmware without Control-IQ.
            log.error("ControlIQInfo failed: \(error.localizedDescription)")
        }

        switch session.send(TandemHomeScreenMirrorRequest()) {
        case let .success(response):
            // BasalStatusIcon: SUSPEND(4) and HYPO_SUSPEND_BASAL_IQ(5) both
            // mean delivery is suspended (pumpx2 HomeScreenMirrorResponse enum).
            state.suspended = response.basalStatusIconId == 4 || response.basalStatusIconId == 5
        case let .failure(error):
            log.error("HomeScreenMirror failed: \(error.localizedDescription)")
        }

        session.refreshTimeSinceReset()

        if state.supportsRemoteBolus {
            reconcileBolusStatus()
        }

        // A Mobi has no screen, so Trio is the only place its alarms can be
        // seen or acknowledged — reading them only inside the cartridge flow
        // meant an alarming pump looked perfectly normal everywhere else. Both
        // are unsigned current-status queries, ungated and cheap, and they run
        // last so nothing dosing depends on waits behind them. A read that
        // times out is left alone for half an hour rather than costing every
        // loop cycle 12 seconds — and is then tried again, because an alarm a
        // Mobi cannot display itself must not stay unreported because of one
        // lost read.
        if !state.alarmReadSuppressed {
            _ = readActiveAlarms()
        }
        if !state.alertReadSuppressed {
            _ = readActiveAlerts()
        }

        // Drop a temp basal the pump has already finished, so the reported
        // basal delivery state does not claim a temp rate that expired.
        if let temp = state.activeTempBasal, !temp.isActive() {
            log.info("Temp basal \(temp.unitsPerHour) U/hr ended")
            state.activeTempBasal = nil
        }

        if !encounteredError {
            state.lastSync = Date.now
            outcome.succeeded = true
        }
        return outcome
    }

    /// True when a failure is one a fresh connection can cure — the link went
    /// silent or produced garbage — rather than the pump answering and
    /// refusing. Reconnecting over a refusal would change nothing, but a link
    /// that stops carrying answers stays "connected" in CoreBluetooth's eyes
    /// indefinitely, so tearing it down is the only recovery there is.
    static func isLinkShapedFailure(_ error: TandemSessionError) -> Bool {
        switch error {
        case .invalidResponse,
             .notConnected,
             .timeout,
             .transport:
            return true
        case .insulinDeliveryActionsDisabled,
             .keyConfirmationFailed,
             .notAuthenticated,
             .pairingFailed,
             .pumpRejected,
             .requestInFlight,
             .staleTimeSinceReset:
            return false
        }
    }

    /// Grace period after which an active bolus the pump shows no trace of is
    /// assumed not to have delivered, so the single-bolus gate is released.
    private static let activeBolusGracePeriod: TimeInterval = .minutes(5)

    /// Reconcile bolus state with the pump. Reports finished boluses (from any
    /// source) to the delegate exactly once, finalizes our tracked bolus, and
    /// releases a stuck uncertain bolus that never registered on the pump.
    /// Must be called on commandQueue.
    private func reconcileBolusStatus() {
        let lastBolus: TandemLastBolusStatusV2Response
        switch session.send(TandemLastBolusStatusV2Request()) {
        case let .success(response): lastBolus = response
        case let .failure(error):
            log.error("LastBolusStatus failed: \(error.localizedDescription)")
            return
        }

        guard lastBolus.bolusId != 0 else {
            checkStuckActiveBolus()
            return
        }

        let units = Double(lastBolus.deliveredVolume) / 1000

        // Case 1: this is our tracked (SMB/manual) bolus, now concluded.
        // Finalize by re-reporting the DELIVERED amount at the SAME timestamp
        // the initial (mutable) event used — Trio dedups pump events by exact
        // timestamp, so re-reporting at the original time updates that record
        // (to a smaller amount if the bolus was cancelled) instead of adding a
        // second, double-counted entry at the pump's timestamp.
        if let active = state.activeBolus, active.bolusId == lastBolus.bolusId {
            let dose = DoseEntry(
                type: .bolus,
                startDate: active.startDate,
                value: units,
                unit: .units,
                deliveredUnits: units,
                insulinType: state.insulinType,
                automatic: active.activationType.isAutomatic,
                isMutable: false
            )
            let event = NewPumpEvent(
                date: active.startDate,
                dose: dose,
                raw: withUnsafeBytes(of: lastBolus.bolusId.littleEndian) { Data($0) } + Data([0xFD]),
                title: "Bolus \(units) U (id \(lastBolus.bolusId))",
                type: .bolus
            )
            state.noteBolusId(lastBolus.bolusId)
            state.activeBolus = nil
            releaseBolusPermission(bolusId: lastBolus.bolusId)
            emitPumpEvents([event])
            return
        }

        // Case 2: a bolus id we already handled (a basal microbolus recorded at
        // delivery time, a finalized SMB, or a pump-UI bolus already recorded).
        // Skip — recording again would double-count (basal pulses were recorded
        // at wall-clock time, not the pump timestamp, so timestamp-dedup would
        // not catch them).
        if state.hasRecentBolusId(lastBolus.bolusId) {
            checkStuckActiveBolus()
            return
        }

        // Case 3: a new bolus from another source (the pump's own UI). Record it
        // once at the pump timestamp; that timestamp is stable, so later polls
        // are deduped by timestamp, and we also remember the id.
        let date = TandemTime.date(fromTandemSeconds: lastBolus.timestamp)
        let dose = DoseEntry(
            type: .bolus,
            startDate: date,
            value: units,
            unit: .units,
            deliveredUnits: units,
            insulinType: state.insulinType,
            automatic: false,
            isMutable: false
        )
        let event = NewPumpEvent(
            date: date,
            dose: dose,
            raw: withUnsafeBytes(of: lastBolus.bolusId.littleEndian) { Data($0) } + withUnsafeBytes(
                of: lastBolus.timestamp.littleEndian
            ) { Data($0) },
            title: "Bolus \(units) U (id \(lastBolus.bolusId))",
            type: .bolus
        )
        state.noteBolusId(lastBolus.bolusId)
        emitPumpEvents([event])
        checkStuckActiveBolus()
    }

    /// Release the single-bolus gate if our tracked bolus is not the pump's last
    /// bolus, is not currently in progress, and the grace period has elapsed.
    /// commandQueue only.
    private func checkStuckActiveBolus() {
        // Our tracked bolus is not the pump's last bolus. If it is also not
        // currently in progress and the grace period has elapsed, assume it
        // never delivered (e.g. an uncertain initiate that did not register)
        // and release the gate so future boluses are not blocked forever.
        if let active = state.activeBolus,
           Date.now.timeIntervalSince(active.startDate) > Self.activeBolusGracePeriod
        {
            // Only release the gate when we POSITIVELY confirm no bolus with
            // our id is in progress. If the query fails we cannot confirm, so
            // keep the gate closed (a bolus might still be delivering) and try
            // again on the next sync.
            switch session.send(TandemCurrentBolusStatusRequest()) {
            case let .success(current) where current.bolusId != active.bolusId:
                log.error("Active bolus id \(active.bolusId) not found on pump after grace period; releasing gate")
                state.activeBolus = nil
                releaseBolusPermission(bolusId: active.bolusId)
            case .success:
                log.info("Active bolus id \(active.bolusId) still shown in progress; keeping gate")
            case let .failure(error):
                log.error("CurrentBolusStatus query failed (\(error.localizedDescription)); keeping gate closed")
            }
        }
    }

    // MARK: - Bolus

    func enactBolus(
        units: Double,
        activationType: BolusActivationType,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        guard !state.cartridgeChangeInProgress else {
            completion(.deviceState(TandemUnsupportedError.cartridgeChangeInProgress))
            return
        }
        guard state.remoteBolusEnabled else {
            completion(.configuration(TandemUnsupportedError.remoteBolusDisabled))
            return
        }
        guard state.supportsRemoteBolus else {
            completion(.configuration(TandemUnsupportedError.remoteBolusUnsupportedFirmware))
            return
        }
        if activationType == .automatic || activationType == .none {
            // Automatic boluses (oref SMBs) are only allowed where Trio is the
            // sole dosing authority and the pump's own automation is off: a Mobi
            // under native basal control, or a t:slim X2 in microbolus-basal
            // mode. Anywhere else we refuse automatic dosing outright, since a
            // second autonomous authority alongside on-pump Control-IQ is unsafe.
            guard automaticDosingAllowed else {
                completion(.configuration(TandemUnsupportedError.automaticBolusNotAllowed))
                return
            }
        }
        guard state.activeBolus == nil else {
            completion(.deviceState(TandemUnsupportedError.bolusInProgress))
            return
        }

        let milliunits = UInt32((units * 1000).rounded())
        guard milliunits >= TandemInitiateBolusRequest.minBolusMilliunits else {
            completion(.configuration(TandemUnsupportedError.bolusTooSmall))
            return
        }

        commandQueue.async {
            // Re-check on the serial queue: the guard above ran on the caller's
            // thread, so two rapid enactBolus calls could both pass it. This is
            // the authoritative single-bolus gate — never request a second
            // permission while a bolus is active.
            guard self.state.activeBolus == nil else {
                completion(.deviceState(TandemUnsupportedError.bolusInProgress))
                return
            }

            // An AUTOMATIC bolus (oref SMB) must obey a stacking guard: only
            // deliver it while the pump's own automation is verifiably off and
            // delivery is not suspended. Manual boluses are exempt (a
            // user-initiated correction on top of pump basal is expected). This
            // guard is local so the safety property does not depend on caller
            // ordering.
            if activationType == .automatic || activationType == .none {
                if let error = self.automaticDosingPreconditionFailure() {
                    self.log.error("Refusing automatic SMB: \(error.localizedDescription)")
                    completion(.configuration(error))
                    return
                }
            }

            switch self.initiateBolusCommand(milliunits: milliunits) {
            case let .delivered(bolusId):
                self.recordTrackedBolus(units: units, bolusId: bolusId, activationType: activationType, uncertain: false)
                completion(nil)
            case let .rejected(reason):
                completion(reason)
            case let .uncertain(bolusId, error):
                // The InitiateBolus request is SIGNED and may have reached the
                // pump even though we never saw the response. Track it so the
                // gate stays CLOSED (no second bolus) and the next status poll
                // reconciles the real delivered amount.
                self.log.error("Bolus delivery uncertain (\(error.localizedDescription)); keeping gate closed")
                self.recordTrackedBolus(units: units, bolusId: bolusId, activationType: activationType, uncertain: true)
                completion(.uncertainDelivery)
            case let .notSent(error):
                completion(.communication(error))
            }
        }
    }

    /// True when Trio is the pump's only autonomous dosing authority, which is
    /// what makes an oref SMB safe to deliver. Either basal control mode
    /// qualifies — both require the pump's own automation to be off.
    var automaticDosingAllowed: Bool {
        state.basalControlMode != .none
    }

    /// Nil when an automatic dose may proceed right now; otherwise the reason it
    /// may not. Must be called on commandQueue, since it reads sync state.
    private func automaticDosingPreconditionFailure() -> TandemUnsupportedError? {
        switch state.basalControlMode {
        case .nativeTempRate:
            // Fail closed on stale status: Control-IQ could have been switched
            // on since the last poll, which would make Trio a second dosing
            // authority.
            guard state.lastSync != .distantPast,
                  Date.now.timeIntervalSince(state.lastSync) < Self.tempBasalContextMaxStaleness
            else { return .basalContextStale }
            guard !state.controlIQEnabled else { return .controlIQActive }
            guard !state.suspended else { return .microbolusBasalPreconditionFailed }
            return nil
        case .microbolus:
            // The stricter set: the pump's own basal must also be zeroed, or the
            // SMB would stack on top of what the pump is already delivering.
            guard microbolusBasalPreconditionsMet(), !state.microbolusSuspended else {
                return .microbolusBasalPreconditionFailed
            }
            return nil
        case .none:
            return .basalControlNotConfigured
        }
    }

    /// True when a send failure provably occurred before the pump could have
    /// started delivering — i.e. the request never reached the pump or the pump
    /// explicitly rejected it. Any other failure (timeout, mid-exchange
    /// disconnect, unparseable reply) is treated as uncertain delivery.
    static func isDefiniteNonDelivery(_ error: TandemSessionError) -> Bool {
        switch error {
        case .insulinDeliveryActionsDisabled,
             // Key confirmation fails during authentication, before any
             // delivery command is built or sent.
             .keyConfirmationFailed,
             .notAuthenticated,
             .pumpRejected,
             .requestInFlight,
             .staleTimeSinceReset:
            return true
        case .invalidResponse,
             .notConnected,
             .pairingFailed,
             .timeout,
             .transport:
            return false
        }
    }

    func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        guard let bolus = state.activeBolus else {
            completion(.success(nil))
            return
        }

        commandQueue.async {
            if let error = self.ensureConnectedAndAuthenticated() {
                completion(.failure(.communication(error)))
                return
            }

            // Cancel is signed; refresh the time reference so the anti-replay
            // guard accepts it and the pump does not reject a stale signature.
            if case let .failure(error) = self.session.refreshTimeSinceReset() {
                completion(.failure(.communication(error)))
                return
            }

            switch self.session.send(TandemCancelBolusRequest(bolusId: bolus.bolusId)) {
            case let .success(response):
                // Treat a clean cancel, or "already delivered" (reason 2), as
                // a concluded bolus: the pump is no longer delivering it.
                guard response.cancelled || response.reasonId == 2 else {
                    self.log.error("Cancel failed: status \(response.statusId) reason \(response.reasonId)")
                    completion(.failure(.deviceState(TandemUnsupportedError.bolusCancelFailed(response.reasonId))))
                    return
                }
                // Finalize the (partial) delivered amount from the pump while
                // activeBolus is still set so reconcile can attribute it, then
                // guarantee the gate is cleared even if the pump has not yet
                // updated its last-bolus record.
                self.reconcileBolusStatus()
                if self.state.activeBolus?.bolusId == bolus.bolusId {
                    self.state.activeBolus = nil
                    self.releaseBolusPermission(bolusId: bolus.bolusId)
                }
                self.playFeedbackTone(.stateChange)
                self.notifyStateDidChange()
                completion(.success(nil))
            case let .failure(error):
                completion(.failure(.communication(error)))
            }
        }
    }

    /// Best-effort permission release. Must be called on commandQueue.
    func releaseBolusPermission(bolusId: UInt16) {
        if case let .failure(error) = session.send(TandemBolusPermissionReleaseRequest(bolusId: bolusId)) {
            log.error("Releasing bolus permission failed: \(error.localizedDescription)")
        }
    }

    /// Outcome of the low-level connect → sign → permission → initiate handshake.
    enum BolusInitiateOutcome {
        /// The pump accepted the InitiateBolus. The permission is still held and
        /// must be released once the bolus is reconciled.
        case delivered(bolusId: UInt16)
        /// The pump definitively refused (permission denied or initiate rejected);
        /// no insulin was delivered. Any held permission was released.
        case rejected(PumpManagerError)
        /// The initiate was signed and sent but the outcome is unknown (timeout,
        /// disconnect). It MAY be delivering. The permission is left held.
        case uncertain(bolusId: UInt16, error: TandemSessionError)
        /// A failure before the initiate could reach the pump; no delivery.
        case notSent(TandemSessionError)
    }

    /// Runs the shared, reviewed bolus handshake for `milliunits`. Does NOT set
    /// `activeBolus` or emit pump events — the caller decides how to record the
    /// result (tracked bolus vs. basal microbolus). Must run on commandQueue.
    func initiateBolusCommand(milliunits: UInt32) -> BolusInitiateOutcome {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        if let error = ensureConnectedAndAuthenticated() {
            return .notSent(error)
        }
        // A fresh time reference is required to sign delivery commands.
        if case let .failure(error) = session.refreshTimeSinceReset() {
            return .notSent(error)
        }

        let permission: TandemBolusPermissionResponse
        switch session.send(TandemBolusPermissionRequest()) {
        case let .success(response): permission = response
        case let .failure(error):
            // Permission failed before any initiate — nothing was delivered.
            return .notSent(error)
        }

        guard permission.granted else {
            log.error("Bolus permission denied: nack \(permission.nackReasonId)")
            return .rejected(.deviceState(TandemUnsupportedError.bolusPermissionDenied(permission.nackReasonId)))
        }

        let request = TandemInitiateBolusRequest(
            totalVolume: milliunits,
            bolusId: permission.bolusId,
            bolusTypeBitmask: 8, // standard remote bolus, as observed from t:connect
            foodVolume: 0,
            correctionVolume: 0
        )

        switch session.send(request) {
        case let .success(response):
            guard response.accepted else {
                log.error("Bolus rejected: status \(response.status)")
                releaseBolusPermission(bolusId: permission.bolusId)
                return .rejected(.deviceState(TandemUnsupportedError.bolusRejected(response.status)))
            }
            return .delivered(bolusId: permission.bolusId)
        case let .failure(error):
            if Self.isDefiniteNonDelivery(error) {
                releaseBolusPermission(bolusId: permission.bolusId)
                return .notSent(error)
            }
            // Permission was granted and the signed initiate may have reached
            // the pump; treat as uncertain and keep the permission held.
            return .uncertain(bolusId: permission.bolusId, error: error)
        }
    }

    /// Record a tracked (manual or SMB) bolus: hold the single-bolus gate and
    /// emit a mutable bolus event. Must run on commandQueue.
    func recordTrackedBolus(units: Double, bolusId: UInt16, activationType: BolusActivationType, uncertain: Bool) {
        let bolus = TandemActiveBolus(
            bolusId: bolusId,
            units: units,
            startDate: Date.now,
            activationTypeRaw: activationType.rawValue
        )
        state.activeBolus = bolus
        state.noteBolusId(bolusId)

        let dose = DoseEntry(
            type: .bolus,
            startDate: bolus.startDate,
            value: units,
            unit: .units,
            insulinType: state.insulinType,
            automatic: activationType.isAutomatic,
            isMutable: true
        )
        let event = NewPumpEvent(
            date: bolus.startDate,
            dose: dose,
            raw: withUnsafeBytes(of: bolusId.littleEndian) { Data($0) } + Data([uncertain ? 0xFE : 0xFF]),
            title: "Bolus \(units) U (id \(bolusId)\(uncertain ? ", uncertain" : ""))",
            type: .bolus
        )
        emitPumpEvents([event], replacePendingEvents: false)
        playFeedbackTone(.dose, forAutomaticDose: activationType.isAutomatic)
        notifyStateDidChange()
    }

    // MARK: - Basal

    /// Basal control has two very different implementations behind it.
    ///
    /// On a **Mobi** the pump accepts a real temp rate, so the request goes
    /// straight to the pump once the user has opted in to remote basal control.
    /// On a **t:slim X2** there is no such command; the only way to move basal
    /// is the experimental microbolus-basal mode, and with that off the request
    /// is refused with an explanation.
    func enactTempBasal(
        unitsPerHour: Double,
        for duration: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        // A cartridge change stops delivery on the pump and takes it through
        // modes that reject dosing commands. Refuse rather than let the loop
        // fight the change.
        guard !state.cartridgeChangeInProgress else {
            completion(.deviceState(TandemUnsupportedError.cartridgeChangeInProgress))
            return
        }
        switch state.basalControlMode {
        case .nativeTempRate:
            commandQueue.async {
                self.enactNativeTempBasal(unitsPerHour: unitsPerHour, duration: duration, completion: completion)
            }
        case .microbolus:
            commandQueue.async {
                self.enactMicrobolusBasal(unitsPerHour: unitsPerHour, duration: duration, completion: completion)
            }
        case .none:
            log.error("Temp basal requested but no basal control mode is enabled")
            completion(.configuration(TandemUnsupportedError.basalControlNotConfigured))
        }
    }

    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        guard !state.cartridgeChangeInProgress else {
            // Already not delivering.
            completion(nil)
            return
        }
        switch state.basalControlMode {
        case .nativeTempRate:
            commandQueue.async {
                self.suspendNativeDelivery(completion: completion)
            }
        case .microbolus:
            commandQueue.async {
                self.suspendMicrobolusBasal(completion: completion)
            }
        case .none:
            completion(TandemUnsupportedError.basalControlNotConfigured)
        }
    }

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        guard !state.cartridgeChangeInProgress else {
            completion(TandemUnsupportedError.cartridgeChangeInProgress)
            return
        }
        switch state.basalControlMode {
        case .nativeTempRate:
            commandQueue.async {
                self.resumeNativeDelivery(completion: completion)
            }
        case .microbolus:
            commandQueue.async {
                self.resumeMicrobolusBasal(completion: completion)
            }
        case .none:
            completion(TandemUnsupportedError.basalControlNotConfigured)
        }
    }

    func syncBasalRateSchedule(
        items: [RepeatingScheduleValue<Double>],
        completion: @escaping (Result<BasalRateSchedule, any Error>) -> Void
    ) {
        // Trio's basal profile is never written to the pump: neither model exposes
        // a "write basal profile" command this driver implements. On a Mobi the
        // temp rates Trio sends are percentages of the pump's OWN profile, and in
        // microbolus-basal mode Trio delivers this schedule itself; in monitor mode
        // oref only uses it for calculations. So accept the schedule locally —
        // failing here would make every basal profile save in Trio's editor
        // impossible while this pump is paired.
        guard let schedule = BasalRateSchedule(dailyItems: items, timeZone: .current) else {
            completion(.failure(TandemUnsupportedError.basalControlUnsupported))
            return
        }
        completion(.success(schedule))
    }

    func syncDeliveryLimits(
        limits: DeliveryLimits,
        completion: @escaping (Result<DeliveryLimits, any Error>) -> Void
    ) {
        // Limits are enforced on the pump; nothing to write.
        completion(.success(limits))
    }

    // MARK: - Observers / state propagation

    func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    func notifyStateDidChange() {
        DispatchQueue.main.async {
            let status = self.status(self.state)
            let oldStatus = self.status(self.oldState)

            self.pumpDelegate.notify { delegate in
                delegate?.pumpManagerDidUpdateState(self)
                delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.statusObservers.forEach { observer in
                observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
            }

            self.oldState = TandemPumpState(rawValue: self.state.rawValue)
        }
    }

    func emitPumpEvents(_ events: [NewPumpEvent], replacePendingEvents: Bool = true) {
        pumpDelegate.notify { delegate in
            delegate?.pumpManager(
                self,
                hasNewPumpEvents: events,
                lastReconciliation: self.state.lastSync,
                replacePendingEvents: replacePendingEvents
            ) { error in
                if let error = error {
                    self.log.error("Failed to store pump events: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Remove this pump from Trio.
    ///
    /// A Mobi running a Trio-commanded temp rate would keep running it after the
    /// pump is removed, with nothing left to cancel it, so stop it first. This
    /// is best effort: if the pump is out of range there is nothing more we can
    /// do than warn in the log, and the rate expires on its own.
    func deletePump() {
        // Tear-down, run once the temp rate (if any) has been dealt with.
        let deactivate = { [weak self] in
            guard let self = self else { return }
            self.session.insulinDeliveryActionsEnabled = false
            self.bluetooth.disconnect()
            // A notification about a pump that is no longer paired is worse
            // than none: nothing on the phone can act on it any more.
            self.state.activeAlarmBits = nil
            self.updateAlarmNotification()
            self.pumpDelegate.notify { delegate in
                delegate?.pumpManagerWillDeactivate(self)
            }
        }

        // Only worth trying while we are already connected: waking a pump we are
        // about to abandon would stall removal for the whole connect timeout,
        // and this runs on the caller's (main) thread, so it must not block.
        guard state.supportsNativeBasalControl,
              let temp = state.activeTempBasal, temp.isActive(),
              bluetooth.isConnected
        else {
            deactivate()
            return
        }

        commandQueue.async {
            self.stopNativeTempBasal { error in
                if let error = error {
                    self.log
                        .error("Could not stop the temp basal before removing the pump: \(error.localizedDescription)")
                }
                deactivate()
            }
        }
    }

    /// Persist a successful pairing and mark onboarding complete.
    ///
    /// `jpakeDerivedSecret` is the shared secret established by the JPAKE
    /// handshake, and is nil for a legacy t:slim X2 pairing whose code is itself
    /// the signing key.
    func completePairing(
        peripheralIdentifier: UUID,
        pairingCode: String,
        pairingCodeType: TandemPairingCodeType,
        pumpModel: TandemPumpModel,
        jpakeDerivedSecret: Data?,
        insulinType: InsulinType
    ) {
        state.peripheralIdentifier = peripheralIdentifier
        state.pairingCode = pairingCode
        state.pairingCodeType = pairingCodeType
        state.pumpModel = pumpModel
        state.jpakeDerivedSecret = jpakeDerivedSecret
        state.insulinType = insulinType
        state.isOnboarded = true
        bluetooth.peripheralIdentifier = peripheralIdentifier
        if pairingCodeType == .legacy16 {
            session.setAuthenticationKey(Data(pairingCode.utf8))
        }
        notifyStateDidChange()

        commandQueue.async {
            if case let .failure(error) = self.refreshIdentity() {
                self.log.error("Post-pairing identity refresh failed: \(error.localizedDescription)")
            }
            self.syncPumpData(completion: nil)
        }
    }

    /// User opt-in/out for remote bolus.
    /// True while the pump is mid-cartridge-change and must not be dosed.
    var isChangingCartridge: Bool { state.cartridgeChangeInProgress }

    func setRemoteBolusEnabled(_ enabled: Bool) {
        state.remoteBolusEnabled = enabled
        // Disabling remote bolus also forces the microbolus-basal mode off,
        // since that mode depends on remote delivery. Tear it down the SAME way
        // setMicrobolusBasalEnabled(false) does, so no stale accumulator or
        // suspend state is left behind.
        if !enabled {
            teardownMicrobolusBasal()
        }
        session.insulinDeliveryActionsEnabled = state.insulinDeliveryActionsAllowed
        notifyStateDidChange()
    }

    /// User opt-in/out for native remote basal control (Mobi only). This is what
    /// lets Trio run a closed loop with the pump's own delivery engine.
    ///
    /// Turning it off leaves the pump on whatever temp rate is currently
    /// running, so the caller should stop that first; `deletePump` and the
    /// settings screen both do.
    func setRemoteBasalEnabled(_ enabled: Bool) {
        guard state.supportsNativeBasalControl || !enabled else {
            log.error("Refusing to enable remote basal control: \(state.pumpModel.localizedTitle) does not support it")
            return
        }
        state.remoteBasalEnabled = enabled
        if enabled {
            // The two modes must never both be live: a pump-side temp rate plus
            // a microbolus stream is a double dose. Tear the other one down
            // completely rather than just clearing its flag.
            teardownMicrobolusBasal()
        } else if state.supportsNativeBasalControl,
                  let temp = state.activeTempBasal, temp.isActive(),
                  bluetooth.isConnected
        {
            // Forgetting the rate is not the same as cancelling it: the Mobi
            // would keep delivering a rate Trio commanded with nothing left
            // managing basal, which is the hazard `deletePump` already guards
            // against. Stop it on the pump; `stopNativeTempBasal` clears the
            // record itself. Only worth trying while already connected — waking
            // the pump would block the queue for the whole connect timeout.
            commandQueue.async {
                self.stopNativeTempBasal { error in
                    if let error = error {
                        self.log.error(
                            "Could not stop the temp basal when turning basal control off: \(error.localizedDescription)"
                        )
                    }
                }
            }
        } else {
            state.activeTempBasal = nil
        }
        session.insulinDeliveryActionsEnabled = state.insulinDeliveryActionsAllowed
        notifyStateDidChange()
    }

    /// User opt-in/out for the microbolus-basal closed-loop mode. Enabling it
    /// implies remote bolus. When turned off, any accrued basal is discarded.
    func setMicrobolusBasalEnabled(_ enabled: Bool) {
        if enabled {
            state.microbolusBasalEnabled = true
            state.microbolusSuspended = false
            state.remoteBolusEnabled = true
            // Leaving native temp-rate control behind: a rate already running on
            // the pump would keep delivering underneath the microbolus stream,
            // so stop it on the pump before switching, not just in our state.
            if state.remoteBasalEnabled {
                state.remoteBasalEnabled = false
                stopRunningTempRateForModeSwitch()
            }
        } else {
            teardownMicrobolusBasal()
        }
        session.insulinDeliveryActionsEnabled = state.insulinDeliveryActionsAllowed
        notifyStateDidChange()
    }

    /// Best-effort stop of a temp rate left running when the user switches away
    /// from native basal control. Runs asynchronously so the settings toggle
    /// stays responsive; a failure is logged and the next status sync catches it.
    private func stopRunningTempRateForModeSwitch() {
        guard let temp = state.activeTempBasal, temp.isActive() else {
            state.activeTempBasal = nil
            return
        }
        commandQueue.async {
            self.stopNativeTempBasal { error in
                if let error = error {
                    self.log.error(
                        "Could not stop the running temp basal while switching to microbolus-basal: \(error.localizedDescription)"
                    )
                    self.state.lastSync = .distantPast
                }
            }
        }
    }

    /// Fully disable the microbolus-basal mode and clear all of its transient
    /// state so it can never be left half-configured (stuck suspended, stale
    /// accrued insulin, or a dangling integration baseline).
    private func teardownMicrobolusBasal() {
        state.microbolusBasalEnabled = false
        state.microbolusSuspended = false
        state.owedBasalInsulin = 0
        state.lastBasalRate = 0
        state.lastBasalUpdate = nil
    }

    // MARK: - Audio feedback

    /// Distinct phone-side cues for pump activity.
    ///
    /// The pump does have an annunciation command — `PlaySound` — but it takes
    /// no parameters at all, so every use of it sounds identical. That is fine
    /// for a glucose alarm, where the pattern can be built from repeats
    /// (`TandemGlucoseAnnunciation`), and no use for telling a bolus from a
    /// cancel. So the phone plays these.
    enum FeedbackTone {
        /// Insulin was accepted for delivery (bolus, SMB, basal microbolus).
        case dose
        /// Delivery state changed (cancel, suspend, resume).
        case stateChange
    }

    func setAudioFeedbackEnabled(_ enabled: Bool) {
        state.audioFeedbackEnabled = enabled
        notifyStateDidChange()
    }

    func setAudioFeedbackForAutomaticDoses(_ enabled: Bool) {
        state.audioFeedbackForAutomaticDoses = enabled
        notifyStateDidChange()
    }

    /// User opt-in for buzzing the pump on Trio's glucose alarms. Turning it off
    /// also drops the rate-limit clock, so turning it back on can annunciate
    /// straight away rather than sitting out the tail of an old window.
    func setGlucoseAnnunciationEnabled(_ enabled: Bool) {
        state.glucoseAnnunciationEnabled = enabled
        if !enabled {
            state.lastAnnunciationAt = nil
        }
        notifyStateDidChange()
    }

    /// Play the cue for `tone`, honoring the user's feedback settings.
    /// Automatic doses (SMBs, basal microboluses) additionally require the
    /// automatic-dose opt-in so microbolus-basal mode does not chirp every cycle.
    func playFeedbackTone(_ tone: FeedbackTone, forAutomaticDose automatic: Bool = false) {
        guard state.audioFeedbackEnabled else { return }
        if automatic, !state.audioFeedbackForAutomaticDoses { return }
        let soundID: SystemSoundID = tone == .dose ? 1103 : 1104
        AudioServicesPlaySystemSound(soundID)
    }
}

// MARK: - TandemPumpSessionDelegate

extension TandemPumpManager: TandemPumpSessionDelegate {
    func sessionDidAuthenticate(_: TandemPumpSession) {
        log.info("Session authenticated")
    }

    func session(_: TandemPumpSession, didReceiveQualifyingEvents events: TandemQualifyingEvents) {
        log.info("Qualifying events: \(events.rawValue)")
        // Pump state changed out-of-band (bolus from the pump UI, suspension,
        // basal change...). Refresh soon; force staleness so the poll runs.
        // This delegate fires on the BLE manager queue, so mutate `state` and
        // run the sync on commandQueue to keep all state access on one queue.
        //
        // The alarm, alert and malfunction bits are in the set because the poll
        // now reads the pump's notification bitmasks: this is the pump telling
        // Trio, the moment it happens, that something the user has to see has
        // fired. On a Mobi, which has no screen, that push is the difference
        // between the alarm appearing now and appearing at the next heartbeat.
        if !events.isDisjoint(with: [
            .bolusChange,
            .basalChange,
            .pumpSuspend,
            .pumpResume,
            .homeScreenChange,
            .alarm,
            .alert,
            .malfunction
        ]) {
            let notificationEvent = !events.isDisjoint(with: [.alarm, .alert, .malfunction])
            commandQueue.async {
                // The pump often pushes several events at once, and each one
                // would otherwise queue a full status read ahead of anything
                // the user asks for. One refresh answers them all.
                guard Date.now.timeIntervalSince(self.state.lastSync) > Self.pushCoalescingInterval else { return }
                if notificationEvent {
                    // The pump is saying a notification fired. A suppression
                    // left over from an earlier lost read must not be the
                    // reason Trio does not go and look.
                    self.state.alarmReadSuppressedUntil = nil
                    self.state.alertReadSuppressedUntil = nil
                }
                self.syncPumpData(completion: nil)
            }
        }
    }

    func session(_: TandemPumpSession, didDisconnect error: Error?) {
        log.info("Session disconnected: \(error?.localizedDescription ?? "clean")")
        notifyStateDidChange()
    }

    func session(_: TandemPumpSession, didReceiveCartridgeEvent event: TandemCartridgeStreamEvent) {
        handleCartridgeStreamEvent(event)
    }
}

// MARK: - Errors

enum TandemUnsupportedError: LocalizedError {
    case basalControlUnsupported
    case remoteBolusDisabled
    case remoteBolusUnsupportedFirmware
    case remoteBasalDisabled
    case automaticBolusNotAllowed
    case bolusInProgress
    case bolusTooSmall
    case bolusPermissionDenied(UInt8)
    case bolusRejected(UInt8)
    case bolusCancelFailed(UInt8)
    case microbolusBasalPreconditionFailed
    case basalContextStale
    case controlIQActive
    case zeroProfileBasal
    case tempBasalRejected(UInt8)
    case suspendRejected(UInt8)
    case resumeRejected(UInt8)
    case cartridgeChangeInProgress
    case basalControlNotConfigured

    var errorDescription: String? {
        switch self {
        case .basalControlUnsupported:
            return "This pump does not accept remote basal commands, so Trio cannot drive basal on it directly."
        case .remoteBasalDisabled:
            return "Remote basal control is disabled. Enable it in the pump settings to let Trio set temp basals on this pump."
        case .basalContextStale:
            return "Trio could not read the pump's current basal profile, so it will not guess at a temp basal rate. Check the pump connection."
        case .controlIQActive:
            return "Control-IQ is running on the pump. Turn Control-IQ off so Trio is the only system adjusting basal delivery."
        case .zeroProfileBasal:
            return "The pump's active basal profile is 0 U/hr. Tandem temp rates are a percentage of the profile rate, so the pump needs a non-zero basal profile for Trio to adjust it."
        case let .tempBasalRejected(status):
            return "The pump rejected the temp basal (status \(status))."
        case let .suspendRejected(status):
            return "The pump refused to suspend delivery (status \(status))."
        case let .resumeRejected(status):
            return "The pump refused to resume delivery (status \(status))."
        case .cartridgeChangeInProgress:
            return "A cartridge change is in progress. Finish or cancel it before Trio delivers insulin again."
        case .basalControlNotConfigured:
            return "Trio is not set up to control basal on this pump. Choose how basal should be driven in the pump settings: a Tandem Mobi can use its own temp rates or microbolus-basal, and a t:slim X2 can only use microbolus-basal."
        case .microbolusBasalPreconditionFailed:
            return "Microbolus-basal is on but the pump is still delivering its own basal or Control-IQ. Set the pump's basal profile to 0 U/hr and turn Control-IQ off, or Trio would stack insulin on top of the pump."
        case .remoteBolusDisabled:
            return "Remote bolus is disabled. Enable it in the pump settings to bolus from Trio."
        case .remoteBolusUnsupportedFirmware:
            return "This pump's firmware does not support remote bolus. t:slim X2 software 7.6 or newer is required."
        case .automaticBolusNotAllowed:
            return "Automatic dosing (SMB) needs Trio to be the pump's only automated dosing system. Enable remote basal control on a Mobi, or microbolus-basal mode on a t:slim X2, with the pump's own Control-IQ turned off."
        case .bolusInProgress:
            return "A bolus is already in progress."
        case .bolusTooSmall:
            return "The requested bolus is below the pump's 0.05 U minimum remote bolus."
        case let .bolusPermissionDenied(reason):
            return "The pump denied the bolus request (reason \(reason)). Dismiss any open screens on the pump and try again."
        case let .bolusRejected(status):
            return "The pump rejected the bolus (status \(status))."
        case let .bolusCancelFailed(reason):
            return "The pump could not cancel the bolus (reason \(reason))."
        }
    }
}

/// Tandem timestamps count seconds from 2008-01-01 00:00:00 UTC.
enum TandemTime {
    static let epoch: Date = {
        var components = DateComponents()
        components.year = 2008
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    static func date(fromTandemSeconds seconds: UInt32) -> Date {
        epoch.addingTimeInterval(TimeInterval(seconds))
    }
}
