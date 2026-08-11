import Foundation
import Observation
import SwiftUI

extension DeliveryCapEditor {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() private var storage: FileStorage!

        /// Displayed in actual insulin units; stored in pumped volume units
        /// (the loop enforces the caps against pumped quantities).
        var windows: [DeliveryCapWindow] = []

        /// The concentration factor, or 1 before `configureView` has injected
        /// settingsManager — SwiftUI evaluates `body` (which reads the bounds
        /// and step below) before that happens.
        private var concentrationFactor: Double {
            settingsManager?.settings.insulinConcentrationFactor ?? 1
        }

        /// Stepper increment in actual insulin units — the pump's 0.05 U volume
        /// step carries proportionally less insulin when diluted (0.005 U at U-10).
        var stepSize: Double {
            0.05 * concentrationFactor
        }

        /// At least 10 pump-volume units expressed in actual insulin units,
        /// extended to cover the largest loaded value so caps rescaled by a
        /// concentration change stay in range — SwiftUI's Stepper clamps an
        /// out-of-range value into its bounds on the first tap, which would
        /// silently collapse (and auto-save) a safety cap.
        var maxBasalUpperBound: Double {
            let staticBound = 10 * concentrationFactor
            let largestLoaded = windows.map { Double(truncating: $0.maxBasalRate as NSDecimalNumber) }.max() ?? 0
            return max(staticBound, largestLoaded)
        }

        var maxSMBUpperBound: Double {
            let staticBound = 5 * concentrationFactor
            let largestLoaded = windows.map { Double(truncating: $0.maxSMB as NSDecimalNumber) }.max() ?? 0
            return max(staticBound, largestLoaded)
        }

        override func subscribe() {
            load()
        }

        func load() {
            let settings = settingsManager.settings
            windows = (storage.retrieve(OpenAPS.Settings.deliveryCaps, as: [DeliveryCapWindow].self) ?? [])
                .map { window in
                    var window = window
                    window.maxBasalRate = settings.realInsulinAmount(fromVolume: window.maxBasalRate)
                    window.maxSMB = settings.realInsulinAmount(fromVolume: window.maxSMB)
                    return window
                }
        }

        func save() {
            let settings = settingsManager.settings
            let stored = windows.map { window -> DeliveryCapWindow in
                var window = window
                window.maxBasalRate = settings.volumeInsulinAmount(fromReal: window.maxBasalRate)
                window.maxSMB = settings.volumeInsulinAmount(fromReal: window.maxSMB)
                return window
            }
            storage.save(stored, as: OpenAPS.Settings.deliveryCaps)
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
