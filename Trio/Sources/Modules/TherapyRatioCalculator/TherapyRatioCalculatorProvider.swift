import Foundation

extension TherapyRatioCalculator {
    final class Provider: BaseProvider, TherapyRatioCalculatorProvider {
        var isfProfile: InsulinSensitivities {
            var retrievedSensitivities = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
                ?? InsulinSensitivities(from: OpenAPS.defaults(for: OpenAPS.Settings.insulinSensitivities))
                ?? InsulinSensitivities(
                    units: .mgdL,
                    userPreferredUnits: .mgdL,
                    sensitivities: []
                )

            // Convert legacy mmol/L profiles to mg/dL in memory only; the persisted
            // migration is owned by the ISF editor and must not happen as a read side effect here.
            if retrievedSensitivities.units == .mmolL || retrievedSensitivities.userPreferredUnits == .mmolL {
                let convertedSensitivities = retrievedSensitivities.sensitivities.map { isf in
                    InsulinSensitivityEntry(
                        sensitivity: storage.parseSettingIfMmolL(value: isf.sensitivity),
                        offset: isf.offset,
                        start: isf.start
                    )
                }
                retrievedSensitivities = InsulinSensitivities(
                    units: .mgdL,
                    userPreferredUnits: .mgdL,
                    sensitivities: convertedSensitivities
                )
            }

            return retrievedSensitivities
        }

        var carbRatios: CarbRatios {
            storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
                ?? CarbRatios(from: OpenAPS.defaults(for: OpenAPS.Settings.carbRatios))
                ?? CarbRatios(units: .grams, schedule: [])
        }

        func saveISFProfile(_ profile: InsulinSensitivities) {
            storage.save(profile, as: OpenAPS.Settings.insulinSensitivities)
        }

        func saveCarbRatios(_ profile: CarbRatios) {
            storage.save(profile, as: OpenAPS.Settings.carbRatios)
        }
    }
}
