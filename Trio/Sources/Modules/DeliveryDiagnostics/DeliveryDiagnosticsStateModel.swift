import Foundation
import Observation
import SwiftUI

extension DeliveryDiagnostics {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() private var exporter: DeliveryDiagnosticsExporter!

        var window: DeliveryDiagnosticsWindow = .twentyFourHours
        var isExporting = false
        var exportedFileURL: URL?
        var exportErrorMessage: String?

        func exportDiagnostics() {
            guard !isExporting else { return }
            isExporting = true
            exportedFileURL = nil
            exportErrorMessage = nil

            let selected = window
            Task { @MainActor in
                do {
                    exportedFileURL = try await exporter.export(window: selected)
                } catch {
                    exportErrorMessage = error.localizedDescription
                    debug(.apsManager, "\(DebuggingIdentifiers.failed) Delivery diagnostics export failed: \(error)")
                }
                isExporting = false
            }
        }
    }
}

extension DeliveryDiagnostics.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {}
}
