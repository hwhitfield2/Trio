import Foundation

/// CRC-16/CCITT-FALSE as used by the Tandem t:slim X2 / Mobi BLE protocol.
/// Polynomial 0x1021, initial value 0xFFFF, no reflection, no final XOR.
/// The pump expects the checksum appended little-endian (low byte first).
///
/// Reference: pumpx2 `Bytes.calculateCRC16` (jwoglom/pumpx2,
/// messages/.../helpers/Bytes.java).
enum TandemCRC {
    private static let table: [UInt16] = {
        (0 ..< 256).map { index -> UInt16 in
            var crc = UInt16(index) << 8
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
            return crc
        }
    }()

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc = (crc << 8) ^ table[Int((UInt16(byte) ^ (crc >> 8)) & 0xFF)]
        }
        return crc
    }

    /// Checksum bytes in wire order (little-endian).
    static func crc16Data(_ data: Data) -> Data {
        let crc = crc16(data)
        return Data([UInt8(crc & 0xFF), UInt8(crc >> 8)])
    }
}
