import Combine
import CoreData
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
        /// ALL storage — ISF, CR, delivery caps, delivery limits, TDD history,
        /// basal profile — is rescaled unconditionally first: the loop reads
        /// these files, so they must stay mutually consistent even when the
        /// pump is unreachable. Pump programming (basal schedule, delivery
        /// limits) is attempted afterwards; failures come back as warning
        /// strings rather than throws so a partial pump failure can never
        /// leave storage half-rescaled.
        func rescaleTherapySettings(_ rescale: InsulinConcentrationRescale) async -> [String] {
            var warnings = rescaleStorage(rescale)
            guard !rescale.isIdentity else { return warnings }
            if let tddWarning = await rescale.rescaleTDDHistory() {
                warnings.append(tddWarning)
            }
            warnings.append(contentsOf: await programPump())
            return warnings
        }

        /// The storage half of the migration: every volume-unit file rescaled
        /// in place, synchronously. It must not be queued behind pump I/O —
        /// until it runs, the stored files and the concentration setting
        /// disagree and every real value derived from them is off by the
        /// factor. TDD history and pump programming follow asynchronously.
        func rescaleStorage(_ rescale: InsulinConcentrationRescale) -> [String] {
            guard !rescale.isIdentity else { return [] }
            var warnings: [String] = []

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
                DispatchQueue.main.async {
                    self.broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) {
                        $0.insulinSensitivitiesDidChange(rescaled)
                    }
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
                DispatchQueue.main.async {
                    self.broadcaster.notify(CarbRatiosObserver.self, on: .main) {
                        $0.carbRatiosDidChange(rescaled)
                    }
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

            // Delivery limits: storage first (unconditionally), pump second.
            let storedLimits = settings()
            let rescaledLimits = PumpSettings(
                insulinActionCurve: storedLimits.insulinActionCurve,
                maxBolus: storedLimits.maxBolus * rescale.amountScale,
                maxBasal: storedLimits.maxBasal * rescale.amountScale
            )
            storage.save(rescaledLimits, as: OpenAPS.Settings.settings)
            let broadcastLimits = rescaledLimits
            processQueue.async {
                self.broadcaster.notify(PumpSettingsObserver.self, on: self.processQueue) {
                    $0.pumpSettingsDidChange(broadcastLimits)
                }
            }

            // Basal profile: pumped units per hour. Rescale exactly, snap to
            // the pump's supported rates via the loss-free string path, and
            // flag any slot the pump grid visibly clamps or floors to zero.
            let pump = deviceManager?.pumpManager
            let profile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
            var clampedSlots: [String] = []
            var rescaledProfile: [BasalProfileEntry] = []
            if profile.isNotEmpty {
                rescaledProfile = profile.map { entry -> BasalProfileEntry in
                    let target = entry.rate * rescale.amountScale
                    var rate = target
                    if let pump = pump {
                        // .decimal converts through the value's string form, so no
                        // binary Double noise lands in the stored profile.
                        rate = pump.roundToSupportedBasalRate(unitsPerHour: Double(target)).decimal ?? target
                    }
                    if (rate == 0 && target > 0) || abs(rate - target) > Decimal(0.1) {
                        clampedSlots.append("\(entry.start): \(target) → \(rate) U/hr")
                    }
                    return BasalProfileEntry(start: entry.start, minutes: entry.minutes, rate: rate)
                }
                storage.save(rescaledProfile, as: OpenAPS.Settings.basalProfile)
                let broadcastProfile = rescaledProfile
                DispatchQueue.main.async {
                    self.broadcaster.notify(BasalProfileObserver.self, on: .main) {
                        $0.basalProfileDidChange(broadcastProfile)
                    }
                }
            }

            if clampedSlots.isNotEmpty {
                warnings.append(String(
                    localized: "The pump cannot deliver some rescaled basal rates and they were clamped: \(clampedSlots.joined(separator: ", ")). Review your basal profile."
                ))
            }

            return warnings
        }

        /// Pushes the currently stored basal schedule and delivery limits to
        /// the pump. Storage is never modified on failure — only the pump's
        /// own fallback programming can be stale, and every failure comes back
        /// as a user-facing warning string so it can be retried.
        func programPump() async -> [String] {
            guard let pump = deviceManager?.pumpManager else {
                return [String(
                    localized: "No pump is connected, so the pump's fallback basal schedule and delivery limits still use the previous concentration."
                )]
            }

            var warnings: [String] = []

            let profile = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
            if profile.isNotEmpty {
                let syncValues = profile.map {
                    RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
                }
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        pump.syncBasalRateSchedule(items: syncValues) { result in
                            switch result {
                            case .success:
                                continuation.resume()
                            case let .failure(error):
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                } catch {
                    warnings.append(String(
                        localized: "Re-programming the pump's basal schedule failed: \(error.localizedDescription)"
                    ))
                }
            }

            // The pump has the last word on delivery limits: save(settings:)
            // persists whatever the pump reports back. Some pumps ignore the
            // request entirely and return their own hardware configuration
            // (Dana), others clamp to a hardware ceiling (Medtronic). That is
            // the truth about what will actually be enforced, but it silently
            // undoes a concentration rescale — so compare and say so.
            let intended = settings()
            do {
                for try await _ in save(settings: intended).values { break }
                let applied = settings()
                if applied.maxBolus != intended.maxBolus || applied.maxBasal != intended.maxBasal {
                    warnings.append(String(
                        localized: "The pump would not accept the rescaled delivery limits and kept its own: Maximum Bolus \(applied.maxBolus) U and Maximum Basal Rate \(applied.maxBasal) U/hr in pumped units. Check that these still match the therapy you intend."
                    ))
                }
            } catch {
                warnings.append(String(
                    localized: "Re-programming the pump's delivery limits failed: \(error.localizedDescription)"
                ))
            }

            return warnings
        }
    }
}
