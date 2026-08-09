import CoreData
import Foundation
import Observation
import SwiftUI

extension Insights {
    @Observable final class StateModel: BaseStateModel<Provider> {
        /// Analysis period in days (14 / 30 / 90). Transient UI state, not persisted.
        var selectedPeriodDays = 30 {
            didSet {
                guard selectedPeriodDays != oldValue else { return }
                runAnalysis()
            }
        }

        var cards: [InsightCard] = []
        var isAnalyzing = false
        var hasAnalyzed = false
        var units: GlucoseUnits = .mgdL

        /// Per-period result cache for the lifetime of this screen.
        @ObservationIgnored private var cache: [Int: [InsightCard]] = [:]

        @ObservationIgnored private let glucoseTaskContext = CoreDataStack.shared.newTaskContext()
        @ObservationIgnored private let carbsTaskContext = CoreDataStack.shared.newTaskContext()
        @ObservationIgnored private let determinationTaskContext = CoreDataStack.shared.newTaskContext()

        override func subscribe() {
            units = settingsManager.settings.units
            runAnalysis()
        }

        func runAnalysis(force: Bool = false) {
            Task {
                await analyze(force: force)
            }
        }

        @MainActor func analyze(force: Bool = false) async {
            // 90 days matches the Core Data purge window — nothing older exists.
            let periodDays = min(selectedPeriodDays, 90)
            if !force, let cached = cache[periodDays] {
                cards = cached
                hasAnalyzed = true
                isAnalyzing = false
                return
            }

            isAnalyzing = true
            let start = Date().addingTimeInterval(-Double(periodDays) * 24 * 60 * 60)

            var config = InsightsConfig()
            config.analysisWindowDays = periodDays
            // Use the user's own alarm thresholds for the hypo/hyper detectors.
            config.lowThreshold = Int(truncating: settingsManager.settings.lowGlucose as NSDecimalNumber)
            config.highThreshold = Int(truncating: settingsManager.settings.highGlucose as NSDecimalNumber)
            let units = units
            config.glucoseFormatter = { value in value.formatted(withUnits: units) }

            async let glucoseTask = fetchGlucose(since: start)
            async let carbsTask = fetchCarbs(since: start)
            async let determinationsTask = fetchDeterminations(since: start)

            let glucose = await glucoseTask
            let carbs = await carbsTask
            let determinations = await determinationsTask

            let result = await Task.detached(priority: .userInitiated) {
                InsightsEngine.analyze(
                    glucose: glucose,
                    carbs: carbs,
                    determinations: determinations,
                    config: config
                )
            }.value

            cache[periodDays] = result
            // If the user switched periods mid-analysis, keep the cached result but do not
            // publish it — the in-flight analysis for the new period will publish its own.
            guard periodDays == min(selectedPeriodDays, 90) else { return }
            cards = result
            hasAnalyzed = true
            isAnalyzing = false
        }

        // MARK: - Data fetching

        private func fetchGlucose(since start: Date) async -> [GlucoseSample] {
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
                    return fetched.compactMap { entry -> GlucoseSample? in
                        guard let date = entry["date"] as? Date,
                              let glucose = entry["glucose"] as? NSNumber
                        else { return nil }
                        return GlucoseSample(date: date, glucose: glucose.intValue)
                    }
                }
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to fetch glucose for insights: \(error)")
                return []
            }
        }

        private func fetchCarbs(since start: Date) async -> [CarbSample] {
            do {
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: CarbEntryStored.self,
                    onContext: carbsTaskContext,
                    predicate: NSPredicate(format: "date >= %@ AND isFPU == NO AND carbs > 0", start as NSDate),
                    key: "date",
                    ascending: true,
                    batchSize: 100,
                    propertiesToFetch: ["date", "carbs", "note"]
                )
                return try await carbsTaskContext.perform {
                    guard let fetched = results as? [[String: Any]] else {
                        throw CoreDataError.fetchError(function: #function, file: #file)
                    }
                    return fetched.compactMap { entry -> CarbSample? in
                        guard let date = entry["date"] as? Date,
                              let carbs = entry["carbs"] as? NSNumber
                        else { return nil }
                        return CarbSample(date: date, carbs: carbs.doubleValue, note: entry["note"] as? String)
                    }
                }
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to fetch carbs for insights: \(error)")
                return []
            }
        }

        private func fetchDeterminations(since start: Date) async -> [DeterminationSample] {
            do {
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: OrefDetermination.self,
                    onContext: determinationTaskContext,
                    predicate: NSPredicate(format: "deliverAt >= %@ AND enacted == YES", start as NSDate),
                    key: "deliverAt",
                    ascending: true,
                    batchSize: 100,
                    propertiesToFetch: ["deliverAt", "rate", "scheduledBasal"]
                )
                return try await determinationTaskContext.perform {
                    guard let fetched = results as? [[String: Any]] else {
                        throw CoreDataError.fetchError(function: #function, file: #file)
                    }
                    return fetched.compactMap { entry -> DeterminationSample? in
                        guard let date = entry["deliverAt"] as? Date else { return nil }
                        let rate = (entry["rate"] as? NSDecimalNumber).map { Double(truncating: $0) }
                        let scheduledBasal = (entry["scheduledBasal"] as? NSDecimalNumber)
                            .map { Double(truncating: $0) }
                        return DeterminationSample(date: date, rate: rate, scheduledBasal: scheduledBasal, enacted: true)
                    }
                }
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to fetch determinations for insights: \(error)")
                return []
            }
        }
    }
}
