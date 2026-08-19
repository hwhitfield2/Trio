import Foundation

/// Message definitions for the Tandem BLE protocol.
///
/// Byte layouts are transcribed from the reverse-engineered pumpx2 library
/// (jwoglom/pumpx2, messages/); multi-byte integers are little-endian.
/// Opcode namespaces are per characteristic: e.g. opcode 32 is
/// ApiVersionRequest on the current-status characteristic but
/// Jpake1aRequest on the authorization characteristic.

enum TandemCharacteristic {
    case currentStatus
    case authorization
    case control
    /// Progress the pump pushes without being asked, during long-running
    /// operations like a cartridge change. Never carries a reply to a request.
    case controlStream
    case historyLog
}

protocol TandemRequest {
    associatedtype Response: TandemResponse
    static var opcode: UInt8 { get }
    static var characteristic: TandemCharacteristic { get }
    static var signed: Bool { get }
    /// Requests that start, change, or stop insulin delivery. These are
    /// refused unless the user has explicitly enabled remote delivery
    /// actions (mirrors pumpx2's actionsAffectingInsulinDelivery gate).
    static var modifiesInsulinDelivery: Bool { get }
    var cargo: Data { get }
}

extension TandemRequest {
    static var characteristic: TandemCharacteristic { .currentStatus }
    static var signed: Bool { false }
    static var modifiesInsulinDelivery: Bool { false }
    var cargo: Data { Data() }
}

protocol TandemResponse {
    static var opcode: UInt8 { get }
    /// Signed responses arrive with a 24-byte time/HMAC trailer appended to
    /// their cargo; `init(cargo:)` receives the cargo with trailer removed.
    static var signed: Bool { get }
    init(cargo: Data) throws
}

extension TandemResponse {
    static var signed: Bool { false }
}

enum TandemMessageError: LocalizedError {
    case unexpectedCargoSize(message: String, expected: Int, actual: Int)
    case pumpError(TandemErrorResponse)
    case unexpectedResponseOpcode(found: UInt8, expected: UInt8)

    var errorDescription: String? {
        switch self {
        case let .unexpectedCargoSize(message, expected, actual):
            return "Unexpected \(message) cargo size \(actual) (expected \(expected))."
        case let .pumpError(error):
            return "Pump rejected the request: \(error.localizedDescription)."
        case let .unexpectedResponseOpcode(found, expected):
            return "Unexpected pump response opcode \(found) (expected \(expected))."
        }
    }
}

private func validateCargo(_ cargo: Data, _ expected: Int, _ message: String) throws {
    guard cargo.count == expected else {
        throw TandemMessageError.unexpectedCargoSize(message: message, expected: expected, actual: cargo.count)
    }
}

extension Data {
    func tandemUInt16(at offset: Int) -> UInt16 {
        let bytes = [UInt8](self)
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    func tandemUInt32(at offset: Int) -> UInt32 {
        let bytes = [UInt8](self)
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    func tandemUInt64(at offset: Int) -> UInt64 {
        UInt64(tandemUInt32(at: offset)) | (UInt64(tandemUInt32(at: offset + 4)) << 32)
    }

    mutating func appendTandemUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendTandemUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

/// ErrorResponse (opcode 77) can arrive on any characteristic in place of
/// the expected response; cargo is 2 bytes (or 26 in some situations).
struct TandemErrorResponse: TandemResponse {
    static let opcode: UInt8 = 77
    /// Which request the pump is complaining about. pumpX2 documents this as
    /// the failing request's opcode, at least for a parameter error.
    let requestCodeId: UInt8
    let errorCodeId: UInt8

    /// The pump's reason, from pumpX2's `ErrorResponse.ErrorCode`.
    ///
    /// Worth naming rather than printing a bare number: "undefined error" and
    /// "bad opcode" and "invalid authentication" are three completely different
    /// diagnoses, and the number alone sends whoever is reading the message
    /// looking in the wrong place.
    enum ErrorCode: UInt8 {
        case undefined = 0
        case crcMismatch = 1
        case transactionIdMismatch = 3
        case badCargoLength = 4
        case badOpcode = 6
        case invalidRequiredParameter = 7
        case messageBufferFull = 8
        case invalidAuthentication = 9

        var localizedDescription: String {
            switch self {
            case .undefined:
                return String(localized: "undefined error")
            case .crcMismatch:
                return String(localized: "CRC mismatch")
            case .transactionIdMismatch:
                return String(localized: "transaction id mismatch")
            case .badCargoLength:
                return String(localized: "bad cargo length")
            case .badOpcode:
                return String(localized: "unrecognised command")
            case .invalidRequiredParameter:
                return String(localized: "invalid parameter")
            case .messageBufferFull:
                return String(localized: "message buffer full")
            case .invalidAuthentication:
                return String(localized: "invalid authentication")
            }
        }
    }

    var errorCode: ErrorCode? { ErrorCode(rawValue: errorCodeId) }

    /// "undefined error (code 0), request 0xf4" — everything there is to know
    /// about a refusal, in one line fit for a log or an alert.
    var localizedDescription: String {
        let name = errorCode?.localizedDescription ?? String(localized: "unknown error")
        let request = String(format: "0x%02x", requestCodeId)
        return String(localized: "\(name) (code \(Int(errorCodeId))), request \(request)")
    }

    init(cargo: Data) throws {
        guard cargo.count >= 2 else {
            throw TandemMessageError.unexpectedCargoSize(message: "ErrorResponse", expected: 2, actual: cargo.count)
        }
        let bytes = [UInt8](cargo)
        requestCodeId = bytes[0]
        errorCodeId = bytes[1]
    }
}

// MARK: - Authentication (legacy 16-character pairing code flow)

struct TandemCentralChallengeRequest: TandemRequest {
    typealias Response = TandemCentralChallengeResponse
    static let opcode: UInt8 = 16
    static let characteristic: TandemCharacteristic = .authorization

    let appInstanceId: UInt16
    let centralChallenge: Data // 8 bytes

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(appInstanceId)
        data.append(centralChallenge.prefix(8))
        return data
    }
}

struct TandemCentralChallengeResponse: TandemResponse {
    static let opcode: UInt8 = 17
    let appInstanceId: UInt16
    let centralChallengeHash: Data // 20 bytes
    let hmacKey: Data // 8 bytes

    init(cargo: Data) throws {
        try validateCargo(cargo, 30, "CentralChallengeResponse")
        appInstanceId = cargo.tandemUInt16(at: 0)
        centralChallengeHash = cargo.subdata(in: cargo.startIndex + 2 ..< cargo.startIndex + 22)
        hmacKey = cargo.subdata(in: cargo.startIndex + 22 ..< cargo.startIndex + 30)
    }
}

struct TandemPumpChallengeRequest: TandemRequest {
    typealias Response = TandemPumpChallengeResponse
    static let opcode: UInt8 = 18
    static let characteristic: TandemCharacteristic = .authorization

    let appInstanceId: UInt16
    // 20 bytes. Per pumpx2 doHmacSha1(hmacKey, pairingChars) — data=hmacKey,
    // key=pairingChars — this is HMAC-SHA1(key: pairing code UTF-8, message:
    // the pump's 8-byte hmacKey). See TandemPumpSession.authenticate.
    let pumpChallengeHash: Data

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(appInstanceId)
        data.append(pumpChallengeHash.prefix(20))
        return data
    }
}

struct TandemPumpChallengeResponse: TandemResponse {
    static let opcode: UInt8 = 19
    let appInstanceId: UInt16
    let success: Bool

    init(cargo: Data) throws {
        try validateCargo(cargo, 3, "PumpChallengeResponse")
        appInstanceId = cargo.tandemUInt16(at: 0)
        success = [UInt8](cargo)[2] == 1
    }
}

// MARK: - Current status

struct TandemApiVersionRequest: TandemRequest {
    typealias Response = TandemApiVersionResponse
    static let opcode: UInt8 = 32
}

struct TandemApiVersionResponse: TandemResponse {
    static let opcode: UInt8 = 33
    let majorVersion: UInt16
    let minorVersion: UInt16

    init(cargo: Data) throws {
        try validateCargo(cargo, 4, "ApiVersionResponse")
        majorVersion = cargo.tandemUInt16(at: 0)
        minorVersion = cargo.tandemUInt16(at: 2)
    }
}

struct TandemTimeSinceResetRequest: TandemRequest {
    typealias Response = TandemTimeSinceResetResponse
    static let opcode: UInt8 = 54
}

struct TandemTimeSinceResetResponse: TandemResponse {
    static let opcode: UInt8 = 55
    /// Seconds since the Tandem epoch (2008-01-01 00:00:00 UTC) per pumpx2.
    let currentTime: UInt32
    /// Seconds since the pump's processor last reset; used for message signing.
    let pumpTimeSinceReset: UInt32

    init(cargo: Data) throws {
        try validateCargo(cargo, 8, "TimeSinceResetResponse")
        currentTime = cargo.tandemUInt32(at: 0)
        pumpTimeSinceReset = cargo.tandemUInt32(at: 4)
    }
}

struct TandemPumpVersionRequest: TandemRequest {
    typealias Response = TandemPumpVersionResponse
    static let opcode: UInt8 = 84
}

struct TandemPumpVersionResponse: TandemResponse {
    static let opcode: UInt8 = 85
    let armSwVer: UInt32
    let serialNum: UInt32
    let modelNum: UInt32

    init(cargo: Data) throws {
        try validateCargo(cargo, 48, "PumpVersionResponse")
        armSwVer = cargo.tandemUInt32(at: 0)
        serialNum = cargo.tandemUInt32(at: 16)
        modelNum = cargo.tandemUInt32(at: 44)
    }
}

struct TandemCurrentBatteryV1Request: TandemRequest {
    typealias Response = TandemCurrentBatteryV1Response
    static let opcode: UInt8 = 52
}

struct TandemCurrentBatteryV1Response: TandemResponse {
    static let opcode: UInt8 = 53
    /// Battery percent as displayed on the pump.
    let currentBatteryIbc: UInt8

    init(cargo: Data) throws {
        try validateCargo(cargo, 2, "CurrentBatteryV1Response")
        currentBatteryIbc = [UInt8](cargo)[1]
    }
}

/// API >= 2.5 replacement for CurrentBatteryV1 (opcode 0x90/0x91).
struct TandemCurrentBatteryV2Request: TandemRequest {
    typealias Response = TandemCurrentBatteryV2Response
    static let opcode: UInt8 = 0x90
}

struct TandemCurrentBatteryV2Response: TandemResponse {
    static let opcode: UInt8 = 0x91
    let currentBatteryIbc: UInt8
    let chargingStatus: UInt8

    init(cargo: Data) throws {
        try validateCargo(cargo, 11, "CurrentBatteryV2Response")
        let bytes = [UInt8](cargo)
        currentBatteryIbc = bytes[1]
        chargingStatus = bytes[2]
    }
}

struct TandemInsulinStatusRequest: TandemRequest {
    typealias Response = TandemInsulinStatusResponse
    static let opcode: UInt8 = 36
}

struct TandemInsulinStatusResponse: TandemResponse {
    static let opcode: UInt8 = 37
    /// Units remaining in the reservoir (whole units; an estimate below ~40u).
    let currentInsulinAmount: UInt16
    let isEstimate: Bool
    let insulinLowAmount: UInt8

    init(cargo: Data) throws {
        try validateCargo(cargo, 4, "InsulinStatusResponse")
        let bytes = [UInt8](cargo)
        currentInsulinAmount = cargo.tandemUInt16(at: 0)
        isEstimate = bytes[2] != 0
        insulinLowAmount = bytes[3]
    }
}

struct TandemCurrentBasalStatusRequest: TandemRequest {
    typealias Response = TandemCurrentBasalStatusResponse
    static let opcode: UInt8 = 40
}

struct TandemCurrentBasalStatusResponse: TandemResponse {
    static let opcode: UInt8 = 41
    /// Profile (programmed) basal rate in milliunits/hour.
    let profileBasalRate: UInt32
    /// Currently delivering basal rate in milliunits/hour (after Control-IQ
    /// adjustment, temp rate, or suspension).
    let currentBasalRate: UInt32
    let basalModifiedBitmask: UInt8

    init(cargo: Data) throws {
        try validateCargo(cargo, 9, "CurrentBasalStatusResponse")
        profileBasalRate = cargo.tandemUInt32(at: 0)
        currentBasalRate = cargo.tandemUInt32(at: 4)
        basalModifiedBitmask = [UInt8](cargo)[8]
    }
}

struct TandemCurrentBolusStatusRequest: TandemRequest {
    typealias Response = TandemCurrentBolusStatusResponse
    static let opcode: UInt8 = 44
}

struct TandemCurrentBolusStatusResponse: TandemResponse {
    static let opcode: UInt8 = 45
    let statusId: UInt8
    let bolusId: UInt16
    /// Seconds since the Tandem epoch.
    let timestamp: UInt32
    /// Requested volume in milliunits.
    let requestedVolume: UInt32
    let bolusSourceId: UInt8
    let bolusTypeBitmask: UInt8

    init(cargo: Data) throws {
        try validateCargo(cargo, 15, "CurrentBolusStatusResponse")
        let bytes = [UInt8](cargo)
        statusId = bytes[0]
        bolusId = cargo.tandemUInt16(at: 1)
        timestamp = cargo.tandemUInt32(at: 5)
        requestedVolume = cargo.tandemUInt32(at: 9)
        bolusSourceId = bytes[13]
        bolusTypeBitmask = bytes[14]
    }
}

/// API >= 2.5. Opcode 0xA4/0xA5 on the current-status characteristic.
struct TandemLastBolusStatusV2Request: TandemRequest {
    typealias Response = TandemLastBolusStatusV2Response
    static let opcode: UInt8 = 0xA4
}

struct TandemLastBolusStatusV2Response: TandemResponse {
    static let opcode: UInt8 = 0xA5
    let status: UInt8
    let bolusId: UInt16
    /// Seconds since the Tandem epoch.
    let timestamp: UInt32
    /// Delivered volume in milliunits.
    let deliveredVolume: UInt32
    let bolusStatusId: UInt8
    let bolusSourceId: UInt8
    let bolusTypeBitmask: UInt8
    let extendedBolusDuration: UInt32
    /// Requested volume in milliunits.
    let requestedVolume: UInt32

    init(cargo: Data) throws {
        try validateCargo(cargo, 24, "LastBolusStatusV2Response")
        let bytes = [UInt8](cargo)
        status = bytes[0]
        bolusId = cargo.tandemUInt16(at: 1)
        timestamp = cargo.tandemUInt32(at: 5)
        deliveredVolume = cargo.tandemUInt32(at: 9)
        bolusStatusId = bytes[13]
        bolusSourceId = bytes[14]
        bolusTypeBitmask = bytes[15]
        extendedBolusDuration = cargo.tandemUInt32(at: 16)
        requestedVolume = cargo.tandemUInt32(at: 20)
    }
}

struct TandemControlIQInfoV1Request: TandemRequest {
    typealias Response = TandemControlIQInfoV1Response
    static let opcode: UInt8 = 104
}

struct TandemControlIQInfoV1Response: TandemResponse {
    static let opcode: UInt8 = 105
    /// True when Control-IQ is actively adjusting delivery on the pump.
    let closedLoopEnabled: Bool
    let currentUserModeType: UInt8

    init(cargo: Data) throws {
        try validateCargo(cargo, 10, "ControlIQInfoV1Response")
        let bytes = [UInt8](cargo)
        closedLoopEnabled = bytes[0] != 0
        currentUserModeType = bytes[5]
    }
}

struct TandemHomeScreenMirrorRequest: TandemRequest {
    typealias Response = TandemHomeScreenMirrorResponse
    static let opcode: UInt8 = 56
}

struct TandemHomeScreenMirrorResponse: TandemResponse {
    static let opcode: UInt8 = 57
    let cgmTrendIconId: UInt8
    let bolusStatusIconId: UInt8
    let basalStatusIconId: UInt8
    let apControlStateIconId: UInt8

    init(cargo: Data) throws {
        try validateCargo(cargo, 9, "HomeScreenMirrorResponse")
        let bytes = [UInt8](cargo)
        cgmTrendIconId = bytes[0]
        bolusStatusIconId = bytes[4]
        basalStatusIconId = bytes[5]
        apControlStateIconId = bytes[6]
    }
}

struct TandemCurrentEGVGuiDataRequest: TandemRequest {
    typealias Response = TandemCurrentEGVGuiDataResponse
    static let opcode: UInt8 = 34
}

struct TandemCurrentEGVGuiDataResponse: TandemResponse {
    static let opcode: UInt8 = 35
    /// Seconds since the Tandem epoch.
    let bgReadingTimestampSeconds: UInt32
    /// CGM reading in mg/dL.
    let cgmReading: UInt16
    let egvStatusId: UInt8
    let trendRate: Int8

    init(cargo: Data) throws {
        try validateCargo(cargo, 8, "CurrentEGVGuiDataResponse")
        let bytes = [UInt8](cargo)
        bgReadingTimestampSeconds = cargo.tandemUInt32(at: 0)
        cgmReading = cargo.tandemUInt16(at: 4)
        egvStatusId = bytes[6]
        trendRate = Int8(bitPattern: bytes[7])
    }
}

// MARK: - Qualifying events

/// Bitmask delivered on the qualifying-events characteristic when pump
/// state changes out-of-band (per pumpx2 QualifyingEvent).
struct TandemQualifyingEvents: OptionSet {
    let rawValue: UInt32

    static let alert = TandemQualifyingEvents(rawValue: 1)
    static let alarm = TandemQualifyingEvents(rawValue: 2)
    static let reminder = TandemQualifyingEvents(rawValue: 4)
    static let malfunction = TandemQualifyingEvents(rawValue: 8)
    static let cgmAlert = TandemQualifyingEvents(rawValue: 16)
    static let homeScreenChange = TandemQualifyingEvents(rawValue: 32)
    static let pumpSuspend = TandemQualifyingEvents(rawValue: 64)
    static let pumpResume = TandemQualifyingEvents(rawValue: 128)
    static let timeChange = TandemQualifyingEvents(rawValue: 256)
    static let basalChange = TandemQualifyingEvents(rawValue: 512)
    static let bolusChange = TandemQualifyingEvents(rawValue: 1024)
}

/// The pump's global settings — read here for the seven annunciation modes,
/// which say whether each category of pump feedback is a tone (at one of three
/// volumes) or a vibration.
///
/// Unsigned, current-status, free to read. The annunciation fields matter to
/// the glucose-alarm probe: the pump has refused `PlaySound` (status 1) with a
/// valid signature, insulin running and no alarms, and the leading suspect is
/// a pump-side sound-mode gate. These fields are how that gets confirmed or
/// eliminated from a field report.
struct TandemPumpGlobalsRequest: TandemRequest {
    typealias Response = TandemPumpGlobalsResponse
    static let opcode: UInt8 = 86
}

/// One of the pump's annunciation modes, per pumpX2's `AnnunciationEnum`.
enum TandemAnnunciationMode: UInt8 {
    case audioHigh = 0
    case audioMedium = 1
    case audioLow = 2
    case vibrate = 3

    var localizedDescription: String {
        switch self {
        case .audioHigh: return String(localized: "loud")
        case .audioMedium: return String(localized: "medium")
        case .audioLow: return String(localized: "quiet")
        case .vibrate: return String(localized: "vibrate")
        }
    }
}

struct TandemPumpGlobalsResponse: TandemResponse {
    static let opcode: UInt8 = 87

    let quickBolusEnabled: Bool
    let buttonAnnunId: UInt8
    let quickBolusAnnunId: UInt8
    let bolusAnnunId: UInt8
    let reminderAnnunId: UInt8
    let alertAnnunId: UInt8
    let alarmAnnunId: UInt8
    let fillTubingAnnunId: UInt8

    init(cargo: Data) throws {
        guard cargo.count >= 14 else {
            throw TandemMessageError.unexpectedCargoSize(message: "PumpGlobalsResponse", expected: 14, actual: cargo.count)
        }
        let bytes = [UInt8](cargo)
        quickBolusEnabled = bytes[0] == 1
        // bytes 1-6 are quick-bolus increments and entry type, not needed here.
        buttonAnnunId = bytes[7]
        quickBolusAnnunId = bytes[8]
        bolusAnnunId = bytes[9]
        reminderAnnunId = bytes[10]
        alertAnnunId = bytes[11]
        alarmAnnunId = bytes[12]
        fillTubingAnnunId = bytes[13]
    }

    private static func name(_ id: UInt8) -> String {
        TandemAnnunciationMode(rawValue: id)?.localizedDescription ?? String(localized: "mode \(Int(id))")
    }

    /// "button vibrate, bolus quiet, alarm loud, …" — one line for the probe's
    /// pump-state report.
    var localizedSoundSummary: String {
        let pairs: [(String, UInt8)] = [
            (String(localized: "button"), buttonAnnunId),
            (String(localized: "bolus"), bolusAnnunId),
            (String(localized: "reminder"), reminderAnnunId),
            (String(localized: "alert"), alertAnnunId),
            (String(localized: "alarm"), alarmAnnunId)
        ]
        return pairs.map { "\($0.0) \(Self.name($0.1))" }.joined(separator: ", ")
    }

    /// True when every category is vibration — the configuration most likely
    /// to make the pump decline to play a speaker tone.
    var allVibrate: Bool {
        [buttonAnnunId, bolusAnnunId, reminderAnnunId, alertAnnunId, alarmAnnunId]
            .allSatisfy { $0 == TandemAnnunciationMode.vibrate.rawValue }
    }
}
