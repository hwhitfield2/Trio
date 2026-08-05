import Foundation
import Observation
import SwiftUI

extension DeliveryCapEditor {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() private var storage: FileStorage!

        var windows: [DeliveryCapWindow] = []

        override func subscribe() {
            load()
        }

        func load() {
            windows = storage.retrieve(OpenAPS.Settings.deliveryCaps, as: [DeliveryCapWindow].self) ?? []
        }

        func save() {
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
