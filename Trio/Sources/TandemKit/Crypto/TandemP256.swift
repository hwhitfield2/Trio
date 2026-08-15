import Foundation

/// Arithmetic on the NIST P-256 (secp256r1) curve, as needed by EC-JPAKE.
///
/// Apple's platform crypto exposes P-256 only as complete key-agreement and
/// signature primitives; EC-JPAKE needs raw point addition and scalar
/// multiplication on points it did not generate, so TandemKit carries its own
/// minimal implementation on top of `TandemBigUInt`.
///
/// Points are held in Jacobian projective coordinates (`x/z²`, `y/z³`), which
/// keeps addition and doubling free of modular inversions; a single inversion
/// converts back to affine when a point is encoded or compared.
///
/// NOT constant-time — see the note on `TandemBigUInt`.
enum TandemP256 {
    private static func constant(_ hex: String) -> TandemBigUInt {
        guard let value = TandemBigUInt(hex: hex) else {
            preconditionFailure("Invalid P-256 curve constant literal")
        }
        return value
    }

    /// Field prime: 2^256 − 2^224 + 2^192 + 2^96 − 1.
    static let p = constant("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF")
    /// Curve coefficient b in y² = x³ − 3x + b.
    static let b = constant("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B")
    /// Order of the generator point.
    static let n = constant("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")

    private static let gx = constant("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296")
    private static let gy = constant("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5")

    /// Length of an uncompressed point encoding: `0x04 || X || Y`.
    static let uncompressedPointLength = 65
    /// Length of a field element or scalar in bytes.
    static let elementLength = 32

    static var generator: Point {
        Point(x: gx, y: gy, z: TandemBigUInt(1))
    }

    static var infinity: Point {
        Point(x: TandemBigUInt(1), y: TandemBigUInt(1), z: TandemBigUInt())
    }

    enum CurveError: LocalizedError {
        case malformedPoint
        case pointNotOnCurve

        var errorDescription: String? {
            switch self {
            case .malformedPoint:
                return "The pump sent a malformed elliptic-curve point during pairing."
            case .pointNotOnCurve:
                return "The pump sent an elliptic-curve point that is not on the expected curve."
            }
        }
    }

    // MARK: - Small modular helpers
    //
    // Doubling and addition scale intermediate values by 2, 3, 4 and 8. Repeated
    // modular addition is cheaper than a full modular multiplication, since the
    // latter runs a binary division.

    private static func fieldDouble(_ value: TandemBigUInt) -> TandemBigUInt {
        TandemBigUInt.modAdd(value, value, p)
    }

    private static func fieldTriple(_ value: TandemBigUInt) -> TandemBigUInt {
        TandemBigUInt.modAdd(fieldDouble(value), value, p)
    }

    fileprivate static func fieldMul(_ lhs: TandemBigUInt, _ rhs: TandemBigUInt) -> TandemBigUInt {
        TandemBigUInt.modMul(lhs, rhs, p)
    }

    private static func fieldSub(_ lhs: TandemBigUInt, _ rhs: TandemBigUInt) -> TandemBigUInt {
        TandemBigUInt.modSub(lhs, rhs, p)
    }

    private static func fieldAdd(_ lhs: TandemBigUInt, _ rhs: TandemBigUInt) -> TandemBigUInt {
        TandemBigUInt.modAdd(lhs, rhs, p)
    }

    // MARK: - Point

    /// A curve point in Jacobian coordinates. `z == 0` is the point at infinity.
    struct Point: Equatable {
        var x: TandemBigUInt
        var y: TandemBigUInt
        var z: TandemBigUInt

        var isInfinity: Bool { z.isZero }

        /// Affine (x, y), or nil at infinity.
        var affine: (x: TandemBigUInt, y: TandemBigUInt)? {
            guard !z.isZero else { return nil }
            if z == TandemBigUInt(1) { return (x, y) }
            let zInverse = TandemBigUInt.modInversePrime(z, TandemP256.p)
            let zInverse2 = TandemP256.fieldMul(zInverse, zInverse)
            let zInverse3 = TandemP256.fieldMul(zInverse2, zInverse)
            return (TandemP256.fieldMul(x, zInverse2), TandemP256.fieldMul(y, zInverse3))
        }

        /// Two Jacobian representations of the same point compare equal.
        static func == (lhs: Point, rhs: Point) -> Bool {
            switch (lhs.affine, rhs.affine) {
            case (nil, nil): return true
            case let (left?, right?): return left.x == right.x && left.y == right.y
            default: return false
            }
        }
    }

    // MARK: - Group operations

    /// Point doubling, using the `dbl-2001-b` formulas, which are valid because
    /// P-256 has a = −3.
    static func double(_ point: Point) -> Point {
        guard !point.isInfinity else { return infinity }

        let delta = fieldMul(point.z, point.z)
        let gamma = fieldMul(point.y, point.y)
        let beta = fieldMul(point.x, gamma)
        let alpha = fieldTriple(fieldMul(fieldSub(point.x, delta), fieldAdd(point.x, delta)))

        let eightBeta = fieldDouble(fieldDouble(fieldDouble(beta)))
        let x3 = fieldSub(fieldMul(alpha, alpha), eightBeta)

        let yPlusZ = fieldAdd(point.y, point.z)
        let z3 = fieldSub(fieldSub(fieldMul(yPlusZ, yPlusZ), gamma), delta)

        let fourBeta = fieldDouble(fieldDouble(beta))
        let gammaSquared = fieldMul(gamma, gamma)
        let y3 = fieldSub(fieldMul(alpha, fieldSub(fourBeta, x3)), fieldDouble(fieldDouble(fieldDouble(gammaSquared))))

        return Point(x: x3, y: y3, z: z3)
    }

    /// Point addition, using the `add-2007-bl` formulas.
    static func add(_ lhs: Point, _ rhs: Point) -> Point {
        if lhs.isInfinity { return rhs }
        if rhs.isInfinity { return lhs }

        let z1z1 = fieldMul(lhs.z, lhs.z)
        let z2z2 = fieldMul(rhs.z, rhs.z)
        let u1 = fieldMul(lhs.x, z2z2)
        let u2 = fieldMul(rhs.x, z1z1)
        let s1 = fieldMul(fieldMul(lhs.y, rhs.z), z2z2)
        let s2 = fieldMul(fieldMul(rhs.y, lhs.z), z1z1)

        let h = fieldSub(u2, u1)
        let r = fieldDouble(fieldSub(s2, s1))

        if h.isZero {
            // Same x coordinate: either the same point (double it) or a point
            // and its negation (the sum is the point at infinity).
            return r.isZero ? double(lhs) : infinity
        }

        let i = fieldMul(fieldDouble(h), fieldDouble(h))
        let j = fieldMul(h, i)
        let v = fieldMul(u1, i)

        let x3 = fieldSub(fieldSub(fieldMul(r, r), j), fieldDouble(v))
        let y3 = fieldSub(fieldMul(r, fieldSub(v, x3)), fieldDouble(fieldMul(s1, j)))
        let zSum = fieldAdd(lhs.z, rhs.z)
        let z3 = fieldMul(fieldSub(fieldSub(fieldMul(zSum, zSum), z1z1), z2z2), h)

        return Point(x: x3, y: y3, z: z3)
    }

    /// Left-to-right double-and-add scalar multiplication.
    static func multiply(_ point: Point, by scalar: TandemBigUInt) -> Point {
        guard !scalar.isZero, !point.isInfinity else { return infinity }
        var result = infinity
        var index = scalar.bitWidth - 1
        while index >= 0 {
            result = double(result)
            if scalar.bit(at: index) {
                result = add(result, point)
            }
            index -= 1
        }
        return result
    }

    // MARK: - Encoding

    /// True when (x, y) satisfies y² = x³ − 3x + b over the field.
    static func isOnCurve(x: TandemBigUInt, y: TandemBigUInt) -> Bool {
        guard TandemBigUInt.compare(x, p) < 0, TandemBigUInt.compare(y, p) < 0 else { return false }
        let left = fieldMul(y, y)
        let right = fieldAdd(fieldSub(fieldMul(fieldMul(x, x), x), fieldTriple(x)), b)
        return left == right
    }

    /// Encode as `0x04 || X || Y`, 65 bytes. Returns nil at infinity.
    static func encode(_ point: Point) -> Data? {
        guard let affine = point.affine,
              let xBytes = affine.x.bigEndianBytes(width: elementLength),
              let yBytes = affine.y.bigEndianBytes(width: elementLength)
        else { return nil }
        return Data([0x04]) + xBytes + yBytes
    }

    /// Decode an uncompressed point, rejecting anything not on the curve.
    ///
    /// Validating the peer's points is what prevents an invalid-curve attack:
    /// a pump (or an attacker impersonating one) that sends a point on a weaker
    /// curve could otherwise recover the pairing code from our scalar
    /// multiplications.
    static func decode(_ data: Data) throws -> Point {
        guard data.count == uncompressedPointLength, data.first == 0x04 else {
            throw CurveError.malformedPoint
        }
        let body = Data(data.dropFirst())
        let x = TandemBigUInt(bigEndianBytes: body.prefix(elementLength))
        let y = TandemBigUInt(bigEndianBytes: body.suffix(elementLength))
        guard isOnCurve(x: x, y: y) else {
            throw CurveError.pointNotOnCurve
        }
        return Point(x: x, y: y, z: TandemBigUInt(1))
    }
}
