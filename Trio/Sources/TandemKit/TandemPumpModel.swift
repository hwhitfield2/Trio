import Foundation
import LoopKit

/// Which Tandem pump TandemKit is talking to.
///
/// The two supported models share a transport, a message set, and most of the
/// status surface, but differ in one way that matters a great deal to Trio:
/// only the **Mobi** accepts remote basal commands (temp rate, suspend,
/// resume). On the t:slim X2 those opcodes are not implemented in firmware, so
/// Trio can only close the loop there through the experimental
/// microbolus-basal workaround.
enum TandemPumpModel: String, CaseIterable {
    case tslimX2
    case mobi

    /// Model reported by a pump we have not identified yet. Treated as the more
    /// restrictive t:slim X2 until identification succeeds, so Trio never sends
    /// a basal command to a pump that may not support it.
    static let `default`: TandemPumpModel = .tslimX2

    var localizedTitle: String {
        switch self {
        case .tslimX2: return "Tandem t:slim X2"
        case .mobi: return "Tandem Mobi"
        }
    }

    /// Short name used inside sentences.
    var shortTitle: String {
        switch self {
        case .tslimX2: return "t:slim X2"
        case .mobi: return "Mobi"
        }
    }

    /// Cartridge size in units.
    var reservoirCapacity: Double {
        switch self {
        case .tslimX2: return 300
        case .mobi: return 200
        }
    }

    /// True when the pump implements the temp-rate / suspend / resume control
    /// opcodes. Per pumpX2's `supportedDevices = MOBI_ONLY` annotations, that is
    /// the Mobi alone.
    var supportsRemoteBasalControl: Bool {
        switch self {
        case .tslimX2: return false
        case .mobi: return true
        }
    }

    /// Prefixes the pump advertises its Bluetooth name with.
    var bluetoothNamePrefixes: [String] {
        switch self {
        case .tslimX2: return ["tslim x2", "t:slim x2"]
        case .mobi: return ["tandem mobi", "mobi"]
        }
    }

    /// Identify a pump from its advertised Bluetooth name, which is how the
    /// reference implementation distinguishes the two models.
    static func from(bluetoothName: String?) -> TandemPumpModel? {
        guard let name = bluetoothName?.lowercased(), !name.isEmpty else { return nil }
        // Check Mobi first: "Tandem Mobi" would not match the t:slim prefixes,
        // but ordering keeps the intent obvious if names ever overlap.
        for model in [TandemPumpModel.mobi, .tslimX2] {
            if model.bluetoothNamePrefixes.contains(where: { name.hasPrefix($0) || name.contains($0) }) {
                return model
            }
        }
        return nil
    }

    /// Secondary identification from the pump's reported API version, for the
    /// case where the Bluetooth name is unavailable (a restored peripheral, for
    /// example). The Mobi's API versions start at 3.5; the t:slim X2 tops out at
    /// 3.4.
    static func from(apiVersionMajor major: Int, minor: Int) -> TandemPumpModel? {
        guard major > 0 else { return nil }
        if major > 3 { return nil }
        if major == 3, minor >= 5 { return .mobi }
        return .tslimX2
    }
}

/// Which pairing handshake a pump uses.
///
/// This is not implied by the model: every Mobi uses JPAKE, but a t:slim X2 uses
/// the legacy challenge/response on software 7.1-7.6 and JPAKE on 7.7+. The
/// length of the code the user is shown is what actually distinguishes them.
enum TandemPairingCodeType: String {
    /// 16-character alphanumeric code, shown on the pump screen. The code itself
    /// is the message-signing key.
    case legacy16
    /// 6-digit numeric code. Establishes a shared secret by EC-JPAKE; the
    /// signing key is derived per connection.
    case jpake6

    static func from(pairingCode: String) -> TandemPairingCodeType? {
        let normalized = TandemPumpSession.normalizePairingCode(pairingCode)
        switch normalized.count {
        case 6 where normalized.allSatisfy({ $0.isNumber && $0.isASCII }): return .jpake6
        case 16: return .legacy16
        default: return nil
        }
    }
}

/// Constraints the Mobi's `SetTempRate` command imposes, per pumpX2's
/// `SetTempRateRequest` validation.
enum TandemTempRateLimits {
    static let minDuration: TimeInterval = .minutes(15)
    static let maxDuration: TimeInterval = .hours(72)
    /// Temp rates are expressed as a whole percentage of the pump's own profile
    /// basal rate, not as an absolute rate.
    static let minPercent: Int = 0
    static let maxPercent: Int = 250
}
