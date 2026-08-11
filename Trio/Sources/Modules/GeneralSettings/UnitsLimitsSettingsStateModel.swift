import Combine
import SwiftUI

extension UnitsLimitsSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var settings: SettingsManager!
        @Injected() var storage: FileStorage!
        @Injected() private var tidepoolManager: TidepoolManager!

        @Published var units: GlucoseUnits = .mgdL
        @Published var unitsIndex = 0 // index 0 is mg/dl

        @Published var maxBolus: Decimal = 10
        @Published var maxBasal: Decimal = 2
        @Published var maxIOB: Decimal = 0
        @Published var maxCOB: Decimal = 120
        @Published var hasChanged: Bool = false
        @Published var threshold_setting: Decimal = 60
        @Published var allowDilution: Bool = false
        @Published var insulinConcentrationOption: InsulinConcentrationOption = .u100
        @Published var concentrationSyncMessage: String?

        /// Insulin concentration the pump was last (re)programmed for; used to
        /// re-sync the pump only when the effective concentration truly changes.
        private var lastSyncedConcentration: Double?

        /// The setting subscriptions replay the stored values synchronously on
        /// subscribe; only user-driven toggles may default the concentration.
        private var isReplayingStoredSettings = true

        var preferences: Preferences {
            settingsManager.preferences
        }

        var pumpSettings: PumpSettings {
            provider.settings()
        }

        override func subscribe() {
            units = settingsManager.settings.units
            subscribeSetting(\.units, on: $unitsIndex.map { $0 == 0 ? GlucoseUnits.mgdL : .mmolL }) {
                unitsIndex = $0 == .mgdL ? 0 : 1
            }

            subscribePreferencesSetting(\.maxIOB, on: $maxIOB) { maxIOB = $0 }
            subscribePreferencesSetting(\.maxCOB, on: $maxCOB) { maxCOB = $0 }
            subscribePreferencesSetting(\.threshold_setting, on: $threshold_setting) { threshold_setting = $0 }

            maxBasal = pumpSettings.maxBasal
            maxBolus = pumpSettings.maxBolus

            lastSyncedConcentration = settingsManager.settings.insulinConcentrationFactor

            subscribeSetting(\.allowDilution, on: $allowDilution, initial: {
                allowDilution = $0
            }, didSet: { [weak self] enabled in
                guard let self else { return }
                if enabled, !self.isReplayingStoredSettings,
                   self.settingsManager.settings.insulinConcentration >= 1
                {
                    // Enabling dilution while U-100 is stored would be a no-op;
                    // default to U-10 (the picker reflects this immediately).
                    self.insulinConcentrationOption = .u10
                }
                self.handleConcentrationChange()
            })

            subscribeSetting(\.insulinConcentration, on: $insulinConcentrationOption.map(\.factor), initial: {
                insulinConcentrationOption = InsulinConcentrationOption(factor: $0)
            }, didSet: { [weak self] _ in
                self?.handleConcentrationChange()
            })

            isReplayingStoredSettings = false
        }

        /// Re-programs the pump (bolus increment, delivery limits, basal
        /// schedule) whenever the effective insulin concentration changes.
        private func handleConcentrationChange() {
            let factor = settingsManager.settings.insulinConcentrationFactor
            guard factor != lastSyncedConcentration else { return }
            lastSyncedConcentration = factor

            Task { @MainActor in
                do {
                    try await provider.resyncPumpInsulinConcentration()
                    concentrationSyncMessage = nil
                } catch {
                    concentrationSyncMessage = String(
                        localized: "Updating the pump for the new insulin concentration failed: \(error.localizedDescription). Do not rely on automated dosing until you have re-saved your basal profile and delivery limits with the pump connected."
                    )
                }
            }
        }

        var isPumpSettingUnchanged: Bool {
            pumpSettings.maxBasal == maxBasal &&
                pumpSettings.maxBolus == maxBolus
        }

        func saveIfChanged() {
            if !isPumpSettingUnchanged {
                let settings = PumpSettings(
                    insulinActionCurve: pumpSettings.insulinActionCurve,
                    maxBolus: maxBolus,
                    maxBasal: maxBasal
                )
                provider.save(settings: settings)
                    .receive(on: DispatchQueue.main)
                    .sink { _ in
                        let settings = self.provider.settings()
                        self.maxBasal = settings.maxBasal
                        self.maxBolus = settings.maxBolus

                        Task.detached(priority: .low) {
                            await self.tidepoolManager.uploadSettings()
                        }
                    } receiveValue: {}
                    .store(in: &lifetime)
            }
        }
    }
}

extension UnitsLimitsSettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
