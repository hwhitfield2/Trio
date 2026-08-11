import Combine
import SwiftUI

extension UnitsLimitsSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var settings: SettingsManager!
        @Injected() var storage: FileStorage!
        @Injected() private var tidepoolManager: TidepoolManager!
        @Injected() private var nightscout: NightscoutManager!

        @Published var units: GlucoseUnits = .mgdL
        @Published var unitsIndex = 0 // index 0 is mg/dl

        // Displayed in actual insulin units; stored in pumped volume units.
        @Published var maxBolus: Decimal = 10
        @Published var maxBasal: Decimal = 2
        @Published var maxIOB: Decimal = 0
        @Published var maxCOB: Decimal = 120
        @Published var hasChanged: Bool = false
        @Published var threshold_setting: Decimal = 60
        @Published var allowDilution: Bool = false
        @Published var insulinConcentrationOption: InsulinConcentrationOption = .u100
        @Published var concentrationSyncMessage: String?

        /// Concentration factor the stored therapy settings are currently
        /// scaled for; changing the effective concentration rescales them.
        private var lastAppliedConcentration: Decimal?

        /// The setting subscriptions replay the stored values synchronously on
        /// subscribe; only user-driven toggles may default the concentration
        /// or trigger a rescale.
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

            subscribePreferencesSetting(\.maxIOB, on: $maxIOB, initial: {
                maxIOB = settingsManager.settings.realInsulinAmount(fromVolume: $0)
            }, map: { [weak self] realValue in
                self?.settingsManager.settings.volumeInsulinAmount(fromReal: realValue) ?? realValue
            })
            subscribePreferencesSetting(\.maxCOB, on: $maxCOB) { maxCOB = $0 }
            subscribePreferencesSetting(\.threshold_setting, on: $threshold_setting) { threshold_setting = $0 }

            refreshDisplayedPumpLimits()

            lastAppliedConcentration = settingsManager.settings.insulinConcentrationFactorDecimal

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

        /// Picker grids for the insulin-denominated limits in actual insulin
        /// units — the grids get proportionally finer under dilution so values
        /// like a real Max IOB of 1.5 U stay selectable.
        var maxIOBPickerSetting: PickerSetting {
            scaledToReal(PickerSettingsProvider.shared.settings.maxIOB)
        }

        var maxBolusPickerSetting: PickerSetting {
            scaledToReal(PickerSettingsProvider.shared.settings.maxBolus)
        }

        var maxBasalPickerSetting: PickerSetting {
            scaledToReal(PickerSettingsProvider.shared.settings.maxBasal)
        }

        private func scaledToReal(_ setting: PickerSetting) -> PickerSetting {
            var setting = setting
            let settings = settingsManager.settings
            setting.value = settings.realInsulinAmount(fromVolume: setting.value)
            setting.step = settings.realInsulinAmount(fromVolume: setting.step)
            setting.min = settings.realInsulinAmount(fromVolume: setting.min)
            setting.max = settings.realInsulinAmount(fromVolume: setting.max)
            return setting
        }

        private func refreshDisplayedPumpLimits() {
            let stored = provider.settings()
            maxBasal = settingsManager.settings.realInsulinAmount(fromVolume: stored.maxBasal)
            maxBolus = settingsManager.settings.realInsulinAmount(fromVolume: stored.maxBolus)
        }

        /// Rescales every stored (volume-unit) therapy setting for the new
        /// concentration so its real-insulin meaning is preserved, and
        /// re-programs the pump (basal schedule, delivery limits).
        private func handleConcentrationChange() {
            guard !isReplayingStoredSettings else { return }
            let newFactor = settingsManager.settings.insulinConcentrationFactorDecimal
            guard let oldFactor = lastAppliedConcentration, oldFactor != newFactor else { return }
            lastAppliedConcentration = newFactor

            let rescale = InsulinConcentrationRescale(from: oldFactor, to: newFactor)

            // Max IOB (preferences) — displayed real value is invariant.
            var prefs = settingsManager.preferences
            prefs.maxIOB *= rescale.amountScale
            settingsManager.preferences = prefs

            // Pump delivery limits — the existing save path also syncs the pump.
            let stored = provider.settings()
            let rescaledLimits = PumpSettings(
                insulinActionCurve: stored.insulinActionCurve,
                maxBolus: stored.maxBolus * rescale.amountScale,
                maxBasal: stored.maxBasal * rescale.amountScale
            )

            Task { @MainActor in
                var syncErrors: [String] = []

                do {
                    try await provider.rescaleTherapySettings(rescale)
                } catch {
                    syncErrors.append(error.localizedDescription)
                }

                do {
                    for try await _ in provider.save(settings: rescaledLimits).values { break }
                } catch {
                    syncErrors.append(error.localizedDescription)
                }

                refreshDisplayedPumpLimits()

                if syncErrors.isEmpty {
                    concentrationSyncMessage = nil
                } else {
                    concentrationSyncMessage = String(
                        localized: "Updating the pump for the new insulin concentration failed: \(syncErrors.joined(separator: " ")) Do not rely on automated dosing until you have re-saved your basal profile and delivery limits with the pump connected."
                    )
                }

                // The loop reads the rescaled profile files on its next cycle;
                // the observer broadcasts above cover in-memory listeners.
                Task.detached(priority: .low) {
                    do {
                        try await self.nightscout.uploadProfiles()
                    } catch {
                        debug(.nightscout, "Failed to upload profiles after concentration change: \(error)")
                    }
                }
                Task.detached(priority: .low) {
                    await self.tidepoolManager.uploadSettings()
                }
            }
        }

        var isPumpSettingUnchanged: Bool {
            let stored = provider.settings()
            return settingsManager.settings.realInsulinAmount(fromVolume: stored.maxBasal) == maxBasal &&
                settingsManager.settings.realInsulinAmount(fromVolume: stored.maxBolus) == maxBolus
        }

        func saveIfChanged() {
            if !isPumpSettingUnchanged {
                let settings = PumpSettings(
                    insulinActionCurve: pumpSettings.insulinActionCurve,
                    maxBolus: settingsManager.settings.volumeInsulinAmount(fromReal: maxBolus),
                    maxBasal: settingsManager.settings.volumeInsulinAmount(fromReal: maxBasal)
                )
                provider.save(settings: settings)
                    .receive(on: DispatchQueue.main)
                    .sink { _ in
                        self.refreshDisplayedPumpLimits()

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
