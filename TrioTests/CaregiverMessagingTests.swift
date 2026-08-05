import Foundation
import Testing

@testable import Trio

@Suite("Caregiver Message Tests") struct CaregiverMessageTests {
    @Test("Composes an update in mg/dL with trend, delta, IOB and COB") func composeMgdlUpdate() {
        var input = CaregiverMessage.Input()
        input.glucoseValue = 104
        input.trendSymbol = "→"
        input.deltaValue = 2
        input.iob = 1.0
        input.cob = 15
        input.units = .mgdL
        input.includeIOBAndCOB = true

        let message = CaregiverMessage.compose(from: input)

        #expect(message.hasPrefix("Trio update:"))
        #expect(message.contains("104 mg/dL"))
        #expect(message.contains("→"))
        #expect(message.contains("+2"))
        #expect(message.contains("IOB: 1 U"))
        #expect(message.contains("COB: 15 g"))
    }

    @Test("Converts glucose and delta to mmol/L") func composeMmolL() {
        var input = CaregiverMessage.Input()
        input.glucoseValue = 104
        input.deltaValue = 4
        input.units = .mmolL
        input.includeIOBAndCOB = false

        let message = CaregiverMessage.compose(from: input)

        #expect(message.contains(104.formattedAsMmolL))
        #expect(message.contains("mmol/L"))
        #expect(!message.contains("104"))
    }

    @Test("Uses alarm-specific leads") func composeAlarmLeads() {
        var input = CaregiverMessage.Input()
        input.glucoseValue = 54

        input.alarm = .low
        #expect(CaregiverMessage.compose(from: input).hasPrefix("Trio LOW glucose alert:"))

        input.alarm = .high
        input.glucoseValue = 300
        #expect(CaregiverMessage.compose(from: input).hasPrefix("Trio HIGH glucose alert:"))
    }

    @Test("Omits IOB and COB when disabled") func composeWithoutIOBCOB() {
        var input = CaregiverMessage.Input()
        input.glucoseValue = 104
        input.iob = 1.0
        input.cob = 15
        input.includeIOBAndCOB = false

        let message = CaregiverMessage.compose(from: input)

        #expect(!message.contains("IOB"))
        #expect(!message.contains("COB"))
    }

    @Test("Falls back to a no-data message without a glucose reading") func composeWithoutGlucose() {
        let message = CaregiverMessage.compose(from: CaregiverMessage.Input())

        #expect(message == "Trio: No recent glucose reading is available.")
    }

    @Test("Parses recipients from comma, semicolon and newline separated input") func parseRecipients() {
        let parsed = CaregiverMessage.recipients(from: " +1 555 123 4567, mom@example.com ;\n dad@example.com,,")

        #expect(parsed == ["+1 555 123 4567", "mom@example.com", "dad@example.com"])
    }

    @Test("Returns no recipients for empty input") func parseEmptyRecipients() {
        #expect(CaregiverMessage.recipients(from: "").isEmpty)
        #expect(CaregiverMessage.recipients(from: " ,; \n ").isEmpty)
    }
}
