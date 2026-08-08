import CoreBluetooth
import Foundation
import HealthKit
import LoopKit

/// Pump driver for the Tandem t:slim X2.
///
/// Capability summary (dictated by the reverse-engineered protocol):
/// - Pairing + live status monitoring on firmware 7.1+ using the 16-character
///   pairing code. Firmware 7.7+ switched to a 6-digit JPAKE pairing flow
///   that this driver does not implement yet.
/// - Remote bolus on firmware 7.6+ (API 2.5), gated behind an explicit user
///   opt-in ("remote bolus"), delivered through the pump's own
///   permission/initiate/status message flow.
/// - NO remote basal modulation: the t:slim X2 protocol does not accept
///   temp-rate, suspend, or resume commands (they exist for the Tandem Mobi
///   only). Control-IQ runs on the pump itself. Trio therefore cannot close
///   the loop with this pump; it acts as monitor, treatment log, and remote
///   bolus interface.
class TandemPumpManager: DeviceManager {
    static let pluginIdentifier = "Tandem"
    let managerIdentifier = "Tandem"
    let localizedTitle = "Tandem t:slim X2"

    private let log = TandemLogger(category: "TandemPumpManager")

    let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()
    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    /// Serializes all pump exchanges; session.send blocks on responses.
    private let commandQueue = DispatchQueue(label: "org.nightscout.trio.TandemPumpManager.commandQueue", qos: .userInitiated)

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
        session.insulinDeliveryActionsEnabled = state.remoteBolusEnabled
        if !state.pairingCode.isEmpty {
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

    /// t:slim X2: boluses 0.05-25 U in 0.01 U increments.
    static var onboardingSupportedBolusVolumes: [Double] {
        (5 ... 2500).map { Double($0) / 100 }
    }

    /// t:slim X2: basal 0-15 U/hr. 0.01 U/hr granularity used for display;
    /// the pump's profile is never written by Trio.
    static var onboardingSupportedBasalRates: [Double] {
        (0 ... 1500).map { Double($0) / 100 }
    }

    static var onboardingSupportedMaximumBolusVolumes: [Double] {
        onboardingSupportedBolusVolumes
    }

    /// t:slim X2 profiles allow 16 segments.
    static var onboardingMaximumBasalScheduleEntryCount: Int { 16 }

    var supportedBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    var supportedMaximumBolusVolumes: [Double] { Self.onboardingSupportedBolusVolumes }
    var supportedBasalRates: [Double] { Self.onboardingSupportedBasalRates }
    var maximumBasalScheduleEntryCount: Int { Self.onboardingMaximumBasalScheduleEntryCount }
    var minimumBasalScheduleEntryDuration: TimeInterval { .minutes(15) }

    func roundToSupportedBolusVolume(units: Double) -> Double {
        supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
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
            name: "Tandem t:slim X2",
            manufacturer: "Tandem Diabetes Care",
            model: state.pumpModelNumber.isEmpty ? "t:slim X2" : state.pumpModelNumber,
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

    var pumpReservoirCapacity: Double { 300 }

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
    private func ensureConnectedAndAuthenticated() -> TandemSessionError? {
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

            // Fresh connection: authenticate and re-establish identity/time.
            if case let .failure(error) = session.authenticate(pairingCode: state.pairingCode) {
                return error
            }
            if case let .failure(error) = refreshIdentity() {
                return error
            }
        }

        return nil
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

    /// Full status refresh. Must be called on commandQueue.
    private func syncPumpData(completion: ((Date?) -> Void)?) {
        dispatchPrecondition(condition: .onQueue(commandQueue))

        if let error = ensureConnectedAndAuthenticated() {
            log.error("Sync failed to connect: \(error.localizedDescription)")
            completion?(nil)
            return
        }

        var encounteredError = false

        switch session.send(TandemInsulinStatusRequest()) {
        case let .success(response):
            state.reservoir = Double(response.currentInsulinAmount)
            state.reservoirIsEstimate = response.isEstimate
            pumpDelegate.notify { delegate in
                delegate?.pumpManager(self, didReadReservoirValue: self.state.reservoir, at: Date.now) { _ in }
            }
        case let .failure(error):
            encounteredError = true
            log.error("InsulinStatus failed: \(error.localizedDescription)")
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
            encounteredError = true
            log.error("CurrentBattery failed: \(error.localizedDescription)")
        }

        switch session.send(TandemCurrentBasalStatusRequest()) {
        case let .success(response):
            state.profileBasalRate = Double(response.profileBasalRate) / 1000
            state.currentBasalRate = Double(response.currentBasalRate) / 1000
        case let .failure(error):
            encounteredError = true
            log.error("CurrentBasalStatus failed: \(error.localizedDescription)")
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

        if !encounteredError {
            state.lastSync = Date.now
        }
        notifyStateDidChange()
        completion?(encounteredError ? nil : state.lastSync)
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

        let isOurs = state.activeBolus != nil && state.activeBolus?.bolusId == lastBolus.bolusId

        // Record a finished bolus once. LastBolusStatus reports a concluded
        // bolus (complete, stopped, or terminated), so its deliveredVolume is
        // the final amount — record it whatever the terminal reason. For our
        // own tracked bolus always finalize; for another source (pump UI) skip
        // if we already reported this id.
        if lastBolus.bolusId != 0, isOurs || lastBolus.bolusId != state.lastReportedBolusId {
            let units = Double(lastBolus.deliveredVolume) / 1000
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

            state.lastReportedBolusId = lastBolus.bolusId
            if isOurs {
                state.activeBolus = nil
                releaseBolusPermission(bolusId: lastBolus.bolusId)
            }
            emitPumpEvents([event])
            return
        }

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
        guard state.remoteBolusEnabled else {
            completion(.configuration(TandemUnsupportedError.remoteBolusDisabled))
            return
        }
        guard state.supportsRemoteBolus else {
            completion(.configuration(TandemUnsupportedError.remoteBolusUnsupportedFirmware))
            return
        }
        guard activationType == .manualNoRecommendation || activationType == .manualRecommendationAccepted else {
            // Never deliver automatic boluses: Control-IQ already doses on
            // the pump; an automated second dosing authority is unsafe.
            completion(.configuration(TandemUnsupportedError.automaticBolusNotAllowed))
            return
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

            if let error = self.ensureConnectedAndAuthenticated() {
                completion(.communication(error))
                return
            }

            // A fresh time reference is required to sign delivery commands.
            if case let .failure(error) = self.session.refreshTimeSinceReset() {
                completion(.communication(error))
                return
            }

            let permission: TandemBolusPermissionResponse
            switch self.session.send(TandemBolusPermissionRequest()) {
            case let .success(response): permission = response
            case let .failure(error):
                completion(.communication(error))
                return
            }

            guard permission.granted else {
                self.log.error("Bolus permission denied: nack \(permission.nackReasonId)")
                completion(.deviceState(TandemUnsupportedError.bolusPermissionDenied(permission.nackReasonId)))
                return
            }

            let request = TandemInitiateBolusRequest(
                totalVolume: milliunits,
                bolusId: permission.bolusId,
                bolusTypeBitmask: 8, // standard remote bolus, as observed from t:connect
                foodVolume: 0,
                correctionVolume: 0
            )

            switch self.session.send(request) {
            case let .success(response):
                guard response.accepted else {
                    self.log.error("Bolus rejected: status \(response.status)")
                    self.releaseBolusPermission(bolusId: permission.bolusId)
                    completion(.deviceState(TandemUnsupportedError.bolusRejected(response.status)))
                    return
                }

                let bolus = TandemActiveBolus(
                    bolusId: permission.bolusId,
                    units: units,
                    startDate: Date.now,
                    activationTypeRaw: activationType.rawValue
                )
                self.state.activeBolus = bolus

                let dose = DoseEntry(
                    type: .bolus,
                    startDate: bolus.startDate,
                    value: units,
                    unit: .units,
                    insulinType: self.state.insulinType,
                    automatic: false,
                    isMutable: true
                )
                let event = NewPumpEvent(
                    date: bolus.startDate,
                    dose: dose,
                    raw: withUnsafeBytes(of: bolus.bolusId.littleEndian) { Data($0) } + Data([0xFF]),
                    title: "Bolus \(units) U (id \(bolus.bolusId))",
                    type: .bolus
                )
                self.emitPumpEvents([event], replacePendingEvents: false)
                self.notifyStateDidChange()
                completion(nil)

            case let .failure(error):
                // Distinguish a definite non-delivery from an uncertain one.
                // The InitiateBolus request is SIGNED and may have reached the
                // pump and started delivery even if we never saw the response.
                // Only errors that provably happened before the pump acted are
                // safe to treat as "no delivery"; everything else must be
                // treated as uncertain so the activeBolus gate stays CLOSED and
                // a second bolus cannot be initiated.
                if Self.isDefiniteNonDelivery(error) {
                    self.releaseBolusPermission(bolusId: permission.bolusId)
                    completion(.communication(error))
                } else {
                    // Uncertain: assume the bolus MAY be delivering. Track it so
                    // the gate stays closed; the next status poll reconciles the
                    // real delivered amount. Do NOT release the permission.
                    self.log.error("Bolus delivery uncertain (\(error.localizedDescription)); keeping gate closed")
                    let bolus = TandemActiveBolus(
                        bolusId: permission.bolusId,
                        units: units,
                        startDate: Date.now,
                        activationTypeRaw: activationType.rawValue
                    )
                    self.state.activeBolus = bolus
                    let dose = DoseEntry(
                        type: .bolus,
                        startDate: bolus.startDate,
                        value: units,
                        unit: .units,
                        insulinType: self.state.insulinType,
                        automatic: false,
                        isMutable: true
                    )
                    let event = NewPumpEvent(
                        date: bolus.startDate,
                        dose: dose,
                        raw: withUnsafeBytes(of: bolus.bolusId.littleEndian) { Data($0) } + Data([0xFE]),
                        title: "Bolus \(units) U (id \(bolus.bolusId), uncertain)",
                        type: .bolus
                    )
                    self.emitPumpEvents([event], replacePendingEvents: false)
                    self.notifyStateDidChange()
                    completion(.uncertainDelivery)
                }
            }
        }
    }

    /// True when a send failure provably occurred before the pump could have
    /// started delivering — i.e. the request never reached the pump or the pump
    /// explicitly rejected it. Any other failure (timeout, mid-exchange
    /// disconnect, unparseable reply) is treated as uncertain delivery.
    private static func isDefiniteNonDelivery(_ error: TandemSessionError) -> Bool {
        switch error {
        case .notAuthenticated,
             .staleTimeSinceReset,
             .requestInFlight,
             .insulinDeliveryActionsDisabled,
             .pumpRejected:
            return true
        case .notConnected,
             .timeout,
             .transport,
             .invalidResponse,
             .pairingFailed:
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
                self.notifyStateDidChange()
                completion(.success(nil))
            case let .failure(error):
                completion(.failure(.communication(error)))
            }
        }
    }

    /// Best-effort permission release. Must be called on commandQueue.
    private func releaseBolusPermission(bolusId: UInt16) {
        if case let .failure(error) = session.send(TandemBolusPermissionReleaseRequest(bolusId: bolusId)) {
            log.error("Releasing bolus permission failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Basal (structurally unsupported on t:slim X2)

    func enactTempBasal(
        unitsPerHour _: Double,
        for _: TimeInterval,
        completion: @escaping (PumpManagerError?) -> Void
    ) {
        log.error("Temp basal requested; the t:slim X2 does not support remote basal control")
        completion(.configuration(TandemUnsupportedError.basalControlUnsupported))
    }

    func suspendDelivery(completion: @escaping ((any Error)?) -> Void) {
        completion(TandemUnsupportedError.basalControlUnsupported)
    }

    func resumeDelivery(completion: @escaping ((any Error)?) -> Void) {
        completion(TandemUnsupportedError.basalControlUnsupported)
    }

    func syncBasalRateSchedule(
        items _: [RepeatingScheduleValue<Double>],
        completion: @escaping (Result<BasalRateSchedule, any Error>) -> Void
    ) {
        // The basal profile lives on the pump and cannot be written remotely.
        completion(.failure(TandemUnsupportedError.basalControlUnsupported))
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
    func deletePump() {
        session.insulinDeliveryActionsEnabled = false
        bluetooth.disconnect()
        pumpDelegate.notify { delegate in
            delegate?.pumpManagerWillDeactivate(self)
        }
    }

    /// Persist a successful pairing and mark onboarding complete.
    func completePairing(peripheralIdentifier: UUID, pairingCode: String, insulinType: InsulinType) {
        state.peripheralIdentifier = peripheralIdentifier
        state.pairingCode = pairingCode
        state.insulinType = insulinType
        state.isOnboarded = true
        bluetooth.peripheralIdentifier = peripheralIdentifier
        session.setAuthenticationKey(Data(pairingCode.utf8))
        notifyStateDidChange()

        commandQueue.async {
            if case let .failure(error) = self.refreshIdentity() {
                self.log.error("Post-pairing identity refresh failed: \(error.localizedDescription)")
            }
            self.syncPumpData(completion: nil)
        }
    }

    /// User opt-in/out for remote bolus.
    func setRemoteBolusEnabled(_ enabled: Bool) {
        state.remoteBolusEnabled = enabled
        session.insulinDeliveryActionsEnabled = enabled
        notifyStateDidChange()
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
        if !events.isDisjoint(with: [.bolusChange, .basalChange, .pumpSuspend, .pumpResume, .homeScreenChange]) {
            commandQueue.async {
                self.state.lastSync = .distantPast
                self.syncPumpData(completion: nil)
            }
        }
    }

    func session(_: TandemPumpSession, didDisconnect error: Error?) {
        log.info("Session disconnected: \(error?.localizedDescription ?? "clean")")
        notifyStateDidChange()
    }
}

// MARK: - Errors

enum TandemUnsupportedError: LocalizedError {
    case basalControlUnsupported
    case remoteBolusDisabled
    case remoteBolusUnsupportedFirmware
    case automaticBolusNotAllowed
    case bolusInProgress
    case bolusTooSmall
    case bolusPermissionDenied(UInt8)
    case bolusRejected(UInt8)
    case bolusCancelFailed(UInt8)

    var errorDescription: String? {
        switch self {
        case .basalControlUnsupported:
            return "The t:slim X2 does not accept remote basal commands. Control-IQ manages automated delivery on the pump itself, so Trio cannot run a closed loop with this pump."
        case .remoteBolusDisabled:
            return "Remote bolus is disabled. Enable it in the pump settings to bolus from Trio."
        case .remoteBolusUnsupportedFirmware:
            return "This pump's firmware does not support remote bolus. t:slim X2 software 7.6 or newer is required."
        case .automaticBolusNotAllowed:
            return "Automatic dosing is not available with the t:slim X2; only manually confirmed boluses can be delivered."
        case .bolusInProgress:
            return "A bolus is already in progress."
        case .bolusTooSmall:
            return "The requested bolus is below the pump's 0.05 U minimum."
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
