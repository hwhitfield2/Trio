import Foundation

/// Cartridge-change messages: entering and leaving change mode, filling the
/// tubing, priming the cannula, and the progress events the pump streams while
/// any of that is happening.
///
/// Every request here is signed, and the ones that push insulin are marked
/// `modifiesInsulinDelivery` so the session's opt-in gate covers them.
///
/// Device support, per pumpX2's `@MessageProps`:
/// - change-cartridge mode, fill-tubing mode and prime-tubing-suspend: both models;
/// - fill cannula: **Mobi only** (API >= 3.5). On the t:slim X2 the cannula
///   prime is a pump-screen operation with no remote equivalent.
///
/// A caution that applies to this whole file: pumpX2 defines and unit-tests
/// these encodings, but nothing in its Android library or sample app ever sends
/// them, so unlike the bolus and temp-rate flows there is no reference
/// implementation whose ordering has been exercised against a pump. The
/// sequencing in TandemCartridgeChange.swift is reconstructed, not transcribed.

// MARK: - Load status

/// Read-only view of the pump's cartridge-loading state machine.
///
/// Unsigned and on the current-status characteristic, so it can be polled
/// freely — including before a cartridge command, to find out whether the pump
/// is in a state that will accept one, and after a refusal, to say what it was
/// actually doing instead of reporting a bare status byte.
struct TandemLoadStatusRequest: TandemRequest {
    typealias Response = TandemLoadStatusResponse
    static let opcode: UInt8 = 20
}

struct TandemLoadStatusResponse: TandemResponse {
    static let opcode: UInt8 = 21

    /// Where the pump is in the load sequence.
    enum LoadState: UInt8 {
        case changeCartridge = 0
        case loadCartridge = 1
        case primeTubing = 2
        case primeCannula = 3
        case primeNudge = 4
        case invalid = 5
        case unknown = 6

        var localizedDescription: String {
            switch self {
            case .changeCartridge: return String(localized: "changing the cartridge")
            case .loadCartridge: return String(localized: "loading the cartridge")
            case .primeTubing: return String(localized: "priming the tubing")
            case .primeCannula: return String(localized: "priming the cannula")
            case .primeNudge: return String(localized: "finishing the prime")
            case .invalid: return String(localized: "in an invalid load state")
            case .unknown: return String(localized: "in an unknown load state")
            }
        }
    }

    /// Detail byte, whose meaning depends on `loadState`.
    enum PrimeTubingStatus: UInt8 {
        case stop = 0
        case start = 1
        case enteredCanExit = 2
        case enteredCannotExit = 3
        case suspended = 4
        case unknown = 5
    }

    /// True while a load sequence is running on the pump.
    let isLoadingActive: Bool
    let loadState: LoadState
    /// The raw state byte, kept separately because anything the enum does not
    /// recognise collapses to `.unknown` and the original value is the part
    /// worth reporting when a command is refused for no stated reason.
    let loadStateId: UInt8
    let primeStatusId: UInt8

    /// Prime-tubing detail, when that is the current state.
    var primeTubingStatus: PrimeTubingStatus? {
        guard loadState == .primeTubing else { return nil }
        return PrimeTubingStatus(rawValue: primeStatusId) ?? .unknown
    }

    init(cargo: Data) throws {
        guard cargo.count >= 3 else {
            throw TandemMessageError.unexpectedCargoSize(message: "LoadStatusResponse", expected: 3, actual: cargo.count)
        }
        let bytes = [UInt8](cargo)
        isLoadingActive = bytes[0] != 0
        loadStateId = bytes[1]
        loadState = LoadState(rawValue: bytes[1]) ?? .unknown
        primeStatusId = bytes[2]
    }

    /// One-line summary for error messages and the cartridge screen.
    ///
    /// When `isLoadingActive` is false the pump is simply not in a load, and
    /// `loadState` is then whatever the state machine last held — commonly
    /// `invalid`, which is its resting value, not a fault. Saying so would send
    /// the user looking for a problem that is not there, so idle reads as idle.
    var localizedDescription: String {
        guard isLoadingActive else {
            return String(localized: "the pump is not loading a cartridge")
        }
        return String(localized: "the pump is \(loadState.localizedDescription)")
    }

    /// Raw ids, for logs. The pump explains a refusal with a single status byte
    /// and nothing else, so the exact values it reports either side of one are
    /// the only evidence there is.
    var diagnosticDescription: String {
        "loadActive=\(isLoadingActive) loadState=\(loadStateId) prime=\(primeStatusId)"
    }
}

// MARK: - Change cartridge mode

/// Put the pump into cartridge-change mode. Delivery stops for the duration.
struct TandemEnterChangeCartridgeModeRequest: TandemRequest {
    typealias Response = TandemEnterChangeCartridgeModeResponse
    static let opcode: UInt8 = 0x90
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true
}

struct TandemEnterChangeCartridgeModeResponse: TandemResponse {
    static let opcode: UInt8 = 0x91
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "EnterChangeCartridgeModeResponse",
                expected: 1,
                actual: 0
            )
        }
        status = first
    }
}

/// Leave cartridge-change mode. Does not itself start delivery — the pump
/// returns to its normal state, and Trio resumes on the next loop cycle.
struct TandemExitChangeCartridgeModeRequest: TandemRequest {
    typealias Response = TandemExitChangeCartridgeModeResponse
    static let opcode: UInt8 = 0x92
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
}

struct TandemExitChangeCartridgeModeResponse: TandemResponse {
    static let opcode: UInt8 = 0x93
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "ExitChangeCartridgeModeResponse",
                expected: 1,
                actual: 0
            )
        }
        status = first
    }
}

// MARK: - Fill tubing

/// Enter fill-tubing mode. **Pushes insulin through the tubing**, so the
/// infusion set must be disconnected from the body first.
struct TandemEnterFillTubingModeRequest: TandemRequest {
    typealias Response = TandemEnterFillTubingModeResponse
    static let opcode: UInt8 = 0x94
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true
}

struct TandemEnterFillTubingModeResponse: TandemResponse {
    static let opcode: UInt8 = 0x95
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(message: "EnterFillTubingModeResponse", expected: 1, actual: 0)
        }
        status = first
    }
}

struct TandemExitFillTubingModeRequest: TandemRequest {
    typealias Response = TandemExitFillTubingModeResponse
    static let opcode: UInt8 = 0x96
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
}

struct TandemExitFillTubingModeResponse: TandemResponse {
    static let opcode: UInt8 = 0x97
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(message: "ExitFillTubingModeResponse", expected: 1, actual: 0)
        }
        status = first
    }
}

// MARK: - Fill cannula (Mobi only)

/// Prime the cannula with `primeSizeMilliunits`. **Pushes insulin into the
/// infusion site**, so this is only ever sent after the set has been inserted
/// and the user has confirmed the prime amount.
struct TandemFillCannulaRequest: TandemRequest {
    typealias Response = TandemFillCannulaResponse
    static let opcode: UInt8 = 0x98
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
    static let modifiesInsulinDelivery = true

    /// pumpX2 validates a positive amount no greater than 3 U.
    static let minPrimeMilliunits: UInt16 = 1
    static let maxPrimeMilliunits: UInt16 = 3000

    let primeSizeMilliunits: UInt16

    var cargo: Data {
        var data = Data()
        data.appendTandemUInt16(primeSizeMilliunits)
        return data
    }
}

struct TandemFillCannulaResponse: TandemResponse {
    static let opcode: UInt8 = 0x99
    static let signed = true
    let status: UInt8

    init(cargo: Data) throws {
        guard let first = cargo.first else {
            throw TandemMessageError.unexpectedCargoSize(message: "FillCannulaResponse", expected: 1, actual: 0)
        }
        status = first
    }
}

// MARK: - Prime tubing suspend

/// Stop an in-progress tubing prime.
struct TandemPrimeTubingSuspendRequest: TandemRequest {
    typealias Response = TandemPrimeTubingSuspendResponse
    static let opcode: UInt8 = 0xEE
    static let characteristic: TandemCharacteristic = .control
    static let signed = true
}

struct TandemPrimeTubingSuspendResponse: TandemResponse {
    static let opcode: UInt8 = 0xEF
    static let signed = true
    let status: UInt8
    let reserve: UInt8

    init(cargo: Data) throws {
        guard cargo.count >= 3 else {
            throw TandemMessageError.unexpectedCargoSize(
                message: "PrimeTubingSuspendResponse",
                expected: 3,
                actual: cargo.count
            )
        }
        let bytes = [UInt8](cargo)
        status = bytes[0]
        // bytes[1] is padding
        reserve = bytes[2]
    }
}

// MARK: - Control-stream progress events

/// Progress the pump pushes, unsolicited, on the control-stream characteristic
/// while a cartridge change is running.
///
/// Two opcodes are overloaded and are told apart by cargo length, exactly as
/// pumpX2 does it: 0xE3 carries a load-cartridge state in one byte or a
/// detection percentage in two, and 0xE9 carries either an exit-fill-tubing
/// state or the equivalent prime-nudge state — the same wire message, so they
/// collapse to one case here.
enum TandemCartridgeStreamEvent: Equatable {
    /// State id from the pump; 2 means "ready to change" per pumpX2.
    case changeCartridgeMode(stateId: UInt8)
    case detectingCartridge(percentComplete: Int)
    case loadCartridge(stateId: UInt8)
    /// The pump's fill-tubing button is held down (t:slim X2 fills while held).
    case fillTubing(buttonDown: Bool)
    /// State id from the pump; 2 means "cannula filled" per pumpX2.
    case fillCannula(stateId: UInt8)
    case fillTubingModeExited(stateId: UInt8)

    /// Opcodes carried on the control-stream characteristic.
    static let changeCartridgeModeOpcode: UInt8 = 0xE1
    static let detectingCartridgeOpcode: UInt8 = 0xE3
    static let fillTubingOpcode: UInt8 = 0xE5
    static let fillCannulaOpcode: UInt8 = 0xE7
    static let exitFillTubingOpcode: UInt8 = 0xE9

    /// Decode a reassembled control-stream frame. Returns nil for an opcode
    /// this driver does not model, which is logged and ignored rather than
    /// treated as an error — the pump may stream more than we recognise.
    init?(frame: TandemMessageFrame) {
        let cargo = frame.unsignedCargo
        switch frame.opcode {
        case Self.changeCartridgeModeOpcode:
            guard let first = cargo.first else { return nil }
            self = .changeCartridgeMode(stateId: first)
        case Self.detectingCartridgeOpcode:
            if cargo.count >= 2 {
                self = .detectingCartridge(percentComplete: Int(cargo.tandemUInt16(at: 0)))
            } else if let first = cargo.first {
                self = .loadCartridge(stateId: first)
            } else {
                return nil
            }
        case Self.fillTubingOpcode:
            guard let first = cargo.first else { return nil }
            self = .fillTubing(buttonDown: first == 1)
        case Self.fillCannulaOpcode:
            guard let first = cargo.first else { return nil }
            self = .fillCannula(stateId: first)
        case Self.exitFillTubingOpcode:
            guard let first = cargo.first else { return nil }
            self = .fillTubingModeExited(stateId: first)
        default:
            return nil
        }
    }

    /// State id the pump reports when a cartridge change may proceed.
    static let readyToChangeStateId: UInt8 = 2
    /// State id the pump reports once the cannula prime has finished.
    static let cannulaFilledStateId: UInt8 = 2

    /// Short human-readable description for the cartridge-change screen.
    var localizedDescription: String {
        switch self {
        case let .changeCartridgeMode(stateId):
            return stateId == Self.readyToChangeStateId
                ? String(localized: "Ready to change the cartridge")
                : String(localized: "Preparing to change the cartridge (state \(stateId))")
        case let .detectingCartridge(percent):
            return String(localized: "Detecting the cartridge — \(percent)%")
        case let .loadCartridge(stateId):
            return String(localized: "Loading the cartridge (state \(stateId))")
        case let .fillTubing(buttonDown):
            return buttonDown
                ? String(localized: "Filling the tubing…")
                : String(localized: "Tubing fill paused")
        case let .fillCannula(stateId):
            return stateId == Self.cannulaFilledStateId
                ? String(localized: "Cannula filled")
                : String(localized: "Filling the cannula (state \(stateId))")
        case let .fillTubingModeExited(stateId):
            return String(localized: "Finished filling the tubing (state \(stateId))")
        }
    }
}
