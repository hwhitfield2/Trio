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
/// Field-verified on a real Mobi: one accepted `PlaySound` plays one FIXED
/// burst — two beeps and two vibrations — and while that burst is playing the
/// pump answers the next request with status 1. There is no pattern, tone or
/// duration parameter, and gaps shorter than the burst are simply swallowed.
/// So the only audible knob is HOW MANY bursts are played, paced at whatever
/// rhythm the pump itself allows.
struct TandemAnnunciationPattern: Equatable {
    /// How many of the pump's fixed beep-and-vibrate bursts to play.
    let bursts: Int

    /// Low is two bursts and high is three — chosen by ear against a real
    /// Mobi. The phone alert still carries the urgency; the pump's job is
    /// only to be tellable apart through a pocket.
    static let low = TandemAnnunciationPattern(bursts: 2)
    static let high = TandemAnnunciationPattern(bursts: 3)

    static func pattern(for kind: TandemGlucoseAlarmKind) -> TandemAnnunciationPattern {
        switch kind {
        case .low: return .low
        case .high: return .high
        }
    }

    /// Pause after an accepted burst before asking for the next one.
    static let interBurstDelay: TimeInterval = 4

    /// The pump refuses a request that lands while it is still playing —
    /// status 1 is its pacing, not a rejection — so a refused burst is retried
    /// on this cadence, up to the cap, instead of being treated as a failure.
    static let busyRetryDelay: TimeInterval = 2.5
    static let maxBusyRetries = 6

    /// Longest a pattern can take with every retry spent, for sanity tests.
    var worstCaseDuration: TimeInterval {
        Double(bursts) * (Self.interBurstDelay + Self.busyRetryDelay * Double(Self.maxBusyRetries))
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
            self.log.info("Annunciating \(kind.rawValue): \(pattern.bursts) bursts")
            self.playAnnunciationBurst(
                remaining: pattern.bursts,
                anyPlayed: false,
                canRekey: true,
                busyRetries: TandemAnnunciationPattern.maxBusyRetries
            )
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

    /// One attempt, with every stage written down.
    ///
    /// The stages share failure strings — a connect timeout, a time-refresh
    /// timeout and a PlaySound timeout all say "timed out" — so without naming
    /// the stage, a field report cannot be diagnosed. The notes are the actual
    /// deliverable of the test button; the alarm path sends them to the log.
    private func sendOnePulse(_ label: String, notes: inout [String]) -> PulseOutcome {
        let wasConnected = bluetooth.isConnected
        if let error = ensureConnectedAndAuthenticated() {
            notes.append("\(label): could not connect and authenticate — \(error.localizedDescription)")
            return .failed(error)
        }
        notes.append(wasConnected
            ? "\(label): link was already up and authenticated"
            : "\(label): connected and authenticated")
        if case let .failure(error) = session.refreshTimeSinceReset() {
            notes.append("\(label): pump time refresh failed — \(error.localizedDescription)")
            return .failed(error)
        }
        switch session.send(TandemPlaySoundRequest()) {
        case let .success(response):
            if response.status != 0 {
                notes.append("\(label): PlaySound refused, status \(Int(response.status))")
                return .refused(String(localized: "status \(Int(response.status))"))
            }
            // Status 0 is pumpX2's documented success. It says the pump ACCEPTED
            // the command, not that anything was audible: PlaySound has no
            // volume of its own and follows the pump's Sound settings.
            notes.append("\(label): PlaySound ACCEPTED (status 0)")
            return .accepted
        case let .failure(error):
            if case let .pumpRejected(refusal) = error {
                notes.append("\(label): PlaySound refused — \(refusal.localizedDescription)")
                return .refused(refusal.localizedDescription)
            }
            notes.append("\(label): PlaySound got no answer — \(error.localizedDescription)")
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
    ///
    /// A pump that was just dropped on purpose can be slow to take the next
    /// connection, so the reconnect gets a second attempt before giving up —
    /// the first field run of this path ended in a bare connect timeout that
    /// swallowed the far more informative refusal before it.
    private func reauthenticateOverFreshLink(notes: inout [String]) -> TandemSessionError? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        let started = Date.now
        bluetooth.disconnect()
        var waited: TimeInterval = 0
        while bluetooth.isConnected, waited < 10 {
            Thread.sleep(forTimeInterval: 0.2)
            waited += 0.2
        }
        notes.append(bluetooth.isConnected
            ? "re-key: link did NOT drop within 10s of disconnecting"
            : String(format: "re-key: link dropped after %.1fs", waited))

        var lastError: TandemSessionError = .notConnected
        for attempt in 1 ... 2 {
            if let error = ensureConnectedAndAuthenticated() {
                notes.append("re-key: reconnect attempt \(attempt) failed — \(error.localizedDescription)")
                lastError = error
                continue
            }
            if case let .failure(error) = session.refreshTimeSinceReset() {
                notes.append("re-key: time refresh after reconnect failed — \(error.localizedDescription)")
                lastError = error
                continue
            }
            notes.append(String(
                format: "re-key: reconnected and re-keyed, %.1fs total",
                Date.now.timeIntervalSince(started)
            ))
            return nil
        }
        return lastError
    }

    /// What the pump says about itself right after a refusal, for the log and
    /// for the test button's result. One line, cheap unsigned reads only.
    ///
    /// The sound modes are in here because they are the leading suspect: the
    /// pump has refused `PlaySound` with a valid signature, insulin running and
    /// no alarms, and a Mobi set to vibrate-everything may simply decline to
    /// play a speaker tone. Whether that is true is exactly what one field
    /// report of this line answers.
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
        if case let .success(globals) = session.send(TandemPumpGlobalsRequest()) {
            parts.append(String(localized: "sounds: \(globals.localizedSoundSummary)"))
        }
        return parts.isEmpty ? String(localized: "no state reading") : parts.joined(separator: ", ")
    }

    private func suppressAnnunciations(reason: String) {
        state.annunciationRefusedUntil = Date.now
            .addingTimeInterval(TandemPumpState.annunciationRefusalSuppression)
        log.error("PlaySound refused after a fresh handshake (\(reason)); pausing annunciations for an hour")
        notifyStateDidChange()
    }

    /// Play one burst and schedule the next. commandQueue only.
    ///
    /// Three different "no"s get three different treatments:
    /// - a refusal while a burst is (or may be) still playing is the pump's
    ///   pacing, so the same burst is retried on a short cadence;
    /// - a refusal on a pattern that has not produced a single burst gets ONE
    ///   fresh-handshake retry (the stale-signing-key cure), and only if that
    ///   also fails does the hour-long suppression arm — a pattern that has
    ///   already sounded must NEVER suppress alarms just because its last
    ///   burst landed in a busy window;
    /// - a transport failure stops the pattern quietly.
    private func playAnnunciationBurst(remaining: Int, anyPlayed: Bool, canRekey: Bool, busyRetries: Int) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        guard remaining > 0 else { return }

        var notes: [String] = []
        defer {
            for note in notes { log.info("Annunciation \(note)") }
        }
        switch sendOnePulse("burst", notes: &notes) {
        case .accepted:
            guard remaining > 1 else { return }
            commandQueue.asyncAfter(deadline: .now() + TandemAnnunciationPattern.interBurstDelay) { [weak self] in
                self?.playAnnunciationBurst(
                    remaining: remaining - 1,
                    anyPlayed: true,
                    canRekey: false,
                    busyRetries: TandemAnnunciationPattern.maxBusyRetries
                )
            }
        case let .refused(reason):
            if busyRetries > 0 {
                commandQueue.asyncAfter(deadline: .now() + TandemAnnunciationPattern.busyRetryDelay) { [weak self] in
                    self?.playAnnunciationBurst(
                        remaining: remaining,
                        anyPlayed: anyPlayed,
                        canRekey: canRekey,
                        busyRetries: busyRetries - 1
                    )
                }
                return
            }
            if anyPlayed {
                // The pattern sounded; losing a tail burst to a stubborn busy
                // window is a cosmetic miss, not a reason to disarm alarms.
                log.error("Annunciation ended \(remaining) burst(s) early: still refused (\(reason))")
                return
            }
            guard canRekey else {
                suppressAnnunciations(reason: reason)
                return
            }
            if let error = reauthenticateOverFreshLink(notes: &notes) {
                log.error("Annunciation stopped: re-key failed (\(error.localizedDescription))")
                return
            }
            playAnnunciationBurst(
                remaining: remaining,
                anyPlayed: false,
                canRekey: false,
                busyRetries: TandemAnnunciationPattern.maxBusyRetries
            )
        case .failed:
            return
        }
    }

    /// Play a pattern from the settings screen so the user can hear (or feel)
    /// the difference between the two before relying on it.
    ///
    /// This is a PROBE, not just a button: it records every stage with its
    /// outcome and hands the whole transcript back on any failure. A refusal on
    /// the first burst gets a few short "the pump may still be playing the last
    /// sound" retries, then one fresh-handshake retry, before it is treated as
    /// real. Success completes once the FIRST burst is accepted; the rest of
    /// the pattern plays on behind it, paced by the pump's own busy answers.
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
            let started = Date.now
            var notes: [String] = []

            func finish(_ error: TandemAnnunciationError?) {
                let stamp = String(format: "%.1fs", Date.now.timeIntervalSince(started))
                notes.append("done at \(stamp)")
                for note in notes { self.log.info("Annunciation test \(note)") }
                completion(error)
            }

            var outcome = self.sendOnePulse("attempt 1", notes: &notes)

            // A refusal right after another sound — a double-tapped test, an
            // alarm burst still playing — is the pump's pacing. Give it a few
            // short waits before treating the refusal as real.
            var busyRetries = 3
            while case .refused = outcome, busyRetries > 0 {
                notes.append("waiting — the pump refuses while a sound is still playing")
                Thread.sleep(forTimeInterval: TandemAnnunciationPattern.busyRetryDelay)
                busyRetries -= 1
                outcome = self.sendOnePulse("busy retry", notes: &notes)
            }

            if case .accepted = outcome {} else {
                // Whatever went wrong, note what the pump says about itself
                // while we are still on the original link — unsigned reads
                // work even when signing is what broke.
                if case .refused = outcome {
                    notes.append("pump state: \(self.annunciationPumpContext())")
                }
                if let error = self.reauthenticateOverFreshLink(notes: &notes) {
                    finish(TandemAnnunciationError.probeFailed(
                        transcript: notes.joined(separator: "\n"),
                        finalProblem: error.localizedDescription
                    ))
                    return
                }
                outcome = self.sendOnePulse("attempt 2", notes: &notes)
            }

            switch outcome {
            case .accepted:
                // The first burst proves the pump accepts the command; the rest
                // of the pattern is best effort, paced by the pump.
                self.state.lastAnnunciationAt = Date.now
                if pattern.bursts > 1 {
                    self.commandQueue.asyncAfter(
                        deadline: .now() + TandemAnnunciationPattern.interBurstDelay
                    ) { [weak self] in
                        self?.playAnnunciationBurst(
                            remaining: pattern.bursts - 1,
                            anyPlayed: true,
                            canRekey: false,
                            busyRetries: TandemAnnunciationPattern.maxBusyRetries
                        )
                    }
                }
                finish(nil)
            case let .refused(reason):
                notes.append("pump state: \(self.annunciationPumpContext())")
                self.suppressAnnunciations(reason: reason)
                finish(TandemAnnunciationError.probeFailed(
                    transcript: notes.joined(separator: "\n"),
                    finalProblem: reason
                ))
            case let .failed(error):
                finish(TandemAnnunciationError.probeFailed(
                    transcript: notes.joined(separator: "\n"),
                    finalProblem: error.localizedDescription
                ))
            }
        }
    }
}

enum TandemAnnunciationError: LocalizedError {
    case notEnabled
    /// The probe did not end in an accepted pulse. The transcript names every
    /// stage with its outcome and timing — which is the point: a connect
    /// timeout, a time-refresh timeout and an unanswered PlaySound all used to
    /// collapse into one indistinguishable "timed out".
    case probeFailed(transcript: String, finalProblem: String)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return String(localized: "Buzzing the pump for glucose alarms is turned off.")
        case let .probeFailed(transcript, finalProblem):
            return String(
                localized: "The test did not get a sound out of the pump: \(finalProblem)\n\nWhat happened, step by step:\n\(transcript)"
            )
        }
    }
}
