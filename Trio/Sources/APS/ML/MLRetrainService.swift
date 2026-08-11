import CoreData
import Foundation

/// On-device retraining with a human-in-the-loop promotion gate.
///
/// Weekly (or on demand from the ML settings screen) this service rebuilds the
/// training set from Core Data, trains a candidate shadow-forecaster, and runs
/// a day-by-day walk-forward gate suite against persistence and the current
/// champion. Only a candidate that passes every gate is stored for review —
/// and even then it does nothing until a human explicitly promotes it.
/// Everything here is shadow-mode: no output can influence dosing.
final class MLRetrainService {
    static let shared = MLRetrainService()

    static let retrainIntervalDays = 7.0
    static let lastRetrainKey = "MLRetrainService.lastRetrainDate"
    /// Gates
    static let minWalkForwardSamples = 200
    /// A candidate must be validated across several distinct days, not one long day
    static let minWalkForwardDays = 3
    /// Compute bounds so year-scale history stays phone-friendly: folds test the
    /// most recent eligible days and training sets are capped to the newest samples
    static let maxWalkForwardTestDays = 14
    static let maxFoldTrainingSamples = 10000
    static let maxTrainingSamples = 25000
    static let minPriorSamplesPerDay = 80
    static let minLowRegionSamples = 20
    static let minChampionComparisonSamples = 48
    static let lowRegionThreshold = 120.0
    static let lowRegionTolerance = 1.10

    private let context = CoreDataStack.shared.newTaskContext()
    private var isRunning = false
    private let stateQueue = DispatchQueue(label: "MLRetrainService")

    private init() {}

    /// Called on app start; retrains at most once per week.
    func retrainIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastRetrainKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.retrainIntervalDays * 24 * 3600 else { return }
        retrainNow()
    }

    /// Builds a candidate and its gate report. Fire-and-forget; the outcome
    /// lands in MLModelStore (report always, candidate only if gates pass).
    func retrainNow(completion: (@Sendable(MLEvalReport?) -> Void)? = nil) {
        let shouldRun = stateQueue.sync { () -> Bool in
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
        guard shouldRun else { completion?(nil)
            return }

        Task(priority: .utility) {
            defer { self.stateQueue.sync { self.isRunning = false } }
            do {
                let report = try await self.run()
                UserDefaults.standard.set(Date(), forKey: Self.lastRetrainKey)
                completion?(report)
            } catch {
                debug(.apsManager, "ML retrain failed: \(error)")
                completion?(nil)
            }
        }
    }

    private func run() async throws -> MLEvalReport {
        let built = try await MLSampleBuilder.buildSamples(context: context)
        let samples = built.samples.sorted { $0.date < $1.date }

        let champion = MLModelStore.shared.activePromotedModel() ?? MLForecastService.bundledModel()
        let championVersion = champion.map { Int($0.modelVersion) ?? 0 } ?? 0
        let candidateVersion = max(championVersion, latestStoredVersion()) + 1
        let championTrainedThrough = championTrainedThroughDate()

        let evaluation = Self.walkForwardEvaluate(
            samples: samples,
            champion: champion,
            championTrainedThrough: championTrainedThrough
        )
        let (gates, passed) = Self.applyGates(evaluation: evaluation)

        let report = MLEvalReport(
            createdAt: Date(),
            candidateVersion: candidateVersion,
            trainedOnSamples: samples.count,
            walkForwardDays: evaluation.days,
            horizons: evaluation.horizons,
            gates: gates,
            passed: passed,
            invalidReadingsDropped: built.invalidReadingsDropped,
            skippedGap: built.skippedGap,
            skippedNoDetermination: built.skippedNoDetermination
        )
        MLModelStore.shared.saveRetrainReport(report)

        if passed {
            let ensembles = MLTrainer.train(samples: Array(samples.suffix(Self.maxTrainingSamples)))
            let model = MLForecastModel(
                modelVersion: String(candidateVersion),
                trainedOnSamples: samples.count,
                featureNames: MLForecastService.featureNames,
                horizons: Dictionary(uniqueKeysWithValues: ensembles.map { (String($0.key), $0.value) })
            )
            try MLModelStore.shared.saveCandidate(MLModelStore.Document(
                model: model,
                status: .candidate,
                createdAt: Date(),
                trainedThrough: samples.last?.date,
                statusChangedAt: nil,
                evalReport: report
            ))
            debug(.apsManager, "ML retrain: candidate v\(candidateVersion) passed gates, awaiting review")
        } else {
            debug(.apsManager, "ML retrain: gates failed, champion retained")
        }
        return report
    }

    private func latestStoredVersion() -> Int {
        MLModelStore.shared.allDocuments().map(\.versionNumber).max() ?? 0
    }

    private func championTrainedThroughDate() -> Date? {
        MLModelStore.shared.allDocuments()
            .first { $0.status == .promoted }?
            .trainedThrough
    }

    // MARK: - Walk-forward evaluation

    struct Evaluation {
        let days: Int
        let horizons: [String: MLEvalReport.HorizonEval]
        let championComparisonSamples: Int
    }

    static func walkForwardEvaluate(
        samples: [MLTrainer.Sample],
        champion: MLForecastModel?,
        championTrainedThrough: Date?
    ) -> Evaluation {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayOf: (MLTrainer.Sample) -> Date = { calendar.startOfDay(for: $0.date) }
        let days = Array(Set(samples.map(dayOf))).sorted()

        struct Scored {
            let date: Date
            let horizon: Int
            let features: [Double]
            let candidate: Double
            let persistence: Double
            let actual: Double
        }
        var scored: [Scored] = []
        var evaluatedDays = 0

        let eligibleDays = days.filter { day in
            samples.filter { dayOf($0) < day }.count >= minPriorSamplesPerDay
                && samples.contains { dayOf($0) == day }
        }
        for day in eligibleDays.suffix(maxWalkForwardTestDays) {
            let train = Array(samples.filter { dayOf($0) < day }.suffix(maxFoldTrainingSamples))
            let test = samples.filter { dayOf($0) == day }
            evaluatedDays += 1

            let ensembles = MLTrainer.train(samples: train)
            let foldModel = MLForecastModel(
                modelVersion: "fold",
                trainedOnSamples: train.count,
                featureNames: MLForecastService.featureNames,
                horizons: Dictionary(uniqueKeysWithValues: ensembles.map { (String($0.key), $0.value) })
            )
            for sample in test {
                for (horizon, actual) in sample.targets {
                    guard let predicted = foldModel.predict(features: sample.features, horizonMinutes: horizon)
                    else { continue }
                    scored.append(Scored(
                        date: sample.date,
                        horizon: horizon,
                        features: sample.features,
                        candidate: predicted,
                        persistence: sample.features[0],
                        actual: actual
                    ))
                }
            }
        }

        func mae<S: Sequence>(_ pairs: S) -> Double? where S.Element == (Double, Double) {
            var total = 0.0, n = 0
            for (a, b) in pairs { total += abs(a - b)
                n += 1 }
            return n > 0 ? total / Double(n) : nil
        }

        var horizons: [String: MLEvalReport.HorizonEval] = [:]
        var championSamples = 0
        // Champion is only scored on samples after its training cutoff —
        // comparing it on data it trained on would flatter it unfairly the
        // other way, and there is no honest score without a cutoff.
        for horizon in [30, 60] {
            let subset = scored.filter { $0.horizon == horizon }
            guard !subset.isEmpty else { continue }
            let low = subset.filter { $0.actual < lowRegionThreshold }

            var championMAE: Double?
            if let champion = champion, let cutoff = championTrainedThrough {
                let comparable = subset.filter { $0.date > cutoff }
                let championErrors: [(Double, Double)] = comparable.compactMap { item in
                    guard let p = champion.predict(features: item.features, horizonMinutes: horizon)
                    else { return nil }
                    return (p, item.actual)
                }
                if championErrors.count >= minChampionComparisonSamples {
                    championMAE = mae(championErrors)
                    championSamples = max(championSamples, championErrors.count)
                }
            }

            horizons[String(horizon)] = MLEvalReport.HorizonEval(
                candidateMAE: mae(subset.map { ($0.candidate, $0.actual) }) ?? 0,
                persistenceMAE: mae(subset.map { ($0.persistence, $0.actual) }) ?? 0,
                championMAE: championMAE,
                sampleCount: subset.count,
                lowRegionCandidateMAE: mae(low.map { ($0.candidate, $0.actual) }),
                lowRegionPersistenceMAE: mae(low.map { ($0.persistence, $0.actual) }),
                lowRegionSampleCount: low.count
            )
        }
        return Evaluation(days: evaluatedDays, horizons: horizons, championComparisonSamples: championSamples)
    }

    // MARK: - Gates (fail closed)

    static func applyGates(evaluation: Evaluation) -> ([MLEvalReport.GateResult], Bool) {
        var gates: [MLEvalReport.GateResult] = []

        let totalSamples = evaluation.horizons.values.map(\.sampleCount).max() ?? 0
        gates.append(MLEvalReport.GateResult(
            name: "minimum_samples",
            passed: totalSamples >= minWalkForwardSamples,
            detail: "\(totalSamples) walk-forward samples (need \(minWalkForwardSamples))"
        ))
        gates.append(MLEvalReport.GateResult(
            name: "minimum_days",
            passed: evaluation.days >= minWalkForwardDays,
            detail: "\(evaluation.days) walk-forward days (need \(minWalkForwardDays)) — one long day is not enough evidence"
        ))

        for (horizon, eval) in evaluation.horizons.sorted(by: { $0.key < $1.key }) {
            gates.append(MLEvalReport.GateResult(
                name: "beats_persistence_\(horizon)min",
                passed: eval.candidateMAE < eval.persistenceMAE,
                detail: String(format: "candidate %.1f vs persistence %.1f mg/dL", eval.candidateMAE, eval.persistenceMAE)
            ))

            if let lowCandidate = eval.lowRegionCandidateMAE,
               let lowPersistence = eval.lowRegionPersistenceMAE,
               eval.lowRegionSampleCount >= minLowRegionSamples
            {
                gates.append(MLEvalReport.GateResult(
                    name: "low_region_\(horizon)min",
                    passed: lowCandidate <= lowPersistence * lowRegionTolerance,
                    detail: String(
                        format: "below-120 MAE %.1f vs persistence %.1f (n=%d)",
                        lowCandidate, lowPersistence, eval.lowRegionSampleCount
                    )
                ))
            } else {
                gates.append(MLEvalReport.GateResult(
                    name: "low_region_\(horizon)min",
                    passed: true,
                    detail: "insufficient below-120 data (n=\(eval.lowRegionSampleCount)); check skipped — review with care"
                ))
            }

            if let championMAE = eval.championMAE {
                gates.append(MLEvalReport.GateResult(
                    name: "beats_champion_\(horizon)min",
                    passed: eval.candidateMAE <= championMAE,
                    detail: String(format: "candidate %.1f vs champion %.1f mg/dL", eval.candidateMAE, championMAE)
                ))
            } else {
                gates.append(MLEvalReport.GateResult(
                    name: "beats_champion_\(horizon)min",
                    passed: true,
                    detail: "champion has no post-training data to compare on; check skipped"
                ))
            }
        }

        return (gates, gates.allSatisfy(\.passed))
    }
}
