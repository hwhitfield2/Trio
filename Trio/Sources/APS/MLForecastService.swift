import CoreData
import Foundation

/// Shadow-mode ML glucose forecaster.
///
/// Evaluates the bundled gradient-boosted tree model (`json/defaults/TrioMLForecaster.json`)
/// after each loop cycle and stores its +30/+60 minute forecasts so Statistics can compare
/// them retrospectively against oref and actual CGM readings.
///
/// This service is strictly observational: nothing it produces feeds back into
/// dosing decisions, and any failure is swallowed after logging.
final class MLForecastService {
    static let shared = MLForecastService()

    private let context = CoreDataStack.shared.newTaskContext()
    private lazy var model: MLForecastModel? = Self.loadBundledModel()

    /// Feature builder constants — these mirror the training pipeline (ml/train.py)
    /// and must not be changed independently of it.
    private enum TrainingParity {
        /// Tolerance when matching CGM lookback readings (ml/train.py CGM_TOLERANCE_S)
        static let cgmTolerance: TimeInterval = 6 * 60
        /// Maximum age of the determination supplying IOB/COB (DETERMINATION_MAX_AGE_S)
        static let determinationMaxAge: TimeInterval = 30 * 60
        /// Basal integration step (BasalSchedule.delivered_units step_s)
        static let integrationStep: TimeInterval = 300
        /// Only the last N carb entries before the anchor are considered (build_samples)
        static let carbEntryLookback = 8
    }

    private init() {}

    /// Computes and stores shadow forecasts for the most recent CGM reading.
    /// Fire-and-forget: called after each successful loop cycle.
    func recordShadowForecast() {
        Task(priority: .utility) {
            do {
                try await self.computeAndStore()
            } catch {
                debug(.apsManager, "ML shadow forecast skipped: \(error)")
            }
        }
    }

    private func computeAndStore() async throws {
        guard let model = model else {
            debug(.apsManager, "ML shadow forecast: no bundled model")
            return
        }
        guard let features = try await buildFeatures() else { return }

        // Skip if we already recorded forecasts for this reading
        let anchor = features.anchorDate
        let alreadyStored = try await context.perform {
            let request = MLForecastStored.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@", anchor as NSDate)
            request.fetchLimit = 1
            return try self.context.count(for: request) > 0
        }
        guard !alreadyStored else { return }

        let vector = features.vector
        try await context.perform {
            for horizon in [30, 60] {
                guard let predicted = model.predict(features: vector, horizonMinutes: horizon) else { continue }
                let stored = MLForecastStored(context: self.context)
                stored.id = UUID()
                stored.date = anchor
                stored.horizonMinutes = Int16(horizon)
                stored.predicted = Int16(max(39, min(401, Int(predicted.rounded()))))
                stored.modelVersion = model.modelVersion
            }
            guard self.context.hasChanges else { return }
            try self.context.save()
        }
    }

    // MARK: - Feature building (must mirror ml/train.py build_samples)

    private struct FeatureSet {
        let anchorDate: Date
        let vector: [Double]
    }

    private func buildFeatures() async throws -> FeatureSet? {
        let now = Date()
        let windowStart = now.addingTimeInterval(-5 * 60 * 60)

        async let glucoseResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@ AND isManual == NO", windowStart as NSDate),
            key: "date",
            ascending: true,
            propertiesToFetch: ["date", "glucose"]
        )
        async let determinationResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate(format: "deliverAt >= %@", windowStart as NSDate),
            key: "deliverAt",
            ascending: false,
            fetchLimit: 12
        )
        async let pumpEventResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(format: "timestamp >= %@", windowStart as NSDate),
            key: "timestamp",
            ascending: true
        )
        async let carbResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@", windowStart as NSDate),
            key: "date",
            ascending: true
        )

        let (glucoseDicts, determinations, pumpEvents, carbEntries) =
            try await (glucoseResult, determinationResult, pumpEventResult, carbResult)

        return await context.perform {
            let readings: [(date: Date, glucose: Double)] = (glucoseDicts as? [[String: Any]] ?? [])
                .compactMap { dict in
                    guard let date = dict["date"] as? Date, let glucose = dict["glucose"] as? Int16 else { return nil }
                    return (date, Double(glucose))
                }
            guard let latest = readings.last else { return nil }
            let anchor = latest.date

            func lookback(_ minutes: Double) -> Double? {
                let target = anchor.addingTimeInterval(-minutes * 60)
                var best: (interval: TimeInterval, glucose: Double)?
                for reading in readings {
                    let interval = abs(reading.date.timeIntervalSince(target))
                    if interval <= TrainingParity.cgmTolerance, best == nil || interval < best!.interval {
                        best = (interval, reading.glucose)
                    }
                }
                return best?.glucose
            }
            guard let bg5 = lookback(5), let bg15 = lookback(15), let bg30 = lookback(30) else { return nil }

            // Latest determination at or before the reading, like training's carry-forward
            guard let det = (determinations as? [OrefDetermination] ?? []).first(where: {
                guard let deliverAt = $0.deliverAt else { return false }
                return deliverAt <= anchor && anchor.timeIntervalSince(deliverAt) <= TrainingParity.determinationMaxAge
            }) else { return nil }

            // Delivered-basal segments from temp basal + suspend/resume events
            var segments: [(start: Date, end: Date, rate: Double)] = []
            var suspendStart: Date?
            for event in pumpEvents as? [PumpEventStored] ?? [] {
                guard let timestamp = event.timestamp else { continue }
                switch event.type {
                case PumpEventStored.EventType.tempBasal.rawValue:
                    if let temp = event.tempBasal {
                        let rate = temp.rate.map { Double(truncating: $0) } ?? 0
                        segments.append((timestamp, timestamp.addingTimeInterval(Double(temp.duration) * 60), rate))
                    }
                case PumpEventStored.EventType.pumpSuspend.rawValue:
                    suspendStart = timestamp
                case PumpEventStored.EventType.pumpResume.rawValue:
                    if let start = suspendStart {
                        segments.append((start, timestamp, 0))
                        suspendStart = nil
                    }
                default:
                    break
                }
            }
            segments.sort { $0.start < $1.start }

            func rate(at date: Date) -> Double {
                var current = 0.0
                for segment in segments {
                    if segment.start > date { break }
                    if segment.start <= date, date < segment.end { current = segment.rate }
                }
                return current
            }

            func deliveredUnits(from: Date, to: Date) -> Double {
                var total = 0.0
                var cursor = from
                while cursor < to {
                    let span = min(TrainingParity.integrationStep, to.timeIntervalSince(cursor))
                    total += rate(at: cursor) * span / 3600.0
                    cursor = cursor.addingTimeInterval(span)
                }
                return total
            }

            // Carbs entered in the trailing windows, capped to the last N entries as in training
            let pastCarbs = (carbEntries as? [CarbEntryStored] ?? [])
                .filter { ($0.date ?? .distantFuture) <= anchor }
                .suffix(TrainingParity.carbEntryLookback)
            func carbs(within seconds: TimeInterval) -> Double {
                pastCarbs
                    .filter { anchor.timeIntervalSince($0.date ?? .distantFuture) <= seconds }
                    .reduce(0) { $0 + $1.carbs }
            }

            // Time of day in UTC, matching the training pipeline's clock
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let components = calendar.dateComponents([.hour, .minute], from: anchor)
            let hour = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60.0

            let vector: [Double] = [
                latest.glucose,
                latest.glucose - bg5,
                latest.glucose - bg15,
                latest.glucose - bg30,
                det.iob.map { Double(truncating: $0) } ?? 0,
                Double(det.cob),
                det.sensitivityRatio.map { Double(truncating: $0) } ?? 1.0,
                rate(at: anchor),
                deliveredUnits(from: anchor.addingTimeInterval(-3600), to: anchor),
                carbs(within: 3600),
                carbs(within: 3 * 3600),
                sin(2 * Double.pi * hour / 24),
                cos(2 * Double.pi * hour / 24)
            ]
            return FeatureSet(anchorDate: anchor, vector: vector)
        }
    }

    private static func loadBundledModel() -> MLForecastModel? {
        guard let url = Foundation.Bundle.main.url(forResource: "json/defaults/TrioMLForecaster", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode(MLForecastModel.self, from: data)
        else {
            return nil
        }
        return model
    }
}

/// Bundled gradient-boosted tree ensemble, exported by ml/export_model.py.
/// Prediction = baseline + learningRate * Σ leaf values, one tree walk per estimator.
struct MLForecastModel: Decodable {
    struct Tree: Decodable {
        let childrenLeft: [Int]
        let childrenRight: [Int]
        let feature: [Int]
        let threshold: [Double]
        let value: [Double]
    }

    struct Ensemble: Decodable {
        let learningRate: Double
        let baseline: Double
        /// When set, the value of this feature is added to the ensemble output —
        /// used by delta models that predict the change from current glucose.
        let outputOffsetFeature: Int?
        let trees: [Tree]
    }

    let modelVersion: String
    let trainedOnSamples: Int
    let featureNames: [String]
    let horizons: [String: Ensemble]

    /// Evaluates the ensemble for the given horizon. Returns nil for unknown horizons
    /// or malformed trees rather than trapping.
    func predict(features: [Double], horizonMinutes: Int) -> Double? {
        guard let ensemble = horizons[String(horizonMinutes)],
              features.count == featureNames.count else { return nil }

        var total = ensemble.baseline
        if let offsetFeature = ensemble.outputOffsetFeature {
            guard offsetFeature >= 0, offsetFeature < features.count else { return nil }
            total += features[offsetFeature]
        }
        for tree in ensemble.trees {
            var node = 0
            while tree.childrenLeft[node] != -1 {
                guard node < tree.feature.count, tree.feature[node] >= 0,
                      tree.feature[node] < features.count else { return nil }
                node = features[tree.feature[node]] <= tree.threshold[node]
                    ? tree.childrenLeft[node]
                    : tree.childrenRight[node]
                guard node >= 0, node < tree.childrenLeft.count else { return nil }
            }
            total += ensemble.learningRate * tree.value[node]
        }
        return total
    }
}
