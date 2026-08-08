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

/// Persisted state of the Tandem pump driver.
///
/// The pairing code doubles as the message-signing key on legacy-firmware
/// pumps, so it is stored here the same way sibling drivers persist their
/// session secrets.
final class TandemPumpState: RawRepresentable {
    typealias RawValue = PumpManager.RawStateValue

    var isOnboarded: Bool
    /// CoreBluetooth identifier of the paired pump.
    var peripheralIdentifier: UUID?
    /// Normalized 16-character pairing code; also the signing key.
    var pairingCode: String
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

    /// User opt-in for remote insulin delivery actions (bolusing). Off by
    /// default; requires firmware with API >= 2.5 (t:slim X2 7.6+).
    var remoteBolusEnabled: Bool

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

    var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        // Either the pump's own suspend or a Trio-commanded microbolus suspend
        // stops delivery (with the pump basal zeroed, the latter is a true stop).
        if suspended || microbolusSuspended {
            return .suspended(lastSync)
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
        pairingCode = ""
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
        remoteBolusEnabled = false
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
    }

    var rawValue: RawValue {
        var value: [String: Any] = [:]
        value["isOnboarded"] = isOnboarded
        value["peripheralIdentifier"] = peripheralIdentifier?.uuidString
        value["pairingCode"] = pairingCode
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
        return value
    }

    var debugDescription: String {
        """
        TandemPumpState(
          onboarded: \(isOnboarded), serial: \(pumpSerial), model: \(pumpModelNumber),
          firmware: \(firmwareVersion), api: \(apiVersionMajor).\(apiVersionMinor),
          lastSync: \(lastSync), reservoir: \(reservoir)u\(reservoirIsEstimate ? " (estimate)" : ""),
          battery: \(batteryPercent.map(String.init) ?? "-")%, basal: \(currentBasalRate)/\(profileBasalRate) U/hr,
          suspended: \(suspended), controlIQ: \(controlIQEnabled), remoteBolusEnabled: \(remoteBolusEnabled)
        )
        """
    }
}
