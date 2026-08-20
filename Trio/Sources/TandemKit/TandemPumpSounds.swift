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

extension TandemPumpManager {
    /// The categories Trio's sound control governs: the ones that make alarms,
    /// alerts and reminders — and Trio's own annunciations — audible. Quick-bolus
    /// and CGM-alert sounds are left as the pump has them.
    private static let soundCategories: TandemSetPumpSoundsRequest.Categories =
        [.reminder, .alert, .alarm]

    /// Set the pump's alarm/alert/reminder sound level. Read-modify-write: it
    /// reads the current settings so the categories it is *not* changing keep
    /// their values, writes the chosen level to the ones it is, and confirms by
    /// reading back.
    ///
    /// Signed but non-delivery, so it needs no bolus opt-in — the same footing
    /// as `PlaySound`. Runs on `commandQueue`; connects if it has to.
    func setPumpSoundMode(
        _ mode: TandemAnnunciationMode,
        completion: @escaping ((any LocalizedError)?) -> Void
    ) {
        commandQueue.async { [weak self] in
            guard let self else { return }

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

            let level = mode.rawValue
            let request = TandemSetPumpSoundsRequest(
                quickBolus: current.quickBolusAnnunId,
                general: current.bolusAnnunId,
                reminder: level,
                alert: level,
                alarm: level,
                cgmAlertA: 0,
                cgmAlertB: 0,
                changeBitmask: Self.soundCategories.rawValue
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

            // The read-back is the verdict — the pump can accept and not apply.
            guard let after = self.readPumpGlobals() else {
                self.finishSound(completion, TandemPumpSoundError.couldNotReadBack)
                return
            }
            let got = TandemAnnunciationMode(rawValue: after.alarmAnnunId) ?? .vibrate
            if after.alarmAnnunId == level {
                self.log.info("Pump sound level set to \(mode.localizedDescription)")
                self.notifyStateDidChange()
                self.finishSound(completion, nil)
            } else {
                self.finishSound(completion, TandemPumpSoundError.didNotTake(requested: mode, got: got))
            }
        }
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
