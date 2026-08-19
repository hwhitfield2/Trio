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

@Suite("Tandem pump load status") struct TandemLoadStatusTests {
    @Test("Reads the pump's load state machine") func parsing() throws {
        // byte 0 = isLoadingActive, byte 1 = LoadState, byte 2 = prime detail.
        let idle = try TandemLoadStatusResponse(cargo: Data([0x00, 0x00, 0x00]))
        #expect(!idle.isLoadingActive)
        #expect(idle.loadState == .changeCartridge)

        let priming = try TandemLoadStatusResponse(cargo: Data([0x01, 0x02, 0x01]))
        #expect(priming.isLoadingActive)
        #expect(priming.loadState == .primeTubing)
        #expect(priming.primeTubingStatus == .start)

        // The detail byte only means prime-tubing status in that state.
        let cannula = try TandemLoadStatusResponse(cargo: Data([0x01, 0x03, 0x01]))
        #expect(cannula.loadState == .primeCannula)
        #expect(cannula.primeTubingStatus == nil)

        // An unrecognised state must not be mistaken for a known one, and the
        // byte the pump actually sent has to survive for the logs.
        let future = try TandemLoadStatusResponse(cargo: Data([0x01, 0x7F, 0x00]))
        #expect(future.loadState == .unknown)
        #expect(future.loadStateId == 0x7F)
        #expect(future.diagnosticDescription.contains("loadState=127"))

        #expect(throws: TandemMessageError.self) { try TandemLoadStatusResponse(cargo: Data([0x00, 0x00])) }
    }

    @Test("Load status is an unsigned current-status query") func messageShape() {
        // It has to be cheap and ungated so it can be polled before a command
        // and again after a refusal, to explain what the pump was doing.
        #expect(TandemLoadStatusRequest.opcode == 20)
        #expect(TandemLoadStatusResponse.opcode == 21)
        #expect(TandemLoadStatusRequest.characteristic == .currentStatus)
        #expect(!TandemLoadStatusRequest.signed)
        #expect(!TandemLoadStatusRequest.modifiesInsulinDelivery)
    }

    @Test("An idle pump is described as idle, not as broken") func idleDescription() throws {
        // isLoadingActive == false means no load is running, and byte 1 is then
        // whatever the state machine last held. A Mobi at rest reports INVALID
        // there, which is its resting value; calling that out as "an invalid
        // load state" sends the user hunting for a fault that does not exist.
        let idle = try TandemLoadStatusResponse(cargo: Data([0x00, 0x05, 0x00]))
        #expect(idle.loadState == .invalid)
        #expect(idle.localizedDescription.contains("not loading"))
        #expect(idle.localizedDescription.contains("invalid") == false)

        // While a load IS running, the state is the whole point of the message
        // — and in tubing fill, the detail byte says what the pump is waiting
        // for. "Waiting for its button" is the one that matters: a Mobi's fill
        // runs only while the pump's own button is held, and a user watching a
        // motionless pump needs the message to say whose move it is.
        let filling = try TandemLoadStatusResponse(cargo: Data([0x01, 0x02, 0x01]))
        #expect(filling.localizedDescription.contains("filling the tubing"))

        let waiting = try TandemLoadStatusResponse(cargo: Data([0x01, 0x02, 0x03]))
        #expect(waiting.localizedDescription.contains("button"))

        let paused = try TandemLoadStatusResponse(cargo: Data([0x01, 0x02, 0x04]))
        #expect(paused.localizedDescription.contains("paused"))
    }

    @Test("A refusal reports what the pump was doing") func diagnosticError() {
        let bare = TandemCartridgeError.rejected(step: "start the cartridge change", status: 1, detail: nil)
        #expect(bare.errorDescription?.contains("status 1") == true)

        let diagnosed = TandemCartridgeError.rejected(
            step: "start the cartridge change",
            status: 1,
            detail: "insulin is still running, the pump is not loading a cartridge"
        )
        #expect(diagnosed.errorDescription?.contains("insulin is still running") == true)

        // The preconditions the pump actually enforces each get their own
        // message rather than surfacing as an opaque status byte.
        #expect(TandemCartridgeError.deliveryMustBeStoppedOnPump.errorDescription?.contains("Stop insulin") == true)
        #expect(TandemCartridgeError.bolusInProgress.errorDescription?.contains("bolus") == true)
        // A suspend the pump accepted but did not act on is a different problem
        // from one it refused, and needs a different instruction.
        #expect(TandemCartridgeError.suspendDidNotTake.errorDescription?.contains("still delivering") == true)
    }
}

@Suite("Tandem pump alarms") struct TandemAlarmTests {
    @Test("Decodes the alarm bitmask with names") func alarmDecoding() throws {
        // Bit index = pumpX2 AlarmResponseType id, little-endian uint64.
        // Bit 8 (empty cartridge) + bit 25 (cartridge removed) + bit 18
        // (resume pump) = 0x0204_0100.
        var cargo = Data(count: 8)
        cargo[1] = 0x01 // bit 8
        cargo[2] = 0x04 // bit 18
        cargo[3] = 0x02 // bit 25
        let alarms = try TandemAlarmStatusResponse(cargo: cargo)
        #expect(alarms.activeBits == [8, 18, 25])
        #expect(alarms.localizedNames == "Empty Cartridge + Resume Pump + Cartridge Removed")

        let none = try TandemAlarmStatusResponse(cargo: Data(count: 8))
        #expect(none.isEmpty)
        #expect(none.localizedNames == nil)

        // An alarm we have no name for still surfaces its bit.
        let unknown = TandemAlarmStatusResponse(bitmask: 1 << 40)
        #expect(TandemAlarmStatusResponse.name(forBit: 40).contains("40"))
        #expect(unknown.localizedNames?.contains("40") == true)

        #expect(throws: TandemMessageError.self) { try TandemAlarmStatusResponse(cargo: Data(count: 7)) }
    }

    @Test("Only cartridge-family alarms are offered for acknowledgment") func dismissScope() {
        // The change screen may clear the alarms the change itself fixes...
        let cartridge = TandemAlarmStatusResponse(bitmask: (1 << 8) | (1 << 25) | (1 << 2))
        #expect(cartridge.cartridgeRelatedBits == [2, 8, 25])

        // ...but never a hardware alarm: a temperature or battery fault is
        // not remedied by a cartridge, so Trio must not silence it.
        let hardware = TandemAlarmStatusResponse(bitmask: (1 << 10) | (1 << 12) | (1 << 22))
        #expect(hardware.cartridgeRelatedBits.isEmpty)

        // Mixed: only the cartridge subset is eligible.
        let mixed = TandemAlarmStatusResponse(bitmask: (1 << 8) | (1 << 10))
        #expect(mixed.cartridgeRelatedBits == [8])

        // Pump reset is acknowledgeable: a reset pump demands acknowledgment
        // and a fresh cartridge load before delivering again, which is this
        // screen. Seen live on a Mobi that reset mid-evening.
        let reset = TandemAlarmStatusResponse(bitmask: 1 << 3)
        #expect(reset.cartridgeRelatedBits == [3])
        #expect(TandemAlarmStatusResponse.name(forBit: 3) == "Pump Reset")
    }

    @Test("Alarm status is an unsigned current-status query") func alarmShape() {
        // It must be readable before anything else works — that is the point.
        #expect(TandemAlarmStatusRequest.opcode == 70)
        #expect(TandemAlarmStatusResponse.opcode == 71)
        #expect(TandemAlarmStatusRequest.characteristic == .currentStatus)
        #expect(!TandemAlarmStatusRequest.signed)
        #expect(!TandemAlarmStatusRequest.modifiesInsulinDelivery)
        #expect(TandemAlertStatusRequest.opcode == 68)
        #expect(TandemAlertStatusResponse.opcode == 69)
    }

    @Test("Alerts name the load-related conditions") func alertDecoding() throws {
        var cargo = Data(count: 8)
        cargo[1] = 0x60 // bits 13 + 14
        let alerts = try TandemAlertStatusResponse(cargo: cargo)
        #expect(alerts.activeBits == [13, 14])
        #expect(alerts.localizedLoadRelatedNames == "Incomplete Cartridge Change + Incomplete Fill Tubing")

        // Alerts outside the load flow stay out of the cartridge screen.
        var other = Data(count: 8)
        other[0] = 0x02 // bit 1, USB connection
        #expect(try TandemAlertStatusResponse(cargo: other).localizedLoadRelatedNames == nil)
    }

    @Test("Dismissal is signed, explicit, and acknowledge-only") func dismissEncoding() {
        let dismiss = TandemDismissNotificationRequest(notificationId: 8, notificationType: .alarm)
        // uint32 LE id, type byte (alarm = 2), extra-action byte.
        #expect(dismiss.cargo == Data([0x08, 0x00, 0x00, 0x00, 0x02, 0x00]))
        #expect(TandemDismissNotificationRequest.opcode == 0xB8)
        // 0xB9 = -71, observed from the pump on hardware. Not 0xB7 — a
        // sign-conversion slip that made a working dismissal report failure.
        #expect(TandemDismissNotificationResponse.opcode == 0xB9)
        #expect(TandemDismissNotificationRequest.characteristic == .control)
        #expect(TandemDismissNotificationRequest.signed)
        // Acknowledging a notification does not move insulin, so it must not
        // be blocked when remote delivery actions are disabled.
        #expect(!TandemDismissNotificationRequest.modifiesInsulinDelivery)
        // The follow-up-action flag stays off: what it triggers per alarm is
        // unknown, and acknowledge-only is the reviewed behaviour.
        #expect(dismiss.executeExtraAction == false)
    }

    @Test("An uncleared alarm is reported, not papered over") func alarmErrorText() {
        let error = TandemCartridgeError.alarmNotCleared("Empty Cartridge")
        #expect(error.errorDescription?.contains("Empty Cartridge") == true)
        #expect(TandemCartridgeError.noAlarmToAcknowledge.errorDescription?.isEmpty == false)
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
    @Test("The stage order matches the pump's own sequence") func stageSequence() {
        // Field-observed on a Mobi: exit-change-mode is the mid-flow "check
        // the new cartridge" step (the pump streams detection the moment it
        // is sent), the tubing fill happens with the pump's own button, and
        // by the finish the pump left change mode long ago — so the finish
        // resumes insulin rather than exiting anything.
        let state = TandemPumpState()
        state.cartridgeSession = TandemCartridgeSession(stage: .cartridgeLoaded, startedAt: Date.now)
        #expect(state.cartridgeChangeInProgress)

        // The new stage survives persistence, so an app restart mid-change
        // resumes from the right step instead of re-running the swap.
        let restored = TandemPumpState(rawValue: state.rawValue)
        #expect(restored.cartridgeSession?.stage == .cartridgeLoaded)
    }

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
