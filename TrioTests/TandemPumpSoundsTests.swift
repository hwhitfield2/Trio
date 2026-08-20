import Foundation
import Testing

@testable import Trio

@Suite("Tandem set pump sounds") struct TandemSetPumpSoundsTests {
    @Test("Encodes the 9-byte cargo in pump order") func cargo() {
        // audioHigh(0) for reminder/alert/alarm; the rest preserved from a read.
        let req = TandemSetPumpSoundsRequest(
            quickBolus: 3, // vibrate, preserved
            general: 1, // medium, preserved
            reminder: 0,
            alert: 0,
            alarm: 0,
            cgmAlertA: 0,
            cgmAlertB: 0,
            changeBitmask: TandemSetPumpSoundsRequest.Categories([.reminder, .alert, .alarm]).rawValue
        )
        // byte0 unknown(0), quickBolus, general, reminder, alert, alarm, cgmA, cgmB, changeBitmask
        #expect(req.cargo == Data([0, 3, 1, 0, 0, 0, 0, 0, 56]))
        #expect(req.cargo.count == 9)
    }

    @Test("Change bitmask is the sum of the pumpX2 category bits") func bitmask() {
        #expect(TandemSetPumpSoundsRequest.Categories.reminder.rawValue == 8)
        #expect(TandemSetPumpSoundsRequest.Categories.alert.rawValue == 16)
        #expect(TandemSetPumpSoundsRequest.Categories.alarm.rawValue == 32)
        // reminder | alert | alarm
        #expect(TandemSetPumpSoundsRequest.Categories([.reminder, .alert, .alarm]).rawValue == 56)
        // quick-bolus and CGM-alert are deliberately out of Trio's set.
        #expect(TandemSetPumpSoundsRequest.Categories.quickBolus.rawValue == 2)
        #expect(TandemSetPumpSoundsRequest.Categories.cgmAlert.rawValue == 64)
    }

    @Test("It is a signed control message, but not an insulin-moving one") func shape() {
        #expect(TandemSetPumpSoundsRequest.opcode == 0xE4)
        #expect(TandemSetPumpSoundsResponse.opcode == 0xE5)
        #expect(TandemSetPumpSoundsRequest.characteristic == .control)
        #expect(TandemSetPumpSoundsRequest.signed)
        // Non-delivery, like PlaySound — so it sits outside the bolus opt-in.
        #expect(!TandemSetPumpSoundsRequest.modifiesInsulinDelivery)
    }

    @Test("The response is a single status byte") func response() throws {
        #expect(try TandemSetPumpSoundsResponse(cargo: Data([0])).status == 0)
        #expect(try TandemSetPumpSoundsResponse(cargo: Data([1])).status == 1)
        #expect(throws: TandemMessageError.self) { try TandemSetPumpSoundsResponse(cargo: Data()) }
    }

    @Test("Levels map to the pump's annunciation ids") func levels() {
        #expect(TandemAnnunciationMode.audioHigh.rawValue == 0)
        #expect(TandemAnnunciationMode.audioMedium.rawValue == 1)
        #expect(TandemAnnunciationMode.audioLow.rawValue == 2)
        #expect(TandemAnnunciationMode.vibrate.rawValue == 3)
    }

    @Test("A sound change that did not take is reported, not assumed") func didNotTake() {
        let error = TandemPumpSoundError.didNotTake(requested: .audioHigh, got: .vibrate)
        #expect(error.errorDescription?.contains("loud") == true)
        #expect(error.errorDescription?.contains("vibrate") == true)
    }
}
