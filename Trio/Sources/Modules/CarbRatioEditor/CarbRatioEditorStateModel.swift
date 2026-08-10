import SwiftUI

extension CarbRatioEditor {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var nightscout: NightscoutManager!
        @Injected() private var tidepoolManager: TidepoolManager!
        @Injected() private var broadcaster: Broadcaster!
        @Published var items: [Item] = []
        @Published var initialItems: [Item] = []
        @Published var therapyItems: [TherapySettingItem] = []
        @Published var shouldDisplaySaving: Bool = false

        let timeValues = stride(from: 0.0, to: 1.days.timeInterval, by: 30.minutes.timeInterval).map { $0 }

        // Supports ratios up to 2000 g/U for very-low-dose regimens (e.g. LADA/
        // type 1.5 with residual insulin production). Tiered step sizes keep the
        // picker wheel responsive across that range: 0.1 g steps where typical
        // ratios live, coarser steps above, where the relative difference between
        // neighboring steps stays small. Kept as separate typed arrays — a single
        // chained expression exceeds the type-checker's budget.
        private static let fineRatios: [Decimal] = stride(from: 10.0, to: 300.0, by: 1.0)
            .map { ($0.decimal ?? .zero) / 10 } // 1.0-29.9 by 0.1
        private static let mediumRatios: [Decimal] = stride(from: 300.0, to: 500.0, by: 5.0)
            .map { ($0.decimal ?? .zero) / 10 } // 30.0-49.5 by 0.5
        private static let coarseRatios: [Decimal] = stride(from: 50.0, to: 100.0, by: 1.0)
            .map { $0.decimal ?? .zero } // 50-99 by 1
        private static let veryCoarseRatios: [Decimal] = stride(from: 100.0, to: 1001.0, by: 5.0)
            .map { $0.decimal ?? .zero } // 100-1000 by 5
        private static let ultraCoarseRatios: [Decimal] = stride(from: 1010.0, to: 2001.0, by: 10.0)
            .map { $0.decimal ?? .zero } // 1010-2000 by 10

        let rateValues: [Decimal] = StateModel.fineRatios + StateModel.mediumRatios +
            StateModel.coarseRatios + StateModel.veryCoarseRatios + StateModel.ultraCoarseRatios

        var canAdd: Bool {
            guard let lastItem = items.last else { return true }
            return lastItem.timeIndex < timeValues.count - 1
        }

        var hasChanges: Bool {
            if initialItems.count != items.count {
                return true
            }

            for (initialItem, currentItem) in zip(initialItems, items) {
                if initialItem.rateIndex != currentItem.rateIndex || initialItem.timeIndex != currentItem.timeIndex {
                    return true
                }
            }

            return false
        }

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
                // not silently fall back to index 0 (the 1 g/U minimum)
                let rateIndex = rateValues.firstIndex(of: therapyItem.value)
                    ?? rateValues.findClosestIndex(to: therapyItem.value) ?? 0
                return Item(rateIndex: rateIndex, timeIndex: timeIndex)
            }
        }

        override func subscribe() {
            items = provider.profile.schedule.map { value in
                let timeIndex = timeValues.firstIndex(of: Double(value.offset * 60)) ?? 0
                // Snap stored values that are off the tiered grid to the closest
                // picker value instead of silently defaulting to the 1 g/U minimum
                let rateIndex = rateValues.firstIndex(of: value.ratio)
                    ?? rateValues.findClosestIndex(to: value.ratio) ?? 0
                return Item(rateIndex: rateIndex, timeIndex: timeIndex)
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
            shouldDisplaySaving = true

            let schedule = items.enumerated().map { _, item -> CarbRatioEntry in
                let fotmatter = DateFormatter()
                fotmatter.timeZone = TimeZone(secondsFromGMT: 0)
                fotmatter.dateFormat = "HH:mm:ss"
                let date = Date(timeIntervalSince1970: self.timeValues[item.timeIndex])
                let minutes = Int(date.timeIntervalSince1970 / 60)
                let rate = self.rateValues[item.rateIndex]
                return CarbRatioEntry(start: fotmatter.string(from: date), offset: minutes, ratio: rate)
            }
            let profile = CarbRatios(units: .grams, schedule: schedule)
            provider.saveProfile(profile)
            initialItems = items.map { Item(rateIndex: $0.rateIndex, timeIndex: $0.timeIndex) }

            DispatchQueue.main.async {
                self.broadcaster.notify(CarbRatiosObserver.self, on: .main) {
                    $0.carbRatiosDidChange(profile)
                }
            }

            Task.detached(priority: .low) {
                do {
                    debug(.nightscout, "Attempting to upload CRs to Nightscout")
                    try await self.nightscout.uploadProfiles()
                } catch {
                    debug(.default, "Failed to upload CRs to Nightscout: \(error)")
                }
            }

            Task.detached(priority: .low) {
                await self.tidepoolManager.uploadSettings()
            }
        }

        func validate() {
            DispatchQueue.main.async {
                let uniq = Array(Set(self.items))
                let sorted = uniq.sorted { $0.timeIndex < $1.timeIndex }
                sorted.first?.timeIndex = 0
                if self.items != sorted {
                    self.items = sorted
                }
            }
        }
    }
}
