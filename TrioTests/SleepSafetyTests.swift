import Foundation
import Testing

@testable import Trio

@Suite("Sleep Safety Tests") struct SleepSafetyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: hour, minute: minute))!
    }

    private func config(
        lowThreshold: Decimal = 72,
        repeatMinutes: Double = 10,
        caregiverEnabled: Bool = false,
        caregiverMinutes: Double = 20
    ) -> SleepSafetyPolicy.Config {
        SleepSafetyPolicy.Config(
            lowThreshold: lowThreshold,
            escalationRepeatMinutes: repeatMinutes,
            caregiverEnabled: caregiverEnabled,
            caregiverEscalationMinutes: caregiverMinutes
        )
    }

    // MARK: - Window arithmetic

    @Test("Same-day window: [08:00, 12:00)") func testSameDayWindow() {
        let start = 8 * 60
        let end = 12 * 60
        #expect(!SleepSafetyPolicy.isInWindow(now: date(hour: 7, minute: 59), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(SleepSafetyPolicy.isInWindow(now: date(hour: 8), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(SleepSafetyPolicy.isInWindow(now: date(hour: 11, minute: 59), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(!SleepSafetyPolicy.isInWindow(now: date(hour: 12), startMinutes: start, endMinutes: end, calendar: calendar))
    }

    @Test("Midnight-crossing window: [22:00, 07:00)") func testMidnightCrossingWindow() {
        let start = 22 * 60
        let end = 7 * 60
        #expect(!SleepSafetyPolicy.isInWindow(now: date(hour: 21, minute: 59), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(SleepSafetyPolicy.isInWindow(now: date(hour: 22), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(SleepSafetyPolicy.isInWindow(now: date(hour: 23, minute: 30), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(SleepSafetyPolicy.isInWindow(now: date(hour: 0), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(SleepSafetyPolicy.isInWindow(now: date(hour: 6, minute: 59), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(!SleepSafetyPolicy.isInWindow(now: date(hour: 7), startMinutes: start, endMinutes: end, calendar: calendar))
        #expect(!SleepSafetyPolicy.isInWindow(now: date(hour: 12), startMinutes: start, endMinutes: end, calendar: calendar))
    }

    @Test("start == end is a zero-length window that is never active") func testZeroLengthWindow() {
        let minutes = 22 * 60
        #expect(!SleepSafetyPolicy.isInWindow(now: date(hour: 22), startMinutes: minutes, endMinutes: minutes, calendar: calendar))
        #expect(!SleepSafetyPolicy.isInWindow(now: date(hour: 3), startMinutes: minutes, endMinutes: minutes, calendar: calendar))
    }

    @Test("Minutes since window start across midnight") func testMinutesSinceWindowStart() {
        let start = 22 * 60
        let end = 7 * 60
        #expect(
            SleepSafetyPolicy
                .minutesSinceWindowStart(now: date(hour: 22, minute: 3), startMinutes: start, endMinutes: end, calendar: calendar) ==
                3
        )
        #expect(
            SleepSafetyPolicy
                .minutesSinceWindowStart(now: date(hour: 1), startMinutes: start, endMinutes: end, calendar: calendar) == 180
        )
        #expect(
            SleepSafetyPolicy
                .minutesSinceWindowStart(now: date(hour: 12), startMinutes: start, endMinutes: end, calendar: calendar) == nil
        )
    }

    // MARK: - Escalation decisions

    @Test("No reading does nothing") func testNoReading() {
        let state = SleepSafetyPolicy.State(glucose: nil)
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2)) == SleepAction.none)
    }

    @Test("Not low without an episode does nothing") func testNotLowNoEpisode() {
        let state = SleepSafetyPolicy.State(glucose: 120)
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2)) == SleepAction.none)
    }

    @Test("Recovery resets a running episode") func testRecoveryResetsEpisode() {
        let state = SleepSafetyPolicy.State(glucose: 95, episodeStartDate: date(hour: 1))
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2)) == .resetEpisode)
    }

    @Test("First low reading starts the episode without escalating") func testFirstLowStartsEpisode() {
        let state = SleepSafetyPolicy.State(glucose: 65)
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2)) == .startEpisode)
    }

    @Test("Threshold is inclusive") func testThresholdInclusive() {
        let state = SleepSafetyPolicy.State(glucose: 72)
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2)) == .startEpisode)
        let notLow = SleepSafetyPolicy.State(glucose: 73)
        #expect(SleepSafetyPolicy.action(state: notLow, config: config(), now: date(hour: 2)) == SleepAction.none)
    }

    @Test("No escalation before the repeat interval elapses") func testNoEscalationBeforeInterval() {
        let state = SleepSafetyPolicy.State(glucose: 65, episodeStartDate: date(hour: 2))
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2, minute: 9)) == SleepAction.none)
    }

    @Test("Escalates once the repeat interval has elapsed") func testEscalatesAfterInterval() {
        let state = SleepSafetyPolicy.State(glucose: 65, episodeStartDate: date(hour: 2))
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2, minute: 10)) == .escalate)
    }

    @Test("Repeat spacing: not again until repeatMinutes after the last escalation") func testRepeatSpacing() {
        let state = SleepSafetyPolicy.State(
            glucose: 65,
            episodeStartDate: date(hour: 2),
            lastEscalationDate: date(hour: 2, minute: 10)
        )
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2, minute: 15)) == SleepAction.none)
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2, minute: 20)) == .escalate)
    }

    @Test("Acknowledgement after the episode start silences escalation") func testAckSilences() {
        let state = SleepSafetyPolicy.State(
            glucose: 65,
            episodeStartDate: date(hour: 2),
            lastAckDate: date(hour: 2, minute: 5)
        )
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2, minute: 30)) == SleepAction.none)
    }

    @Test("Acknowledgement before the episode start does not silence") func testOldAckDoesNotSilence() {
        let state = SleepSafetyPolicy.State(
            glucose: 65,
            episodeStartDate: date(hour: 2),
            lastAckDate: date(hour: 1)
        )
        #expect(SleepSafetyPolicy.action(state: state, config: config(), now: date(hour: 2, minute: 10)) == .escalate)
    }

    @Test("Caregiver stage fires together with an escalation when both are due") func testCaregiverFiresWhenDue() {
        let state = SleepSafetyPolicy.State(
            glucose: 65,
            episodeStartDate: date(hour: 2),
            lastEscalationDate: date(hour: 2, minute: 10)
        )
        let cfg = config(caregiverEnabled: true, caregiverMinutes: 20)
        #expect(SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2, minute: 20)) == .escalateAndNotifyCaregiver)
    }

    @Test("Caregiver stage alone when escalation spacing is not yet met") func testCaregiverAlone() {
        let state = SleepSafetyPolicy.State(
            glucose: 65,
            episodeStartDate: date(hour: 2),
            lastEscalationDate: date(hour: 2, minute: 15)
        )
        let cfg = config(caregiverEnabled: true, caregiverMinutes: 20)
        #expect(SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2, minute: 20)) == .notifyCaregiver)
    }

    @Test("Caregiver SMS fires only once per episode") func testCaregiverSingleFire() {
        let state = SleepSafetyPolicy.State(
            glucose: 65,
            episodeStartDate: date(hour: 2),
            lastEscalationDate: date(hour: 2, minute: 25),
            caregiverSentForEpisode: true
        )
        let cfg = config(caregiverEnabled: true, caregiverMinutes: 20)
        #expect(SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2, minute: 30)) == SleepAction.none)
    }

    @Test("Caregiver disabled never notifies") func testCaregiverDisabled() {
        let state = SleepSafetyPolicy.State(
            glucose: 65,
            episodeStartDate: date(hour: 2),
            lastEscalationDate: date(hour: 2, minute: 55)
        )
        #expect(
            SleepSafetyPolicy.action(state: state, config: config(caregiverEnabled: false), now: date(hour: 3)) ==
                .escalate
        )
    }

    @Test("Full episode sequence: start, escalate, caregiver, recover") func testFullSequence() {
        let cfg = config(caregiverEnabled: true, caregiverMinutes: 20)
        var state = SleepSafetyPolicy.State(glucose: 60)

        // 02:00 - first low: episode starts, normal alarm is stage 1.
        #expect(SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2)) == .startEpisode)
        state.episodeStartDate = date(hour: 2)

        // 02:10 - still low, unacknowledged: escalate.
        #expect(SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2, minute: 10)) == .escalate)
        state.lastEscalationDate = date(hour: 2, minute: 10)

        // 02:20 - still low: escalate again and text the caregiver.
        #expect(
            SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2, minute: 20)) ==
                .escalateAndNotifyCaregiver
        )
        state.lastEscalationDate = date(hour: 2, minute: 20)
        state.caregiverSentForEpisode = true

        // 02:30 - still low: only the notification repeats, the caregiver is not texted again.
        #expect(SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2, minute: 30)) == .escalate)
        state.lastEscalationDate = date(hour: 2, minute: 30)

        // 02:40 - recovered: reset for the next episode.
        state.glucose = 90
        #expect(SleepSafetyPolicy.action(state: state, config: cfg, now: date(hour: 2, minute: 40)) == .resetEpisode)
    }
}
