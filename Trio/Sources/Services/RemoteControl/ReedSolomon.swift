import Foundation

/// Reed-Solomon over GF(2^8), primitive polynomial 0x11D, generator α = 2,
/// first consecutive root α^0 — the same code family QR uses, but with the
/// block sizes the dense setup matrix needs. Systematic: a codeword is the
/// message followed by `paritySymbols` parity bytes, and up to
/// `paritySymbols / 2` byte errors anywhere in it can be corrected.
///
/// The algorithms (Berlekamp-Massey, Chien search, Forney with the X_j
/// factor for fcr=0) mirror the validated Python prototype byte for byte;
/// the unit tests pin them to vectors that prototype generated.
enum ReedSolomon {
    private static let prim = 0x11D

    private static let tables: (exp: [UInt8], log: [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0 ..< 255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= prim }
        }
        for i in 255 ..< 512 {
            exp[i] = exp[i - 255]
        }
        return (exp, log)
    }()

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return tables.exp[tables.log[Int(a)] + tables.log[Int(b)]]
    }

    private static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 { return 0 }
        let idx = (tables.log[Int(a)] - tables.log[Int(b)] + 255) % 255
        return tables.exp[idx]
    }

    /// α^n for n ≥ 0.
    private static func pow2(_ n: Int) -> UInt8 {
        tables.exp[n % 255]
    }

    private static func inv(_ a: UInt8) -> UInt8 {
        tables.exp[255 - tables.log[Int(a)]]
    }

    // Polynomials are coefficient arrays, HIGH-order first.

    private static func polyMul(_ p: [UInt8], _ q: [UInt8]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: p.count + q.count - 1)
        for (i, pi) in p.enumerated() where pi != 0 {
            for (j, qj) in q.enumerated() {
                r[i + j] ^= mul(pi, qj)
            }
        }
        return r
    }

    private static func polyScale(_ p: [UInt8], _ s: UInt8) -> [UInt8] {
        p.map { mul($0, s) }
    }

    private static func polyAdd(_ p: [UInt8], _ q: [UInt8]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: max(p.count, q.count))
        let pOffset = r.count - p.count
        for (i, c) in p.enumerated() { r[i + pOffset] = c }
        let qOffset = r.count - q.count
        for (i, c) in q.enumerated() { r[i + qOffset] ^= c }
        return r
    }

    private static func polyEval(_ poly: [UInt8], _ x: UInt8) -> UInt8 {
        var y = poly[0]
        for c in poly.dropFirst() {
            y = mul(y, x) ^ c
        }
        return y
    }

    private static func generatorPoly(_ nsym: Int) -> [UInt8] {
        var g: [UInt8] = [1]
        for i in 0 ..< nsym {
            g = polyMul(g, [1, pow2(i)])
        }
        return g
    }

    /// Encodes systematically: returns message + parity.
    static func encode(_ message: [UInt8], paritySymbols nsym: Int) -> [UInt8] {
        let gen = generatorPoly(nsym)
        var res = message + [UInt8](repeating: 0, count: nsym)
        for i in 0 ..< message.count {
            let coef = res[i]
            if coef != 0 {
                for j in 1 ..< gen.count {
                    res[i + j] ^= mul(gen[j], coef)
                }
            }
        }
        return message + Array(res.suffix(nsym))
    }

    private static func syndromes(_ codeword: [UInt8], _ nsym: Int) -> [UInt8] {
        (0 ..< nsym).map { polyEval(codeword, pow2($0)) }
    }

    private static func errorLocator(_ synd: [UInt8], _ nsym: Int) -> [UInt8] {
        var errLoc: [UInt8] = [1]
        var oldLoc: [UInt8] = [1]
        for i in 0 ..< nsym {
            var delta = synd[i]
            if errLoc.count > 1 {
                for j in 1 ..< errLoc.count {
                    delta ^= mul(errLoc[errLoc.count - 1 - j], synd[i - j])
                }
            }
            oldLoc.append(0)
            if delta != 0 {
                if oldLoc.count > errLoc.count {
                    let newLoc = polyScale(oldLoc, delta)
                    oldLoc = polyScale(errLoc, inv(delta))
                    errLoc = newLoc
                }
                errLoc = polyAdd(errLoc, polyScale(oldLoc, delta))
            }
        }
        while errLoc.count > 1, errLoc[0] == 0 {
            errLoc.removeFirst()
        }
        return errLoc
    }

    /// Decodes a codeword, correcting up to `paritySymbols / 2` byte errors.
    /// Returns the message (parity stripped), or nil when uncorrectable.
    /// A decode that happens to land on a *wrong* codeword is possible when
    /// the error count exceeds the correction bound — callers must verify the
    /// result against an outer checksum, as the dense matrix header does.
    static func decode(_ codeword: [UInt8], paritySymbols nsym: Int) -> [UInt8]? {
        guard codeword.count > nsym, codeword.count <= 255 else { return nil }
        var cw = codeword
        var synd = syndromes(cw, nsym)
        if synd.allSatisfy({ $0 == 0 }) {
            return Array(cw.dropLast(nsym))
        }

        let errLoc = errorLocator(synd, nsym)
        let errs = errLoc.count - 1
        guard errs * 2 <= nsym else { return nil }

        // Chien search: position pos (0 = first byte) has power cw.count-1-pos;
        // it is in error when the locator vanishes at α^(-power).
        var errPos: [Int] = []
        for i in 0 ..< cw.count where polyEval(errLoc, inv(pow2(i))) == 0 {
            errPos.append(cw.count - 1 - i)
        }
        guard errPos.count == errs else { return nil }

        // Forney: Ω(x) = [S(x)·Λ(x)] mod x^nsym, e_j = X_j·Ω(X_j⁻¹)/Λ'(X_j⁻¹).
        let syndPoly = Array(synd.reversed())
        let prod = polyMul(syndPoly, errLoc)
        let omega = Array(prod.suffix(nsym))

        let lamLow = Array(errLoc.reversed())
        for pos in errPos {
            let power = cw.count - 1 - pos
            let xInv = inv(pow2(power))
            let y = polyEval(omega, xInv)
            var lamDeriv: UInt8 = 0
            var k = 1
            while k < lamLow.count {
                lamDeriv ^= mul(lamLow[k], gfPow(xInv, k - 1))
                k += 2
            }
            guard lamDeriv != 0 else { return nil }
            let magnitude = mul(pow2(power), div(y, lamDeriv))
            cw[pos] ^= magnitude
        }

        synd = syndromes(cw, nsym)
        guard synd.allSatisfy({ $0 == 0 }) else { return nil }
        return Array(cw.dropLast(nsym))
    }

    /// x^n for arbitrary field element x, n ≥ 0.
    private static func gfPow(_ x: UInt8, _ n: Int) -> UInt8 {
        if n == 0 { return 1 }
        if x == 0 { return 0 }
        return tables.exp[(tables.log[Int(x)] * n) % 255]
    }
}
