import Foundation
import LoopKit

/// A bolus the driver initiated remotely and is tracking to completion.
struct TandemActiveBolus: Codable {
    var bolusId: UInt16
    var units: Double
    var startDate: Date
    var activationTypeRaw: String

    var activationType: BolusActivationType {
        BolusActivationType(rawValue: activationTypeRaw) ?? .manualNoRecommendation
    }
}

/// A temp basal the driver commanded on a Mobi and is tracking to expiry.
struct TandemActiveTempBasal: Codable {
    /// Identifier the pump returned, used to stop the rate early.
    var tempRateId: UInt16
    /// Rate the pump will actually deliver: the commanded percentage applied to
    /// the pump's own profile basal rate. This is what Trio must record for
    /// IOB, not the rate oref asked for.
    var unitsPerHour: Double
    /// Percentage of profile basal that was commanded.
    var percent: Int
    var startDate: Date
    var duration: TimeInterval

    var endDate: Date { startDate.addingTimeInterval(duration) }

    func isActive(at date: Date = Date()) -> Bool {
        date >= startDate && date < endDate
    }
}

/// A cartridge change Trio is walking the user through.
///
/// Persisted so that an app restart mid-change still knows the pump is in
/// cartridge-change mode and that delivery must not resume on its own. The
/// disconnect confirmation deliberately does NOT live here — see
/// `TandemPumpState.cartridgeDisconnectConfirmedAt`.
struct TandemCartridgeSession: Codable, Equatable {
    /// How far through the change we are. The pump drives the real state
    /// machine; this is what Trio has asked for and seen acknowledged.
    enum Stage: String, Codable {
        /// Pump is in change-cartridge mode; delivery is stopped and the pump
        /// is waiting for the physical cartridge swap.
        case changeMode
        /// The new cartridge has been inserted and detected. Leaving change
        /// mode is what triggers detection — on the pump, "exit change mode"
        /// is the mid-flow "check the new cartridge" step, not the finish.
        case cartridgeLoaded
        /// Fill-tubing mode is active. On a Mobi the actual fill is driven by
        /// holding the pump's own button; Trio only opens the mode.
        case fillingTubing
        /// Tubing fill has been ended.
        case tubingFilled
        /// The cannula prime has completed (Mobi only).
        case cannulaFilled
    }

    var stage: Stage
    var startedAt: Date

    /// Longest a change is allowed to sit before Trio stops trusting it and
    /// insists the user start over; a stale session means the pump's real state
    /// is unknown.
    static let maximumDuration: TimeInterval = .hours(2)

    func isStale(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(startedAt) > Self.maximumDuration
    }
}

/// How Trio drives basal delivery on the pump.
///
/// The two working modes are mutually exclusive and must stay that way: a
/// pump-side temp rate running at the same time as a stream of basal
/// microboluses is a straightforward double dose. `TandemPumpState` derives the
/// mode rather than letting callers read the two opt-in flags independently, and
/// the manager's setters make sure only one is ever on.
enum TandemBasalControlMode: Hashable {
    /// The pump manages basal itself; Trio only monitors and (optionally) boluses.
    case none
    /// Trio sets real temp rates with the pump's own command. **Mobi only.**
    case nativeTempRate
    /// Trio delivers all basal as a stream of small automatic boluses. Works on
    /// either model, and is the only way to close the loop on a t:slim X2.
    case microbolus
}

/// Persisted state of the Tandem pump driver.
///
/// The pairing code doubles as the message-signing key on legacy-firmware
/// pumps, so it is stored here the same way sibling drivers persist their
/// session secrets. JPAKE pumps instead persist the derived shared secret and
/// re-key on every connection.
final class TandemPumpState: RawRepresentable {
    typealias RawValue = PumpManager.RawStateValue

    var isOnboarded: Bool
    /// CoreBluetooth identifier of the paired pump.
    var peripheralIdentifier: UUID?
    /// Which Tandem pump this is. Only the Mobi accepts remote basal commands.
    var pumpModel: TandemPumpModel
    /// Which pairing handshake the pump uses.
    var pairingCodeType: TandemPairingCodeType
    /// Normalized pairing code: 16 characters on legacy t:slim X2 software
    /// (where it is also the signing key), or 6 digits for JPAKE pumps.
    var pairingCode: String
    /// JPAKE shared secret established at pairing. Combined with a per-connection
    /// nonce from the pump it produces the message-signing key, so it must
    /// survive app restarts or the user would have to re-pair every launch.
    var jpakeDerivedSecret: Data?
    var pumpSerial: String
    var pumpModelNumber: String
    var firmwareVersion: String
    var apiVersionMajor: Int
    var apiVersionMinor: Int

    var lastSync: Date
    /// Units remaining, as reported by InsulinStatus (whole units, estimate).
    var reservoir: Double
    var reservoirIsEstimate: Bool
    var batteryPercent: Int?
    var batteryCharging: Bool
    /// Profile basal rate in U/hr from the pump's active profile.
    var profileBasalRate: Double
    /// Actual delivering rate in U/hr (Control-IQ adjusted).
    var currentBasalRate: Double
    var suspended: Bool
    /// Control-IQ is actively managing delivery on the pump.
    var controlIQEnabled: Bool
    var insulinType: InsulinType?

    /// The temp basal Trio commanded on a Mobi, tracked until it expires.
    var activeTempBasal: TandemActiveTempBasal?

    /// User opt-in for driving a cartridge change from Trio. Separate from the
    /// bolus and basal opt-ins because it is a different kind of risk: filling
    /// tubing and priming a cannula push insulin, and Trio cannot see whether
    /// the infusion set is connected to the body.
    var cartridgeChangeEnabled: Bool

    /// The cartridge change currently in progress, if any.
    var cartridgeSession: TandemCartridgeSession?

    /// True while the pump is in a cartridge change and must not be dosed.
    var cartridgeChangeInProgress: Bool {
        guard let session = cartridgeSession else { return false }
        return !session.isStale()
    }

    // MARK: Runtime-only cartridge state (NOT persisted)

    /// When the user last confirmed the infusion set is disconnected from their
    /// body. Deliberately not persisted: after an app restart the user must
    /// confirm again rather than inherit a confirmation Trio cannot vouch for.
    var cartridgeDisconnectConfirmedAt: Date?

    /// Most recent progress line from the pump's control stream, for display.
    var lastCartridgeEventDescription: String?

    /// The pump's active-alarm bitmask from the last AlarmStatus read, or nil
    /// if it has not been read this session. Runtime-only: an alarm state must
    /// be re-observed after a restart, never inherited.
    var activeAlarmBits: UInt64?

    /// Active-alert bitmask from the last AlertStatus read. Runtime-only for
    /// the same reason.
    var activeAlertBits: UInt64?

    /// Names of active notifications the cartridge screen may offer to
    /// acknowledge — cartridge-family alarms plus the started-but-unfinished
    /// load alerts that block resuming — or nil when there are none.
    var dismissableCartridgeAlarmNames: String? {
        var names: [String] = []
        if let bits = activeAlarmBits, bits != 0 {
            names += TandemAlarmStatusResponse(bitmask: bits).cartridgeRelatedBits
                .map(TandemAlarmStatusResponse.name(forBit:))
        }
        if let bits = activeAlertBits, bits != 0 {
            names += TandemAlertStatusResponse(bitmask: bits).incompleteLoadAlertBits
                .compactMap { TandemAlertStatusResponse.loadRelated[$0] }
        }
        guard !names.isEmpty else { return nil }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.joined(separator: " + ")
    }

    /// Where the user last said the infusion set is. Runtime-only for the same
    /// reason as the timestamp: a restart must not inherit it.
    var confirmedSetPlacement: TandemSetPlacement?

    /// How long a disconnect confirmation stays good for.
    static let disconnectConfirmationValidity: TimeInterval = .minutes(10)

    /// True when the user has recently confirmed the set is off their body.
    func hasFreshDisconnectConfirmation(at date: Date = Date()) -> Bool {
        guard let confirmed = cartridgeDisconnectConfirmedAt else { return false }
        return date.timeIntervalSince(confirmed) < Self.disconnectConfirmationValidity
    }

    /// User opt-in for remote insulin delivery actions (bolusing). Off by
    /// default; requires firmware with API >= 2.5 (t:slim X2 7.6+).
    var remoteBolusEnabled: Bool

    /// User opt-in for remote basal control: temp rate, suspend and resume.
    /// **Mobi only** — the t:slim X2 firmware does not implement those opcodes.
    /// This is what lets Trio actually close the loop, so it also requires the
    /// pump's own Control-IQ to be off (verified at each command).
    var remoteBasalEnabled: Bool

    /// True when any insulin-affecting command may be sent. Drives the session's
    /// `insulinDeliveryActionsEnabled` gate.
    ///
    /// The cartridge opt-in counts here because entering fill-tubing mode and
    /// priming the cannula are `modifiesInsulinDelivery` commands. This gate is
    /// only the outermost backstop — each command still checks its own opt-in,
    /// so enabling cartridge changes does not by itself permit a bolus.
    var insulinDeliveryActionsAllowed: Bool {
        remoteBolusEnabled || remoteBasalEnabled || cartridgeChangeEnabled
    }

    /// User opt-in for the microbolus-basal closed-loop mode: Trio delivers all
    /// basal/temp-basal as a stream of small boluses. REQUIRES the pump's own
    /// basal profile to be 0 U/hr and Control-IQ off, or delivery would stack
    /// on top of the pump's own delivery. Implies remoteBolusEnabled.
    var microbolusBasalEnabled: Bool

    /// Trio-commanded suspend of microbolus delivery (distinct from the pump's
    /// own `suspended`). With the pump basal zeroed, withholding microboluses
    /// is a true suspend.
    var microbolusSuspended: Bool

    /// Play a phone-side sound when the driver changes delivery (bolus accepted,
    /// cancel, suspend/resume). The t:slim X2 protocol has no remote beep
    /// command, so the phone provides the Omnipod-style audio indication.
    var audioFeedbackEnabled: Bool

    /// Also play the dose sound for automatic deliveries (SMBs and basal
    /// microboluses). Off by default — in microbolus-basal mode this sounds
    /// every loop cycle.
    var audioFeedbackForAutomaticDoses: Bool

    // MARK: Runtime-only microbolus-basal accumulator (NOT persisted)

    //
    // These are deliberately reset to zero on every manager construction
    // (including app restart). Persisting them would risk dumping stale accrued
    // basal after the app was closed for a long time. Losing at most one cycle's
    // worth of accrual on restart is the safe trade.

    /// Insulin (U) accrued from the commanded basal rate but not yet delivered
    /// because it was below the minimum bolus. Carried across cycles in-session.
    var owedBasalInsulin: Double
    /// The most recently commanded basal rate (U/hr) being integrated.
    var lastBasalRate: Double
    /// When `lastBasalRate` was last updated (start of the current accrual step).
    var lastBasalUpdate: Date?

    /// Runtime-only: recently handled bolus ids (driver-initiated pulses/SMBs
    /// and pump-UI boluses already recorded), for reconcile dedup. Bounded and
    /// wrap-around safe — only the most recent ids matter. NOT persisted.
    var recentBolusIds: [UInt16]
    var activeBolus: TandemActiveBolus?

    /// Remember a handled bolus id, evicting the oldest beyond the bound.
    func noteBolusId(_ id: UInt16) {
        guard !recentBolusIds.contains(id) else { return }
        recentBolusIds.append(id)
        let maxRecent = 64
        if recentBolusIds.count > maxRecent {
            recentBolusIds.removeFirst(recentBolusIds.count - maxRecent)
        }
    }

    func hasRecentBolusId(_ id: UInt16) -> Bool {
        recentBolusIds.contains(id)
    }

    /// Remote bolus requires API >= 2.5 per pumpx2 message gating.
    var supportsRemoteBolus: Bool {
        apiVersionMajor > 2 || (apiVersionMajor == 2 && apiVersionMinor >= 5)
    }

    /// True when Trio can drive basal with the pump's own temp-rate command.
    /// Mobi only; on the t:slim X2 the opcodes are not implemented in firmware.
    var supportsNativeBasalControl: Bool {
        pumpModel.supportsRemoteBasalControl
    }

    /// How basal is being driven right now.
    ///
    /// Microbolus takes precedence if both flags are somehow set, because it is
    /// the mode that delivers on its own initiative — preferring it means a
    /// stale `remoteBasalEnabled` can never add a temp rate on top of a
    /// microbolus stream.
    var basalControlMode: TandemBasalControlMode {
        if microbolusBasalEnabled { return .microbolus }
        if remoteBasalEnabled, supportsNativeBasalControl { return .nativeTempRate }
        return .none
    }

    var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        // A cartridge change stops delivery on the pump for its whole duration.
        if cartridgeChangeInProgress {
            return .suspended(cartridgeSession?.startedAt ?? lastSync)
        }
        // Either the pump's own suspend or a Trio-commanded microbolus suspend
        // stops delivery (with the pump basal zeroed, the latter is a true stop).
        if suspended || microbolusSuspended {
            return .suspended(lastSync)
        }
        if let temp = activeTempBasal, temp.isActive() {
            return .tempBasal(DoseEntry(
                type: .tempBasal,
                startDate: temp.startDate,
                endDate: temp.endDate,
                value: temp.unitsPerHour,
                unit: .unitsPerHour,
                insulinType: insulinType,
                automatic: true
            ))
        }
        return .active(lastSync == .distantPast ? .distantPast : lastSync)
    }

    var bolusDeliveryState: PumpManagerStatus.BolusState {
        if let bolus = activeBolus {
            return .inProgress(DoseEntry(
                type: .bolus,
                startDate: bolus.startDate,
                value: bolus.units,
                unit: .units,
                insulinType: insulinType,
                automatic: false,
                isMutable: true
            ))
        }
        return .noBolus
    }

    init() {
        isOnboarded = false
        peripheralIdentifier = nil
        pumpModel = .default
        pairingCodeType = .legacy16
        pairingCode = ""
        jpakeDerivedSecret = nil
        pumpSerial = ""
        pumpModelNumber = ""
        firmwareVersion = ""
        apiVersionMajor = 0
        apiVersionMinor = 0
        lastSync = .distantPast
        reservoir = 0
        reservoirIsEstimate = true
        batteryPercent = nil
        batteryCharging = false
        profileBasalRate = 0
        currentBasalRate = 0
        suspended = false
        controlIQEnabled = false
        insulinType = nil
        activeTempBasal = nil
        cartridgeChangeEnabled = false
        cartridgeSession = nil
        cartridgeDisconnectConfirmedAt = nil
        lastCartridgeEventDescription = nil
        confirmedSetPlacement = nil
        remoteBolusEnabled = false
        remoteBasalEnabled = false
        microbolusBasalEnabled = false
        microbolusSuspended = false
        audioFeedbackEnabled = true
        audioFeedbackForAutomaticDoses = false
        owedBasalInsulin = 0
        lastBasalRate = 0
        lastBasalUpdate = nil
        recentBolusIds = []
        activeBolus = nil
    }

    required convenience init(rawValue: RawValue) {
        self.init()
        isOnboarded = rawValue["isOnboarded"] as? Bool ?? false
        if let identifier = rawValue["peripheralIdentifier"] as? String {
            peripheralIdentifier = UUID(uuidString: identifier)
        }
        pairingCode = rawValue["pairingCode"] as? String ?? ""
        jpakeDerivedSecret = rawValue["jpakeDerivedSecret"] as? Data
        if let rawModel = rawValue["pumpModel"] as? String, let model = TandemPumpModel(rawValue: rawModel) {
            pumpModel = model
        }
        if let rawCodeType = rawValue["pairingCodeType"] as? String,
           let codeType = TandemPairingCodeType(rawValue: rawCodeType)
        {
            pairingCodeType = codeType
        } else {
            // Pre-Mobi state has no stored code type; infer it from the code we
            // already have so an existing t:slim X2 pairing keeps working.
            pairingCodeType = TandemPairingCodeType.from(pairingCode: pairingCode) ?? .legacy16
        }
        pumpSerial = rawValue["pumpSerial"] as? String ?? ""
        pumpModelNumber = rawValue["pumpModelNumber"] as? String ?? ""
        firmwareVersion = rawValue["firmwareVersion"] as? String ?? ""
        apiVersionMajor = rawValue["apiVersionMajor"] as? Int ?? 0
        apiVersionMinor = rawValue["apiVersionMinor"] as? Int ?? 0
        lastSync = rawValue["lastSync"] as? Date ?? .distantPast
        reservoir = rawValue["reservoir"] as? Double ?? 0
        reservoirIsEstimate = rawValue["reservoirIsEstimate"] as? Bool ?? true
        batteryPercent = rawValue["batteryPercent"] as? Int
        batteryCharging = rawValue["batteryCharging"] as? Bool ?? false
        profileBasalRate = rawValue["profileBasalRate"] as? Double ?? 0
        currentBasalRate = rawValue["currentBasalRate"] as? Double ?? 0
        suspended = rawValue["suspended"] as? Bool ?? false
        controlIQEnabled = rawValue["controlIQEnabled"] as? Bool ?? false
        remoteBolusEnabled = rawValue["remoteBolusEnabled"] as? Bool ?? false
        remoteBasalEnabled = rawValue["remoteBasalEnabled"] as? Bool ?? false
        cartridgeChangeEnabled = rawValue["cartridgeChangeEnabled"] as? Bool ?? false
        if let rawCartridgeSession = rawValue["cartridgeSession"] as? Data {
            cartridgeSession = try? JSONDecoder().decode(TandemCartridgeSession.self, from: rawCartridgeSession)
        }
        // cartridgeDisconnectConfirmedAt is runtime-only: a restart must not
        // inherit a confirmation that the set is off the body.
        microbolusBasalEnabled = rawValue["microbolusBasalEnabled"] as? Bool ?? false
        microbolusSuspended = rawValue["microbolusSuspended"] as? Bool ?? false
        audioFeedbackEnabled = rawValue["audioFeedbackEnabled"] as? Bool ?? true
        audioFeedbackForAutomaticDoses = rawValue["audioFeedbackForAutomaticDoses"] as? Bool ?? false
        // owedBasalInsulin / lastBasalRate / lastBasalUpdate / recentBolusIds
        // are runtime-only: they keep the init() defaults so the accumulator and
        // dedup state always start fresh after a restart, never dumping stale
        // accrued basal.
        if let rawInsulinType = rawValue["insulinType"] as? InsulinType.RawValue {
            insulinType = InsulinType(rawValue: rawInsulinType)
        }
        if let rawActiveBolus = rawValue["activeBolus"] as? Data {
            activeBolus = try? JSONDecoder().decode(TandemActiveBolus.self, from: rawActiveBolus)
        }
        if let rawTempBasal = rawValue["activeTempBasal"] as? Data {
            activeTempBasal = try? JSONDecoder().decode(TandemActiveTempBasal.self, from: rawTempBasal)
        }
    }

    var rawValue: RawValue {
        var value: [String: Any] = [:]
        value["isOnboarded"] = isOnboarded
        value["peripheralIdentifier"] = peripheralIdentifier?.uuidString
        value["pairingCode"] = pairingCode
        value["jpakeDerivedSecret"] = jpakeDerivedSecret
        value["pumpModel"] = pumpModel.rawValue
        value["pairingCodeType"] = pairingCodeType.rawValue
        value["pumpSerial"] = pumpSerial
        value["pumpModelNumber"] = pumpModelNumber
        value["firmwareVersion"] = firmwareVersion
        value["apiVersionMajor"] = apiVersionMajor
        value["apiVersionMinor"] = apiVersionMinor
        value["lastSync"] = lastSync
        value["reservoir"] = reservoir
        value["reservoirIsEstimate"] = reservoirIsEstimate
        value["batteryPercent"] = batteryPercent
        value["batteryCharging"] = batteryCharging
        value["profileBasalRate"] = profileBasalRate
        value["currentBasalRate"] = currentBasalRate
        value["suspended"] = suspended
        value["controlIQEnabled"] = controlIQEnabled
        value["remoteBolusEnabled"] = remoteBolusEnabled
        value["remoteBasalEnabled"] = remoteBasalEnabled
        value["cartridgeChangeEnabled"] = cartridgeChangeEnabled
        if let cartridgeSession = cartridgeSession {
            value["cartridgeSession"] = try? JSONEncoder().encode(cartridgeSession)
        }
        value["microbolusBasalEnabled"] = microbolusBasalEnabled
        value["microbolusSuspended"] = microbolusSuspended
        value["audioFeedbackEnabled"] = audioFeedbackEnabled
        value["audioFeedbackForAutomaticDoses"] = audioFeedbackForAutomaticDoses
        // owedBasalInsulin / lastBasalRate / lastBasalUpdate / recentBolusIds
        // are intentionally NOT persisted (runtime-only; see declarations).
        value["insulinType"] = insulinType?.rawValue
        if let activeBolus = activeBolus {
            value["activeBolus"] = try? JSONEncoder().encode(activeBolus)
        }
        if let activeTempBasal = activeTempBasal {
            value["activeTempBasal"] = try? JSONEncoder().encode(activeTempBasal)
        }
        return value
    }

    var debugDescription: String {
        """
        TandemPumpState(
          onboarded: \(isOnboarded), pump: \(pumpModel.localizedTitle), serial: \(pumpSerial),
          modelNumber: \(pumpModelNumber), pairing: \(pairingCodeType.rawValue),
          firmware: \(firmwareVersion), api: \(apiVersionMajor).\(apiVersionMinor),
          lastSync: \(lastSync), reservoir: \(reservoir)u\(reservoirIsEstimate ? " (estimate)" : ""),
          battery: \(batteryPercent.map(String.init) ?? "-")%, basal: \(currentBasalRate)/\(profileBasalRate) U/hr,
          suspended: \(suspended), controlIQ: \(controlIQEnabled), remoteBolusEnabled: \(remoteBolusEnabled),
          tempBasal: \(activeTempBasal.map { "\($0.unitsPerHour) U/hr until \($0.endDate)" } ?? "none")
        )
        """
    }
}
