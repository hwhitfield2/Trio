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
