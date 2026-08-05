import CoreData
import Foundation

/// One scored oref forecast: what the algorithm predicted for a point in time vs what the CGM measured
struct ForecastAccuracyPoint: Identifiable {
    var id = UUID()
    /// Time the forecast was made (determination deliverAt)
    let decisionDate: Date
    /// Forecast horizon in minutes (30 or 60)
    let horizonMinutes: Int
    /// oref's predicted glucose for decisionDate + horizon (mg/dL)
    let predicted: Int
    /// Glucose at decision time — the persistence baseline forecast (mg/dL)
    let glucoseAtDecision: Int
    /// What the CGM actually measured at decisionDate + horizon (mg/dL)
    let actual: Int
    /// Whether carbs were on board when the forecast was made
    let hadCOB: Bool
    /// Shadow forecast from the bundled ML model, when one was recorded for this cycle (mg/dL)
    let mlPredicted: Int?

    var orefError: Int { abs(predicted - actual) }
    var persistenceError: Int { abs(glucoseAtDecision - actual) }
    var mlError: Int? { mlPredicted.map { abs($0 - actual) } }
}

/// Mean absolute forecast error for one situation at one horizon
struct ForecastAccuracyStats: Identifiable {
    let situation: ForecastSituation
    let horizonMinutes: Int
    let orefMAE: Double
    let persistenceMAE: Double
    /// Mean error of the shadow ML forecasts; nil when none were recorded in this window.
    /// Coverage can be partial, so compare against the mlSampleCount, not sampleCount.
    let mlMAE: Double?
    let sampleCount: Int
    let mlSampleCount: Int
    var id: String { "\(situation.rawValue)-\(horizonMinutes)" }
}

/// Situations a forecast can be scored under
enum ForecastSituation: String, CaseIterable, Identifiable {
    case all
    case carbsOnBoard
    case noCarbs
    case low
    case inRange
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return String(localized: "All")
        case .carbsOnBoard: return String(localized: "COB active")
        case .noCarbs: return String(localized: "No COB")
        case .low: return String(localized: "Below range")
        case .inRange: return String(localized: "In range")
        case .high: return String(localized: "Above range")
        }
    }
}

/// Per-day count of CGM delivery gaps long enough to trigger the stale-glucose alert
struct CGMGapStats: Identifiable {
    /// Start of day
    let day: Date
    /// Number of gaps between consecutive readings longer than the 12-minute staleness threshold
    let gapCount: Int
    /// Number of readings stored that day
    let readingCount: Int
    var id: Date { day }
}

extension Stat.StateModel {
    /// Staleness threshold used by APSManager's glucose validation (12 minutes)
    private static let staleThreshold: TimeInterval = 12 * 60
    /// Gaps longer than this are treated as the sensor being off, not delivery loss
    private static let sensorOffThreshold: TimeInterval = 6 * 60 * 60
    /// Matching tolerance when pairing a forecast target time with an actual CGM reading
    private static let matchTolerance: TimeInterval = 10 * 60

    /// Scores oref's stored forecast curves against actual glucose and computes CGM delivery gaps.
    /// Forecast curves are only retained for ~2 days (see TrioApp cleanup), so accuracy covers that window;
    /// gap statistics cover the last 7 days.
    func setupForecastStats() {
        Task {
            do {
                let (points, gaps) = try await calculateForecastStats()
                await MainActor.run {
                    self.forecastAccuracyPoints = points
                    self.forecastAccuracyStats = Self.aggregate(points: points, lowLimit: self.lowLimit, highLimit: self.highLimit)
                    self.cgmGapStats = gaps
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) failed to fetch forecast stats: \(error)")
            }
        }
    }

    private func calculateForecastStats() async throws -> ([ForecastAccuracyPoint], [CGMGapStats]) {
        let now = Date()
        let accuracyStart = now.addingTimeInterval(-2.days.timeInterval)
        let gapStart = now.addingTimeInterval(-7.days.timeInterval)

        async let determinationsResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: forecastTaskContext,
            predicate: NSPredicate(format: "deliverAt >= %@ AND forecasts.@count > 0", accuracyStart as NSDate),
            key: "deliverAt",
            ascending: true,
            relationshipKeyPathsForPrefetching: ["forecasts", "forecasts.forecastValues"]
        )

        async let mlForecastResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: MLForecastStored.self,
            onContext: forecastTaskContext,
            predicate: NSPredicate(format: "date >= %@", accuracyStart as NSDate),
            key: "date",
            ascending: true,
            propertiesToFetch: ["date", "horizonMinutes", "predicted"]
        )

        async let glucoseResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: forecastTaskContext,
            predicate: NSPredicate(format: "date >= %@ AND isManual == NO", gapStart as NSDate),
            key: "date",
            ascending: true,
            propertiesToFetch: ["date", "glucose"]
        )

        let (determinations, glucoseDicts, mlForecastDicts) = try await (determinationsResult, glucoseResult, mlForecastResult)

        return await forecastTaskContext.perform {
            let readings: [(date: Date, glucose: Int)] = (glucoseDicts as? [[String: Any]] ?? [])
                .compactMap { dict in
                    guard let date = dict["date"] as? Date, let glucose = dict["glucose"] as? Int16 else { return nil }
                    return (date, Int(glucose))
                }

            let gaps = Self.calculateGaps(readings: readings)

            // Shadow ML forecasts keyed by horizon, date-ascending
            var mlByHorizon: [Int: [(date: Date, predicted: Int)]] = [:]
            for dict in mlForecastDicts as? [[String: Any]] ?? [] {
                guard let date = dict["date"] as? Date,
                      let horizon = dict["horizonMinutes"] as? Int16,
                      let predicted = dict["predicted"] as? Int16 else { continue }
                mlByHorizon[Int(horizon), default: []].append((date, Int(predicted)))
            }

            guard let dets = determinations as? [OrefDetermination] else { return ([], gaps) }

            var points: [ForecastAccuracyPoint] = []
            for det in dets {
                guard let deliverAt = det.deliverAt,
                      let curve = Self.primaryForecastCurve(for: det),
                      let bgAtDecision = det.glucose.map({ Int(truncating: $0) })
                else { continue }

                for horizon in [30, 60] {
                    let index = horizon / 5
                    guard curve.count > index else { continue }
                    let targetDate = deliverAt.addingTimeInterval(TimeInterval(horizon * 60))
                    guard targetDate <= now,
                          let actual = Self.nearestReading(in: readings, to: targetDate, tolerance: Self.matchTolerance)
                    else { continue }

                    // ML shadow forecasts anchor on the CGM reading just before this decision
                    let mlPredicted = mlByHorizon[horizon]?
                        .filter { abs($0.date.timeIntervalSince(deliverAt)) <= 5 * 60 }
                        .min { abs($0.date.timeIntervalSince(deliverAt)) < abs($1.date.timeIntervalSince(deliverAt)) }?
                        .predicted

                    points.append(ForecastAccuracyPoint(
                        decisionDate: deliverAt,
                        horizonMinutes: horizon,
                        predicted: Int(curve[index]),
                        glucoseAtDecision: bgAtDecision,
                        actual: actual,
                        hadCOB: det.cob > 0,
                        mlPredicted: mlPredicted
                    ))
                }
            }
            return (points, gaps)
        }
    }

    /// The curve oref itself leans on: COB when carbs are on board, else UAM, else IOB
    private static func primaryForecastCurve(for determination: OrefDetermination) -> [Int32]? {
        let forecasts = determination.forecasts ?? []
        for type in ["cob", "uam", "iob"] {
            if let forecast = forecasts.first(where: { $0.type == type }) {
                let values = forecast.forecastValuesArray.map(\.value)
                if !values.isEmpty { return values }
            }
        }
        return nil
    }

    private static func nearestReading(
        in readings: [(date: Date, glucose: Int)],
        to target: Date,
        tolerance: TimeInterval
    ) -> Int? {
        // Binary search over the date-ascending readings
        var low = 0, high = readings.count - 1
        guard high >= 0 else { return nil }
        while low < high {
            let mid = (low + high) / 2
            if readings[mid].date < target { low = mid + 1 } else { high = mid }
        }
        var best: (interval: TimeInterval, glucose: Int)?
        for candidate in [low - 1, low] where candidate >= 0 && candidate < readings.count {
            let interval = abs(readings[candidate].date.timeIntervalSince(target))
            if interval <= tolerance, best == nil || interval < best!.interval {
                best = (interval, readings[candidate].glucose)
            }
        }
        return best?.glucose
    }

    private static func calculateGaps(readings: [(date: Date, glucose: Int)]) -> [CGMGapStats] {
        let calendar = Calendar.current
        var gapsByDay: [Date: Int] = [:]
        var readingsByDay: [Date: Int] = [:]

        for (index, reading) in readings.enumerated() {
            let day = calendar.startOfDay(for: reading.date)
            readingsByDay[day, default: 0] += 1
            guard index > 0 else { continue }
            let interval = reading.date.timeIntervalSince(readings[index - 1].date)
            if interval > staleThreshold, interval <= sensorOffThreshold {
                gapsByDay[day, default: 0] += 1
            }
        }

        return readingsByDay.keys.sorted().map { day in
            CGMGapStats(day: day, gapCount: gapsByDay[day] ?? 0, readingCount: readingsByDay[day] ?? 0)
        }
    }

    private static func aggregate(
        points: [ForecastAccuracyPoint],
        lowLimit: Decimal,
        highLimit: Decimal
    ) -> [ForecastAccuracyStats] {
        let low = Int(truncating: lowLimit as NSDecimalNumber)
        let high = Int(truncating: highLimit as NSDecimalNumber)

        func matches(_ point: ForecastAccuracyPoint, _ situation: ForecastSituation) -> Bool {
            switch situation {
            case .all: return true
            case .carbsOnBoard: return point.hadCOB
            case .noCarbs: return !point.hadCOB
            case .low: return point.glucoseAtDecision < low
            case .inRange: return point.glucoseAtDecision >= low && point.glucoseAtDecision <= high
            case .high: return point.glucoseAtDecision > high
            }
        }

        var stats: [ForecastAccuracyStats] = []
        for horizon in [30, 60] {
            for situation in ForecastSituation.allCases {
                let subset = points.filter { $0.horizonMinutes == horizon && matches($0, situation) }
                guard !subset.isEmpty else { continue }
                let mlErrors = subset.compactMap(\.mlError)
                stats.append(ForecastAccuracyStats(
                    situation: situation,
                    horizonMinutes: horizon,
                    orefMAE: Double(subset.map(\.orefError).reduce(0, +)) / Double(subset.count),
                    persistenceMAE: Double(subset.map(\.persistenceError).reduce(0, +)) / Double(subset.count),
                    mlMAE: mlErrors.isEmpty ? nil : Double(mlErrors.reduce(0, +)) / Double(mlErrors.count),
                    sampleCount: subset.count,
                    mlSampleCount: mlErrors.count
                ))
            }
        }
        return stats
    }
}
