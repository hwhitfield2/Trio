import Foundation

/// What the sleep-safety evaluation should do for the current glucose reading.
enum SleepAction: Equatable {
    /// Nothing to do (no reading, not low, or already acknowledged).
    case none
    /// A new low episode begins; stage 1 is Trio's normal low alarm, so only record the start.
    case startEpisode
    /// Glucose recovered; clear the episode bookkeeping.
    case resetEpisode
    /// Post an additional escalation notification.
    case escalate
    /// Send the caregiver SMS for this episode.
    case notifyCaregiver
    /// Both an escalation notification and the caregiver SMS are due.
    case escalateAndNotifyCaregiver
}

/// Pure, dependency-free decision logic for the sleep-safe overnight mode, so both the
/// window arithmetic and the escalation ladder stay unit-testable. It only ever ADDS
/// reminders on top of Trio's normal alerts and never doses.
enum SleepSafetyPolicy {
    struct Config: Equatable {
        /// Low alarm limit (mg/dL) an episode is measured against.
        var lowThreshold: Decimal
        /// Minutes after the episode start before the first escalation, and between repeats.
        var escalationRepeatMinutes: Double
        /// Whether the caregiver SMS stage is enabled at all.
        var caregiverEnabled: Bool
        /// Minutes of unacknowledged low before the caregiver SMS fires.
        var caregiverEscalationMinutes: Double
    }

    struct State: Equatable {
        /// Latest glucose reading (mg/dL); nil when no recent reading exists.
        var glucose: Int?
        /// When the current low episode began; nil outside an episode.
        var episodeStartDate: Date?
        /// When the last escalation notification was posted; nil if none yet.
        var lastEscalationDate: Date?
        /// Last acknowledgement (app opened or alerts snoozed); nil if never.
        var lastAckDate: Date?
        /// Whether the caregiver SMS already went out for this episode.
        var caregiverSentForEpisode: Bool = false
    }

    /// Whether `now` falls inside the [start, end) window given in minutes since midnight.
    /// The window crosses midnight when `endMinutes < startMinutes`; `start == end` means
    /// a zero-length window that is never active.
    static func isInWindow(now: Date, startMinutes: Int, endMinutes: Int, calendar: Calendar = .current) -> Bool {
        guard startMinutes != endMinutes else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutesOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinutes < endMinutes {
            return minutesOfDay >= startMinutes && minutesOfDay < endMinutes
        }
        return minutesOfDay >= startMinutes || minutesOfDay < endMinutes
    }

    /// How many minutes `now` is past the window start, or nil when outside the window.
    static func minutesSinceWindowStart(
        now: Date,
        startMinutes: Int,
        endMinutes: Int,
        calendar: Calendar = .current
    ) -> Int? {
        guard isInWindow(now: now, startMinutes: startMinutes, endMinutes: endMinutes, calendar: calendar) else {
            return nil
        }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutesOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return minutesOfDay >= startMinutes ? minutesOfDay - startMinutes : minutesOfDay + 24 * 60 - startMinutes
    }

    /// Decides the escalation step for the current reading. Callers only invoke this while
    /// the sleep window is active and the feature is enabled.
    static func action(state: State, config: Config, now: Date) -> SleepAction {
        guard let glucose = state.glucose else { return .none }

        guard Decimal(glucose) <= config.lowThreshold else {
            return state.episodeStartDate != nil ? .resetEpisode : .none
        }

        guard let episodeStart = state.episodeStartDate else { return .startEpisode }

        // Opening the app or snoozing after the episode began counts as acknowledgement.
        if let ack = state.lastAckDate, ack >= episodeStart { return .none }

        let minutesSinceStart = now.timeIntervalSince(episodeStart) / 60
        let minutesSinceEscalation = state.lastEscalationDate.map { now.timeIntervalSince($0) / 60 } ?? .infinity

        let shouldEscalate = minutesSinceStart >= config.escalationRepeatMinutes &&
            minutesSinceEscalation >= config.escalationRepeatMinutes
        let shouldNotifyCaregiver = config.caregiverEnabled && !state.caregiverSentForEpisode &&
            minutesSinceStart >= config.caregiverEscalationMinutes

        switch (shouldEscalate, shouldNotifyCaregiver) {
        case (true, true):
            return .escalateAndNotifyCaregiver
        case (true, false):
            return .escalate
        case (false, true):
            return .notifyCaregiver
        case (false, false):
            return .none
        }
    }
}
