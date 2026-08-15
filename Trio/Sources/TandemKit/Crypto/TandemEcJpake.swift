import CryptoKit
import Foundation
import Security

/// Source of randomness for the JPAKE handshake. Abstracted so tests can replay
/// a fixed script of scalars and produce byte-exact reference vectors.
protocol TandemJpakeRandomSource {
    func randomBytes(count: Int) throws -> Data
    /// A uniformly distributed scalar in [1, order − 1].
    func randomScalar(order: TandemBigUInt) throws -> TandemBigUInt
}

extension TandemJpakeRandomSource {
    func randomScalar(order: TandemBigUInt) throws -> TandemBigUInt {
        // Rejection sampling: draw a full-width value and discard anything
        // outside [1, order − 1] rather than reducing, which would bias the
        // low end of the range.
        let width = (order.bitWidth + 7) / 8
        for _ in 0 ..< 256 {
            let candidate = TandemBigUInt(bigEndianBytes: try randomBytes(count: width))
            if !candidate.isZero, TandemBigUInt.compare(candidate, order) < 0 {
                return candidate
            }
        }
        throw TandemJpakeError.randomnessUnavailable
    }
}

/// The system CSPRNG.
struct TandemSecureRandomSource: TandemJpakeRandomSource {
    func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw TandemJpakeError.randomnessUnavailable
        }
        return data
    }
}

enum TandemJpakeError: LocalizedError {
    case invalidState
    case truncatedMessage
    case unexpectedCurve
    case zeroKnowledgeProofFailed
    case randomnessUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "The pairing handshake ran out of order."
        case .truncatedMessage:
            return "The pump sent a truncated pairing message."
        case .unexpectedCurve:
            return "The pump asked for an unsupported elliptic curve during pairing."
        case .zeroKnowledgeProofFailed:
            return "The pump could not prove it knows the pairing code. Check the code and try again."
        case .randomnessUnavailable:
            return "Could not generate secure random data for pairing."
        }
    }
}

/// EC-JPAKE over P-256, as specified by the Thread 1.1 spec and implemented by
/// mbed TLS.
///
/// This is a Swift port of the implementation the pumpX2 project uses
/// (`io.particle.crypto.EcJpake`, itself derived from mbed TLS), because the
/// Tandem Mobi — and t:slim X2 software 7.7 and newer — replaced the old
/// 16-character challenge/response pairing with this password-authenticated key
/// exchange over a 6-digit code.
///
/// The exchange establishes a shared secret that neither an eavesdropper nor an
/// active attacker can derive without the pairing code, and (unlike the legacy
/// flow) never puts a value derived from the code directly on the wire.
///
/// Wire format, matching the reference implementation byte for byte:
/// - a point is `uint8 length` followed by the uncompressed `0x04 || X || Y`;
/// - a scalar is `uint8 length` followed by its minimal big-endian encoding;
/// - round 1 is `point, ZKP, point, ZKP` — 330 bytes, split across two
///   BLE messages by the caller;
/// - round 2 is one `point, ZKP` — 165 bytes from the client; the pump (server)
///   prefixes a 3-byte named-curve id, making 168.
final class TandemEcJpake {
    enum Role {
        case client
        case server

        var identifier: Data {
            switch self {
            case .client: return Data("client".utf8)
            case .server: return Data("server".utf8)
            }
        }

        var peer: Role {
            self == .client ? .server : .client
        }
    }

    /// RFC 4492 named-curve id for secp256r1.
    private static let namedCurveId: UInt16 = 23
    /// TLS ECCurveType.named_curve.
    private static let namedCurveType: UInt8 = 3

    private let role: Role
    private let random: TandemJpakeRandomSource
    /// The pairing code as an integer, mixed into the round-2 scalar.
    private let s: TandemBigUInt

    private var xm1: TandemBigUInt?
    private var capitalXm1: TandemP256.Point?
    private var xm2: TandemBigUInt?
    private var capitalXm2: TandemP256.Point?
    private var capitalXp1: TandemP256.Point?
    private var capitalXp2: TandemP256.Point?
    private var capitalXp: TandemP256.Point?

    private var myRound1: Data?
    private var myRound2: Data?
    private var hasPeerRound1 = false
    private var hasPeerRound2 = false
    private var derivedSecretValue: Data?

    init(role: Role, secret: Data, random: TandemJpakeRandomSource = TandemSecureRandomSource()) {
        self.role = role
        self.random = random
        s = TandemBigUInt(bigEndianBytes: secret)
    }

    // MARK: - Round 1

    /// Our round-1 message: 330 bytes.
    func round1() throws -> Data {
        if let existing = myRound1 { return existing }

        var out = Data()
        let generator = TandemP256.generator

        let first = try generateKeyPair(base: generator)
        xm1 = first.privateKey
        capitalXm1 = first.publicKey
        try write(point: first.publicKey, to: &out)
        try writeZeroKnowledgeProof(
            base: generator,
            privateKey: first.privateKey,
            publicKey: first.publicKey,
            identifier: role.identifier,
            to: &out
        )

        let second = try generateKeyPair(base: generator)
        xm2 = second.privateKey
        capitalXm2 = second.publicKey
        try write(point: second.publicKey, to: &out)
        try writeZeroKnowledgeProof(
            base: generator,
            privateKey: second.privateKey,
            publicKey: second.publicKey,
            identifier: role.identifier,
            to: &out
        )

        myRound1 = out
        return out
    }

    /// Consume the peer's round-1 message, verifying both zero-knowledge proofs.
    func readRound1(_ data: Data) throws {
        guard !hasPeerRound1 else { throw TandemJpakeError.invalidState }
        var reader = Reader(data)
        let generator = TandemP256.generator

        let peer1 = try readPoint(&reader)
        try readZeroKnowledgeProof(&reader, base: generator, publicKey: peer1, identifier: role.peer.identifier)
        let peer2 = try readPoint(&reader)
        try readZeroKnowledgeProof(&reader, base: generator, publicKey: peer2, identifier: role.peer.identifier)

        capitalXp1 = peer1
        capitalXp2 = peer2
        hasPeerRound1 = true
    }

    // MARK: - Round 2

    /// Our round-2 message: 165 bytes as the client, 168 as the server.
    func round2() throws -> Data {
        if let existing = myRound2 { return existing }
        guard hasPeerRound1, myRound1 != nil,
              let capitalXp1 = capitalXp1, let capitalXp2 = capitalXp2,
              let capitalXm1 = capitalXm1, let xm2 = xm2
        else { throw TandemJpakeError.invalidState }

        var out = Data()
        let base = TandemP256.add(TandemP256.add(capitalXp1, capitalXp2), capitalXm1)
        let scalar = try multiplyBySecret(xm2, negate: false)
        let point = TandemP256.multiply(base, by: scalar)

        if role == .server {
            out.append(Self.namedCurveType)
            out.append(UInt8(Self.namedCurveId >> 8))
            out.append(UInt8(Self.namedCurveId & 0xFF))
        }
        try write(point: point, to: &out)
        try writeZeroKnowledgeProof(
            base: base,
            privateKey: scalar,
            publicKey: point,
            identifier: role.identifier,
            to: &out
        )

        myRound2 = out
        return out
    }

    /// Consume the peer's round-2 message, verifying its zero-knowledge proof.
    func readRound2(_ data: Data) throws {
        guard hasPeerRound1, myRound1 != nil, !hasPeerRound2,
              let capitalXm1 = capitalXm1, let capitalXm2 = capitalXm2, let capitalXp1 = capitalXp1
        else { throw TandemJpakeError.invalidState }

        var reader = Reader(data)
        if role == .client {
            guard try reader.readUInt8() == Self.namedCurveType else {
                throw TandemJpakeError.unexpectedCurve
            }
            let high = try reader.readUInt8()
            let low = try reader.readUInt8()
            guard (UInt16(high) << 8) | UInt16(low) == Self.namedCurveId else {
                throw TandemJpakeError.unexpectedCurve
            }
        }

        let base = TandemP256.add(TandemP256.add(capitalXm1, capitalXm2), capitalXp1)
        let peerPoint = try readPoint(&reader)
        try readZeroKnowledgeProof(&reader, base: base, publicKey: peerPoint, identifier: role.peer.identifier)

        capitalXp = peerPoint
        hasPeerRound2 = true
    }

    // MARK: - Shared secret

    /// SHA-256 of the x coordinate of the agreed point: 32 bytes.
    func deriveSecret() throws -> Data {
        if let existing = derivedSecretValue { return existing }
        guard hasPeerRound2, let capitalXp = capitalXp, let capitalXp2 = capitalXp2, let xm2 = xm2 else {
            throw TandemJpakeError.invalidState
        }

        let negatedSecretScalar = try multiplyBySecret(xm2, negate: true)
        let intermediate = TandemP256.add(capitalXp, TandemP256.multiply(capitalXp2, by: negatedSecretScalar))
        let agreed = TandemP256.multiply(intermediate, by: xm2)

        guard let affine = agreed.affine else { throw TandemJpakeError.invalidState }
        let secret = Data(SHA256.hash(data: Self.unsignedByteArray(affine.x)))
        derivedSecretValue = secret
        return secret
    }

    // MARK: - Zero-knowledge proofs

    private struct KeyPair {
        let privateKey: TandemBigUInt
        let publicKey: TandemP256.Point
    }

    private func generateKeyPair(base: TandemP256.Point) throws -> KeyPair {
        let privateKey = try random.randomScalar(order: TandemP256.n)
        return KeyPair(privateKey: privateKey, publicKey: TandemP256.multiply(base, by: privateKey))
    }

    /// Schnorr proof of knowledge of `privateKey` such that
    /// `publicKey == base * privateKey`, bound to `identifier` so a proof cannot
    /// be replayed back at its author.
    private func writeZeroKnowledgeProof(
        base: TandemP256.Point,
        privateKey: TandemBigUInt,
        publicKey: TandemP256.Point,
        identifier: Data,
        to out: inout Data
    ) throws {
        let ephemeral = try generateKeyPair(base: base)
        let challenge = try proofChallenge(
            base: base,
            commitment: ephemeral.publicKey,
            publicKey: publicKey,
            identifier: identifier
        )
        // r = (v − x·h) mod n
        let product = TandemBigUInt.modMul(privateKey, challenge, TandemP256.n)
        let response = TandemBigUInt.modSub(ephemeral.privateKey.modulo(TandemP256.n), product, TandemP256.n)
        try write(point: ephemeral.publicKey, to: &out)
        write(scalar: response, to: &out)
    }

    private func readZeroKnowledgeProof(
        _ reader: inout Reader,
        base: TandemP256.Point,
        publicKey: TandemP256.Point,
        identifier: Data
    ) throws {
        let commitment = try readPoint(&reader)
        let response = try readScalar(&reader)
        let challenge = try proofChallenge(
            base: base,
            commitment: commitment,
            publicKey: publicKey,
            identifier: identifier
        )
        // base·r + publicKey·h must reproduce the commitment.
        let reconstructed = TandemP256.add(
            TandemP256.multiply(base, by: response),
            TandemP256.multiply(publicKey, by: challenge)
        )
        guard reconstructed == commitment else {
            throw TandemJpakeError.zeroKnowledgeProofFailed
        }
    }

    private func proofChallenge(
        base: TandemP256.Point,
        commitment: TandemP256.Point,
        publicKey: TandemP256.Point,
        identifier: Data
    ) throws -> TandemBigUInt {
        var input = Data()
        for point in [base, commitment, publicKey] {
            guard let encoded = TandemP256.encode(point) else { throw TandemJpakeError.invalidState }
            input.append(uint32BigEndian(UInt32(encoded.count)))
            input.append(encoded)
        }
        input.append(uint32BigEndian(UInt32(identifier.count)))
        input.append(identifier)
        let digest = Data(SHA256.hash(data: input))
        return TandemBigUInt(bigEndianBytes: digest).modulo(TandemP256.n)
    }

    /// `(x · (r·n + s)) mod n`, optionally negated — the round-2 scalar that
    /// folds the pairing code into the exchange. The random multiple of the
    /// group order does not change the result modulo n; it exists so the
    /// intermediate product does not leak the secret through its size.
    private func multiplyBySecret(_ value: TandemBigUInt, negate: Bool) throws -> TandemBigUInt {
        let blinding = TandemBigUInt(bigEndianBytes: try random.randomBytes(count: 16))
        let factor = blinding * TandemP256.n + s
        let product = (value * factor).modulo(TandemP256.n)
        return negate ? TandemBigUInt.modNegate(product, TandemP256.n) : product
    }

    // MARK: - Wire encoding

    /// BouncyCastle's `asUnsignedByteArray`, which the reference implementation
    /// uses: minimal big-endian, but a single `0x00` rather than nothing for
    /// zero.
    private static func unsignedByteArray(_ value: TandemBigUInt) -> Data {
        let bytes = value.bigEndianBytes
        return bytes.isEmpty ? Data([0]) : bytes
    }

    private func uint32BigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func write(point: TandemP256.Point, to out: inout Data) throws {
        // Only the point at infinity fails to encode, and reaching it here would
        // mean a degenerate exchange; refuse rather than emit a short message.
        guard let encoded = TandemP256.encode(point) else { throw TandemJpakeError.invalidState }
        out.append(UInt8(encoded.count))
        out.append(encoded)
    }

    private func write(scalar: TandemBigUInt, to out: inout Data) {
        let encoded = Self.unsignedByteArray(scalar)
        out.append(UInt8(encoded.count))
        out.append(encoded)
    }

    private func readPoint(_ reader: inout Reader) throws -> TandemP256.Point {
        let length = Int(try reader.readUInt8())
        let encoded = try reader.read(length)
        return try TandemP256.decode(encoded)
    }

    private func readScalar(_ reader: inout Reader) throws -> TandemBigUInt {
        let length = Int(try reader.readUInt8())
        return TandemBigUInt(bigEndianBytes: try reader.read(length))
    }

    /// A cursor over an inbound message.
    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = Data(data)
            offset = 0
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else { throw TandemJpakeError.truncatedMessage }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func read(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw TandemJpakeError.truncatedMessage }
            defer { offset += count }
            return data.subdata(in: offset ..< offset + count)
        }
    }
}
