import Foundation

/// A minimal arbitrary-precision unsigned integer.
///
/// EC-JPAKE (used by the Tandem Mobi pairing flow) needs modular arithmetic on
/// values wider than 64 bits — P-256 field elements, curve-order scalars, and
/// the intermediate products of both. Apple's platform crypto exposes no raw
/// big-integer or elliptic-curve point arithmetic, so this type provides the
/// small subset TandemKit needs: add, subtract, multiply, modulo, and modular
/// exponentiation.
///
/// This is deliberately the simplest implementation that is easy to verify by
/// reading, not the fastest: `modulo` is a shift-and-subtract binary division
/// rather than a word-wise or Montgomery reduction. A full JPAKE bootstrap runs
/// on the order of a dozen scalar multiplications, which takes a couple of
/// seconds on-device — acceptable because it happens once, off the main thread,
/// behind the pairing spinner. Reconnecting to an already-paired pump re-derives
/// the session key with HKDF only and does no curve arithmetic at all.
///
/// NOT constant-time. It is used only for the JPAKE handshake, whose inputs are
/// a short-lived shared pairing code and freshly generated ephemeral scalars;
/// TandemKit never signs or decrypts long-lived material with it.
struct TandemBigUInt: Equatable, Comparable, CustomStringConvertible {
    /// Little-endian 64-bit limbs, normalized so there are no trailing zero
    /// limbs. Zero is the empty array.
    private(set) var limbs: [UInt64]

    // MARK: - Creation

    init() {
        limbs = []
    }

    init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    private init(normalizing limbs: [UInt64]) {
        var limbs = limbs
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
        self.limbs = limbs
    }

    /// Interpret `bytes` as an unsigned big-endian integer.
    init(bigEndianBytes bytes: Data) {
        var limbs: [UInt64] = []
        limbs.reserveCapacity(bytes.count / 8 + 1)
        var accumulator: UInt64 = 0
        var shift: UInt64 = 0
        for byte in bytes.reversed() {
            accumulator |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                limbs.append(accumulator)
                accumulator = 0
                shift = 0
            }
        }
        if shift > 0 {
            limbs.append(accumulator)
        }
        self.init(normalizing: limbs)
    }

    /// Parse a hexadecimal literal. Returns nil for non-hex input. Used for the
    /// compiled-in curve constants.
    init?(hex: String) {
        var nibbles: [UInt8] = []
        nibbles.reserveCapacity(hex.utf8.count)
        for character in hex.utf8 {
            switch character {
            case 0x30 ... 0x39: nibbles.append(character - 0x30)
            case 0x41 ... 0x46: nibbles.append(character - 0x41 + 10)
            case 0x61 ... 0x66: nibbles.append(character - 0x61 + 10)
            default: return nil
            }
        }
        guard !nibbles.isEmpty else { return nil }
        if nibbles.count % 2 == 1 {
            nibbles.insert(0, at: 0)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(nibbles.count / 2)
        var index = 0
        while index < nibbles.count {
            bytes.append(nibbles[index] << 4 | nibbles[index + 1])
            index += 2
        }
        self.init(bigEndianBytes: Data(bytes))
    }

    // MARK: - Inspection

    var isZero: Bool { limbs.isEmpty }

    /// Number of significant bits; zero has width 0.
    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
    }

    /// Bit `index` counting from the least-significant bit.
    func bit(at index: Int) -> Bool {
        let limbIndex = index >> 6
        guard limbIndex >= 0, limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> UInt64(index & 63)) & 1 == 1
    }

    var description: String {
        let bytes = bigEndianBytes
        return bytes.isEmpty ? "00" : bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Encoding

    /// Minimal big-endian encoding with no leading zero bytes. Zero encodes as
    /// empty, matching BouncyCastle's `BigIntegers.asUnsignedByteArray`, which
    /// the reference EC-JPAKE implementation uses on the wire.
    var bigEndianBytes: Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(limbs.count * 8)
        for limb in limbs.reversed() {
            var shift = 56
            while shift >= 0 {
                bytes.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
                shift -= 8
            }
        }
        var start = 0
        while start < bytes.count, bytes[start] == 0 {
            start += 1
        }
        return Data(bytes[start...])
    }

    /// Fixed-width big-endian encoding, zero-padded on the left. Returns nil if
    /// the value does not fit in `width` bytes.
    func bigEndianBytes(width: Int) -> Data? {
        let minimal = bigEndianBytes
        guard minimal.count <= width else { return nil }
        return Data(repeating: 0, count: width - minimal.count) + minimal
    }

    // MARK: - Comparison

    static func compare(_ lhs: TandemBigUInt, _ rhs: TandemBigUInt) -> Int {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count ? -1 : 1
        }
        var index = lhs.limbs.count - 1
        while index >= 0 {
            if lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] < rhs.limbs[index] ? -1 : 1
            }
            index -= 1
        }
        return 0
    }

    static func < (lhs: TandemBigUInt, rhs: TandemBigUInt) -> Bool {
        compare(lhs, rhs) < 0
    }

    // MARK: - Arithmetic

    static func + (lhs: TandemBigUInt, rhs: TandemBigUInt) -> TandemBigUInt {
        let count = max(lhs.limbs.count, rhs.limbs.count)
        var result: [UInt64] = []
        result.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for index in 0 ..< count {
            let left = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, overflow1) = left.addingReportingOverflow(right)
            let (sum, overflow2) = partial.addingReportingOverflow(carry)
            result.append(sum)
            // At most one of the two additions can overflow: if the first
            // overflowed, `partial` is at most 2^64 - 2 and adding a carry of 1
            // cannot overflow again.
            carry = (overflow1 || overflow2) ? 1 : 0
        }
        if carry > 0 {
            result.append(carry)
        }
        return TandemBigUInt(normalizing: result)
    }

    /// Truncated subtraction. The caller must guarantee `lhs >= rhs`.
    static func - (lhs: TandemBigUInt, rhs: TandemBigUInt) -> TandemBigUInt {
        precondition(compare(lhs, rhs) >= 0, "TandemBigUInt subtraction would go negative")
        var result: [UInt64] = []
        result.reserveCapacity(lhs.limbs.count)
        var borrow: UInt64 = 0
        for index in 0 ..< lhs.limbs.count {
            let left = lhs.limbs[index]
            let right = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, borrow1) = left.subtractingReportingOverflow(right)
            let (difference, borrow2) = partial.subtractingReportingOverflow(borrow)
            result.append(difference)
            // As with addition, at most one of the two can borrow: after a
            // borrowing subtraction `partial` is at least 1.
            borrow = (borrow1 || borrow2) ? 1 : 0
        }
        return TandemBigUInt(normalizing: result)
    }

    static func * (lhs: TandemBigUInt, rhs: TandemBigUInt) -> TandemBigUInt {
        if lhs.isZero || rhs.isZero { return TandemBigUInt() }
        var result = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0 ..< lhs.limbs.count {
            let left = lhs.limbs[i]
            var carry: UInt64 = 0
            for j in 0 ..< rhs.limbs.count {
                // result[i+j] + left*rhs[j] + carry always fits in 128 bits:
                // (2^64-1)^2 + 2*(2^64-1) == 2^128 - 1.
                let (high, low) = left.multipliedFullWidth(by: rhs.limbs[j])
                var newCarry = high
                let (partial, overflow1) = result[i + j].addingReportingOverflow(low)
                if overflow1 { newCarry &+= 1 }
                let (sum, overflow2) = partial.addingReportingOverflow(carry)
                if overflow2 { newCarry &+= 1 }
                result[i + j] = sum
                carry = newCarry
            }
            var index = i + rhs.limbs.count
            while carry > 0, index < result.count {
                let (sum, overflow) = result[index].addingReportingOverflow(carry)
                result[index] = sum
                carry = overflow ? 1 : 0
                index += 1
            }
        }
        return TandemBigUInt(normalizing: result)
    }

    /// Shift left by `bits` (0-63), growing by at most one limb.
    private static func shiftedLeft(_ limbs: [UInt64], by bits: Int) -> [UInt64] {
        guard bits > 0 else { return limbs }
        var result: [UInt64] = []
        result.reserveCapacity(limbs.count + 1)
        var carry: UInt64 = 0
        for limb in limbs {
            result.append((limb << UInt64(bits)) | carry)
            carry = limb >> UInt64(64 - bits)
        }
        if carry != 0 {
            result.append(carry)
        }
        return result
    }

    /// Shift right by `bits` (0-63).
    private static func shiftedRight(_ limbs: [UInt64], by bits: Int) -> [UInt64] {
        guard bits > 0 else { return limbs }
        var result = [UInt64](repeating: 0, count: limbs.count)
        var carry: UInt64 = 0
        var index = limbs.count - 1
        while index >= 0 {
            result[index] = (limbs[index] >> UInt64(bits)) | carry
            carry = limbs[index] << UInt64(64 - bits)
            index -= 1
        }
        return result
    }

    /// Remainder after division by `modulus`, using Knuth's algorithm D
    /// (the schoolbook long division of Hacker's Delight `divmnu64`) over
    /// 64-bit limbs. `modulus` must be non-zero.
    ///
    /// A bit-at-a-time division would be far simpler, but this runs on every
    /// modular multiplication — thousands of times per scalar multiplication —
    /// and the word-wise version is what keeps a JPAKE pairing to a couple of
    /// seconds rather than minutes.
    func modulo(_ modulus: TandemBigUInt) -> TandemBigUInt {
        precondition(!modulus.isZero, "TandemBigUInt division by zero")
        if Self.compare(self, modulus) < 0 { return self }

        let n = modulus.limbs.count

        // Single-limb divisor: one pass of 128-by-64 divisions.
        if n == 1 {
            let divisor = modulus.limbs[0]
            var remainder: UInt64 = 0
            var index = limbs.count - 1
            while index >= 0 {
                (_, remainder) = divisor.dividingFullWidth((high: remainder, low: limbs[index]))
                index -= 1
            }
            return TandemBigUInt(remainder)
        }

        // Normalize so the divisor's top limb has its high bit set, which is
        // what makes the quotient-digit estimate below accurate to within one.
        let shift = modulus.limbs[n - 1].leadingZeroBitCount
        let v = Self.shiftedLeft(modulus.limbs, by: shift)
        let m = limbs.count - n
        var u = Self.shiftedLeft(limbs, by: shift)
        while u.count < m + n + 1 {
            u.append(0)
        }

        var j = m
        while j >= 0 {
            // Estimate this quotient digit from the top two limbs.
            var qhat: UInt64
            var rhat: UInt64
            var rhatOverflowed: Bool
            if u[j + n] == v[n - 1] {
                // The true digit would not fit in a limb; clamp it and let the
                // correction loop (and the add-back below) fix the estimate.
                qhat = UInt64.max
                let (sum, overflow) = v[n - 1].addingReportingOverflow(u[j + n - 1])
                rhat = sum
                rhatOverflowed = overflow
            } else {
                (qhat, rhat) = v[n - 1].dividingFullWidth((high: u[j + n], low: u[j + n - 1]))
                rhatOverflowed = false
            }

            while !rhatOverflowed {
                let (productHigh, productLow) = qhat.multipliedFullWidth(by: v[n - 2])
                guard productHigh > rhat || (productHigh == rhat && productLow > u[j + n - 2]) else { break }
                qhat -= 1
                let (sum, overflow) = rhat.addingReportingOverflow(v[n - 1])
                rhat = sum
                rhatOverflowed = overflow
            }

            // u[j ... j+n] -= qhat * v
            var borrow: UInt64 = 0
            var carry: UInt64 = 0
            for i in 0 ..< n {
                let (productHigh, productLow) = qhat.multipliedFullWidth(by: v[i])
                let (piece, carried) = productLow.addingReportingOverflow(carry)
                // productHigh is at most 2^64 - 2, so the increment cannot wrap.
                let nextCarry = productHigh &+ (carried ? 1 : 0)
                let (difference, borrowed1) = u[i + j].subtractingReportingOverflow(piece)
                let (result, borrowed2) = difference.subtractingReportingOverflow(borrow)
                u[i + j] = result
                borrow = (borrowed1 || borrowed2) ? 1 : 0
                carry = nextCarry
            }
            let (topDifference, topBorrowed1) = u[j + n].subtractingReportingOverflow(carry)
            let (topResult, topBorrowed2) = topDifference.subtractingReportingOverflow(borrow)
            u[j + n] = topResult

            if topBorrowed1 || topBorrowed2 {
                // The estimate was one too large: add the divisor back.
                var addCarry: UInt64 = 0
                for i in 0 ..< n {
                    let (partial, overflow1) = u[i + j].addingReportingOverflow(v[i])
                    let (sum, overflow2) = partial.addingReportingOverflow(addCarry)
                    u[i + j] = sum
                    addCarry = (overflow1 || overflow2) ? 1 : 0
                }
                u[j + n] = u[j + n] &+ addCarry
            }

            j -= 1
        }

        // The remainder occupies the low n limbs, still scaled by the
        // normalization shift.
        return TandemBigUInt(normalizing: Self.shiftedRight(Array(u[0 ..< n]), by: shift))
    }

    // MARK: - Modular arithmetic
    //
    // The `mod`-prefixed helpers require their operands to already be reduced
    // (strictly less than `modulus`) unless stated otherwise.

    static func modAdd(_ lhs: TandemBigUInt, _ rhs: TandemBigUInt, _ modulus: TandemBigUInt) -> TandemBigUInt {
        let sum = lhs + rhs
        return compare(sum, modulus) >= 0 ? sum - modulus : sum
    }

    static func modSub(_ lhs: TandemBigUInt, _ rhs: TandemBigUInt, _ modulus: TandemBigUInt) -> TandemBigUInt {
        if compare(lhs, rhs) >= 0 {
            return lhs - rhs
        }
        return (lhs + modulus) - rhs
    }

    /// Accepts unreduced operands.
    static func modMul(_ lhs: TandemBigUInt, _ rhs: TandemBigUInt, _ modulus: TandemBigUInt) -> TandemBigUInt {
        (lhs * rhs).modulo(modulus)
    }

    /// Additive inverse: `(modulus - value) mod modulus`.
    static func modNegate(_ value: TandemBigUInt, _ modulus: TandemBigUInt) -> TandemBigUInt {
        let reduced = value.modulo(modulus)
        return reduced.isZero ? reduced : modulus - reduced
    }

    /// Right-to-left square-and-multiply. Accepts an unreduced base.
    static func modPow(_ base: TandemBigUInt, _ exponent: TandemBigUInt, _ modulus: TandemBigUInt) -> TandemBigUInt {
        if modulus == TandemBigUInt(1) { return TandemBigUInt() }
        var result = TandemBigUInt(1)
        var square = base.modulo(modulus)
        let width = exponent.bitWidth
        var index = 0
        while index < width {
            if exponent.bit(at: index) {
                result = modMul(result, square, modulus)
            }
            index += 1
            if index < width {
                square = modMul(square, square, modulus)
            }
        }
        return result
    }

    /// Multiplicative inverse modulo a **prime** `modulus`, via Fermat's little
    /// theorem (`a^(p-2) mod p`). Returns zero for a zero input, which callers
    /// treat as "no inverse".
    static func modInversePrime(_ value: TandemBigUInt, _ modulus: TandemBigUInt) -> TandemBigUInt {
        let reduced = value.modulo(modulus)
        guard !reduced.isZero else { return TandemBigUInt() }
        return modPow(reduced, modulus - TandemBigUInt(2), modulus)
    }
}
