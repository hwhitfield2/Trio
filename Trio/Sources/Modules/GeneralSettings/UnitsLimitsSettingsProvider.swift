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
            let limits = DeliveryLimits(
                maximumBasalRate: HKQuantity(unit: .internationalUnitsPerHour, doubleValue: Double(settings.maxBasal)),
                maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: Double(settings.maxBolus))
            )
            return Future { promise in
                self.processQueue.async {
                    pump.syncDeliveryLimits(limits: limits) { result in
                        switch result {
                        case let .success(actual):
                            // Store the limits from the pumpManager to ensure the correct values
                            // Example: Dana pumps don't allow to set these limits, only to fetch them
                            // This will ensure we always have the correct values stored
                            save(PumpSettings(
                                insulinActionCurve: settings.insulinActionCurve,
                                maxBolus: Decimal(
                                    actual.maximumBolus?
                                        .doubleValue(for: .internationalUnit()) ?? Double(settings.maxBolus)
                                ),
                                maxBasal: Decimal(
                                    actual.maximumBasalRate?
                                        .doubleValue(for: .internationalUnitsPerHour) ?? Double(settings.maxBasal)
                                )
                            ))
                            promise(.success(()))
                        case let .failure(error):
                            promise(.failure(error))
                        }
                    }
                }
            }.eraseToAnyPublisher()
        }

        /// Rescales the stored (pump-volume-unit) therapy settings for a new
        /// insulin concentration so their real-insulin meaning is preserved.
        ///
        /// All storage is rescaled unconditionally first — the loop reads these
        /// files, so they must stay mutually consistent even when the pump is
        /// unreachable. The pump's fallback basal schedule is then re-programmed;
        /// a failure there is thrown so the UI can warn the user to re-save the
        /// basal profile with the pump connected.
        func rescaleTherapySettings(_ rescale: InsulinConcentrationRescale) async throws {
            guard !rescale.isIdentity else { return }

            // ISF: mg/dL per pumped unit.
            if let isf = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self) {
                let rescaled = InsulinSensitivities(
                    units: isf.units,
                    userPreferredUnits: isf.userPreferredUnits,
                    sensitivities: isf.sensitivities.map {
                        InsulinSensitivityEntry(
                            sensitivity: $0.sensitivity * rescale.ratioScale,
                            offset: $0.offset,
                            start: $0.start
                        )
                    }
                )
                storage.save(rescaled, as: OpenAPS.Settings.insulinSensitivities)
                broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) {
                    $0.insulinSensitivitiesDidChange(rescaled)
                }
            }

            // Carb ratios: grams per pumped unit.
            if let carbRatios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) {
                let rescaled = CarbRatios(
                    units: carbRatios.units,
                    schedule: carbRatios.schedule.map {
                        CarbRatioEntry(start: $0.start, offset: $0.offset, ratio: $0.ratio * rescale.ratioScale)
                    }
                )
                storage.save(rescaled, as: OpenAPS.Settings.carbRatios)
                broadcaster.notify(CarbRatiosObserver.self, on: .main) {
                    $0.carbRatiosDidChange(rescaled)
                }
            }

            // Scheduled delivery caps: pumped units and pumped units per hour.
            if let caps = storage.retrieve(OpenAPS.Settings.deliveryCaps, as: [DeliveryCapWindow].self) {
                let rescaled = caps.map { window in
                    var window = window
                    window.maxBasalRate *= rescale.amountScale
                    window.maxSMB *= rescale.amountScale
                    return window
                }
                storage.save(rescaled, as: OpenAPS.Settings.deliveryCaps)
            }

            // Autotune output is derived from pump history whose volume units
            // changed meaning at the switch — discard it and let it regenerate.
            storage.remove(OpenAPS.Settings.autotune)

            // Basal profile: pumped units per hour. Rescale, snap to the pump's
            // supported rates, store, then re-program the pump's own schedule.
            let profile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
            guard profile.isNotEmpty else { return }

            let pump = deviceManager?.pumpManager
            let rescaledProfile = profile.map { entry -> BasalProfileEntry in
                var rate = entry.rate * rescale.amountScale
                if let pump = pump {
                    rate = Decimal(pump.roundToSupportedBasalRate(unitsPerHour: Double(rate)))
                }
                return BasalProfileEntry(start: entry.start, minutes: entry.minutes, rate: rate)
            }
            storage.save(rescaledProfile, as: OpenAPS.Settings.basalProfile)
            broadcaster.notify(BasalProfileObserver.self, on: .main) {
                $0.basalProfileDidChange(rescaledProfile)
            }

            guard let connectedPump = pump else {
                throw NSError(
                    domain: "UnitsLimitsSettings",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "No pump is connected, so the pump's fallback basal schedule still uses the previous concentration."
                        )
                    ]
                )
            }

            let syncValues = rescaledProfile.map {
                RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectedPump.syncBasalRateSchedule(items: syncValues) { result in
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
