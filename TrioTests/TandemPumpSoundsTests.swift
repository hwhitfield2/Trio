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

    @Test("Only the writable categories exist, each with the right change bit") func categories() {
        // Button and fill-tubing are deliberately absent: SetPumpSounds has no
        // field for them, so they must not appear as settable categories.
        #expect(TandemSoundCategory.allCases.map(\.rawValue).sorted()
            == ["alarm", "alert", "bolus", "quickBolus", "reminder"])
        // Bolus is written through the "general" field/bit.
        #expect(TandemSoundCategory.bolus.changeBit == .general)
        #expect(TandemSoundCategory.reminder.changeBit == .reminder)
        #expect(TandemSoundCategory.alert.changeBit == .alert)
        #expect(TandemSoundCategory.alarm.changeBit == .alarm)
        #expect(TandemSoundCategory.quickBolus.changeBit == .quickBolus)
    }

    @Test("Each category reads its own level from PumpGlobals") func currentLevels() throws {
        // PumpGlobals layout: [7]=button, [8]=quickBolus, [9]=bolus,
        // [10]=reminder, [11]=alert, [12]=alarm, [13]=fillTubing.
        var cargo = Data(count: 14)
        cargo[7] = 3 // button vibrate (read-only)
        cargo[8] = 2 // quickBolus low
        cargo[9] = 1 // bolus medium
        cargo[10] = 0 // reminder loud
        cargo[11] = 3 // alert vibrate
        cargo[12] = 0 // alarm loud
        cargo[13] = 1 // fillTubing (read-only)
        let g = try TandemPumpGlobalsResponse(cargo: cargo)

        #expect(TandemSoundCategory.bolus.currentLevel(from: g) == 1)
        #expect(TandemSoundCategory.reminder.currentLevel(from: g) == 0)
        #expect(TandemSoundCategory.alert.currentLevel(from: g) == 3)
        #expect(TandemSoundCategory.alarm.currentLevel(from: g) == 0)
        #expect(TandemSoundCategory.quickBolus.currentLevel(from: g) == 2)
        // Button is not a settable category, but the pump still reports it.
        #expect(g.buttonAnnunId == 3)
    }

    @Test("Writing several categories builds one mask and one cargo") func multiCategoryCargo() {
        // Set bolus=low(2), alarm=vibrate(3); leave the rest at a read baseline.
        let req = TandemSetPumpSoundsRequest(
            quickBolus: 0,
            general: 2, // bolus low
            reminder: 0,
            alert: 0,
            alarm: 3, // alarm vibrate
            cgmAlertA: 0,
            cgmAlertB: 0,
            changeBitmask: (TandemSoundCategory.bolus.changeBit.rawValue
                | TandemSoundCategory.alarm.changeBit.rawValue)
        )
        // general(bit 4) | alarm(bit 32) = 36.
        #expect(req.cargo == Data([0, 0, 2, 0, 0, 3, 0, 0, 36]))
    }
}
