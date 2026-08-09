import Foundation

/// Control-characteristic (signed) messages.
///
/// All of these require an established authentication key and a fresh
/// pump-time-since-reset value for the HMAC trailer. Requests marked
/// `modifiesInsulinDelivery` are additionally refused by the session unless
/// remote delivery actions have been explicitly enabled by the user.
///
/// Device support per pumpx2 `@MessageProps`:
/// - Bolus permission/initiate/cancel: t:slim X2 (API >= 2.5, i.e. firmware
///   7.6+) and Mobi.
/// - Temp rate, stop temp rate, suspend, resume: Mobi only. The t:slim X2
///   does not accept remote basal modulation — Control-IQ runs on-pump.

// MARK: - Bolus permission flow

struct TandemBolusPermissionRequest: TandemRequest {
    typealias Response = TandemBolusPermissionResponse
    static let opcode: UInt8 = 0xA2
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
}

struct TandemBolusPermissionResponse: TandemResponse {
    static let opcode: UInt8 = 0xA3
    static let signed = true
    let status: UInt8
    let bolusId: UInt16
    let nackReasonId: UInt8

    /// isPermissionGranted per pumpx2: status 0 AND nackReason PERMISSION_GRANTED(0).
    /// A status-0 response with a non-zero nack reason is NOT a grant.
    var granted: Bool { status == 0 && nackReasonId == 0 }

    init(cargo: Data) throws {
        guard cargo.count >= 6 else {
            throw TandemMessageError.unexpectedCargoSize(message: "BolusPermissionResponse", expected: 6, actual: cargo.count)
        }
        let bytes = [UInt8](cargo)
        status = bytes[0]
        bolusId = cargo.tandemUInt16(at: 1)
        nackReasonId = bytes[5]
    }
}

struct TandemBolusPermissionReleaseRequest: TandemRequest {
    typealias Response = TandemBolusPermissionReleaseResponse
    static let opcode: UInt8 = 0xF0
    static let characteristic: TandemCharacteristic = .control
    static let signed = true

    let bolusId: UInt16

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(bolusId)
        data.appendTandemUInt16(0)
        return data
    }
}

struct TandemBolusPermissionReleaseResponse: TandemResponse {
    static let opcode: UInt8 = 0xF1
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(message: "BolusPermissionReleaseResponse", expected: 1, actual: 0)
        }
        status = first
    }
}

// MARK: - Bolus delivery

struct TandemInitiateBolusRequest: TandemRequest {
    typealias Response = TandemInitiateBolusResponse
    static let opcode: UInt8 = 0x9E
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true

    /// Smallest bolus we will command, in milliunits. The cargo is milliunits
    /// (0.001 U), but the firmware enforces a 0.05 U floor on remote boluses:
    /// empirically confirmed on a t:slim X2 running 7.6.0.1 via the settings
    /// minimum-dose test — 0.05 U is accepted, smaller amounts are rejected
    /// at initiate with status 1 (matching pumpx2's 0.05 U validation floor).
    /// Above the floor the wire still carries milliunit resolution, so
    /// amounts like 0.053 U remain expressible. A pump nack of a too-small
    /// pulse is handled gracefully (permission released, no delivery), so a
    /// firmware with a different floor fails safe.
    static let minBolusMilliunits: UInt32 = 50

    /// Total bolus volume in milliunits.
    let totalVolume: UInt32
    /// Bolus id obtained from a granted BolusPermissionResponse.
    let bolusId: UInt16
    /// 8 = standard bolus initiated remotely (matches observed t:connect traffic).
    let bolusTypeBitmask: UInt8
    let foodVolume: UInt32
    let correctionVolume: UInt32

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt32(totalVolume)
        data.appendTandemUInt16(bolusId)
        data.appendTandemUInt16(0)
        data.append(bolusTypeBitmask)
        data.appendTandemUInt32(foodVolume)
        data.appendTandemUInt32(correctionVolume)
        data.appendTandemUInt16(0) // bolusCarbs
        data.appendTandemUInt16(0) // bolusBG
        data.appendTandemUInt32(0) // bolusIOB
        data.appendTandemUInt32(0) // extendedVolume
        data.appendTandemUInt32(0) // extendedSeconds
        data.appendTandemUInt32(0) // extended3
        return data
    }
}

struct TandemInitiateBolusResponse: TandemResponse {
    static let opcode: UInt8 = 0x9F
    static let signed = true
    let status: UInt8
    let bolusId: UInt16
    let statusTypeId: UInt8

    /// wasBolusInitiated per pumpx2: status 0 AND statusType SUCCESS(0).
    /// A status-0 response with a non-SUCCESS type (e.g. REVOKED_PRIORITY) is
    /// NOT an initiated bolus.
    var accepted: Bool { status == 0 && statusTypeId == 0 }

    init(cargo: Data) throws {
        guard cargo.count >= 6 else {
            throw TandemMessageError.unexpectedCargoSize(message: "InitiateBolusResponse", expected: 6, actual: cargo.count)
        }
        let bytes = [UInt8](cargo)
        status = bytes[0]
        bolusId = cargo.tandemUInt16(at: 1)
        statusTypeId = bytes[5]
    }
}

struct TandemCancelBolusRequest: TandemRequest {
    typealias Response = TandemCancelBolusResponse
    static let opcode: UInt8 = 0xA0
    static let characteristic: TandemCharacteristic = .control
    static let signed = true

    let bolusId: UInt16

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(bolusId)
        data.appendTandemUInt16(0)
        return data
    }
}

struct TandemCancelBolusResponse: TandemResponse {
    static let opcode: UInt8 = 0xA1
    static let signed = true
    let statusId: UInt8
    let bolusId: UInt16
    let reasonId: UInt8

    /// wasCancelled per pumpx2: status SUCCESS(0) AND reason NO_ERROR(0).
    var cancelled: Bool { statusId == 0 && reasonId == 0 }

    init(cargo: Data) throws {
        // Documented cargo is 5 bytes (byte 4 unused); reject anything shorter,
        // matching the guard-equals-documented-size convention used elsewhere.
        guard cargo.count >= 5 else {
            throw TandemMessageError.unexpectedCargoSize(message: "CancelBolusResponse", expected: 5, actual: cargo.count)
        }
        let bytes = [UInt8](cargo)
        statusId = bytes[0]
        bolusId = cargo.tandemUInt16(at: 1)
        reasonId = bytes[3]
    }
}

// MARK: - Basal control (Mobi only — kept for future Mobi support)

struct TandemSetTempRateRequest: TandemRequest {
    typealias Response = TandemSetTempRateResponse
    static let opcode: UInt8 = 0xA4
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true

    let duration: TimeInterval
    /// Percentage of profile basal (100 = no change).
    let percent: UInt16

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt32(UInt32(duration * 1000))
        data.appendTandemUInt16(percent)
        return data
    }
}

struct TandemSetTempRateResponse: TandemResponse {
    static let opcode: UInt8 = 0xA5
    static let signed = true
    let status: UInt8
    let tempRateId: UInt16

    init(cargo: Data) throws {
        guard cargo.count >= 3 else {
            throw TandemMessageError.unexpectedCargoSize(message: "SetTempRateResponse", expected: 4, actual: cargo.count)
        }
        status = [UInt8](cargo)[0]
        tempRateId = cargo.tandemUInt16(at: 1)
    }
}

struct TandemStopTempRateRequest: TandemRequest {
    typealias Response = TandemStopTempRateResponse
    static let opcode: UInt8 = 0xA6
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true
}

struct TandemStopTempRateResponse: TandemResponse {
    static let opcode: UInt8 = 0xA7
    static let signed = true
    let status: UInt8
    let tempRateId: UInt16

    init(cargo: Data) throws {
        guard cargo.count >= 3 else {
            throw TandemMessageError.unexpectedCargoSize(message: "StopTempRateResponse", expected: 3, actual: cargo.count)
        }
        status = [UInt8](cargo)[0]
        tempRateId = cargo.tandemUInt16(at: 1)
    }
}

struct TandemSuspendPumpingRequest: TandemRequest {
    typealias Response = TandemSuspendPumpingResponse
    static let opcode: UInt8 = 0x9C
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true
}

struct TandemSuspendPumpingResponse: TandemResponse {
    static let opcode: UInt8 = 0x9D
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(message: "SuspendPumpingResponse", expected: 1, actual: 0)
        }
        status = first
    }
}

struct TandemResumePumpingRequest: TandemRequest {
    typealias Response = TandemResumePumpingResponse
    static let opcode: UInt8 = 0x9A
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true
}

struct TandemResumePumpingResponse: TandemResponse {
    static let opcode: UInt8 = 0x9B
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(message: "ResumePumpingResponse", expected: 1, actual: 0)
        }
        status = first
    }
}
