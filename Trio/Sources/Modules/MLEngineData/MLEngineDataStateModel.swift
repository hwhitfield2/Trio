import Foundation
import Observation
import SwiftUI

extension MLEngineData {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() private var mlDataExporter: MLDataExporter!
        @ObservationIgnored @Injected() private var decisionAuditService: DecisionAuditService!

        var exportDaysBack = 90
        var isExporting = false
        var exportedFileURL: URL?
        var exportErrorMessage: String?
        var auditFileURLs: [URL] = []

        override func subscribe() {
            loadAuditFiles()
        }

        func loadAuditFiles() {
            // Newest first for the browser.
            auditFileURLs = decisionAuditService.auditFileURLs().reversed()
        }

        func exportTrainingData() {
            guard !isExporting else { return }
            isExporting = true
            exportedFileURL = nil
            exportErrorMessage = nil
            let daysBack = exportDaysBack
            Task { @MainActor in
                do {
                    let url = try await mlDataExporter.exportTrainingData(daysBack: daysBack)
                    exportedFileURL = url
                } catch {
                    exportErrorMessage = error.localizedDescription
                    debug(.apsManager, "ML training data export failed: \(error)")
                }
                isExporting = false
            }
        }
    }
}

extension MLEngineData.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {}
}
