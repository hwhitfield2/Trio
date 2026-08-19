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
        guard !state.annunciationRefusalActive else {
            log.info("Skipping \(kind.rawValue) annunciation: the pump refused PlaySound recently")
            return
        }

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
            self.playAnnunciationPulse(remaining: pattern.pulses, gap: pattern.gap, canRekey: true)
        }
    }

    /// One attempt at one pulse, reduced to the three things a caller can act on.
    private enum PulseOutcome {
        case accepted
        /// The pump answered and said no — a non-zero status, or the generic
        /// ErrorResponse a pump gives a signed command it does not accept.
        case refused(String)
        /// The attempt never got an answer (link, timeout, local error).
        case failed(TandemSessionError)
    }

    private func sendOnePulse() -> PulseOutcome {
        if let error = ensureConnectedAndAuthenticated() {
            return .failed(error)
        }
        if case let .failure(error) = session.refreshTimeSinceReset() {
            return .failed(error)
        }
        switch session.send(TandemPlaySoundRequest()) {
        case let .success(response):
            if response.status != 0 {
                return .refused(String(localized: "status \(Int(response.status))"))
            }
            // Status 0 is pumpX2's documented success. It says the pump ACCEPTED
            // the command, not that anything was audible: PlaySound has no
            // volume of its own and follows the pump's Sound settings.
            return .accepted
        case let .failure(error):
            if case let .pumpRejected(refusal) = error {
                return .refused(refusal.localizedDescription)
            }
            return .failed(error)
        }
    }

    /// Tear the link down and bring it back with a fresh handshake.
    ///
    /// This exists because the one refusal seen from a real Mobi matched what
    /// pumpX2's field notes document for a signed command whose signature the
    /// pump does not accept — and a JPAKE signing key is only valid on the
    /// link whose nonce produced it. Reconnecting re-runs the key exchange, so
    /// a refusal caused by a stale key is cured by exactly this.
    private func reauthenticateOverFreshLink() -> TandemSessionError? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        log.info("Re-keying: dropping the link to force a fresh handshake")
        bluetooth.disconnect()
        var waited: TimeInterval = 0
        while bluetooth.isConnected, waited < 5 {
            Thread.sleep(forTimeInterval: 0.2)
            waited += 0.2
        }
        if let error = ensureConnectedAndAuthenticated() {
            return error
        }
        if case let .failure(error) = session.refreshTimeSinceReset() {
            return error
        }
        return nil
    }

    /// What the pump says about itself right after a refusal, for the log and
    /// for the test button's result. One line, cheap unsigned reads only.
    private func annunciationPumpContext() -> String {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        var parts: [String] = []
        if case let .success(mirror) = session.send(TandemHomeScreenMirrorRequest()) {
            parts.append(
                mirror.basalStatusIconId == 4 || mirror.basalStatusIconId == 5
                    ? String(localized: "insulin stopped")
                    : String(localized: "insulin running")
            )
        }
        if let alarms = readActiveAlarms()?.localizedNames {
            parts.append(String(localized: "alarming: \(alarms)"))
        }
        return parts.isEmpty ? String(localized: "no state reading") : parts.joined(separator: ", ")
    }

    private func suppressAnnunciations(reason: String) {
        state.annunciationRefusedUntil = Date.now
            .addingTimeInterval(TandemPumpState.annunciationRefusalSuppression)
        log.error("PlaySound refused after a fresh handshake (\(reason)); pausing annunciations for an hour")
        notifyStateDidChange()
    }

    /// Play one pulse and schedule the next. commandQueue only.
    ///
    /// A refusal gets ONE second chance, over a torn-down and re-keyed link —
    /// the failure mode the field has actually produced is a stale signing key,
    /// which that cures. A pump that refuses the re-keyed attempt too gets left
    /// alone for an hour.
    private func playAnnunciationPulse(remaining: Int, gap: TimeInterval, canRekey: Bool) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        guard remaining > 0 else { return }

        switch sendOnePulse() {
        case .accepted:
            break
        case let .refused(reason):
            guard canRekey else {
                suppressAnnunciations(reason: reason)
                return
            }
            log.error("PlaySound refused (\(reason)); retrying once over a fresh handshake")
            if let error = reauthenticateOverFreshLink() {
                log.error("Annunciation stopped: re-key failed (\(error.localizedDescription))")
                return
            }
            playAnnunciationPulse(remaining: remaining, gap: gap, canRekey: false)
            return
        case let .failed(error):
            log.error("Annunciation stopped: \(error.localizedDescription)")
            return
        }

        guard remaining > 1 else { return }
        commandQueue.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.playAnnunciationPulse(remaining: remaining - 1, gap: gap, canRekey: false)
        }
    }

    /// Play a pattern from the settings screen so the user can hear (or feel)
    /// the difference between the two before relying on it.
    ///
    /// Unlike the real thing this ignores the rate limit — the user is standing
    /// there asking for it — but it connects the same way, retries over a fresh
    /// handshake the same way, and on a second refusal reports everything there
    /// is to know: the pump's named reason and what the pump said about its own
    /// state, so the answer can be diagnosed rather than shrugged at.
    func testAnnunciation(_ kind: TandemGlucoseAlarmKind, completion: @escaping ((any LocalizedError)?) -> Void) {
        guard state.glucoseAnnunciationEnabled else {
            completion(TandemAnnunciationError.notEnabled)
            return
        }
        // Pressing test IS the retry, so it clears the refusal pause rather
        // than being blocked by it.
        state.annunciationRefusedUntil = nil
        commandQueue.async { [weak self] in
            guard let self = self else { return }
            let pattern = TandemAnnunciationPattern.pattern(for: kind)

            var outcome = self.sendOnePulse()
            if case let .refused(reason) = outcome {
                self.log.error("PlaySound refused (\(reason)); test retrying once over a fresh handshake")
                if let error = self.reauthenticateOverFreshLink() {
                    completion(error)
                    return
                }
                outcome = self.sendOnePulse()
            }

            switch outcome {
            case .accepted:
                // The first pulse is the one that proves the pump accepts the
                // command; the rest are the pattern, and are best effort.
                self.state.lastAnnunciationAt = Date.now
                if pattern.pulses > 1 {
                    self.commandQueue.asyncAfter(deadline: .now() + pattern.gap) { [weak self] in
                        self?.playAnnunciationPulse(remaining: pattern.pulses - 1, gap: pattern.gap, canRekey: false)
                    }
                }
                completion(nil)
            case let .refused(reason):
                let context = self.annunciationPumpContext()
                self.suppressAnnunciations(reason: reason)
                completion(TandemAnnunciationError.refusedTwice(reason: reason, context: context))
            case let .failed(error):
                completion(error)
            }
        }
    }
}

enum TandemAnnunciationError: LocalizedError {
    case notEnabled
    /// The pump said no twice — once on the standing link and once more after a
    /// full reconnect and key exchange. That rules out the stale-signing-key
    /// failure, so what remains is the pump itself: its named reason and its
    /// own state at that moment are the whole finding.
    case refusedTwice(reason: String, context: String)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return String(localized: "Buzzing the pump for glucose alarms is turned off.")
        case let .refusedTwice(reason, context):
            return String(
                localized: "The pump refused to play the sound twice — once more after reconnecting with a fresh key — answering: \(reason). The pump reported: \(context). Trio will not ask again for an hour; a test button asks immediately."
            )
        }
    }
}
