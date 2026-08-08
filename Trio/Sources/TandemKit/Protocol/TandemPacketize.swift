import CryptoKit
import Foundation

/// Wire framing for Tandem pump messages.
///
/// A message travels as `[opcode, txId, cargoLength, cargo...]` with a
/// CRC-16 appended, split across BLE writes/notifications of the form
/// `[packetsRemaining, txId, chunk...]` where `packetsRemaining` counts
/// down to 0 on the final packet.
///
/// Signed (control) messages carry a 24-byte trailer inside their cargo:
/// 4 bytes little-endian pump time-since-reset followed by a 20-byte
/// HMAC-SHA1 over everything that precedes it, keyed with the
/// authentication key derived during pairing.
///
/// Reference: pumpx2 `Packetize`, `Packet`, `PacketArrayList`
/// (jwoglom/pumpx2, messages/).
enum TandemPacketize {
    /// Chunk size for currentStatus/authorization writes.
    static let defaultMaxChunkSize = 18
    /// Chunk size for control-characteristic requests.
    static let controlMaxChunkSize = 40

    static let signedTrailerLength = 24
    static let hmacLength = 20

    enum PacketizeError: LocalizedError {
        case missingAuthenticationKey

        var errorDescription: String? {
            switch self {
            case .missingAuthenticationKey:
                return "Cannot sign pump message: no authentication key is available."
            }
        }
    }

    static func hmacSHA1(_ data: Data, key: Data) -> Data {
        var hmac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: key))
        hmac.update(data: data)
        return Data(hmac.finalize())
    }

    /// Build the BLE write payloads for one outgoing message.
    static func packetize(
        opcode: UInt8,
        cargo: Data,
        txId: UInt8,
        signed: Bool,
        authenticationKey: Data?,
        timeSinceReset: UInt32?,
        maxChunkSize: Int
    ) throws -> [Data] {
        var frame = Data()
        let totalCargoLength = cargo.count + (signed ? signedTrailerLength : 0)
        frame.append(opcode)
        frame.append(txId)
        frame.append(UInt8(totalCargoLength))
        frame.append(cargo)

        if signed {
            guard let authenticationKey = authenticationKey, let timeSinceReset = timeSinceReset else {
                throw PacketizeError.missingAuthenticationKey
            }
            var timeData = Data()
            timeData.append(UInt8(timeSinceReset & 0xFF))
            timeData.append(UInt8((timeSinceReset >> 8) & 0xFF))
            timeData.append(UInt8((timeSinceReset >> 16) & 0xFF))
            timeData.append(UInt8((timeSinceReset >> 24) & 0xFF))
            frame.append(timeData)
            frame.append(hmacSHA1(frame, key: authenticationKey))
        }

        frame.append(TandemCRC.crc16Data(frame))

        var chunks: [Data] = []
        var index = frame.startIndex
        while index < frame.endIndex {
            let end = frame.index(index, offsetBy: maxChunkSize, limitedBy: frame.endIndex) ?? frame.endIndex
            chunks.append(frame.subdata(in: index ..< end))
            index = end
        }

        var packets: [Data] = []
        for (i, chunk) in chunks.enumerated() {
            var packet = Data()
            packet.append(UInt8(chunks.count - 1 - i))
            packet.append(txId)
            packet.append(chunk)
            packets.append(packet)
        }
        return packets
    }
}

/// A fully reassembled, CRC-validated inbound message.
struct TandemMessageFrame {
    let opcode: UInt8
    let txId: UInt8
    let cargo: Data

    /// For signed frames: cargo with the 24-byte time/HMAC trailer removed.
    var unsignedCargo: Data {
        guard cargo.count >= TandemPacketize.signedTrailerLength else { return cargo }
        return cargo.prefix(cargo.count - TandemPacketize.signedTrailerLength)
    }
}

/// Reassembles notification packets from one characteristic into messages.
///
/// Mirrors pumpx2 `PacketArrayList.validatePacket`: the first packet of a
/// message embeds the message header `[opcode, txId, cargoLength]` after
/// the two packet-header bytes; continuation packets contribute cargo, and
/// `packetsRemaining & 0x0F` counts down to zero on the final packet.
final class TandemResponseAccumulator {
    enum ParseError: LocalizedError {
        case emptyPacket
        case packetTooShort
        case unexpectedTransactionId(found: UInt8, expected: UInt8)
        case unexpectedPacketsRemaining(found: UInt8, expected: UInt8)
        case truncatedMessage
        case invalidCRC
        case invalidSignature

        var errorDescription: String? {
            switch self {
            case .emptyPacket: return "Received an empty packet from the pump."
            case .packetTooShort: return "Received a truncated packet from the pump."
            case let .unexpectedTransactionId(found, expected):
                return "Unexpected pump transaction id \(found) (expected \(expected))."
            case let .unexpectedPacketsRemaining(found, expected):
                return "Unexpected packet continuation counter \(found) (expected \(expected))."
            case .truncatedMessage: return "Pump message ended before the declared cargo length."
            case .invalidCRC: return "Pump message failed CRC validation."
            case .invalidSignature: return "Pump message failed HMAC signature validation."
            }
        }
    }

    private var buffer = Data()
    private var packetsRemaining: UInt8?
    private var expectedTxId: UInt8?

    func reset() {
        buffer.removeAll()
        packetsRemaining = nil
        expectedTxId = nil
    }

    /// Feed one BLE notification. Returns a validated frame once the final
    /// packet arrives, or nil while more packets are needed.
    func accumulate(
        packet: Data,
        expectedTxId: UInt8?,
        signed: Bool,
        authenticationKey: Data?
    ) throws -> TandemMessageFrame? {
        guard !packet.isEmpty else { throw ParseError.emptyPacket }
        guard packet.count >= 3 else { throw ParseError.packetTooShort }

        let bytes = [UInt8](packet)
        let remaining = bytes[0] & 0x0F
        let txId = bytes[1]

        if let expectedTxId = expectedTxId, txId != expectedTxId {
            throw ParseError.unexpectedTransactionId(found: txId, expected: expectedTxId)
        }

        if buffer.isEmpty {
            self.expectedTxId = txId
            packetsRemaining = remaining
        } else {
            if txId != self.expectedTxId {
                throw ParseError.unexpectedTransactionId(found: txId, expected: self.expectedTxId ?? 0)
            }
            if remaining != packetsRemaining {
                throw ParseError.unexpectedPacketsRemaining(found: remaining, expected: packetsRemaining ?? 0)
            }
        }

        buffer.append(packet.dropFirst(2))

        if remaining > 0 {
            packetsRemaining = remaining - 1
            return nil
        }

        defer { reset() }
        return try Self.parseFrame(buffer, signed: signed, authenticationKey: authenticationKey)
    }

    private static func parseFrame(_ frame: Data, signed: Bool, authenticationKey: Data?) throws -> TandemMessageFrame {
        let bytes = [UInt8](frame)
        guard bytes.count >= 5 else { throw ParseError.packetTooShort }

        let opcode = bytes[0]
        let txId = bytes[1]
        let cargoLength = Int(bytes[2])
        guard bytes.count == 3 + cargoLength + 2 else { throw ParseError.truncatedMessage }

        let messageData = frame.prefix(3 + cargoLength)
        let expectedCRC = frame.suffix(2)
        guard TandemCRC.crc16Data(messageData) == expectedCRC else { throw ParseError.invalidCRC }

        // Signed responses (control characteristic) carry a trailing 24-byte
        // trailer (4-byte time + 20-byte HMAC over everything before it).
        //
        // The pump may answer any request with an unsigned ErrorResponse
        // (opcode 77), which legitimately has no trailer — allow that on CRC
        // alone. But a frame that claims to be the expected signed response
        // MUST carry and pass the HMAC: never accept a short/forged signed
        // response on CRC alone, or signature verification could be bypassed.
        if signed, opcode != TandemErrorResponse.opcode {
            guard cargoLength >= TandemPacketize.signedTrailerLength else {
                throw ParseError.invalidSignature
            }
            guard let authenticationKey = authenticationKey else { throw ParseError.invalidSignature }
            let signedPortion = messageData.prefix(messageData.count - TandemPacketize.hmacLength)
            let expectedHmac = messageData.suffix(TandemPacketize.hmacLength)
            let hmac = TandemPacketize.hmacSHA1(Data(signedPortion), key: authenticationKey)
            guard hmac == Data(expectedHmac) else { throw ParseError.invalidSignature }
        }

        let cargo = frame.subdata(in: frame.startIndex + 3 ..< frame.startIndex + 3 + cargoLength)
        return TandemMessageFrame(opcode: opcode, txId: txId, cargo: cargo)
    }
}
