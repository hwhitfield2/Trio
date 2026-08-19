import Foundation
import LoopKit

/// Which of Trio's glucose alarms is being announced on the pump.
enum TandemGlucoseAlarmKind: String, Codable, CaseIterable {
    case low
    case high

    var localizedTitle: String {
        switch self {
        case .low: return String(localized: "Low glucose")
        case .high: return String(localized: "High glucose")
        }
    }
}

/// How a glucose alarm is spelled out on the pump.
///
/// `PlaySound` has no parameters at all — no pattern, no duration, no tone —
/// so the only thing that can distinguish one alarm from another is how many
/// times Trio asks and how far apart it asks. Both fields differ between low
/// and high on purpose: count alone is easy to miscount through a shirt, and
/// rhythm alone is easy to miss, so the two patterns differ in both.
struct TandemAnnunciationPattern: Equatable {
    let pulses: Int
    /// Quiet time after one pulse is acknowledged before the next is sent.
    ///
    /// Measured from the END of the previous round trip, not its start, because
    /// that is all a serial command queue can promise — the real rhythm is this
    /// plus however long the pump took to answer. Both patterns pay the same
    /// round trip, so they stay tellable apart regardless.
    let gap: TimeInterval

    /// Low is urgent: three pulses, close together.
    static let low = TandemAnnunciationPattern(pulses: 3, gap: 1.0)
    /// High is not: two pulses, spaced out.
    static let high = TandemAnnunciationPattern(pulses: 2, gap: 3.0)

    static func pattern(for kind: TandemGlucoseAlarmKind) -> TandemAnnunciationPattern {
        switch kind {
        case .low: return .low
        case .high: return .high
        }
    }

    /// Roughly how long the whole pattern takes, ignoring BLE round trips.
    var nominalDuration: TimeInterval {
        gap * Double(max(0, pulses - 1))
    }
}

extension TandemPumpManager {
    /// Shortest time between two annunciations, whatever asks for them.
    ///
    /// Trio's own glucose alarms already de-duplicate per reading and honour
    /// the snooze, so this is not the primary limit — it is the driver refusing
    /// to trust its callers about how often it may buzz someone's pump.
    static let minimumAnnunciationInterval: TimeInterval = .minutes(5)

    /// Buzz the pump for a glucose alarm.
    ///
    /// Safe to call from any thread. Everything about it is deliberately
    /// best-effort: it is a notification, not therapy, and it must never be the
    /// reason something that moves insulin was slow.
    ///
    /// - It does nothing unless the user opted in.
    /// - It **connects if it has to**. An alarm that only reaches the pump when
    ///   the radio link happens to be up is an alarm you cannot rely on, and
    ///   between loop cycles the link often is not up. The rate limit below is
    ///   what stops that from meaning "wake the pump constantly".
    /// - Each pulse is scheduled as its own item on `commandQueue` rather than
    ///   held in a single blocking loop, so a temp basal or a bolus enqueued
    ///   during a pattern waits for one pulse's round trip instead of the whole
    ///   pattern.
    /// - A pulse that fails abandons the rest. A pattern that cannot be
    ///   finished is not worth a series of retries against a pump that is not
    ///   answering.
    func annunciateGlucoseAlarm(_ kind: TandemGlucoseAlarmKind) {
        guard state.glucoseAnnunciationEnabled else { return }

        commandQueue.async { [weak self] in
            guard let self = self else { return }
            // Checked before connecting, so a rate-limited alarm never wakes the
            // pump just to be dropped.
            if let last = self.state.lastAnnunciationAt,
               Date.now.timeIntervalSince(last) < Self.minimumAnnunciationInterval
            {
                self.log.info("Skipping \(kind.rawValue) annunciation: one was played less than 5 minutes ago")
                return
            }
            self.state.lastAnnunciationAt = Date.now
            let pattern = TandemAnnunciationPattern.pattern(for: kind)
            self.log.info("Annunciating \(kind.rawValue): \(pattern.pulses) pulses \(pattern.gap)s apart")
            self.playAnnunciationPulse(remaining: pattern.pulses, gap: pattern.gap)
        }
    }

    /// Play one pulse and schedule the next. commandQueue only.
    private func playAnnunciationPulse(remaining: Int, gap: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        guard remaining > 0 else { return }

        // Connects when it has to and is a cheap no-op when the link is already
        // up, so the same call covers both the first pulse and a pump that
        // dropped out mid-pattern.
        if let error = ensureConnectedAndAuthenticated() {
            log.error("Annunciation stopped: \(error.localizedDescription)")
            return
        }
        if case let .failure(error) = session.refreshTimeSinceReset() {
            log.error("Annunciation stopped: time refresh failed (\(error.localizedDescription))")
            return
        }
        switch session.send(TandemPlaySoundRequest()) {
        case let .success(response):
            if response.status != 0 {
                log.error("PlaySound refused with status \(response.status); stopping the pattern")
                return
            }
            // Status 0 is pumpX2's documented success. It says the pump ACCEPTED
            // the command, not that anything was audible: PlaySound has no
            // volume of its own and follows the pump's Sound settings.
            log.info("PlaySound accepted (status 0)")
        case let .failure(error):
            log.error("PlaySound failed: \(error.localizedDescription); stopping the pattern")
            return
        }

        guard remaining > 1 else { return }
        commandQueue.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.playAnnunciationPulse(remaining: remaining - 1, gap: gap)
        }
    }

    /// Play a pattern from the settings screen so the user can hear (or feel)
    /// the difference between the two before relying on it.
    ///
    /// Unlike the real thing this ignores the rate limit — the user is standing
    /// there asking for it — but it still requires the opt-in, connects the same
    /// way, and reports what happened instead of failing silently.
    func testAnnunciation(_ kind: TandemGlucoseAlarmKind, completion: @escaping ((any LocalizedError)?) -> Void) {
        guard state.glucoseAnnunciationEnabled else {
            completion(TandemAnnunciationError.notEnabled)
            return
        }
        commandQueue.async { [weak self] in
            guard let self = self else { return }
            let pattern = TandemAnnunciationPattern.pattern(for: kind)
            if let error = self.ensureConnectedAndAuthenticated() {
                completion(error)
                return
            }
            if case let .failure(error) = self.session.refreshTimeSinceReset() {
                completion(error)
                return
            }
            switch self.session.send(TandemPlaySoundRequest()) {
            case let .success(response):
                guard response.status == 0 else {
                    completion(TandemAnnunciationError.rejected(status: response.status))
                    return
                }
            case let .failure(error):
                completion(error)
                return
            }
            // The first pulse is the one that proves the pump accepts the
            // command; the rest are the pattern, and are best effort.
            self.state.lastAnnunciationAt = Date.now
            if pattern.pulses > 1 {
                self.commandQueue.asyncAfter(deadline: .now() + pattern.gap) { [weak self] in
                    self?.playAnnunciationPulse(remaining: pattern.pulses - 1, gap: pattern.gap)
                }
            }
            completion(nil)
        }
    }
}

enum TandemAnnunciationError: LocalizedError {
    case notEnabled
    case rejected(status: UInt8)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return String(localized: "Buzzing the pump for glucose alarms is turned off.")
        case let .rejected(status):
            // pumpX2's StatusMessage documents 0 as success, so anything else is
            // the pump saying no. The number is worth quoting: this command has
            // never been sent to a real pump by anyone, so which value comes
            // back is itself the finding.
            return String(
                localized: "The pump refused to play a sound and answered status \(Int(status)). This command has not been verified against a real pump, so your pump's software may not support it."
            )
        }
    }
}
