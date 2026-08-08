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

    /// Highest bolus id already reported to Trio, for deduplication.
    var lastReportedBolusId: UInt16
    var activeBolus: TandemActiveBolus?

    /// Remote bolus requires API >= 2.5 per pumpx2 message gating.
    var supportsRemoteBolus: Bool {
        apiVersionMajor > 2 || (apiVersionMajor == 2 && apiVersionMinor >= 5)
    }

    var basalDeliveryState: PumpManagerStatus.BasalDeliveryState {
        if suspended {
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
        lastReportedBolusId = 0
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
        lastReportedBolusId = UInt16(rawValue["lastReportedBolusId"] as? Int ?? 0)
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
        value["lastReportedBolusId"] = Int(lastReportedBolusId)
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
