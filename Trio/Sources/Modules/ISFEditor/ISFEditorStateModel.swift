import CoreData
import Observation
import SwiftUI

extension [Decimal] {
    func findClosestIndex(to target: Element) -> Int? {
        guard !isEmpty else { return nil }

        return enumerated().min(by: {
            abs($0.element - target) < abs($1.element - target)
        })?.offset
    }
}

extension ISFEditor {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var determinationStorage: DeterminationStorage!
        @ObservationIgnored @Injected() private var nightscout: NightscoutManager!
        @ObservationIgnored @Injected() private var tidepoolManager: TidepoolManager!
        @ObservationIgnored @Injected() private var broadcaster: Broadcaster!

        var items: [Item] = []
        var initialItems: [Item] = []
        var therapyItems: [TherapySettingItem] = []
        var shouldDisplaySaving: Bool = false

        let context = CoreDataStack.shared.newTaskContext()

        let timeValues = stride(from: 0.0, to: 1.days.timeInterval, by: 30.minutes.timeInterval).map { $0 }

        /// Sensitivities are mg/dL per *pumped* unit, so the grid is the
        /// clinical (per-actual-unit) tiers scaled by the concentration: a
        /// prescription of 50 mg/dL/U has to stay settable at every
        /// concentration, and at U-10 that is a stored 5.0 — far below the
        /// undiluted grid's floor of 9. Scaling keeps exactly the set of stored
        /// values the editor could round-trip before, so a rescale can never
        /// push a schedule off the grid and snap it to the minimum.
        var rateValues: [Decimal] {
            let settingsProvider = PickerSettingsProvider.shared
            let factor = settingsManager?.settings.insulinConcentrationFactorDecimal ?? 1
            // Max raised to 7200 mg/dL/U to support very-low-dose therapy regimens,
            // e.g. LADA/type 1.5 with substantial residual insulin production
            // (paired with carb ratios up to 2000 g/U). Tiered step sizes keep the
            // picker wheel responsive across that range: fine steps where typical
            // values live, coarser steps above, where the relative difference
            // between neighboring steps stays small.
            let segments: [PickerSetting] = [
                PickerSetting(value: 100, step: 1, min: 9, max: 399, type: .glucose),
                PickerSetting(value: 400, step: 5, min: 400, max: 795, type: .glucose),
                PickerSetting(value: 800, step: 10, min: 800, max: 1190, type: .glucose),
                PickerSetting(value: 1200, step: 25, min: 1200, max: 3575, type: .glucose),
                PickerSetting(value: 3600, step: 50, min: 3600, max: 7200, type: .glucose)
            ]
            // Diluted grids are finer, so the mmol/L de-duplication has to key
            // on more decimals or it would collapse the whole wheel.
            let mmolDecimals = factor >= 1 ? 1 : (factor >= Decimal(0.1) ? 2 : 3)
            return segments.flatMap { segment -> [Decimal] in
                var scaled = segment
                scaled.value *= factor
                scaled.step *= factor
                scaled.min *= factor
                scaled.max *= factor
                return settingsProvider.generatePickerValues(from: scaled, units: units, mmolDecimals: mmolDecimals)
            }
        }

        /// The per-actual-unit ISF a shown per-pumped-unit value corresponds
        /// to, for the caption under each row. nil at U-100.
        ///
        /// Sensitivities are stored in mg/dL whatever the user's display unit,
        /// so the caption must be converted before it is labelled — otherwise a
        /// mmol/L user reads a mg/dL number tagged "mmol/L", wrong by 18x.
        func actualInsulinCaption(forVolumeRatio ratio: Decimal) -> String? {
            let displayRatio = units == .mmolL ? ratio.asMmolL : ratio
            return settingsManager?.settings.actualInsulinCaption(
                forVolumeRatio: displayRatio,
                unit: units.rawValue
            )
        }

        var canAdd: Bool {
            guard let lastItem = items.last else { return true }
            return lastItem.timeIndex < timeValues.count - 1
        }

        var hasChanges: Bool {
            initialItems != items
        }

        private(set) var units: GlucoseUnits = .mgdL

        // Convert items to TherapySettingItem format
        func getTherapyItems() -> [TherapySettingItem] {
            items.map { item in
                TherapySettingItem(
                    time: timeValues[item.timeIndex],
                    value: rateValues[item.rateIndex]
                )
            }
        }

        // Update items from TherapySettingItem format
        func updateFromTherapyItems(_ therapyItems: [TherapySettingItem]) {
            items = therapyItems.map { therapyItem in
                let timeIndex = timeValues.firstIndex(where: { abs($0 - therapyItem.time) < 1 }) ?? 0
                // Snap to the closest picker value — a value off the tiered grid must
                // not silently fall back to index 0 (the 9 mg/dL/U minimum)
                let rateIndex = rateValues.firstIndex(of: therapyItem.value)
                    ?? rateValues.findClosestIndex(to: therapyItem.value) ?? 0
                return Item(rateIndex: rateIndex, timeIndex: timeIndex)
            }
        }

        override func subscribe() {
            units = settingsManager.settings.units

            let profile = provider.profile

            // Sensitivities are mg/dL per *pumped* unit everywhere — stored,
            // shown, and used by oref. The caption carries the per-actual-unit
            // figure a prescription is written in.
            items = profile.sensitivities.map { value in
                let timeIndex = timeValues.firstIndex(of: Double(value.offset * 60)) ?? 0
                var rateIndex = rateValues.firstIndex(of: value.sensitivity)
                if rateIndex == nil {
                    // try to look up the closest value
                    if let min = rateValues.first, let max = rateValues.last {
                        if value.sensitivity >= (min - 1), value.sensitivity <= (max + 1) {
                            rateIndex = rateValues.findClosestIndex(to: value.sensitivity)
                        }
                    }
                }
                return Item(rateIndex: rateIndex ?? 0, timeIndex: timeIndex)
            }

            initialItems = items.map { Item(rateIndex: $0.rateIndex, timeIndex: $0.timeIndex) }
        }

        func add() {
            var time = 0
            var rate = 0
            if let last = items.last {
                time = last.timeIndex + 1
                rate = last.rateIndex
            }

            let newItem = Item(rateIndex: rate, timeIndex: time)

            items.append(newItem)
        }

        func save() {
            guard hasChanges else { return }
            shouldDisplaySaving.toggle()

            let sensitivities = items.map { item -> InsulinSensitivityEntry in
                let fotmatter = DateFormatter()
                fotmatter.timeZone = TimeZone(secondsFromGMT: 0)
                fotmatter.dateFormat = "HH:mm:ss"
                let date = Date(timeIntervalSince1970: self.timeValues[item.timeIndex])
                let minutes = Int(date.timeIntervalSince1970 / 60)
                // Displayed values are already per pumped unit: store as-is.
                let rate = self.rateValues[item.rateIndex]
                return InsulinSensitivityEntry(sensitivity: rate, offset: minutes, start: fotmatter.string(from: date))
            }
            let profile = InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: sensitivities
            )
            provider.saveProfile(profile)
            initialItems = items.map { Item(rateIndex: $0.rateIndex, timeIndex: $0.timeIndex) }

            DispatchQueue.main.async {
                self.broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) {
                    $0.insulinSensitivitiesDidChange(profile)
                }
            }

            Task.detached(priority: .low) {
                do {
                    debug(.nightscout, "Attempting to upload ISF to Nightscout")
                    try await self.nightscout.uploadProfiles()
                } catch {
                    debug(
                        .default,
                        "\(DebuggingIdentifiers.failed) Faile to upload ISF to Nightscout: \(error)"
                    )
                }
            }

            Task.detached(priority: .low) {
                await self.tidepoolManager.uploadSettings()
            }
        }

        func validate() {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    let uniq = Array(Set(self.items))
                    let sorted = uniq.sorted { $0.timeIndex < $1.timeIndex }
                    sorted.first?.timeIndex = 0
                    if self.items != sorted {
                        self.items = sorted
                    }
                    if self.items.isEmpty {
                        self.units = self.settingsManager.settings.units
                    }
                }
            }
        }
    }
}

extension ISFEditor.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
