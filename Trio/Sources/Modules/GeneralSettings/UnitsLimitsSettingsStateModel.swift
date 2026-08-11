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

        /// Every write to the stored delivery limits — concentration
        /// migrations, retries, and the limits editor's own save — is strictly
        /// serialized through this chain, so each one reads storage only after
        /// the previous has finished (including its multi-second pump sync)
        /// and can never apply its scale to a stale snapshot.
        ///
        /// Type-level, not per-instance: the screen can be left and re-entered
        /// mid-migration, which destroys the StateModel but not the in-flight
        /// work it started.
        @MainActor private static var settingsWriteChain: Task<Void, Never>?

        /// Appends `work` to the serialized chain of stored-limit writes. The
        /// read-modify-write of the chain itself happens on the main actor, so
        /// callers on any queue (setting subscriptions fire wherever the value
        /// was set) enqueue safely and in order.
        private func serialized(_ work: @escaping @MainActor() async -> Void) {
            Task { @MainActor in
                let previous = Self.settingsWriteChain
                Self.settingsWriteChain = Task { @MainActor in
                    await previous?.value
                    await work()
                }
            }
        }

        /// A failed pump re-programming outlives this screen: the warning is
        /// persisted and restored on re-entry until a retry succeeds.
        @Persisted(key: "UnitsLimitsSettings.concentrationSyncWarning") private var persistedSyncWarning: String = ""

        /// Warnings about storage that the last migration produced (clamped
        /// basal rates, a failed TDD rescale). Retrying the pump cannot fix
        /// these, so they are re-emitted rather than cleared.
        @MainActor private var storageWarnings: [String] = []

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

            concentrationSyncMessage = persistedSyncWarning.isEmpty ? nil : persistedSyncWarning

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
        /// The stored values as loaded, NOT the live picker bindings — a grid
        /// whose bounds follow the wheel's own selection ratchets shut as the
        /// user scrolls down.
        private var loadedMaxBolus: Decimal = 0
        private var loadedMaxBasal: Decimal = 0
        private var loadedMaxIOB: Decimal = 0

        var maxIOBPickerSetting: PickerSetting {
            scaledToReal(PickerSettingsProvider.shared.settings.maxIOB, coveringCurrent: loadedMaxIOB)
        }

        var maxBolusPickerSetting: PickerSetting {
            scaledToReal(PickerSettingsProvider.shared.settings.maxBolus, coveringCurrent: loadedMaxBolus)
        }

        var maxBasalPickerSetting: PickerSetting {
            scaledToReal(PickerSettingsProvider.shared.settings.maxBasal, coveringCurrent: loadedMaxBasal)
        }

        /// A concentration rescale preserves the real value, which can exceed
        /// the scaled grid's default ceiling (e.g. real Max Bolus 10 U vs a
        /// U-10 ceiling of 3 U) — extend the grid so the stored value stays
        /// visible and re-selectable instead of silently snapping down.
        private func scaledToReal(_ setting: PickerSetting, coveringCurrent current: Decimal) -> PickerSetting {
            // SwiftUI evaluates `body` — and therefore this grid — before
            // `configureView` sets the resolver that injects settingsManager,
            // so fall back to the unscaled (U-100) grid until it is available.
            guard let settings = settingsManager?.settings else { return setting }
            var setting = setting
            setting.value = settings.realInsulinAmount(fromVolume: setting.value)
            setting.step = settings.realInsulinAmount(fromVolume: setting.step)
            setting.min = settings.realInsulinAmount(fromVolume: setting.min)
            setting.max = settings.realInsulinAmount(fromVolume: setting.max)
            return setting.extended(toCover: current)
        }

        private func refreshDisplayedPumpLimits() {
            let stored = provider.settings()
            maxBasal = settingsManager.settings.realInsulinAmount(fromVolume: stored.maxBasal)
            maxBolus = settingsManager.settings.realInsulinAmount(fromVolume: stored.maxBolus)
            // Snapshot for the picker grids: the ceiling must not follow the
            // wheel's own selection, or scrolling down would ratchet the
            // reachable range shut.
            loadedMaxBasal = maxBasal
            loadedMaxBolus = maxBolus
            loadedMaxIOB = maxIOB
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

            // Max IOB (preferences): synchronous, so consecutive changes
            // compose here the same way the chained file rescales do below.
            var prefs = settingsManager.preferences
            prefs.maxIOB *= rescale.amountScale
            settingsManager.preferences = prefs

            // Rescale storage NOW, not on the chain: the concentration setting
            // has already been written, so until the files follow, every real
            // value derived from them is off by the factor. Only pump
            // programming — which can take tens of seconds over BLE — is queued.
            let storageWarnings = provider.rescaleStorage(rescale)
            refreshDisplayedPumpLimits()

            serialized { [self] in
                var persistentWarnings = storageWarnings
                if let tddWarning = await rescale.rescaleTDDHistory() {
                    persistentWarnings.append(tddWarning)
                }
                // Remembered so a later Retry Pump Sync cannot erase them: they
                // describe storage, which retrying the pump does not touch.
                self.storageWarnings = persistentWarnings
                let pumpWarnings = await provider.programPump()
                finishPumpSync(warnings: persistentWarnings + pumpWarnings)

                // The loop reads the rescaled profile files on its next cycle;
                // the observer broadcasts in the provider cover in-memory listeners.
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

        /// Re-attempts programming the pump (basal schedule + delivery limits)
        /// from the current stored settings after an earlier failure.
        func retryPumpSync() {
            serialized { [self] in
                let warnings = await provider.programPump()
                // A pump retry cannot undo a storage-level problem (a clamped
                // basal rate, a failed TDD rescale), so those warnings survive
                // it — only the pump-programming ones are cleared on success.
                finishPumpSync(warnings: storageWarnings + warnings)
            }
        }

        @MainActor private func finishPumpSync(warnings: [String]) {
            refreshDisplayedPumpLimits()

            if warnings.isEmpty {
                concentrationSyncMessage = nil
                persistedSyncWarning = ""
            } else {
                let message = String(
                    localized: "Updating the pump for the new insulin concentration reported problems: \(warnings.joined(separator: " ")) Do not rely on automated dosing until the pump has been re-programmed — retry below or re-save your basal profile with the pump connected."
                )
                concentrationSyncMessage = message
                persistedSyncWarning = message
            }
        }

        /// Persists the edited limits. The displayed values are actual insulin
        /// units, whose meaning a concentration migration deliberately
        /// preserves, so the conversion to volume — and the comparison against
        /// storage — must happen *after* any queued migration completes,
        /// using the factor and stored values in force by then.
        func saveIfChanged() {
            let desiredRealBolus = maxBolus
            let desiredRealBasal = maxBasal
            let capturedFactor = settingsManager.settings.insulinConcentrationFactorDecimal

            serialized { [self] in
                // A concentration change queued after these values were read
                // has already preserved their real meaning; re-applying them
                // against the new factor would double-count it.
                guard settingsManager.settings.insulinConcentrationFactorDecimal == capturedFactor else { return }

                let currentSettings = settingsManager.settings
                let volumeBolus = currentSettings.volumeInsulinAmount(fromReal: desiredRealBolus)
                let volumeBasal = currentSettings.volumeInsulinAmount(fromReal: desiredRealBasal)
                let stored = provider.settings()
                guard volumeBolus != stored.maxBolus || volumeBasal != stored.maxBasal else { return }

                let settings = PumpSettings(
                    insulinActionCurve: stored.insulinActionCurve,
                    maxBolus: volumeBolus,
                    maxBasal: volumeBasal
                )

                do {
                    for try await _ in provider.save(settings: settings).values { break }
                } catch {
                    debug(.service, "Failed to save delivery limits: \(error)")
                }

                refreshDisplayedPumpLimits()

                Task.detached(priority: .low) {
                    await self.tidepoolManager.uploadSettings()
                }
            }
        }
    }
}

extension UnitsLimitsSettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
