import Foundation
import Observation
import SwiftUI

extension DeliveryCapEditor {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() private var storage: FileStorage!

        /// Displayed, entered and stored in pumped volume units — the same
        /// units the loop enforces the caps against.
        var windows: [DeliveryCapWindow] = []

        /// Stepper increment: the pump's own 0.05 U volume step, at every
        /// concentration — the caps are pumped volumes.
        var stepSize: Double { 0.05 }

        /// The actual insulin a shown pumped-volume cap carries, for the
        /// caption beneath it. nil at U-100.
        func actualInsulinCaption(forVolumeAmount amount: Decimal, unit: String) -> String? {
            settingsManager?.settings.actualInsulinCaption(forVolumeAmount: amount, unit: unit)
        }

        /// At least 10 pump-volume units, extended to cover the largest
        /// loaded value so caps rescaled by a
        /// concentration change stay in range — SwiftUI's Stepper clamps an
        /// out-of-range value into its bounds on the first tap, which would
        /// silently collapse (and auto-save) a safety cap.
        /// Snapshots from `load()`, not the live windows — a bound computed
        /// from the current values follows them downward, so a stepped-down cap
        /// could never be restored.
        private var largestLoadedBasalRate: Double = 0
        private var largestLoadedSMB: Double = 0

        var maxBasalUpperBound: Double {
            max(10, largestLoadedBasalRate)
        }

        var maxSMBUpperBound: Double {
            max(5, largestLoadedSMB)
        }

        override func subscribe() {
            load()
        }

        func load() {
            windows = storage.retrieve(OpenAPS.Settings.deliveryCaps, as: [DeliveryCapWindow].self) ?? []

            largestLoadedBasalRate = windows.map { Double(truncating: $0.maxBasalRate as NSDecimalNumber) }.max() ?? 0
            largestLoadedSMB = windows.map { Double(truncating: $0.maxSMB as NSDecimalNumber) }.max() ?? 0
        }

        func save() {
            // Shown values are already pumped volumes: store as-is.
            storage.save(windows, as: OpenAPS.Settings.deliveryCaps)
        }

        func addWindow() {
            // New windows default to "no insulin from the loop" — the primary use case.
            windows.append(DeliveryCapWindow(startMinutes: 0, endMinutes: 6 * 60, maxBasalRate: 0, maxSMB: 0))
            save()
        }

        func removeWindows(at offsets: IndexSet) {
            windows.remove(atOffsets: offsets)
            save()
        }
    }
}

extension DeliveryCapEditor.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {}
}
