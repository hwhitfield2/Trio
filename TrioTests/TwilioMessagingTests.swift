import Foundation
import Testing

@testable import Trio

@Suite("Twilio Alert Policy Tests") struct TwilioAlertPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeConditions() -> TwilioAlertPolicy.Conditions {
        TwilioAlertPolicy.Conditions(
            sendUrgentLow: true,
            sendLow: true,
            sendHigh: true,
            sendLoopFailure: true,
            urgentLowThreshold: 55,
            lowThreshold: 72,
            highThreshold: 270,
            loopFailureGraceMinutes: 45,
            cooldownMinutes: 30
        )
    }

    private func makeState(glucose: Int?) -> TwilioAlertPolicy.State {
        TwilioAlertPolicy.State(
            glucose: glucose,
            lastLoopDate: now.addingTimeInterval(-5 * 60),
            lastSentDate: nil,
            activeAlertKind: nil,
            now: now
        )
    }

    @Test("Urgent low outranks low") func urgentLowPriority() {
        let conditions = makeConditions()

        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: makeState(glucose: 54)) == .urgentLow)
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: makeState(glucose: 55)) == .urgentLow)
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: makeState(glucose: 60)) == .low)
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: makeState(glucose: 100)) == nil)
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: makeState(glucose: 280)) == .high)
    }

    @Test("Disabled conditions never fire") func disabledConditions() {
        var conditions = makeConditions()
        conditions.sendUrgentLow = false
        conditions.sendLow = false
        conditions.sendHigh = false
        conditions.sendLoopFailure = false

        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: makeState(glucose: 40)) == nil)
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: makeState(glucose: 400)) == nil)
    }

    @Test("Loop failure fires only after the grace period") func loopFailure() {
        let conditions = makeConditions()
        var state = makeState(glucose: 100)

        state.lastLoopDate = now.addingTimeInterval(-44 * 60)
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: state) == nil)

        state.lastLoopDate = now.addingTimeInterval(-46 * 60)
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: state) == .loopFailure)

        // A glucose alarm takes priority over loop failure
        state.glucose = 60
        #expect(TwilioAlertPolicy.currentKind(conditions: conditions, state: state) == .low)
    }

    @Test("An active alert is not re-sent") func dedupeActiveAlert() {
        let conditions = makeConditions()
        var state = makeState(glucose: 60)
        state.activeAlertKind = .low

        #expect(TwilioAlertPolicy.evaluate(conditions: conditions, state: state) == nil)

        // Escalation from low to urgent low goes through
        state.glucose = 50
        #expect(TwilioAlertPolicy.evaluate(conditions: conditions, state: state) == .urgentLow)
    }

    @Test("Cooldown throttles everything except urgent lows") func cooldown() {
        let conditions = makeConditions()
        var state = makeState(glucose: 280)
        state.lastSentDate = now.addingTimeInterval(-10 * 60)

        #expect(TwilioAlertPolicy.evaluate(conditions: conditions, state: state) == nil)

        state.lastSentDate = now.addingTimeInterval(-31 * 60)
        #expect(TwilioAlertPolicy.evaluate(conditions: conditions, state: state) == .high)

        state.lastSentDate = now.addingTimeInterval(-10 * 60)
        state.glucose = 50
        #expect(TwilioAlertPolicy.evaluate(conditions: conditions, state: state) == .urgentLow)
    }
}

@Suite("Twilio Config Tests") struct TwilioConfigTests {
    @Test("Snaps cooldown to the nearest picker option") func cooldownSnap() {
        #expect(TwilioConfig.StateModel.nearestCooldownOption(to: 20) == 15)
        #expect(TwilioConfig.StateModel.nearestCooldownOption(to: 30) == 30)
        #expect(TwilioConfig.StateModel.nearestCooldownOption(to: 1000) == 240)
        #expect(TwilioConfig.StateModel.nearestCooldownOption(to: 1) == 5)
    }
}

@Suite("Twilio Request Builder Tests") struct TwilioRequestBuilderTests {
    @Test("Builds a valid Twilio API request") func buildRequest() throws {
        let request = try #require(TwilioRequestBuilder.request(
            accountSID: "AC123",
            authToken: "secret",
            from: "+15550001111",
            to: "+15552223333",
            body: "Trio update: 104 mg/dL"
        ))

        #expect(request.url?.absoluteString == "https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json")
        #expect(request.httpMethod == "POST")

        let expectedAuth = "Basic " + Data("AC123:secret".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expectedAuth)

        let bodyString = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(bodyString.contains("To=%2B15552223333"))
        #expect(bodyString.contains("From=%2B15550001111"))
        #expect(bodyString.contains("Body=Trio%20update%3A%20104%20mg%2FdL"))
    }

    @Test("Percent-encodes reserved characters") func percentEncoding() {
        #expect(TwilioRequestBuilder.percentEncoded("+& =") == "%2B%26%20%3D")
        #expect(TwilioRequestBuilder.percentEncoded("abc-._~123") == "abc-._~123")
    }
}
