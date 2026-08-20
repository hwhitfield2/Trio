import CoreGraphics
import CryptoSwift
import Foundation

/// Trio's dense setup matrix (TDM1): a single static 2D code that carries the
/// whole device-setup transfer in one image, instead of a looping sequence of
/// QR frames. Only Trio itself ever renders or reads it, so the format is
/// free to spend its area on data and error correction rather than on being
/// decodable by third-party scanners:
///
/// - a solid 2-module black frame with a 1-module white gap marks the symbol
///   (the scanner finds the white card by rectangle detection, then locks to
///   this frame), leaving the entire interior for data;
/// - a 16-byte header protected by RS(48,16) — magic, version, grid size,
///   payload length and a SHA-256 prefix — decodes first and cheaply, which
///   is how the scanner confirms grid size and rotation;
/// - the zlib-compressed payload is Reed-Solomon coded in interleaved
///   RS(255,191) blocks (any 32 corrupted bytes per block recover, and
///   interleaving spreads a local smudge across blocks);
/// - everything is XOR-scrambled so the rendered symbol has no large uniform
///   areas, and unused cells carry the same pseudo-random texture.
///
/// Because the symbol is static, the scanner can average many camera frames
/// per cell before deciding — that vote is what lets a phone screen carry
/// several kilobytes in one matrix where a single-shot QR gives up.
enum DenseMatrixCode {
    static let magic: [UInt8] = Array("TDM".utf8)
    static let version: UInt8 = 1

    static let headerLength = 16
    static let headerParity = 32 // RS(48,16)
    static let bodyBlockData = 191
    static let bodyBlockParity = 64 // RS(255,191)

    /// Allowed grid sizes. The scanner tries these against the detected frame,
    /// so the ladder must stay short; the header then confirms the match.
    static let sizes = [121, 161, 201, 241, 281]

    /// Modules on each side that are not data: 2 frame + 1 gap.
    static let borderModules = 3

    enum CodeError: LocalizedError {
        case payloadTooLarge

        var errorDescription: String? {
            switch self {
            case .payloadTooLarge:
                return String(
                    localized: "This configuration is too large for a single setup matrix. Use the QR code sequence instead."
                )
            }
        }
    }

    /// A rendered symbol: `modules[row * size + col]`, true = black.
    struct Symbol {
        let size: Int
        let modules: [Bool]
    }

    static func dataCellCount(size n: Int) -> Int {
        (n - 2 * borderModules) * (n - 2 * borderModules)
    }

    static func capacityBytes(size n: Int) -> Int {
        dataCellCount(size: n) / 8
    }

    static func encodedByteCount(payloadLength: Int) -> Int {
        let blocks = (payloadLength + bodyBlockData - 1) / bodyBlockData
        return headerLength + headerParity + payloadLength + bodyBlockParity * blocks
    }

    static func pickSize(payloadLength: Int) -> Int? {
        let need = encodedByteCount(payloadLength: payloadLength)
        return sizes.first { capacityBytes(size: $0) >= need }
    }

    // MARK: - Encoding

    static func encode(payload: Data) throws -> Symbol {
        guard let n = pickSize(payloadLength: payload.count) else {
            throw CodeError.payloadTooLarge
        }

        let header = makeHeader(size: n, payload: payload)
        var stream = ReedSolomon.encode(header, paritySymbols: headerParity)

        let blocks = bodyBlocks(payload: Array(payload))
        stream += interleave(blocks)
        stream = scramble(stream)

        // Bit-pack MSB first into the data region, then pad the remaining
        // cells with the same pseudo-random texture so the symbol has no
        // large blank areas for the camera's exposure to smear over.
        let cells = dataCellCount(size: n)
        var bits = [Bool]()
        bits.reserveCapacity(cells)
        for byte in stream {
            for k in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> k) & 1 == 1)
            }
        }
        let padMask = scrambleMask(count: (cells - bits.count) / 8 + 2)
        var padIndex = 0
        while bits.count < cells {
            let byte = padMask[(padIndex / 8) % padMask.count]
            bits.append((byte >> (7 - padIndex % 8)) & 1 == 1)
            padIndex += 1
        }

        return Symbol(size: n, modules: assembleModules(size: n, dataBits: bits))
    }

    private static func makeHeader(size n: Int, payload: Data) -> [UInt8] {
        var header = magic
        header.append(version)
        header.append(UInt8(n >> 8))
        header.append(UInt8(n & 0xFF))
        let length = UInt32(payload.count)
        header.append(UInt8((length >> 24) & 0xFF))
        header.append(UInt8((length >> 16) & 0xFF))
        header.append(UInt8((length >> 8) & 0xFF))
        header.append(UInt8(length & 0xFF))
        header += Array(payload.sha256().prefix(6))
        return header
    }

    private static func bodyBlocks(payload: [UInt8]) -> [[UInt8]] {
        var blocks = [[UInt8]]()
        var index = 0
        while index < payload.count {
            let end = min(index + bodyBlockData, payload.count)
            blocks.append(ReedSolomon.encode(Array(payload[index ..< end]), paritySymbols: bodyBlockParity))
            index = end
        }
        return blocks
    }

    private static func interleave(_ blocks: [[UInt8]]) -> [UInt8] {
        guard let maxLen = blocks.map(\.count).max() else { return [] }
        var out = [UInt8]()
        for i in 0 ..< maxLen {
            for block in blocks where i < block.count {
                out.append(block[i])
            }
        }
        return out
    }

    private static func deinterleave(_ stream: [UInt8], blockLengths: [Int]) -> [[UInt8]]? {
        guard stream.count >= blockLengths.reduce(0, +) else { return nil }
        var blocks: [[UInt8]] = blockLengths.map { _ in [] }
        var index = 0
        let maxLen = blockLengths.max() ?? 0
        for i in 0 ..< maxLen {
            for (bi, blen) in blockLengths.enumerated() where i < blen {
                blocks[bi].append(stream[index])
                index += 1
            }
        }
        return blocks
    }

    private static func bodyBlockLengths(payloadLength: Int) -> [Int] {
        var lengths = [Int]()
        var remaining = payloadLength
        while remaining > 0 {
            let d = min(remaining, bodyBlockData)
            lengths.append(d + bodyBlockParity)
            remaining -= d
        }
        return lengths
    }

    /// Fills the full module grid: 2-module black frame, 1-module white gap,
    /// data cells row-major inside. True = black; a data bit 1 renders black.
    private static func assembleModules(size n: Int, dataBits: [Bool]) -> [Bool] {
        var modules = [Bool](repeating: false, count: n * n)
        for row in 0 ..< n {
            for col in 0 ..< n {
                let onFrame = row < 2 || col < 2 || row >= n - 2 || col >= n - 2
                if onFrame { modules[row * n + col] = true }
            }
        }
        let inner = n - 2 * borderModules
        for i in 0 ..< dataBits.count {
            let row = borderModules + i / inner
            let col = borderModules + i % inner
            modules[row * n + col] = dataBits[i]
        }
        return modules
    }

    // MARK: - Scrambling

    /// xorshift32 stream with a fixed seed; identical on both sides. XOR with
    /// a stream means a prefix can be descrambled without knowing the total
    /// length, which is what lets the header decode before the body length is
    /// known.
    static func scrambleMask(count: Int) -> [UInt8] {
        var state: UInt32 = 0x5DEE_CE66
        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0 ..< count {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            out.append(UInt8(state & 0xFF))
        }
        return out
    }

    static func scramble(_ data: [UInt8]) -> [UInt8] {
        let mask = scrambleMask(count: data.count)
        return zip(data, mask).map { $0 ^ $1 }
    }

    // MARK: - Decoding

    /// Decoded header, the cheap first stage the scanner uses to confirm a
    /// grid-size/rotation hypothesis.
    struct Header {
        let size: Int
        let payloadLength: Int
        let hashPrefix: [UInt8]
    }

    static func decodeHeader(bits: [Bool]) -> Header? {
        let headerBits = (headerLength + headerParity) * 8
        guard bits.count >= headerBits else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerLength + headerParity)
        for i in 0 ..< headerLength + headerParity {
            var b: UInt8 = 0
            for k in 0 ..< 8 {
                b = (b << 1) | (bits[i * 8 + k] ? 1 : 0)
            }
            bytes.append(b)
        }
        bytes = scramble(bytes) // XOR stream: prefix descrambles cleanly
        guard let header = ReedSolomon.decode(bytes, paritySymbols: headerParity) else { return nil }
        guard Array(header[0 ..< 3]) == magic, header[3] == version else { return nil }
        let size = Int(header[4]) << 8 | Int(header[5])
        guard sizes.contains(size) else { return nil }
        let length = Int(header[6]) << 24 | Int(header[7]) << 16 | Int(header[8]) << 8 | Int(header[9])
        guard length > 0, length <= capacityBytes(size: size) else { return nil }
        return Header(size: size, payloadLength: length, hashPrefix: Array(header[10 ..< 16]))
    }

    /// Decodes the payload from the binarized data-region bits of one
    /// orientation. Returns nil unless every RS block decodes and the
    /// payload hash matches the header.
    static func decodeBits(_ bits: [Bool], size n: Int) -> Data? {
        guard bits.count == dataCellCount(size: n) else { return nil }
        guard let header = decodeHeader(bits: bits), header.size == n else { return nil }

        let blockLengths = bodyBlockLengths(payloadLength: header.payloadLength)
        let totalBytes = headerLength + headerParity + blockLengths.reduce(0, +)
        guard totalBytes * 8 <= bits.count else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(totalBytes)
        for i in 0 ..< totalBytes {
            var b: UInt8 = 0
            for k in 0 ..< 8 {
                b = (b << 1) | (bits[i * 8 + k] ? 1 : 0)
            }
            bytes.append(b)
        }
        bytes = scramble(bytes)

        let bodyStream = Array(bytes.dropFirst(headerLength + headerParity))
        guard let blocks = deinterleave(bodyStream, blockLengths: blockLengths) else { return nil }

        var payload = [UInt8]()
        payload.reserveCapacity(header.payloadLength)
        for block in blocks {
            guard let decoded = ReedSolomon.decode(block, paritySymbols: bodyBlockParity) else { return nil }
            payload += decoded
        }
        guard payload.count == header.payloadLength else { return nil }
        guard Array(Data(payload).sha256().prefix(6)) == header.hashPrefix else { return nil }
        return Data(payload)
    }

    /// Decodes from raw luminance samples of the data region (row-major,
    /// `(n-6)^2` values, any orientation): binarizes with an Otsu threshold,
    /// then tries all four rotations. The header stage rejects wrong
    /// rotations within a few hundred cells, so the trials are cheap.
    static func decode(interiorLuminances: [Float], size n: Int) -> Data? {
        let inner = n - 2 * borderModules
        guard interiorLuminances.count == inner * inner else { return nil }

        guard let threshold = otsuThreshold(interiorLuminances) else { return nil }
        // Dark cell = bit 1, matching the renderer (true = black).
        var bits = interiorLuminances.map { $0 < threshold }

        for _ in 0 ..< 4 {
            if let payload = decodeBits(bits, size: n) {
                return payload
            }
            bits = rotateClockwise(bits, side: inner)
        }
        return nil
    }

    static func rotateClockwise(_ bits: [Bool], side: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: bits.count)
        for row in 0 ..< side {
            for col in 0 ..< side {
                out[col * side + (side - 1 - row)] = bits[row * side + col]
            }
        }
        return out
    }

    /// Otsu's threshold over a 256-bin histogram of the luminances. Returns
    /// nil for degenerate input (all cells the same brightness — the camera
    /// is not looking at a symbol).
    static func otsuThreshold(_ values: [Float]) -> Float? {
        guard let minV = values.min(), let maxV = values.max(), maxV - minV > 0.05 else { return nil }
        let bins = 256
        var histogram = [Int](repeating: 0, count: bins)
        let scale = Float(bins - 1) / (maxV - minV)
        for v in values {
            histogram[Int((v - minV) * scale)] += 1
        }

        let total = values.count
        var sumAll: Double = 0
        for i in 0 ..< bins {
            sumAll += Double(i * histogram[i])
        }

        var sumBackground: Double = 0
        var weightBackground = 0
        var bestVariance = -1.0
        var bestBin = bins / 2
        for i in 0 ..< bins {
            weightBackground += histogram[i]
            if weightBackground == 0 { continue }
            let weightForeground = total - weightBackground
            if weightForeground == 0 { break }
            sumBackground += Double(i * histogram[i])
            let meanBackground = sumBackground / Double(weightBackground)
            let meanForeground = (sumAll - sumBackground) / Double(weightForeground)
            let diff = meanBackground - meanForeground
            let variance = Double(weightBackground) * Double(weightForeground) * diff * diff
            if variance > bestVariance {
                bestVariance = variance
                bestBin = i
            }
        }
        return minV + (Float(bestBin) + 0.5) / scale
    }

    // MARK: - Rendering

    /// Renders the symbol as a black-on-white bitmap, `pixelsPerModule` px per
    /// cell plus a quiet margin. The caller shows it pixel-exact
    /// (`interpolation(.none)`).
    static func render(_ symbol: Symbol, pixelsPerModule: Int = 4, quietModules: Int = 4) -> CGImage? {
        let n = symbol.size
        let sidePx = (n + 2 * quietModules) * pixelsPerModule
        guard let context = CGContext(
            data: nil,
            width: sidePx,
            height: sidePx,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: sidePx, height: sidePx))
        context.setFillColor(gray: 0, alpha: 1)

        let offset = quietModules * pixelsPerModule
        for row in 0 ..< n {
            for col in 0 ..< n where symbol.modules[row * n + col] {
                // CGContext origin is bottom-left; flip rows so module (0,0)
                // renders top-left, matching the sampling convention.
                context.fill(CGRect(
                    x: offset + col * pixelsPerModule,
                    y: sidePx - offset - (row + 1) * pixelsPerModule,
                    width: pixelsPerModule,
                    height: pixelsPerModule
                ))
            }
        }
        return context.makeImage()
    }
}
