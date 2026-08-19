import Foundation
import LoopKit
import Testing

@testable import Trio

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("Tandem pump model") struct TandemPumpModelTests {
    @Test("Identifies the model from the advertised Bluetooth name") func nameDetection() {
        #expect(TandemPumpModel.from(bluetoothName: "Tandem Mobi 123456") == .mobi)
        #expect(TandemPumpModel.from(bluetoothName: "tandem mobi") == .mobi)
        #expect(TandemPumpModel.from(bluetoothName: "tslim X2 987654") == .tslimX2)
        #expect(TandemPumpModel.from(bluetoothName: "t:slim X2") == .tslimX2)
        #expect(TandemPumpModel.from(bluetoothName: "Dexcom G7") == nil)
        #expect(TandemPumpModel.from(bluetoothName: nil) == nil)
        #expect(TandemPumpModel.from(bluetoothName: "") == nil)
    }

    @Test("Falls back to the API version when there is no name") func apiVersionDetection() {
        // Mobi software reports 3.5 and up; the t:slim X2 stops at 3.4.
        #expect(TandemPumpModel.from(apiVersionMajor: 3, minor: 5) == .mobi)
        #expect(TandemPumpModel.from(apiVersionMajor: 3, minor: 8) == .mobi)
        #expect(TandemPumpModel.from(apiVersionMajor: 3, minor: 4) == .tslimX2)
        #expect(TandemPumpModel.from(apiVersionMajor: 2, minor: 5) == .tslimX2)
        // Nothing known yet: do not guess.
        #expect(TandemPumpModel.from(apiVersionMajor: 0, minor: 0) == nil)
    }

    @Test("Only the Mobi advertises remote basal control") func capabilities() {
        #expect(TandemPumpModel.mobi.supportsRemoteBasalControl)
        #expect(!TandemPumpModel.tslimX2.supportsRemoteBasalControl)
        #expect(TandemPumpModel.mobi.reservoirCapacity == 200)
        #expect(TandemPumpModel.tslimX2.reservoirCapacity == 300)
        // The conservative default must be the model without basal control, so
        // an unidentified pump never receives a command it cannot honor.
        #expect(!TandemPumpModel.default.supportsRemoteBasalControl)
    }

    @Test("Classifies pairing codes by shape") func pairingCodeType() {
        #expect(TandemPairingCodeType.from(pairingCode: "123456") == .jpake6)
        #expect(TandemPairingCodeType.from(pairingCode: "123-456") == .jpake6)
        #expect(TandemPairingCodeType.from(pairingCode: "ABCD1234EFGH5678") == .legacy16)
        #expect(TandemPairingCodeType.from(pairingCode: "ABCD-1234-EFGH-5678") == .legacy16)
        #expect(TandemPairingCodeType.from(pairingCode: "12345") == nil)
        // Six characters that are not all digits are not a JPAKE code.
        #expect(TandemPairingCodeType.from(pairingCode: "12345A") == nil)
    }
}

@Suite("Tandem temp basal conversion") struct TandemTempBasalConversionTests {
    @Test("Converts an absolute rate to a percentage of the profile rate") func percentConversion() {
        // Tandem temp rates are a percentage of the pump's own profile rate, so
        // every conversion depends on that rate.
        #expect(TandemPumpManager.tempRatePercent(forRate: 1.0, profileRate: 1.0) == 100)
        #expect(TandemPumpManager.tempRatePercent(forRate: 0.5, profileRate: 1.0) == 50)
        #expect(TandemPumpManager.tempRatePercent(forRate: 0.0, profileRate: 1.0) == 0)
        #expect(TandemPumpManager.tempRatePercent(forRate: 1.5, profileRate: 0.75) == 200)
        // Rounds to the nearest whole percent.
        #expect(TandemPumpManager.tempRatePercent(forRate: 0.333, profileRate: 1.0) == 33)
        #expect(TandemPumpManager.tempRatePercent(forRate: 0.336, profileRate: 1.0) == 34)
    }

    @Test("Clamps to what the pump accepts") func percentClamping() {
        // The pump refuses anything above 250%, so a higher request is capped
        // rather than sent and rejected.
        #expect(TandemPumpManager.tempRatePercent(forRate: 10, profileRate: 1.0) == 250)
        // Negative rates are not expressible; treat them as a zero temp.
        #expect(TandemPumpManager.tempRatePercent(forRate: -1, profileRate: 1.0) == 0)
        // With no profile rate there is nothing to take a percentage of.
        #expect(TandemPumpManager.tempRatePercent(forRate: 1.0, profileRate: 0) == 0)
    }
}

@Suite("Tandem basal control mode") struct TandemBasalControlModeTests {
    private func state(model: TandemPumpModel) -> TandemPumpState {
        let state = TandemPumpState()
        state.pumpModel = model
        state.apiVersionMajor = model == .mobi ? 3 : 2
        state.apiVersionMinor = 5
        return state
    }

    @Test("Nothing drives basal until a mode is chosen") func defaultsToNone() {
        #expect(state(model: .mobi).basalControlMode == .none)
        #expect(state(model: .tslimX2).basalControlMode == .none)
    }

    @Test("Microbolus-basal is available on the Mobi too") func microbolusOnMobi() {
        // The whole point of this mode is that it only needs the ability to
        // bolus, which both models have — so selecting it on a Mobi must route
        // to the microbolus engine rather than falling back to temp rates.
        let mobi = state(model: .mobi)
        mobi.microbolusBasalEnabled = true
        #expect(mobi.basalControlMode == .microbolus)

        let tslim = state(model: .tslimX2)
        tslim.microbolusBasalEnabled = true
        #expect(tslim.basalControlMode == .microbolus)
    }

    @Test("Native temp rates stay Mobi-only") func nativeIsMobiOnly() {
        let mobi = state(model: .mobi)
        mobi.remoteBasalEnabled = true
        #expect(mobi.basalControlMode == .nativeTempRate)

        // A t:slim X2 cannot honour temp rates even if the flag is somehow set,
        // so the mode must not resolve to one.
        let tslim = state(model: .tslimX2)
        tslim.remoteBasalEnabled = true
        #expect(tslim.basalControlMode == .none)
    }

    @Test("Microbolus wins if both flags are set") func modesNeverOverlap() {
        // Both live at once would mean a pump-side temp rate delivering
        // underneath a microbolus stream: a double dose. Resolving to the
        // self-delivering mode is the safe direction.
        let mobi = state(model: .mobi)
        mobi.remoteBasalEnabled = true
        mobi.microbolusBasalEnabled = true
        #expect(mobi.basalControlMode == .microbolus)
    }

    @Test("Any mode permits automatic dosing; no mode does not") func automaticDosingGate() {
        let mobi = state(model: .mobi)
        #expect(mobi.basalControlMode == .none)
        mobi.microbolusBasalEnabled = true
        #expect(mobi.basalControlMode != .none)
        mobi.microbolusBasalEnabled = false
        mobi.remoteBasalEnabled = true
        #expect(mobi.basalControlMode != .none)
    }

    @Test("Mode survives the raw-state round trip") func persistence() {
        let mobi = state(model: .mobi)
        mobi.microbolusBasalEnabled = true
        let restored = TandemPumpState(rawValue: mobi.rawValue)
        #expect(restored.basalControlMode == .microbolus)
    }
}

@Suite("Tandem Mobi control messages") struct TandemMobiControlMessageTests {
    @Test("Encodes a temp rate as milliseconds and percent") func setTempRateCargo() {
        // 30 minutes at 150% of profile: duration is carried in milliseconds,
        // little-endian, followed by the percentage.
        let request = TandemSetTempRateRequest(minutes: 30, percent: 150)
        #expect(request.cargo.hex == "40771b009600")
        #expect(TandemSetTempRateRequest.opcode == 0xA4)
        #expect(TandemSetTempRateRequest.characteristic == .control)
        #expect(TandemSetTempRateRequest.signed)
        #expect(TandemSetTempRateRequest.modifiesInsulinDelivery)

        // The pump's documented minimum, 15 minutes at 0%.
        #expect(TandemSetTempRateRequest(minutes: 15, percent: 0).cargo.hex == "a0bb0d000000")
    }

    @Test("Parses temp rate and suspend/resume replies") func controlResponses() throws {
        let setResponse = try TandemSetTempRateResponse(cargo: Data([0x00, 0x2A, 0x00, 0x00]))
        #expect(setResponse.status == 0)
        #expect(setResponse.tempRateId == 42)

        let stopResponse = try TandemStopTempRateResponse(cargo: Data([0x00, 0x2A, 0x00]))
        #expect(stopResponse.tempRateId == 42)

        #expect(try TandemSuspendPumpingResponse(cargo: Data([0x00])).status == 0)
        #expect(try TandemResumePumpingResponse(cargo: Data([0x01])).status == 1)

        // Short cargo is rejected rather than silently misread.
        #expect(throws: TandemMessageError.self) { try TandemSetTempRateResponse(cargo: Data([0x00])) }
        #expect(throws: TandemMessageError.self) { try TandemSuspendPumpingResponse(cargo: Data()) }
    }

    @Test("Mobi basal opcodes match the reverse-engineered protocol") func opcodes() {
        #expect(TandemStopTempRateRequest.opcode == 0xA6)
        #expect(TandemStopTempRateResponse.opcode == 0xA7)
        #expect(TandemSuspendPumpingRequest.opcode == 0x9C)
        #expect(TandemSuspendPumpingResponse.opcode == 0x9D)
        #expect(TandemResumePumpingRequest.opcode == 0x9A)
        #expect(TandemResumePumpingResponse.opcode == 0x9B)
    }
}

@Suite("Tandem JPAKE messages") struct TandemJpakeMessageTests {
    @Test("Round 1 requests carry the app instance id and 165 bytes") func round1Cargo() {
        let half = Data(repeating: 0xAB, count: TandemJpakeSizes.roundHalfLength)
        let request = TandemJpake1aRequest(appInstanceId: 0, challenge: half)
        #expect(request.cargo.count == 167)
        #expect(request.cargo.prefix(2) == Data([0x00, 0x00]))
        #expect(Data(request.cargo.dropFirst(2)) == half)
        #expect(TandemJpake1aRequest.opcode == 32)
        #expect(TandemJpake1aRequest.characteristic == .authorization)
        // JPAKE traffic is never signed and never moves insulin.
        #expect(!TandemJpake1aRequest.signed)
        #expect(!TandemJpake1aRequest.modifiesInsulinDelivery)

        #expect(TandemJpake1bRequest(appInstanceId: 0, challenge: half).cargo.count == 167)
        #expect(TandemJpake2Request(appInstanceId: 0, challenge: half).cargo.count == 167)
    }

    @Test("Parses the round-1 and round-2 replies") func roundResponses() throws {
        let half = Data(repeating: 0xCD, count: TandemJpakeSizes.roundHalfLength)
        let response1a = try TandemJpake1aResponse(cargo: Data([0x00, 0x00]) + half)
        #expect(response1a.challengeHash == half)
        let response1b = try TandemJpake1bResponse(cargo: Data([0x00, 0x00]) + half)
        #expect(response1b.challengeHash == half)

        // Round 2 from the pump is three bytes longer: it prefixes a curve id.
        let full = Data(repeating: 0xEF, count: TandemJpakeSizes.serverRound2Length)
        let response2 = try TandemJpake2Response(cargo: Data([0x00, 0x00]) + full)
        #expect(response2.challengeHash.count == 168)

        #expect(throws: TandemMessageError.self) { try TandemJpake2Response(cargo: Data([0x00, 0x00]) + half) }
    }

    @Test("Encodes and parses the session key and confirmation exchange") func keyConfirmation() throws {
        let sessionRequest = TandemJpake3SessionKeyRequest(challengeParameter: 0)
        #expect(sessionRequest.cargo.hex == "0000")
        #expect(TandemJpake3SessionKeyRequest.opcode == 38)

        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let reserved = Data(repeating: 0, count: 8)
        let sessionResponse = try TandemJpake3SessionKeyResponse(cargo: Data([0x00, 0x00]) + nonce + reserved)
        #expect(sessionResponse.deviceKeyNonce == nonce)
        #expect(sessionResponse.reserved == reserved)

        let digest = Data(repeating: 0x5A, count: 32)
        let confirmRequest = TandemJpake4KeyConfirmationRequest(
            appInstanceId: 0,
            nonce: nonce,
            hashDigest: digest
        )
        #expect(confirmRequest.cargo.count == 50)
        // Layout: appInstanceId, our nonce, 8 reserved zero bytes, digest.
        #expect(Data(confirmRequest.cargo[2 ..< 10]) == nonce)
        #expect(Data(confirmRequest.cargo[10 ..< 18]) == reserved)
        #expect(Data(confirmRequest.cargo[18 ..< 50]) == digest)

        let confirmResponse = try TandemJpake4KeyConfirmationResponse(
            cargo: Data([0x00, 0x00]) + nonce + reserved + digest
        )
        #expect(confirmResponse.nonce == nonce)
        #expect(confirmResponse.hashDigest == digest)

        #expect(throws: TandemMessageError.self) { try TandemJpake4KeyConfirmationResponse(cargo: Data([0x00, 0x00])) }
    }
}

@Suite("Tandem pump state") struct TandemPumpStateTests {
    private func mobiState() -> TandemPumpState {
        let state = TandemPumpState()
        state.pumpModel = .mobi
        state.pairingCodeType = .jpake6
        state.pairingCode = "246810"
        state.jpakeDerivedSecret = Data(repeating: 0x7F, count: 32)
        state.remoteBasalEnabled = true
        state.insulinType = .novolog
        state.lastSync = Date(timeIntervalSince1970: 1_700_000_000)
        return state
    }

    @Test("Round-trips the Mobi fields through the raw state") func rawRoundTrip() {
        let state = mobiState()
        state.activeTempBasal = TandemActiveTempBasal(
            tempRateId: 7,
            unitsPerHour: 1.25,
            percent: 125,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            duration: .minutes(30)
        )

        let restored = TandemPumpState(rawValue: state.rawValue)
        #expect(restored.pumpModel == .mobi)
        #expect(restored.pairingCodeType == .jpake6)
        #expect(restored.pairingCode == "246810")
        #expect(restored.jpakeDerivedSecret == state.jpakeDerivedSecret)
        #expect(restored.remoteBasalEnabled)
        #expect(restored.activeTempBasal?.tempRateId == 7)
        #expect(restored.activeTempBasal?.percent == 125)
        #expect(restored.supportsNativeBasalControl)
    }

    @Test("Infers the pairing type for state saved before Mobi support") func legacyStateMigration() {
        // A t:slim X2 paired by an older build has no stored pairing-code type;
        // it must keep working rather than being treated as a JPAKE pump.
        let raw: PumpManager.RawStateValue = [
            "isOnboarded": true,
            "pairingCode": "ABCD1234EFGH5678"
        ]
        let restored = TandemPumpState(rawValue: raw)
        #expect(restored.pairingCodeType == .legacy16)
        #expect(restored.pumpModel == .tslimX2)
        #expect(!restored.supportsNativeBasalControl)
        #expect(!restored.remoteBasalEnabled)
    }

    @Test("Reports a running temp basal as the basal delivery state") func basalDeliveryState() {
        let state = mobiState()
        state.activeTempBasal = TandemActiveTempBasal(
            tempRateId: 1,
            unitsPerHour: 0.8,
            percent: 80,
            startDate: Date.now.addingTimeInterval(-.minutes(5)),
            duration: .minutes(30)
        )
        guard case let .tempBasal(dose) = state.basalDeliveryState else {
            Issue.record("Expected a temp basal delivery state")
            return
        }
        #expect(dose.unitsPerHour == 0.8)

        // An expired temp basal falls back to scheduled delivery.
        state.activeTempBasal = TandemActiveTempBasal(
            tempRateId: 1,
            unitsPerHour: 0.8,
            percent: 80,
            startDate: Date.now.addingTimeInterval(-.hours(2)),
            duration: .minutes(30)
        )
        guard case .active = state.basalDeliveryState else {
            Issue.record("Expected scheduled delivery after the temp basal expired")
            return
        }

        // A suspend wins over any temp basal.
        state.suspended = true
        guard case .suspended = state.basalDeliveryState else {
            Issue.record("Expected suspended delivery")
            return
        }
    }

    @Test("Gates insulin-affecting commands on an explicit opt-in") func deliveryGate() {
        let state = TandemPumpState()
        #expect(!state.insulinDeliveryActionsAllowed)
        state.remoteBasalEnabled = true
        #expect(state.insulinDeliveryActionsAllowed)
        state.remoteBasalEnabled = false
        state.remoteBolusEnabled = true
        #expect(state.insulinDeliveryActionsAllowed)
    }
}

@Suite("Tandem pump screen status") struct TandemPumpStatusSummaryTests {
    private func syncedMobi() -> TandemPumpState {
        let state = TandemPumpState()
        state.pumpModel = .mobi
        state.pairingCodeType = .jpake6
        state.pairingCode = "246810"
        state.lastSync = Date.now
        state.reservoir = 180
        state.reservoirIsEstimate = false
        state.batteryPercent = 90
        return state
    }

    @Test("The headline ranks worst-first, so an alarm is never hidden by its own consequences")
    func headlineRanking() {
        let state = syncedMobi()
        // Nobody has asked Trio to drive basal, so the pump is simply being
        // watched — informational, never a warning on the home screen.
        #expect(state.headlineStatus.tone == .info)
        #expect(state.headlineStatus.title == "Monitoring")

        // A suspend alone is a caution.
        state.suspended = true
        #expect(state.headlineStatus.tone == .caution)

        // An alarm outranks it: the alarm is why insulin stopped, and reporting
        // the suspend instead is what used to send people looking in the wrong
        // place. Bit 8 is Empty Cartridge.
        state.activeAlarmBits = 1 << 8
        #expect(state.headlineStatus.tone == .critical)
        #expect(state.activeAlarmNames == "Empty Cartridge")

        // An unpaired pump outranks everything.
        state.pairingCode = ""
        #expect(state.headlineStatus.title == "Not Paired")
    }

    @Test("A pump that cannot loop is never reported as ready") func notLooping() {
        let state = syncedMobi()
        state.remoteBasalEnabled = true
        state.profileBasalRate = 1.0

        #expect(state.basalControlIsReady)
        #expect(state.headlineStatus.title == "Looping")
        #expect(state.headlineStatus.tone == .ok)

        // Control-IQ back on is the pump taking basal over again: Trio is not
        // looping, and the screen must not show a green tick over it.
        state.controlIQEnabled = true
        #expect(!state.basalControlIsReady)
        #expect(state.headlineStatus.title == "Not Looping")
        #expect(state.headlineStatus.tone == .caution)
    }

    @Test("A pump Trio has never read is not reported as an empty cartridge") func neverSynced() {
        let state = TandemPumpState()
        state.pumpModel = .mobi
        state.pairingCode = "246810"
        #expect(!state.hasEverSynced)
        #expect(state.reservoirFraction == nil)
        #expect(state.reservoirDescription == "—")
        #expect(state.headlineStatus.tone == .caution)

        // Once it has been read, zero units really is an emergency.
        state.lastSync = Date.now
        state.reservoir = 0
        #expect(state.headlineStatus.tone == .critical)
        #expect(state.reservoirFraction == 0)
    }

    @Test("Reservoir is shown against this model's cartridge size, estimate flag included")
    func reservoirPresentation() {
        let state = syncedMobi()
        #expect(state.reservoirCapacity == 200)
        #expect(state.reservoirFraction == 0.9)
        #expect(state.reservoirDescription == "180 U")

        state.reservoirIsEstimate = true
        #expect(state.reservoirDescription == "180+ U")

        // A t:slim X2 carries 300 U, so the same reading is a different fraction.
        state.pumpModel = .tslimX2
        #expect(state.reservoirCapacity == 300)
        #expect(state.reservoirFraction == 0.6)
    }

    @Test("Sync freshness escalates rather than jumping straight to signal loss") func syncFreshness() {
        let state = syncedMobi()
        #expect(state.syncTone == .ok)
        #expect(!state.syncIsStale)

        state.lastSync = Date.now.addingTimeInterval(-.minutes(8))
        #expect(state.syncTone == .caution)
        #expect(!state.syncIsStale)

        state.lastSync = Date.now.addingTimeInterval(-.minutes(20))
        #expect(state.syncTone == .critical)
        #expect(state.syncIsStale)
        #expect(state.headlineStatus.title == "Signal Loss")
    }

    @Test("The readiness checklist asks the same questions the driver enforces") func readinessChecks() {
        let state = syncedMobi()
        // No mode chosen: nothing to check, and nothing is ready.
        #expect(state.basalControlChecks.isEmpty)
        #expect(!state.basalControlIsReady)

        state.remoteBasalEnabled = true
        state.profileBasalRate = 1.0
        state.controlIQEnabled = false
        #expect(state.basalControlMode == .nativeTempRate)
        #expect(state.basalControlChecks.count == 4)
        #expect(state.basalControlIsReady)
        #expect(state.maximumTempRate == 2.5)

        // Control-IQ on is exactly what the driver refuses on, so exactly one
        // check must fail.
        state.controlIQEnabled = true
        #expect(state.basalControlChecks.filter { !$0.isMet }.count == 1)
        #expect(!state.basalControlIsReady)

        // A status older than the driver's staleness window fails closed here too.
        state.controlIQEnabled = false
        state.lastSync = Date.now.addingTimeInterval(-.minutes(11))
        #expect(!state.basalControlIsReady)
    }

    @Test("Microbolus mode checks the zeroed profile, not a non-zero one") func microbolusChecks() {
        let state = syncedMobi()
        state.microbolusBasalEnabled = true
        state.profileBasalRate = 1.0
        #expect(state.basalControlMode == .microbolus)
        #expect(!state.basalControlIsReady)

        state.profileBasalRate = 0
        #expect(state.basalControlIsReady)
    }

    @Test("Only alarms Trio may clear are offered, and the rest are still named") func alarmSplit() {
        let state = syncedMobi()
        // Empty Cartridge (8) is in the acknowledgeable family; Temperature (10)
        // is not, and must still be visible somewhere — a Mobi has no screen.
        state.activeAlarmBits = (1 << 8) | (1 << 10)
        #expect(state.isAlarming)
        #expect(state.activeAlarmNames == "Empty Cartridge + Temperature")
        #expect(state.dismissableCartridgeAlarmNames == "Empty Cartridge")
        #expect(state.unacknowledgeableAlarmNames == "Temperature")

        state.activeAlarmBits = 0
        #expect(!state.isAlarming)
        #expect(state.activeAlarmNames == nil)
        #expect(state.unacknowledgeableAlarmNames == nil)
    }

    @Test("Alarm and cartridge-progress state is never persisted") func runtimeOnlyState() {
        let state = syncedMobi()
        state.activeAlarmBits = 1 << 8
        state.activeAlertBits = 1 << 13
        state.notifiedAlarmBits = 1 << 8
        state.cartridgeDetectionPercent = 40
        state.fillTubingButtonDown = true
        state.alarmReadSuppressedUntil = Date.now.addingTimeInterval(.minutes(30))
        state.alertReadSuppressedUntil = Date.now.addingTimeInterval(.minutes(30))

        let restored = TandemPumpState(rawValue: state.rawValue)
        #expect(restored.activeAlarmBits == nil)
        #expect(restored.activeAlertBits == nil)
        #expect(restored.notifiedAlarmBits == 0)
        #expect(restored.cartridgeDetectionPercent == nil)
        #expect(restored.fillTubingButtonDown == nil)
        #expect(restored.alarmReadSuppressedUntil == nil)
        #expect(restored.alertReadSuppressedUntil == nil)
        // …and an alarm that is not re-observed reads as no alarm, not as a
        // remembered one.
        #expect(!restored.isAlarming)
    }
}

@Suite("Tandem glucose annunciation") struct TandemGlucoseAnnunciationTests {
    @Test("PlaySound matches the reverse-engineered protocol") func messageShape() {
        // pumpX2 PlaySoundRequest opCode = -12, PlaySoundResponse = -11.
        #expect(TandemPlaySoundRequest.opcode == 0xF4)
        #expect(TandemPlaySoundResponse.opcode == 0xF5)
        #expect(TandemPlaySoundRequest.signed)
        #expect(TandemPlaySoundRequest.characteristic == .control)
        // It moves no insulin, so it must not sit behind the delivery opt-in —
        // an alarm the user cannot be told about is the failure this feature
        // exists to prevent.
        #expect(!TandemPlaySoundRequest.modifiesInsulinDelivery)
        // The message carries nothing at all: no pattern, no tone, no volume.
        #expect(TandemPlaySoundRequest().cargo.isEmpty)
    }

    @Test("The response reports the pump's status byte") func responseParsing() throws {
        #expect(try TandemPlaySoundResponse(cargo: Data([0])).status == 0)
        #expect(try TandemPlaySoundResponse(cargo: Data([1])).status == 1)
        #expect(throws: TandemMessageError.self) { try TandemPlaySoundResponse(cargo: Data()) }
    }

    @Test("Low and high differ in both count and rhythm") func patternsAreDistinguishable() {
        let low = TandemAnnunciationPattern.pattern(for: .low)
        let high = TandemAnnunciationPattern.pattern(for: .high)

        // Either dimension alone is easy to miss through a pocket: counting
        // buzzes is unreliable, and so is judging a gap in isolation. Both must
        // differ, or the two alarms are not actually tellable apart.
        #expect(low.pulses != high.pulses)
        #expect(low.gap != high.gap)

        // Low is the urgent one: more buzzes, closer together.
        #expect(low.pulses > high.pulses)
        #expect(low.gap < high.gap)

        // And neither pattern may drag on so long it is still buzzing at the
        // next CGM reading.
        #expect(low.nominalDuration < .minutes(1))
        #expect(high.nominalDuration < .minutes(1))
    }

    @Test("A single pulse has no gap to wait out") func singlePulseDuration() {
        #expect(TandemAnnunciationPattern(pulses: 1, gap: 5).nominalDuration == 0)
        #expect(TandemAnnunciationPattern(pulses: 3, gap: 2).nominalDuration == 4)
    }

    @Test("The opt-in persists and the rate-limit clock does not") func statePersistence() {
        let state = TandemPumpState()
        #expect(!state.glucoseAnnunciationEnabled)

        state.glucoseAnnunciationEnabled = true
        state.lastAnnunciationAt = Date.now

        let restored = TandemPumpState(rawValue: state.rawValue)
        #expect(restored.glucoseAnnunciationEnabled)
        // Runtime-only: after a restart the worst case is one extra buzz, which
        // is the safe direction for an alarm.
        #expect(restored.lastAnnunciationAt == nil)
    }

    @Test("Every alarm kind has a pattern and a name") func kindCoverage() {
        for kind in TandemGlucoseAlarmKind.allCases {
            #expect(!kind.localizedTitle.isEmpty)
            #expect(TandemAnnunciationPattern.pattern(for: kind).pulses > 0)
        }
        #expect(TandemGlucoseAlarmKind.allCases.count == 2)
    }
}
