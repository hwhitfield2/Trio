import Foundation
import LoopKit

/// Setting the pump's sound level from Trio.
///
/// A Mobi has no screen, and cannot run the Tandem app while Trio is its
/// controller, so Trio is the *only* place its sound level can be changed. This
/// is what makes the pump's own alarms — and Trio's `PlaySound` annunciations,
/// which have no volume of their own and follow the pump's setting — actually
/// audible.
enum TandemPumpSoundError: LocalizedError {
    case notConnected(String)
    case rejected(UInt8)
    case didNotTake(requested: TandemAnnunciationMode, got: TandemAnnunciationMode)
    case couldNotReadBack

    var errorDescription: String? {
        switch self {
        case let .notConnected(why):
            return "Could not reach the pump to change its sound level: \(why)"
        case let .rejected(status):
            return "The pump refused the sound change (status \(status))."
        case let .didNotTake(requested, got):
            return "Trio asked for \(requested.localizedDescription) but the pump still reports \(got.localizedDescription). Try again."
        case .couldNotReadBack:
            return "The pump accepted the change, but Trio could not read the setting back to confirm it. Check with Read pump data."
        }
    }
}

/// A pump sound category whose level Trio can *set*.
///
/// Only these five are writable: `SetPumpSounds` has no field for the pump's
/// **button** or **fill-tubing** sounds, so those are read-only — the pump
/// reports them but nothing can change them remotely.
enum TandemSoundCategory: String, CaseIterable, Identifiable {
    case bolus
    case reminder
    case alert
    case alarm
    case quickBolus

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .bolus: return String(localized: "Bolus")
        case .reminder: return String(localized: "Reminder")
        case .alert: return String(localized: "Alert")
        case .alarm: return String(localized: "Alarm")
        case .quickBolus: return String(localized: "Quick bolus")
        }
    }

    /// The change-bitmask bit that tells the pump this category is being written.
    var changeBit: TandemSetPumpSoundsRequest.Categories {
        switch self {
        case .bolus: return .general
        case .reminder: return .reminder
        case .alert: return .alert
        case .alarm: return .alarm
        case .quickBolus: return .quickBolus
        }
    }

    /// This category's current level from a PumpGlobals read. `SetPumpSounds`
    /// calls the bolus level "general", but PumpGlobals reads it as `bolus`.
    func currentLevel(from globals: TandemPumpGlobalsResponse) -> UInt8 {
        switch self {
        case .bolus: return globals.bolusAnnunId
        case .reminder: return globals.reminderAnnunId
        case .alert: return globals.alertAnnunId
        case .alarm: return globals.alarmAnnunId
        case .quickBolus: return globals.quickBolusAnnunId
        }
    }
}

extension TandemPumpManager {
    /// Read the pump's full sound configuration for display, off the BLE queue.
    /// Completion is delivered on the main queue.
    func readPumpSoundConfig(completion: @escaping (TandemPumpGlobalsResponse?) -> Void) {
        commandQueue.async { [weak self] in
            guard let self else { return }
            if self.ensureConnectedAndAuthenticated() != nil {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let globals = self.readPumpGlobals()
            DispatchQueue.main.async { completion(globals) }
        }
    }

    /// Set the level of one or more sound categories. Read-modify-write: it reads
    /// the current settings so untargeted categories keep their values, writes
    /// the chosen levels to the ones in `desired`, and confirms by reading back —
    /// each changed category must actually report its new level, because the
    /// pump can accept a change and not apply it.
    ///
    /// Signed but non-delivery, so it needs no bolus opt-in — the same footing
    /// as `PlaySound`. Runs on `commandQueue`; connects if it has to.
    func setPumpSoundLevels(
        _ desired: [TandemSoundCategory: TandemAnnunciationMode],
        completion: @escaping ((any LocalizedError)?) -> Void
    ) {
        commandQueue.async { [weak self] in
            guard let self else { return }
            guard !desired.isEmpty else {
                self.finishSound(completion, nil)
                return
            }

            if let error = self.ensureConnectedAndAuthenticated() {
                self.finishSound(completion, TandemPumpSoundError.notConnected(error.localizedDescription))
                return
            }

            // Read current settings so untargeted categories are preserved even
            // if the pump were to ignore the change bitmask.
            guard let current = self.readPumpGlobals() else {
                self.finishSound(completion, TandemPumpSoundError.couldNotReadBack)
                return
            }

            // Signing needs a fresh time reference.
            if case let .failure(error) = self.session.refreshTimeSinceReset() {
                self.finishSound(completion, TandemPumpSoundError.notConnected(error.localizedDescription))
                return
            }

            func level(_ category: TandemSoundCategory) -> UInt8 {
                desired[category]?.rawValue ?? category.currentLevel(from: current)
            }
            let mask = desired.keys.reduce(UInt8(0)) { $0 | $1.changeBit.rawValue }

            let request = TandemSetPumpSoundsRequest(
                quickBolus: level(.quickBolus),
                general: level(.bolus),
                reminder: level(.reminder),
                alert: level(.alert),
                alarm: level(.alarm),
                cgmAlertA: 0,
                cgmAlertB: 0,
                changeBitmask: mask
            )

            switch self.session.send(request) {
            case let .success(response):
                guard response.status == 0 else {
                    self.finishSound(completion, TandemPumpSoundError.rejected(response.status))
                    return
                }
            case let .failure(error):
                self.finishSound(completion, TandemPumpSoundError.notConnected(error.localizedDescription))
                return
            }

            // The read-back is the verdict — every changed category must report
            // the level we asked for.
            guard let after = self.readPumpGlobals() else {
                self.finishSound(completion, TandemPumpSoundError.couldNotReadBack)
                return
            }
            for (category, mode) in desired where category.currentLevel(from: after) != mode.rawValue {
                let got = TandemAnnunciationMode(rawValue: category.currentLevel(from: after)) ?? .vibrate
                self.finishSound(completion, TandemPumpSoundError.didNotTake(requested: mode, got: got))
                return
            }

            let summary = desired
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value.localizedDescription)" }
                .joined(separator: ", ")
            self.log.info("Pump sound levels updated: \(summary)")
            self.notifyStateDidChange()
            self.finishSound(completion, nil)
        }
    }

    /// Convenience: set alarm, alert and reminder to one level together.
    func setPumpSoundMode(
        _ mode: TandemAnnunciationMode,
        completion: @escaping ((any LocalizedError)?) -> Void
    ) {
        setPumpSoundLevels([.reminder: mode, .alert: mode, .alarm: mode], completion: completion)
    }

    /// Read the pump's current sound configuration, unsigned and cheap.
    func readPumpGlobals() -> TandemPumpGlobalsResponse? {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        switch session.send(TandemPumpGlobalsRequest()) {
        case let .success(response):
            return response
        case let .failure(error):
            log.error("PumpGlobals read failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func finishSound(_ completion: @escaping ((any LocalizedError)?) -> Void, _ error: (any LocalizedError)?) {
        DispatchQueue.main.async { completion(error) }
    }
}
