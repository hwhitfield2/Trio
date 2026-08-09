import CoreData
import Foundation
import Observation
import SwiftUI

extension ClinicReport {
    @Observable final class StateModel: BaseStateModel<Provider> {
        /// Report period in days (14 / 30 / 90). Transient UI state, not persisted.
        var selectedPeriodDays = 14 {
            didSet {
                guard selectedPeriodDays != oldValue else { return }
                pdfFileURL = nil
                loadReportData()
            }
        }

        var reportData: AGPReportData?
        var isLoading = false
        var isGeneratingPDF = false
        var pdfFileURL: URL?
        var errorMessage: String?
        var units: GlucoseUnits = .mgdL

        private let glucoseTaskContext = CoreDataStack.shared.newTaskContext()
        private let tddTaskContext = CoreDataStack.shared.newTaskContext()
        private let carbsTaskContext = CoreDataStack.shared.newTaskContext()

        override func subscribe() {
            units = settingsManager.settings.units
            loadReportData()
        }

        func loadReportData() {
            isLoading = true
            // 90 days matches the Core Data purge window — nothing older exists.
            let periodDays = min(selectedPeriodDays, 90)
            let start = Date().addingTimeInterval(-Double(periodDays) * 24 * 60 * 60)

            Task {
                async let readingsTask = fetchGlucoseReadings(since: start)
                async let tddSamplesTask = fetchTDDSamples(since: start)
                async let carbSamplesTask = fetchCarbSamples(since: start)

                let readings = await readingsTask
                let tddSamples = await tddSamplesTask
                let carbSamples = await carbSamplesTask

                let data = AGPCalculator.calculate(
                    readings: readings,
                    periodDays: periodDays,
                    dailyTDDMeans: AGPCalculator.dailyMeans(of: tddSamples),
                    dailyCarbTotals: AGPCalculator.dailyTotals(of: carbSamples)
                )

                await MainActor.run {
                    self.reportData = data
                    self.isLoading = false
                }
            }
        }

        @MainActor func generatePDF() async {
            guard let data = reportData, !isGeneratingPDF else { return }
            isGeneratingPDF = true
            errorMessage = nil
            pdfFileURL = nil
            // Let the spinner appear before the (main-actor) render work starts.
            await Task.yield()
            do {
                pdfFileURL = try ClinicReportPDFRenderer.render(data: data, units: units)
            } catch {
                errorMessage = String(localized: "Could not generate the PDF report.")
                debug(.default, "\(DebuggingIdentifiers.failed) Clinic report PDF generation failed: \(error)")
            }
            isGeneratingPDF = false
        }

        // MARK: - Data fetching

        private func fetchGlucoseReadings(since start: Date) async -> [GlucoseReadingLite] {
            do {
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: GlucoseStored.self,
                    onContext: glucoseTaskContext,
                    predicate: NSPredicate(format: "date >= %@", start as NSDate),
                    key: "date",
                    ascending: true,
                    batchSize: 100,
                    propertiesToFetch: ["date", "glucose"]
                )
                return try await glucoseTaskContext.perform {
                    guard let fetched = results as? [[String: Any]] else {
                        throw CoreDataError.fetchError(function: #function, file: #file)
                    }
                    return fetched.compactMap { entry -> GlucoseReadingLite? in
                        guard let date = entry["date"] as? Date,
                              let glucose = entry["glucose"] as? NSNumber
                        else { return nil }
                        return GlucoseReadingLite(date: date, glucose: glucose.intValue)
                    }
                }
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to fetch glucose for clinic report: \(error)")
                return []
            }
        }

        /// TDD rows are rolling-24h samples written every ~5 minutes; the calculator
        /// turns them into per-day means before averaging.
        private func fetchTDDSamples(since start: Date) async -> [(date: Date, value: Double)] {
            do {
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: TDDStored.self,
                    onContext: tddTaskContext,
                    predicate: NSPredicate(format: "date >= %@", start as NSDate),
                    key: "date",
                    ascending: true,
                    batchSize: 100,
                    propertiesToFetch: ["date", "total"]
                )
                return try await tddTaskContext.perform {
                    guard let fetched = results as? [[String: Any]] else {
                        throw CoreDataError.fetchError(function: #function, file: #file)
                    }
                    return fetched.compactMap { entry -> (date: Date, value: Double)? in
                        guard let date = entry["date"] as? Date,
                              let total = entry["total"] as? NSDecimalNumber,
                              total.doubleValue > 0
                        else { return nil }
                        return (date: date, value: total.doubleValue)
                    }
                }
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to fetch TDD for clinic report: \(error)")
                return []
            }
        }

        private func fetchCarbSamples(since start: Date) async -> [(date: Date, value: Double)] {
            do {
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: CarbEntryStored.self,
                    onContext: carbsTaskContext,
                    predicate: NSPredicate(format: "date >= %@ AND isFPU == false", start as NSDate),
                    key: "date",
                    ascending: true,
                    batchSize: 100,
                    propertiesToFetch: ["date", "carbs"]
                )
                return try await carbsTaskContext.perform {
                    guard let fetched = results as? [[String: Any]] else {
                        throw CoreDataError.fetchError(function: #function, file: #file)
                    }
                    return fetched.compactMap { entry -> (date: Date, value: Double)? in
                        guard let date = entry["date"] as? Date,
                              let carbs = entry["carbs"] as? NSNumber
                        else { return nil }
                        return (date: date, value: carbs.doubleValue)
                    }
                }
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to fetch carbs for clinic report: \(error)")
                return []
            }
        }
    }
}
