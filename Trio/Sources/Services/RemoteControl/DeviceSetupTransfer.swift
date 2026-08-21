import CryptoSwift
import Foundation

/// Everything needed to make a new phone run Trio exactly like this one:
/// the complete settings backup plus the remote-control identity — paired
/// followers with their secrets, APNS/FCM credentials and the legacy shared
/// secret. Rendered as a sequence of QR codes on the old device and scanned
/// by the new one.
///
/// Treat the encoded frames like a password: together they contain every
/// follower secret and the APNS key. They are only ever rendered on the host
/// screen, never persisted or shared.
struct DeviceSetupTransfer: Codable {
    static let currentSchemaVersion = 1
    static let transferType = "trio-device-setup"

    var schemaVersion: Int = DeviceSetupTransfer.currentSchemaVersion
    var type: String = DeviceSetupTransfer.transferType
    var createdAt: Date?
    var hostName: String?
    var appVersion: String?

    /// The same machine-readable backup a backup file carries — settings,
    /// algorithm preferences, delivery limits, therapy profiles and presets.
    var backup: TrioSettingsBackup?

    /// The host's remote-control identity, absent when the host has never
    /// configured remote control.
    var remoteControl: RemoteControlTransfer?
}

/// Remote-control state that lives outside the settings files: keychain
/// credentials, the follower list (including per-follower secrets and push
/// registrations) and the UserDefaults toggles.
struct RemoteControlTransfer: Codable {
    var enabled: Bool
    /// Legacy LoopFollow-style shared secret, if one was ever generated.
    var sharedSecret: String?

    var apnsTeamId: String?
    var apnsKeyId: String?
    var apnsKey: String?
    var fcmServiceAccountJSON: String?

    /// Complete `PairedFollower` records: secrets, sequence counters, push
    /// registrations and alert profiles all carry over, so followers keep
    /// working without re-pairing. Carrying `lastSequence` preserves replay
    /// protection across the move.
    var followers: [PairedFollower]?

    /// The VAPID key web viewers' push subscriptions are bound to. Optional so
    /// transfers from hosts that predate web viewers still decode.
    var vapidPrivateKey: String?
}

enum DeviceSetupCodecError: LocalizedError {
    case encodingFailed
    case notASetupFrame
    case malformedFrame
    case unsupportedVersion(Int)
    case mismatchedTransfer
    case incomplete
    case corruptPayload

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return String(localized: "Could not prepare the device setup code.")
        case .notASetupFrame:
            return String(localized: "This QR code is not a Trio device setup code.")
        case .malformedFrame:
            return String(localized: "This QR code is damaged. Keep the camera on the old device's screen.")
        case let .unsupportedVersion(version):
            return String(
                localized: "This setup code was created by a newer version of Trio (format \(version)). Update Trio on this phone and try again."
            )
        case .mismatchedTransfer:
            return String(localized: "This QR code belongs to a different setup session. Restart the setup code on the old device and scan again.")
        case .incomplete:
            return String(localized: "Not all parts of the setup code have been scanned yet.")
        case .corruptPayload:
            return String(localized: "The scanned setup code could not be read. Restart the setup code on the old device and scan again.")
        }
    }
}

/// One scanned QR frame, parsed from its string.
struct DeviceSetupFrame: Equatable {
    let transferId: String
    let index: Int
    let count: Int
    let chunk: String

    /// Wire format: `TRIODS<version>:<transferId>:<index>:<count>:<chunk>`.
    /// The transfer id doubles as an integrity check — it is the first 8 hex
    /// characters of SHA-256 over the complete base64 payload, verified once
    /// all chunks are assembled.
    static let framePrefix = "TRIODS"

    static func parse(_ string: String) throws -> DeviceSetupFrame {
        guard string.hasPrefix(framePrefix) else {
            throw DeviceSetupCodecError.notASetupFrame
        }
        let parts = string.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5 else {
            throw DeviceSetupCodecError.malformedFrame
        }
        guard let version = Int(parts[0].dropFirst(framePrefix.count)) else {
            throw DeviceSetupCodecError.malformedFrame
        }
        guard version == DeviceSetupTransfer.currentSchemaVersion else {
            throw DeviceSetupCodecError.unsupportedVersion(version)
        }
        let transferId = String(parts[1])
        guard !transferId.isEmpty,
              let index = Int(parts[2]),
              let count = Int(parts[3]),
              count > 0, index >= 0, index < count
        else {
            throw DeviceSetupCodecError.malformedFrame
        }
        let chunk = String(parts[4])
        guard !chunk.isEmpty else {
            throw DeviceSetupCodecError.malformedFrame
        }
        return DeviceSetupFrame(transferId: transferId, index: index, count: count, chunk: chunk)
    }
}

/// Shared payload coding for both symbol formats: compact JSON (dates and
/// keys deterministic), zlib. The dense matrix carries the compressed bytes
/// raw; the QR frames carry them base64-encoded.
enum DeviceSetupPayloadCoder {
    /// Compact on purpose — the pretty-printed `JSONCoding.encoder` would
    /// waste a third of the symbol on indentation. Decoding accepts either.
    private static var compactEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .customISO8601
        return encoder
    }

    static func compress(_ transfer: DeviceSetupTransfer) throws -> Data {
        let json = try compactEncoder.encode(transfer)
        guard let compressed = try? (json as NSData).compressed(using: .zlib) as Data else {
            throw DeviceSetupCodecError.encodingFailed
        }
        return compressed
    }

    static func decompress(_ compressed: Data) throws -> DeviceSetupTransfer {
        guard let json = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let transfer = try? JSONCoding.decoder.decode(DeviceSetupTransfer.self, from: json),
              transfer.type == DeviceSetupTransfer.transferType
        else {
            throw DeviceSetupCodecError.corruptPayload
        }
        guard transfer.schemaVersion <= DeviceSetupTransfer.currentSchemaVersion else {
            throw DeviceSetupCodecError.unsupportedVersion(transfer.schemaVersion)
        }
        return transfer
    }
}

/// Encodes a transfer into QR frame strings and back. The payload is JSON,
/// zlib-compressed and base64-encoded, then split into chunks small enough
/// that each QR stays comfortably scannable from another phone's screen.
enum DeviceSetupQRCodec {
    /// Chunk size in base64 characters. ~700 bytes per QR keeps the module
    /// count in easy scanning range (the single-frame follower pairing code
    /// is twice that); the payload is spread over as many frames as needed.
    static let maxChunkLength = 700

    static func encode(_ transfer: DeviceSetupTransfer, chunkLength: Int = maxChunkLength) throws -> [String] {
        let base64 = try DeviceSetupPayloadCoder.compress(transfer).base64EncodedString()
        let transferId = Self.transferId(forBase64Payload: base64)

        var chunks: [String] = []
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: chunkLength, limitedBy: base64.endIndex) ?? base64.endIndex
            chunks.append(String(base64[start ..< end]))
            start = end
        }
        guard !chunks.isEmpty else {
            throw DeviceSetupCodecError.encodingFailed
        }

        let version = DeviceSetupTransfer.currentSchemaVersion
        return chunks.enumerated().map { index, chunk in
            "\(DeviceSetupFrame.framePrefix)\(version):\(transferId):\(index):\(chunks.count):\(chunk)"
        }
    }

    static func decode(base64: String, expectedTransferId: String) throws -> DeviceSetupTransfer {
        guard transferId(forBase64Payload: base64) == expectedTransferId,
              let compressed = Data(base64Encoded: base64)
        else {
            throw DeviceSetupCodecError.corruptPayload
        }
        return try DeviceSetupPayloadCoder.decompress(compressed)
    }

    static func transferId(forBase64Payload base64: String) -> String {
        Data(base64.utf8).sha256().prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// Collects scanned frames in any order until the transfer is complete.
/// Frames repeat on the host's screen in a loop, so duplicates are the
/// normal case and simply ignored.
final class DeviceSetupScanAssembler {
    private(set) var transferId: String?
    private(set) var expectedCount: Int?
    private var chunks: [Int: String] = [:]

    var receivedCount: Int { chunks.count }

    var isComplete: Bool {
        guard let expectedCount else { return false }
        return chunks.count == expectedCount
    }

    /// Adds one scanned QR string. Returns true when the frame was new
    /// (progress advanced), false for an already-seen frame. Throws for
    /// strings that are not valid frames of this transfer.
    @discardableResult func add(_ string: String) throws -> Bool {
        let frame = try DeviceSetupFrame.parse(string)

        if let transferId {
            // The host restarts with a fresh id when the code is re-opened;
            // mixing frames of two sessions can never assemble.
            guard frame.transferId == transferId, frame.count == expectedCount else {
                throw DeviceSetupCodecError.mismatchedTransfer
            }
        } else {
            transferId = frame.transferId
            expectedCount = frame.count
        }

        guard chunks[frame.index] == nil else { return false }
        chunks[frame.index] = frame.chunk
        return true
    }

    func assemble() throws -> DeviceSetupTransfer {
        guard let transferId, let expectedCount, chunks.count == expectedCount else {
            throw DeviceSetupCodecError.incomplete
        }
        let base64 = (0 ..< expectedCount).compactMap { chunks[$0] }.joined()
        return try DeviceSetupQRCodec.decode(base64: base64, expectedTransferId: transferId)
    }
}
