import Foundation

/// Authorization-characteristic messages for the JPAKE pairing flow used by the
/// Tandem Mobi (and by t:slim X2 software 7.7 and newer).
///
/// These share the authorization characteristic — and therefore the opcode
/// namespace — with the legacy `CentralChallenge`/`PumpChallenge` messages, but
/// occupy a different opcode range (32-41 rather than 16-19). The pump chooses
/// which flow applies: a JPAKE pump simply never answers a CentralChallenge.
///
/// Layouts are transcribed from pumpX2's `Jpake*Request`/`Jpake*Response`
/// classes. Every message begins with a little-endian `appInstanceId`, which
/// pumpX2 always sends as 0 and ignores on the way back.

/// Length of one half of the 330-byte JPAKE round-1 payload.
enum TandemJpakeSizes {
    static let roundHalfLength = 165
    /// Round 2 from the pump carries a 3-byte named-curve prefix.
    static let serverRound2Length = 168
    static let nonceLength = 8
    static let reservedLength = 8
    static let digestLength = 32
}

// MARK: - Round 1 (330 bytes, split across two messages)

struct TandemJpake1aRequest: TandemRequest {
    typealias Response = TandemJpake1aResponse
    static let opcode: UInt8 = 32
    static let characteristic: TandemCharacteristic = .authorization

    let appInstanceId: UInt16
    /// First 165 bytes of our round-1 payload.
    let challenge: Data

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(appInstanceId)
        data.append(challenge.prefix(TandemJpakeSizes.roundHalfLength))
        return data
    }
}

struct TandemJpake1aResponse: TandemResponse {
    static let opcode: UInt8 = 33
    let appInstanceId: UInt16
    /// First 165 bytes of the pump's round-1 payload.
    let challengeHash: Data

    init(cargo: Data) throws {
        guard cargo.count == 2 + TandemJpakeSizes.roundHalfLength else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "Jpake1aResponse",
                expected: 2 + TandemJpakeSizes.roundHalfLength,
                actual: cargo.count
            )
        }
        appInstanceId = cargo.tandemUInt16(at: 0)
        challengeHash = Data(cargo.dropFirst(2))
    }
}

struct TandemJpake1bRequest: TandemRequest {
    typealias Response = TandemJpake1bResponse
    static let opcode: UInt8 = 34
    static let characteristic: TandemCharacteristic = .authorization

    let appInstanceId: UInt16
    /// Second 165 bytes of our round-1 payload.
    let challenge: Data

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(appInstanceId)
        data.append(challenge.prefix(TandemJpakeSizes.roundHalfLength))
        return data
    }
}

struct TandemJpake1bResponse: TandemResponse {
    static let opcode: UInt8 = 35
    let appInstanceId: UInt16
    /// Second 165 bytes of the pump's round-1 payload.
    let challengeHash: Data

    init(cargo: Data) throws {
        guard cargo.count == 2 + TandemJpakeSizes.roundHalfLength else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "Jpake1bResponse",
                expected: 2 + TandemJpakeSizes.roundHalfLength,
                actual: cargo.count
            )
        }
        appInstanceId = cargo.tandemUInt16(at: 0)
        challengeHash = Data(cargo.dropFirst(2))
    }
}

// MARK: - Round 2

struct TandemJpake2Request: TandemRequest {
    typealias Response = TandemJpake2Response
    static let opcode: UInt8 = 36
    static let characteristic: TandemCharacteristic = .authorization

    let appInstanceId: UInt16
    /// Our 165-byte round-2 payload (the client sends no curve-id prefix).
    let challenge: Data

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(appInstanceId)
        data.append(challenge.prefix(TandemJpakeSizes.roundHalfLength))
        return data
    }
}

struct TandemJpake2Response: TandemResponse {
    static let opcode: UInt8 = 37
    let appInstanceId: UInt16
    /// The pump's 168-byte round-2 payload, including its curve-id prefix.
    let challengeHash: Data

    init(cargo: Data) throws {
        guard cargo.count == 2 + TandemJpakeSizes.serverRound2Length else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "Jpake2Response",
                expected: 2 + TandemJpakeSizes.serverRound2Length,
                actual: cargo.count
            )
        }
        appInstanceId = cargo.tandemUInt16(at: 0)
        challengeHash = Data(cargo.dropFirst(2))
    }
}

// MARK: - Session key + key confirmation

/// Asks the pump for a fresh session nonce. Sent on every connection — including
/// reconnections that reuse a stored derived secret — because the nonce is what
/// makes each connection's signing key unique.
struct TandemJpake3SessionKeyRequest: TandemRequest {
    typealias Response = TandemJpake3SessionKeyResponse
    static let opcode: UInt8 = 38
    static let characteristic: TandemCharacteristic = .authorization

    let challengeParameter: UInt16

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(challengeParameter)
        return data
    }
}

struct TandemJpake3SessionKeyResponse: TandemResponse {
    static let opcode: UInt8 = 39
    let appInstanceId: UInt16
    /// 8-byte nonce; the HKDF salt for this connection's signing key.
    let deviceKeyNonce: Data
    let reserved: Data

    init(cargo: Data) throws {
        let expected = 2 + TandemJpakeSizes.nonceLength + TandemJpakeSizes.reservedLength
        guard cargo.count == expected else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "Jpake3SessionKeyResponse",
                expected: expected,
                actual: cargo.count
            )
        }
        appInstanceId = cargo.tandemUInt16(at: 0)
        let base = cargo.startIndex
        deviceKeyNonce = cargo.subdata(in: base + 2 ..< base + 10)
        reserved = cargo.subdata(in: base + 10 ..< base + 18)
    }
}

/// Proves to the pump that we derived the same key, and carries the nonce the
/// pump proves itself against in its reply.
struct TandemJpake4KeyConfirmationRequest: TandemRequest {
    typealias Response = TandemJpake4KeyConfirmationResponse
    static let opcode: UInt8 = 40
    static let characteristic: TandemCharacteristic = .authorization

    static let reserved = Data(repeating: 0, count: TandemJpakeSizes.reservedLength)

    let appInstanceId: UInt16
    /// Our 8-byte nonce.
    let nonce: Data
    /// HMAC-SHA256 of the pump's nonce under the derived session key.
    let hashDigest: Data

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(appInstanceId)
        data.append(nonce.prefix(TandemJpakeSizes.nonceLength))
        data.append(Self.reserved)
        data.append(hashDigest.prefix(TandemJpakeSizes.digestLength))
        return data
    }
}

struct TandemJpake4KeyConfirmationResponse: TandemResponse {
    static let opcode: UInt8 = 41
    let appInstanceId: UInt16
    /// The pump's 8-byte nonce, which our expected digest is computed over.
    let nonce: Data
    let reserved: Data
    /// The pump's proof that it derived the same session key.
    let hashDigest: Data

    init(cargo: Data) throws {
        let expected = 2 + TandemJpakeSizes.nonceLength + TandemJpakeSizes.reservedLength
            + TandemJpakeSizes.digestLength
        guard cargo.count == expected else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "Jpake4KeyConfirmationResponse",
                expected: expected,
                actual: cargo.count
            )
        }
        appInstanceId = cargo.tandemUInt16(at: 0)
        let base = cargo.startIndex
        nonce = cargo.subdata(in: base + 2 ..< base + 10)
        reserved = cargo.subdata(in: base + 10 ..< base + 18)
        hashDigest = cargo.subdata(in: base + 18 ..< base + 50)
    }
}
