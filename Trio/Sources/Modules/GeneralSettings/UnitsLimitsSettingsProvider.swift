import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI

protocol PumpSettingsObserver {
    func pumpSettingsDidChange(_ pumpSettings: PumpSettings)
}

extension UnitsLimitsSettings {
    final class Provider: BaseProvider, UnitsLimitsSettingsProvider {
        private let processQueue = DispatchQueue(label: "UnitsLimitsSettingsProvider.processQueue")
        @Injected() private var broadcaster: Broadcaster!
        @Injected() private var settingsManager: SettingsManager!

        func settings() -> PumpSettings {
            storage.retrieve(OpenAPS.Settings.settings, as: PumpSettings.self)
                ?? PumpSettings(from: OpenAPS.defaults(for: OpenAPS.Settings.settings))
                ?? PumpSettings(insulinActionCurve: 10.0, maxBolus: 10, maxBasal: 2)
        }

        func save(settings: PumpSettings) -> AnyPublisher<Void, Error> {
            func save(_ settings: PumpSettings) {
                storage.save(settings, as: OpenAPS.Settings.settings)
                processQueue.async {
                    self.broadcaster.notify(PumpSettingsObserver.self, on: self.processQueue) {
                        $0.pumpSettingsDidChange(settings)
                    }
                }
            }

            guard let pump = deviceManager?.pumpManager else {
                save(settings)
                return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
            }
            // The pump expects limits in volume units; stored limits are actual insulin units.
            let concentration = settingsManager.settings.insulinConcentrationFactor
            let limits = settings.pumpDeliveryLimits(insulinConcentration: concentration)
            return Future { promise in
                self.processQueue.async {
                    pump.syncDeliveryLimits(limits: limits) { result in
                        switch result {
                        case let .success(actual):
                            // Store the limits from the pumpManager to ensure the correct values
                            // Example: Dana pumps don't allow to set these limits, only to fetch them
                            // This will ensure we always have the correct values stored
                            save(settings.applyingPumpReported(limits: actual, insulinConcentration: concentration))
                            promise(.success(()))
                        case let .failure(error):
                            promise(.failure(error))
                        }
                    }
                }
            }.eraseToAnyPublisher()
        }

        /// Re-programs the pump after the insulin concentration setting changed:
        /// the pump meters volume, so its bolus increment, delivery limits and —
        /// critically — its fallback basal schedule (used whenever the loop is
        /// not running) must be rescaled to keep delivering the same actual
        /// insulin. No-op when no pump is paired; pairing a pump re-derives
        /// these values anyway.
        func resyncPumpInsulinConcentration() async throws {
            guard let pump = deviceManager?.pumpManager else { return }
            let concentration = settingsManager.settings.insulinConcentrationFactor

            // Bolus increment preference, in actual insulin units.
            if let volumeIncrement = pump.supportedBolusVolumes.first {
                var preferences = settingsManager.preferences
                let increment = Decimal(volumeIncrement) * settingsManager.settings.insulinConcentrationFactorDecimal
                preferences.bolusIncrement = increment > 0 ? increment : 0.1
                settingsManager.preferences = preferences
            }

            // Delivery limits (converted inside `save`).
            for try await _ in save(settings: settings()).values {
                break
            }

            // Basal schedule, so pump-side scheduled basal delivers the
            // intended actual insulin when the loop is not dictating rates.
            let profile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
            guard !profile.isEmpty else { return }
            let items = profile.map {
                RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate) / concentration)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pump.syncBasalRateSchedule(items: items) { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
