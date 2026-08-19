import Foundation
import LoopKit
import Testing

@testable import Trio

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Build a reassembled frame the way the accumulator would hand one to the
/// stream decoder: opcode, txId and cargo, with the signed trailer already
/// stripped by `unsignedCargo`.
private func streamFrame(opcode: UInt8, cargo: [UInt8]) -> TandemMessageFrame {
    // The decoder reads `unsignedCargo`, which drops the last 24 bytes, so the
    // trailer has to be present for the frame to be realistic.
    let trailer = Data(repeating: 0, count: TandemPacketize.signedTrailerLength)
    return TandemMessageFrame(opcode: opcode, txId: 7, cargo: Data(cargo) + trailer)
}

@Suite("Tandem cartridge messages") struct TandemCartridgeMessageTests {
    @Test("Cartridge opcodes match the reverse-engineered protocol") func opcodes() {
        #expect(TandemEnterChangeCartridgeModeRequest.opcode == 0x90)
        #expect(TandemEnterChangeCartridgeModeResponse.opcode == 0x91)
        #expect(TandemExitChangeCartridgeModeRequest.opcode == 0x92)
        #expect(TandemExitChangeCartridgeModeResponse.opcode == 0x93)
        #expect(TandemEnterFillTubingModeRequest.opcode == 0x94)
        #expect(TandemEnterFillTubingModeResponse.opcode == 0x95)
        #expect(TandemExitFillTubingModeRequest.opcode == 0x96)
        #expect(TandemExitFillTubingModeResponse.opcode == 0x97)
        #expect(TandemFillCannulaRequest.opcode == 0x98)
        #expect(TandemFillCannulaResponse.opcode == 0x99)
        #expect(TandemPrimeTubingSuspendRequest.opcode == 0xEE)
        #expect(TandemPrimeTubingSuspendResponse.opcode == 0xEF)
    }

    @Test("Insulin-moving steps are gated, the others are not") func deliveryFlags() {
        // Entering change mode stops delivery; entering fill-tubing and priming
        // push insulin. Leaving either mode does not, so those are not gated.
        #expect(TandemEnterChangeCartridgeModeRequest.modifiesInsulinDelivery)
        #expect(TandemEnterFillTubingModeRequest.modifiesInsulinDelivery)
        #expect(TandemFillCannulaRequest.modifiesInsulinDelivery)
        #expect(!TandemExitChangeCartridgeModeRequest.modifiesInsulinDelivery)
        #expect(!TandemExitFillTubingModeRequest.modifiesInsulinDelivery)

        // Every cartridge command is signed and rides the control characteristic.
        #expect(TandemEnterChangeCartridgeModeRequest.signed)
        #expect(TandemFillCannulaRequest.signed)
        #expect(TandemPrimeTubingSuspendRequest.signed)
        #expect(TandemEnterChangeCartridgeModeRequest.characteristic == .control)
        #expect(TandemFillCannulaRequest.characteristic == .control)
    }

    @Test("Encodes the cannula prime volume in milliunits") func fillCannulaCargo() {
        // 0.3 U -> 300 milliunits, little-endian.
        #expect(TandemFillCannulaRequest(primeSizeMilliunits: 300).cargo.hex == "2c01")
        #expect(TandemFillCannulaRequest(primeSizeMilliunits: 3000).cargo.hex == "b80b")
        #expect(TandemFillCannulaRequest(primeSizeMilliunits: 1).cargo.hex == "0100")
    }

    @Test("Converts prime units and rejects what the pump will not take") func primeConversion() {
        #expect(TandemPumpManager.primeMilliunits(forUnits: 0.3) == 300)
        #expect(TandemPumpManager.primeMilliunits(forUnits: 3.0) == 3000)
        #expect(TandemPumpManager.primeMilliunits(forUnits: 0.001) == 1)
        // Above the pump's 3 U ceiling, or not a positive amount.
        #expect(TandemPumpManager.primeMilliunits(forUnits: 3.001) == nil)
        #expect(TandemPumpManager.primeMilliunits(forUnits: 0) == nil)
        #expect(TandemPumpManager.primeMilliunits(forUnits: -1) == nil)
        #expect(TandemPumpManager.primeMilliunits(forUnits: .nan) == nil)
        #expect(TandemPumpManager.primeMilliunits(forUnits: .infinity) == nil)
    }

    @Test("Parses the status replies") func responses() throws {
        #expect(try TandemEnterChangeCartridgeModeResponse(cargo: Data([0x00])).status == 0)
        #expect(try TandemExitChangeCartridgeModeResponse(cargo: Data([0x01])).status == 1)
        #expect(try TandemEnterFillTubingModeResponse(cargo: Data([0x00])).status == 0)
        #expect(try TandemExitFillTubingModeResponse(cargo: Data([0x00])).status == 0)
        #expect(try TandemFillCannulaResponse(cargo: Data([0x00])).status == 0)

        // Prime-tubing-suspend has a padding byte between status and reserve.
        let suspend = try TandemPrimeTubingSuspendResponse(cargo: Data([0x00, 0x00, 0x2A]))
        #expect(suspend.status == 0)
        #expect(suspend.reserve == 42)

        #expect(throws: TandemMessageError.self) { try TandemFillCannulaResponse(cargo: Data()) }
        #expect(throws: TandemMessageError.self) { try TandemPrimeTubingSuspendResponse(cargo: Data([0x00])) }
    }
}

@Suite("Tandem cartridge progress stream") struct TandemCartridgeStreamTests {
    @Test("Decodes each progress opcode") func decoding() {
        #expect(
            TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE1, cargo: [2]))
                == .changeCartridgeMode(stateId: 2)
        )
        #expect(
            TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE5, cargo: [1]))
                == .fillTubing(buttonDown: true)
        )
        #expect(
            TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE5, cargo: [0]))
                == .fillTubing(buttonDown: false)
        )
        #expect(
            TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE7, cargo: [2]))
                == .fillCannula(stateId: 2)
        )
        #expect(
            TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE9, cargo: [3]))
                == .fillTubingModeExited(stateId: 3)
        )
    }

    @Test("Tells the two 0xE3 messages apart by cargo length") func overloadedOpcode() {
        // One byte is a load-cartridge state; two bytes are a detection
        // percentage. Getting this backwards would report a 2% detection as
        // state 2, so it is worth pinning down.
        #expect(
            TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE3, cargo: [4]))
                == .loadCartridge(stateId: 4)
        )
        #expect(
            TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE3, cargo: [0x64, 0x00]))
                == .detectingCartridge(percentComplete: 100)
        )
    }

    @Test("Ignores opcodes the driver does not model") func unknownOpcode() {
        #expect(TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE0, cargo: [1])) == nil)
        // An empty cargo carries nothing to act on.
        #expect(TandemCartridgeStreamEvent(frame: streamFrame(opcode: 0xE1, cargo: [])) == nil)
    }

    @Test("The control stream is its own characteristic") func characteristic() {
        // Stream traffic must not be mistaken for a reply on the control
        // characteristic, or it would satisfy a pending request.
        #expect(TandemCharacteristic.controlStream != TandemCharacteristic.control)
    }
}

@Suite("Tandem cartridge session state") struct TandemCartridgeSessionTests {
    @Test("A change in progress reads as suspended delivery") func suspendsDelivery() {
        let state = TandemPumpState()
        state.pumpModel = .mobi
        state.cartridgeSession = TandemCartridgeSession(stage: .changeMode, startedAt: Date.now)
        guard case .suspended = state.basalDeliveryState else {
            Issue.record("Expected delivery to read as suspended during a cartridge change")
            return
        }
        #expect(state.cartridgeChangeInProgress)
    }

    @Test("A stale change stops being trusted") func staleSession() {
        let state = TandemPumpState()
        // Older than the two-hour cap: Trio no longer knows the pump's state, so
        // it must not keep reporting a change (and blocking dosing) forever.
        state.cartridgeSession = TandemCartridgeSession(
            stage: .changeMode,
            startedAt: Date.now.addingTimeInterval(-.hours(3))
        )
        #expect(!state.cartridgeChangeInProgress)
        #expect(state.cartridgeSession?.isStale() == true)
    }

    @Test("The disconnect confirmation expires and is never persisted") func confirmationHandling() {
        let state = TandemPumpState()
        state.cartridgeChangeEnabled = true
        state.cartridgeSession = TandemCartridgeSession(stage: .changeMode, startedAt: Date.now)
        state.confirmedSetPlacement = .disconnected
        state.cartridgeDisconnectConfirmedAt = Date.now
        #expect(state.hasFreshDisconnectConfirmation())

        // Old confirmations do not authorise a fill.
        state.cartridgeDisconnectConfirmedAt = Date.now.addingTimeInterval(-.minutes(30))
        #expect(!state.hasFreshDisconnectConfirmation())

        // A restart must force the user to answer again, so neither the
        // placement nor its timestamp survives the raw-state round trip.
        state.cartridgeDisconnectConfirmedAt = Date.now
        let restored = TandemPumpState(rawValue: state.rawValue)
        #expect(restored.cartridgeChangeEnabled)
        #expect(restored.cartridgeSession?.stage == .changeMode)
        #expect(restored.confirmedSetPlacement == nil)
        #expect(!restored.hasFreshDisconnectConfirmation())
    }

    @Test("Enabling cartridge changes opens the session gate but not dosing") func deliveryGate() {
        let state = TandemPumpState()
        #expect(!state.insulinDeliveryActionsAllowed)
        state.cartridgeChangeEnabled = true
        // The outermost gate opens, because fill and prime are
        // modifiesInsulinDelivery commands...
        #expect(state.insulinDeliveryActionsAllowed)
        // ...but the per-feature opt-ins that actually permit dosing stay off.
        #expect(!state.remoteBolusEnabled)
        #expect(!state.remoteBasalEnabled)
    }

    @Test("Only the Mobi can prime the cannula remotely") func cannulaFillSupport() {
        #expect(TandemPumpModel.mobi.supportsRemoteCannulaFill)
        #expect(!TandemPumpModel.tslimX2.supportsRemoteCannulaFill)
    }
}
